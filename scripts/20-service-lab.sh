#!/usr/bin/env bash
# ============================================================================
# 实验组一：通过 Service 实现蓝绿发布与灰度发布
#
# 两个场景共用同一套工作负载，区别只在「入口 Service 的 selector」：
#   场景 A（蓝绿）：selector 带 version 标签 → 切换 = 全量切流
#   场景 B（灰度）：selector 不带 version 标签 → 两个版本共享后端，比例由副本数决定
# ============================================================================
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="kubectl"
NS=release-lab
ROOT=/opt/k3s-release-lab

hr() { echo; echo "════════════════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════════════════"; }

# 统计 N 次请求分别落到哪个版本
probe() {
  local label="$1" url="$2" n="${3:-50}"
  local tmp; tmp=$(mktemp)
  for _ in $(seq 1 "$n"); do
    curl -s --max-time 3 "$url" 2>/dev/null || echo "<ERR>"
    echo
  done > "$tmp"
  echo "  [$label] 发 ${n} 次请求："
  sort "$tmp" | uniq -c | while read -r c v; do
    pct=$(awk -v c="$c" -v n="$n" 'BEGIN{printf "%.1f", c*100/n}')
    printf '      %-30s %4d 次  %s%%\n' "$v" "$c" "$pct"
  done
  rm -f "$tmp"
}

# ============================================================================
hr "0. 部署基础工作负载"
$K apply -f "$ROOT/manifests/00-namespace.yaml"
$K apply -f "$ROOT/manifests/app/"
$K apply -f "$ROOT/manifests/service-lab/"
echo "--- 等待 rollout ---"
$K -n "$NS" rollout status deploy/web-blue  --timeout=180s
$K -n "$NS" rollout status deploy/web-green --timeout=180s
echo
echo "--- Pod 与版本标签 ---"
$K -n "$NS" get pods -o custom-columns='NAME:.metadata.name,POD-IP:.status.podIP,APP:.metadata.labels.app,VERSION:.metadata.labels.version,READY:.status.containerStatuses[0].ready' --sort-by=.metadata.labels.version
echo
echo "--- Service 一览（重点看 selector）---"
$K -n "$NS" get svc -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[0].port,NODEPORT:.spec.ports[0].nodePort,SELECTOR:.spec.selector'
echo
echo "--- 各 Service 的 Endpoints 数量 ---"
for s in web-blue web-green web-bg web-ratio; do
  eps=$($K -n "$NS" get endpoints "$s" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  cnt=$(echo "$eps" | wc -w)
  printf '  %-12s %s 个\n' "$s" "$cnt"
done

# ============================================================================
hr "场景 A：Service 层蓝绿发布  入口 = NodePort 30081 (svc/web-bg)"
echo
echo ">>> A1 基线：web-bg.selector = $( $K -n "$NS" get svc web-bg -o jsonpath='{.spec.selector}' )"
probe "基线" http://127.0.0.1:30081/ 50

echo
echo ">>> A2 执行发布：selector 整体切到 green"
echo "    kubectl -n $NS patch svc web-bg -p '{\"spec\":{\"selector\":{\"app\":\"web\",\"version\":\"green\"}}}'"
$K -n "$NS" patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
echo "    切换后 selector = $( $K -n "$NS" get svc web-bg -o jsonpath='{.spec.selector}' )"
echo "    切换后 endpoints = $( $K -n "$NS" get endpoints web-bg -o jsonpath='{.subsets[*].addresses[*].ip}' )"
sleep 2
probe "发布后" http://127.0.0.1:30081/ 50

echo
echo ">>> A3 回滚：selector 切回 blue"
$K -n "$NS" patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
sleep 2
probe "回滚后" http://127.0.0.1:30081/ 50
echo
echo "  ★ 现象：切换与回滚瞬时全量生效，不存在中间比例 —— 这是蓝绿的本质。"
echo "  ★ 代价：无观察期。新版本一旦有问题，受影响面直接是 100% 用户。"

# ============================================================================
hr "场景 B：Service 层灰度发布  入口 = NodePort 30082 (svc/web-ratio)"
echo "  web-ratio.selector = $( $K -n "$NS" get svc web-ratio -o jsonpath='{.spec.selector}' )"
echo "  → 两个版本同时是它的后端，流量占比 ≈ 副本数占比"
echo

scale_and_probe() {
  local b="$1" g="$2"
  echo ">>> 缩放 blue=${b} / green=${g}"
  $K -n "$NS" scale deploy/web-blue  --replicas="$b" >/dev/null
  $K -n "$NS" scale deploy/web-green --replicas="$g" >/dev/null
  $K -n "$NS" rollout status deploy/web-blue  --timeout=120s >/dev/null 2>&1
  $K -n "$NS" rollout status deploy/web-green --timeout=120s >/dev/null 2>&1
  sleep 4
  local eps; eps=$($K -n "$NS" get endpoints web-ratio -o jsonpath='{.subsets[*].addresses[*].ip}')
  echo "    后端 Pod 总数 = $(echo "$eps" | wc -w)"
  probe "blue=${b}:green=${g}" http://127.0.0.1:30082/ 100
  echo
}

echo ">>> B1  5:5  （初始 50/50）"
scale_and_probe 5 5
echo ">>> B2  9:1  （目标 ~10% 走新版本）"
scale_and_probe 9 1
echo ">>> B3  7:3  （目标 ~30%）"
scale_and_probe 7 3
echo ">>> B4  5:5  （目标 ~50%）"
scale_and_probe 5 5
echo ">>> B5  1:9  （目标 ~90%）"
scale_and_probe 1 9
echo ">>> B6  0:10 （收口，全量新版本）"
scale_and_probe 0 10

echo "  ★ 现象：比例只由副本数配比决定，不能指定精确权重。"
echo "  ★ 能力边界："
echo "      1) 分辨率 = 1/总副本数 —— 10 个 Pod 只能表达 10% 的整数倍"
echo "      2) kube-proxy 随机转发，短窗口实测值会在目标值附近波动"
echo "      3) 无法按请求头 / Cookie / 用户定向 —— 精细灰度必须上移到 Ingress"
echo "  ★ 结论：Service 层适合「粗粒度按比例」灰度；要精确权重与定向引流，看实验组二。"

# ============================================================================
hr "收尾：恢复到可复现基线（blue=5 / green=5，selector=blue）"
$K -n "$NS" patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"blue"}}}' >/dev/null
$K -n "$NS" scale deploy/web-blue  --replicas=5 >/dev/null
$K -n "$NS" scale deploy/web-green --replicas=5 >/dev/null
$K -n "$NS" rollout status deploy/web-blue  --timeout=120s >/dev/null 2>&1
$K -n "$NS" rollout status deploy/web-green --timeout=120s >/dev/null 2>&1
echo "  完成。"
