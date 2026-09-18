#!/usr/bin/env bash
# K3S 集群状态复核（安装后基线）
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K=kubectl

echo "===== 1. 节点 ====="
$K get nodes -o wide

echo
echo "===== 2. 系统组件（k3s 自带）====="
$K get pods -n kube-system -o wide

echo
echo "===== 3. StorageClass / IngressClass ====="
echo "--- StorageClass ---"
$K get storageclass 2>&1
echo "--- IngressClass ---"
$K get ingressclass 2>&1

echo
echo "===== 4. Traefik 是否已禁用（应无输出）====="
$K get pods -n kube-system -l app.kubernetes.io/name=traefik 2>&1
$K get crd 2>/dev/null | grep -i traefik || echo "(traefik CRD absent -> 已禁用，端口 80/443 留给 ingress-nginx)"

echo
echo "===== 5. 内核转发与 iptables 规则 ====="
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables 2>/dev/null
echo "iptables 规则条数: $(iptables -S 2>/dev/null | wc -l)"
echo "--- kube-proxy 模式 ---"
$K get configmap -n kube-system kube-proxy -o jsonpath='{.data}' 2>/dev/null; echo

echo
echo "===== 6. 镜像加速生效验证（从 docker.io 拉小镜像）====="
$K run mirror-test --image=hashicorp/http-echo:0.2.3 --restart=Never --image-pull-policy=Always --command -- /http-echo -text=ok 2>&1
for i in $(seq 1 20); do
  st=$($K get pod mirror-test -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$st" = "Running" ] || [ "$st" = "Succeeded" ] || [ "$st" = "Failed" ] && break
  sleep 3
done
$K get pod mirror-test -o wide 2>&1
echo "--- 事件（截取镜像相关）---"
$K describe pod mirror-test 2>/dev/null | sed -n '/Events:/,$p' | head -15
$K delete pod mirror-test --force --grace-period=0 2>&1 | head -2

echo
echo "===== 7. 端口占用复核（80/443 应为空）====="
ss -lntp 2>/dev/null | grep -E ':(80|443)\b' || echo "(80/443 空闲，可供 ingress-nginx 使用)"
