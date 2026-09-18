#!/usr/bin/env bash
# 安装 K3S 运行依赖（Rocky Linux 10 最小化安装缺失项）
set -u
echo "===== 安装前状态 ====="
for c in iptables conntrack socat tar openssl iptables-legacy; do
  printf '%-16s %s\n' "$c" "$(command -v $c || echo MISSING)"
done

echo
echo "===== dnf makecache（验证软件源可达）====="
dnf -q makecache 2>&1 | tail -5
echo "makecache rc=$?"

echo
echo "===== 安装依赖包 ====="
dnf -y install iptables conntrack-tools socat tar openssl 2>&1 | tail -25

echo
echo "===== 安装后校验 ====="
for c in iptables ct conntrack socat tar openssl; do
  printf '%-16s %s\n' "$c" "$(command -v $c || echo STILL-MISSING)"
done
echo
echo "--- iptables 版本与规则表可读性 ---"
iptables --version
iptables -t nat -L -n 2>&1 | head -5
echo
echo "--- nft 后端确认 ---"
update-alternatives --list iptables 2>/dev/null || true
iptables-nft --version 2>/dev/null || true
