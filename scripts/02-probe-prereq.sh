#!/usr/bin/env bash
# 前置条件确认：k3s-selinux 包、GitHub raw、ingress-nginx 静态清单可达性
set -u
echo "===== A. k3s-selinux RPM 仓库（RHEL 系 SELinux 策略包）====="
curl -s -o /dev/null -w 'rpm.rancher.io/k3s-selinux -> %{http_code}\n' --max-time 8 https://rpm.rancher.io/k3s-selinux/stable/el10/noarch/
echo "--- 可用 el 版本目录 ---"
for v in el8 el9 el10; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://rpm.rancher.io/k3s-selinux/stable/$v/noarch/")
  echo "  $v -> ${code:-fail}"
done
echo "--- el9 目录内容样例 ---"
curl -s --max-time 8 https://rpm.rancher.io/k3s-selinux/stable/el9/noarch/ | grep -oE 'k3s-selinux-[0-9.\-]+\.el9\.noarch\.rpm' | tail -3
echo

echo "===== B. GitHub raw / 静态清单可达性 ====="
for u in \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/baremetal/deploy.yaml" \
  "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/baremetal/deploy.yaml" \
  "https://raw.githubusercontent.com/k3s-io/k3s/master/README.md" ; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u")
  echo "$(basename $(dirname $u))/$(basename $u) -> $code"
done
echo

echo "===== C. get.k3s.io 安装脚本头部校验 ====="
curl -s --max-time 10 https://get.k3s.io | head -5
echo

echo "===== D. 目标机当前时间/时区（用于日志对齐）====="
date --iso-8601=seconds
echo

echo "===== E. 系统包管理器可用性（devel 工具链，编译用）====="
for c in curl tar gzip openssl socat iptables conntrack; do
  if command -v "$c" >/dev/null 2>&1; then echo "FOUND: $c"; else echo "MISSING: $c"; fi
done
echo "--- dnf 可用性与源 ---"
dnf --version 2>/dev/null | head -2
ls /etc/yum.repos.d/ 2>/dev/null | head
