#!/usr/bin/env bash
# ============================================================================
# 实验组二：通过 Ingress 实现蓝绿发布与灰度发布
#
# 入口统一为 ingress-nginx（宿主 80 端口，Host 头 web.lab.local）
# 四个场景：
#   A 蓝绿     —— 改 Ingress 后端 Service 名，原子切换
#   B 灰度·权重 —— canary 注解 + canary-weight，比例递进
#   C 灰度·请求头 —— canary-by-header，确定性定向
#   D 灰度·Cookie —— canary-by-cookie，粘性定向
# ============================================================================
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="kubectl"
NS=release-lab
ROOT=/opt/k3s-release-lab
HOSTHDR="Host: web.lab.local"
URL=http://127.0.0.1/

hr() { echo; echo "════════════════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════════════════"; }

probe() {
  local label="$1" n="${2:-50}"; shift 2
  local tmp; tmp=$(mktemp)
  for _ in $(seq 1 "$n"); do
    curl -s --max-time 3 -H "$HOSTHDR" "$@" "$URL" 2>/dev/null || echo "<ERR>"
    echo
  done > "$tmp"
  echo "  [$label] 发 ${n} 次请求："
  sort "$tmp" | uniq -c | while read -r c v; do
    pct=$(awk -v c="$c" -v n="$n" 'BEGIN{printf "%.1f", c*100/n}')
    printf '      %-30s %4d 次  %s%%\n' "$v" "$c" "$pct"
  done
  rm -f "$tmp"
}

show_ingress() {
  echo "  --- 当前 Ingress 与后端 ---"
  $K -n "$NS" get ingress -o custom-columns='NAME:.metadata.name,CANARY:.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary,WEIGHT:.metadata.annotations.nginx\.ingress\.kubernetes\.io/canary-weight,BACKEND:.spec.rules[0].http.paths[0].backend.service.name' 2>/dev/null
}

# ============================================================================
hr "0. 前置：控制器与后端 Service 就绪性检查"
echo "--- ingress-nginx 控制器 ---"
$K -n ingress-nginx get pods -l app.kubernetes.io/component=controller
echo "--- IngressClass ---"
$K get ingressclass
echo "--- 后端 Service 与端点 ---"
$K -n "$NS" get svc web-blue web-green
for s in web-blue web-green; do
  echo "  $s endpoints = $( $K -n "$NS" get endpoints "$s" -o jsonpath='{.subsets[*].addresses[*].ip}' )"
done
echo
echo "--- 控制器在线确认（无匹配 Ingress 时应返回 404）---"
curl -s -o /dev/null -w '    HTTP %{http_code}\n' --max-time 8 -H "$HOSTHDR" "$URL"

# ============================================================================
hr "场景 A：Ingress 层蓝绿发布"
$K apply -f "$ROOT/manifests/ingress-lab/30-ingress-bluegreen.yaml"
sleep 5
show_ingress
probe "发布前（后端=web-blue）" 50

echo
echo ">>> 执行发布：把 Ingress 后端从 web-blue 改成 web-green"
echo "    kubectl -n $NS patch ingress web --type=json \\"
echo "      -p '[{\"op\":\"replace\",\"path\":\"/spec/rules/0/http/paths/0/backend/service/name\",\"value\":\"web-green\"}]'"
$K -n "$NS" patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-green"}]'
sleep 5
show_ingress
probe "发布后（后端=web-green）" 50

echo
echo ">>> 回滚：后端改回 web-blue"
$K -n "$NS" patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-blue"}]'
sleep 5
probe "回滚后" 50
echo
echo "  ★ 与 Service 层蓝绿同构：切换点不同（selector → Ingress 后端），语义都是「原子全量」。"

# ============================================================================
hr "场景 B：Ingress 层灰度 —— 按权重 canary-weight"
$K apply -f "$ROOT/manifests/ingress-lab/31-ingress-canary-weight.yaml"
$K -n "$NS" delete job --ignore-not-found >/dev/null 2>&1 || true

for w in 20 50 80; do
  echo ">>> 设 canary-weight=${w}%"
  $K -n "$NS" annotate ingress web-canary --overwrite \
    nginx.ingress.kubernetes.io/canary-weight="${w}" >/dev/null
  sleep 5
  probe "weight=${w}%" 100
  echo
done

echo ">>> 收口：weight=100（等价于全量切到新版本）"
$K -n "$NS" annotate ingress web-canary --overwrite \
  nginx.ingress.kubernetes.io/canary-weight="100" >/dev/null
sleep 5
probe "weight=100%" 100
echo
echo "  ★ 现象：权重是「概率」而非「路由」，实测值会在配置值附近小幅波动，这是正常现象。"
echo "  ★ 优势：比例粒度可以是 1%，不受 Pod 数量限制（对比实验组一的分辨率问题）。"

# ============================================================================
hr "场景 C：Ingress 层灰度 —— 按请求头定向（确定性）"
$K apply -f "$ROOT/manifests/ingress-lab/32-ingress-canary-header.yaml"
sleep 5
show_ingress
echo
probe "不带 X-Canary 头" 30
probe "带 X-Canary: always" 30 -H "X-Canary: always"
probe "带 X-Canary: other" 30 -H "X-Canary: other"
echo
echo "  ★ 现象：带指定头的请求 100% 命中新版本，不带的一定命中旧版本 —— 这是「定向」而非「比例」。"
echo "  ★ 适用：内部测试账号、真机联调、指定客户端先行验证。"

# ============================================================================
hr "场景 D：Ingress 层灰度 —— 按 Cookie 定向（粘性）"
$K apply -f "$ROOT/manifests/ingress-lab/33-ingress-canary-cookie.yaml"
sleep 5
show_ingress
echo
probe "不带 Cookie" 30
probe "Cookie canary_user=always" 30 -b "canary_user=always"
probe "Cookie canary_user=never" 30 -b "canary_user=never"
echo
echo "  ★ 现象：浏览器带上该 Cookie 后，后续所有请求持续命中新版本，无需每次加头。"
echo "  ★ 适用：让一批用户长期停留在灰度版本上做观察式灰度。"
echo "  ★ 优先级：canary-by-header > canary-by-cookie > canary-weight"

# ============================================================================
hr "收尾：清理金丝雀 Ingress，恢复纯蓝基线"
$K -n "$NS" delete ingress web-canary --ignore-not-found
$K apply -f "$ROOT/manifests/ingress-lab/30-ingress-bluegreen.yaml" >/dev/null
sleep 4
show_ingress
probe "最终基线" 30
