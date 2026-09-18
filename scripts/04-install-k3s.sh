#!/usr/bin/env bash
# K3S 单节点集群安装
# 环境事实（由 00/01 探测得出）：
#   - docker.io 不可达 → 必须配置镜像加速，否则 k3s 自身镜像与演示镜像都拉不下来
#   - registry.k8s.io / quay.io / ghcr.io 可达 → 无需代理
#   - Traefik 由 k3s 默认安装，本实验统一使用 ingress-nginx，故 --disable traefik
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"

echo "===== 1. 写入 containerd 镜像加速配置 ====="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
EOF
cat /etc/rancher/k3s/registries.yaml

echo
echo "===== 2. SELinux 现状 ====="
getenforce

echo
echo "===== 3. 执行 K3S 官方安装脚本 ====="
echo "K3S_VERSION=${K3S_VERSION}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_SYMLINK=force \
  INSTALL_K3S_NAME="" \
  INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644 --node-name k3s-lab --kubelet-arg=fail-swap-on=false" \
  sh -s - 2>&1 | tail -30

echo
echo "===== 4. 服务状态 ====="
systemctl is-enabled k3s 2>&1 || true
systemctl is-active k3s 2>&1 || true

echo
echo "===== 5. 等待节点就绪（最多 180s）====="
for i in $(seq 1 60); do
  if /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    echo "节点 Ready（第 ${i} 次探测，约 $((i*3)) 秒）"
    break
  fi
  sleep 3
done

echo
echo "===== 6. 集群总览 ====="
/usr/local/bin/k3s kubectl get nodes -o wide 2>&1 || true
echo "--- 版本 ---"
/usr/local/bin/k3s --version 2>&1 || true
/usr/local/bin/k3s kubectl version 2>&1 | head -4 || true
echo "--- 全部 Pod ---"
/usr/local/bin/k3s kubectl get pods -A -o wide 2>&1 || true

echo
echo "===== 7. 若未就绪，输出诊断 ====="
if ! /usr/local/bin/k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
  echo "--- systemctl status k3s ---"
  systemctl status k3s --no-pager -l 2>&1 | tail -25
  echo "--- journalctl -u k3s ---"
  journalctl -u k3s --no-pager -n 60 2>&1 | tail -60
fi
