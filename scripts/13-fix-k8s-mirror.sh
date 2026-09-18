#!/usr/bin/env bash
# 修复 registry.k8s.io 不可用问题
#
# 现象：kubelet 拉 registry.k8s.io/ingress-nginx/* 失败，
#       报 dial tcp <pkg.dev 的 IP>:443: connect: connection refused
# 原因：registry.k8s.io 只是重定向器，manifest 请求会被 302 到 us-west2/asia-east1-docker.pkg.dev，
#       而 *.pkg.dev 在本网络被拒绝（curl /v2/ 能通，但真实拉取走的是 pkg.dev）。
# 解决：为 registry.k8s.io 增加国内镜像源（实测 k8s.m.daocloud.io 可完整代理该路径）
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "===== 1. 更新 containerd 镜像配置 ====="
cp -n /etc/rancher/k3s/registries.yaml /etc/rancher/k3s/registries.yaml.bak 2>/dev/null || true
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
  registry.k8s.io:
    endpoint:
      - "https://k8s.m.daocloud.io"
EOF
cat /etc/rancher/k3s/registries.yaml

echo
echo "===== 2. 重启 k3s 使 containerd 重新加载配置 ====="
systemctl restart k3s
for i in $(seq 1 40); do
  if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then echo "节点就绪（约 $((i*3)) 秒）"; break; fi
  sleep 3
done

echo
echo "===== 3. 清理失败的金丝雀初始化 Job 与卡住的控制器 Pod ====="
kubectl -n ingress-nginx delete job ingress-nginx-admission-create ingress-nginx-admission-patch --ignore-not-found
kubectl -n ingress-nginx delete pod -l app.kubernetes.io/component=controller --ignore-not-found --wait=false

echo
echo "===== 4. 重新下发清单（重建 Job）====="
kubectl apply -f /opt/k3s-release-lab/vendor/ingress-nginx-1.12.1.yaml 2>&1 | tail -8

echo
echo "===== 5. 等待 controller 就绪（最多 420s）====="
for i in $(seq 1 140); do
  ready=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller \
          -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
  if [ "$ready" = "true" ]; then echo "控制器就绪（约 $((i*3)) 秒）"; break; fi
  sleep 3
done

echo
echo "===== 6. 状态复核 ====="
kubectl -n ingress-nginx get pods -o wide
echo "--- 宿主 80/443 监听 ---"
ss -lntp 2>/dev/null | grep -E ':(80|443)\b' || echo "(未监听)"
echo "--- 连通性 ---"
curl -s -o /dev/null -w '  Host: web.lab.local -> HTTP %{http_code}\n' --max-time 8 -H 'Host: web.lab.local' http://127.0.0.1/
echo
echo "===== 7. 若仍失败，输出事件 ====="
if [ "$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" != "true" ]; then
  kubectl -n ingress-nginx describe pod -l app.kubernetes.io/component=controller 2>/dev/null | sed -n '/Events:/,$p' | tail -15
  kubectl -n ingress-nginx get pods 2>&1
fi
