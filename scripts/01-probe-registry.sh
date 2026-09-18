#!/usr/bin/env bash
# 镜像仓库与 K3S 发行版可达性探测（只读）
set -u
echo "===== A. k3s 版本通道 ====="
curl -s --max-time 10 https://update.k3s.io/v1-release/channels | head -40
echo
echo "--- stable 通道解析 ---"
curl -s --max-time 10 https://update.k3s.io/v1-release/channels/stable | head -5
echo

echo "===== B. 容器镜像仓库 v2 探测（401/200 = 可达；000 = 不可达）====="
for r in registry.k8s.io index.docker.io registry-1.docker.io quay.io ghcr.io \
         registry.cn-hangzhou.aliyuncs.com registry.cn-beijing.aliyuncs.com \
         docker.m.daocloud.io docker.1ms.run mirror.ccs.tencentyun.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$r/v2/" 2>/dev/null)
  echo "$r -> ${code:-fail}"
done
echo

echo "===== C. GitHub Releases 可达（k3s 二进制下载源）====="
curl -s -o /dev/null -w 'github api -> %{http_code}\n' --max-time 8 https://api.github.com/repos/k3s-io/k3s/releases/latest
curl -s -o /dev/null -w 'objects.githubusercontent -> %{http_code}\n' --max-time 8 https://objects.githubusercontent.com/
echo

echo "===== D. 拉取 manifest 实测（小体积）====="
echo "--- docker.io/hashicorp/http-echo ---"
curl -s -o /dev/null -w 'token -> %{http_code}\n' --max-time 8 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:hashicorp/http-echo:pull"
echo "--- registry.k8s.io ingress-nginx controller ---"
curl -s -o /dev/null -w 'token -> %{http_code}\n' --max-time 8 "https://registry.k8s.io/v2/ingress-nginx/controller/manifests/v1.11.2"
