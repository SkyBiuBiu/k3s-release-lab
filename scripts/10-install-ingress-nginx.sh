#!/usr/bin/env bash
# 安装 ingress-nginx 作为 Ingress 实验的入口控制器
#
# 选型说明：
#   k3s 默认内置 Traefik，但 Traefik 的灰度需要 IngressRoute/TraefikService 这类 CRD，
#   而 ingress-nginx 用注解即可表达"按权重/请求头/Cookie"的灰度，语义更贴近 K8s 原生 Ingress，
#   也便于与主流云上 Ingress 控制器对照。因此安装时已 --disable traefik。
#
# 暴露方式：
#   baremetal 清单默认用 NodePort（30080/30443）；改成 LoadBalancer 后，
#   k3s 自带的 servicelb(klipper) 会把 svc 端口 80/443 直接绑到宿主，方便直接访问。
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
MANIFEST="${1:-/opt/k3s-release-lab/vendor/ingress-nginx-1.12.1.yaml}"

echo "===== 1. 应用 ingress-nginx 官方静态清单 ====="
echo "清单路径: $MANIFEST"
kubectl apply -f "$MANIFEST" 2>&1 | tail -25

echo
echo "===== 2. 等待 controller 就绪（最多 300s）====="
kubectl -n ingress-nginx wait --for=condition=Ready \
  pod -l app.kubernetes.io/component=controller --timeout=300s 2>&1 || true

echo
echo "===== 3. 暴露为 LoadBalancer（k3s servicelb 绑定宿主 80/443）====="
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p '{"spec":{"type":"LoadBalancer"}}' 2>&1

for i in $(seq 1 20); do
  ip=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$ip" ]; then echo "LoadBalancer 已分配地址: $ip (第 ${i} 次探测)"; break; fi
  sleep 3
done

echo
echo "===== 4. 状态复核 ====="
echo "--- Pod ---"
kubectl -n ingress-nginx get pods -o wide
echo "--- Service ---"
kubectl -n ingress-nginx get svc
echo "--- IngressClass ---"
kubectl get ingressclass
echo "--- 宿主 80/443 监听 ---"
ss -lntp 2>/dev/null | grep -E ':(80|443)\b' || echo "(未监听)"
echo "--- servicelb DaemonSet ---"
kubectl -n kube-system get ds 2>&1 | head -5

echo
echo "===== 5. 控制器版本与入口连通性 ====="
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
  /nginx-ingress-controller --version 2>&1 | head -6 || true
echo "--- 裸访问（无 Host 头，预期 404，说明控制器在线）---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 http://127.0.0.1/ || true
echo "--- 带 Host 头（Ingress 尚未创建，预期 404）---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 -H 'Host: web.lab.local' http://127.0.0.1/ || true
