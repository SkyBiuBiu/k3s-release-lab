#!/usr/bin/env bash
# 探测可用的 ingress-nginx 镜像源
# 背景：registry.k8s.io 会把 manifest 请求 302 到 *.pkg.dev，而 pkg.dev 被防火墙拒绝，
#       因此必须找到一个能代理 registry.k8s.io 路径的国内镜像站。
set -u
PULL="k3s ctr -n k8s.io images pull --platform linux/amd64"
IMG_CTRL="ingress-nginx/controller:v1.12.1"
IMG_CERT="ingress-nginx/kube-webhook-certgen:v1.5.2"

try() {
  local ref="$1"
  printf '%-95s ' "$ref"
  if timeout 75 $PULL "$ref" >/tmp/pull.log 2>&1; then
    echo "OK"
    return 0
  else
    echo "FAIL  ($(grep -oiE 'connection refused|no such host|401 Unauthorized|403|not found|denied|timeout|i/o timeout|unexpected status' /tmp/pull.log | head -1))"
    return 1
  fi
}

echo "===== A. controller 镜像 · 候选源 ====="
try "k8s.m.daocloud.io/$IMG_CTRL"
try "registry.cn-hangzhou.aliyuncs.com/google_containers/ingress-nginx-controller:v1.12.1"
try "docker.m.daocloud.io/$IMG_CTRL"
try "docker.1ms.run/kubernetes/ingress-nginx/controller:v1.12.1"
try "swr.cn-north-4.myhuaweicloud.com/ddn-k8s/registry.k8s.io/$IMG_CTRL"

echo
echo "===== B. 已成功拉取的本地镜像 ====="
k3s ctr -n k8s.io images ls -q | grep -iE 'ingress|nginx' || echo "(none)"
