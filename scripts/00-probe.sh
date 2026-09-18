#!/usr/bin/env bash
# 目标机环境采集（只读，不修改任何配置）
set -u
echo "===== 1. 主机与系统 ====="
hostname
uname -a
echo "--- os-release ---"
cat /etc/os-release 2>/dev/null

echo
echo "===== 2. 资源 ====="
echo "--- CPU ---"
nproc
lscpu 2>/dev/null | grep -E '^Model name|^CPU\(s\)|^Architecture' | head -5
echo "--- 内存 ---"
free -h
echo "--- 磁盘 ---"
df -h / /var 2>/dev/null
echo "--- swap ---"
swapon --show 2>/dev/null || echo "(no swap)"

echo
echo "===== 3. 网络 ====="
ip -brief addr 2>/dev/null || ifconfig -a 2>/dev/null | head -30
echo "--- 默认路由 ---"
ip route 2>/dev/null | head -5
echo "--- DNS ---"
cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | head -5

echo
echo "===== 4. 已有运行时/集群 ====="
for c in docker podman crictl ctr kubectl helm k3s containerd nerdctl; do
  if command -v "$c" >/dev/null 2>&1; then echo "FOUND: $c -> $(command -v $c)"; else echo "absent: $c"; fi
done
echo "--- 相关 systemd 单元 ---"
systemctl list-units --type=service --all 2>/dev/null | grep -Ei 'k3s|docker|containerd|kubelet|traefik' || echo "(none)"

echo
echo "===== 5. 端口占用（80/443/6443/8080）====="
(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep -E ':(80|443|6443|8080|30080|30443)\b' || echo "(these ports are free)"

echo
echo "===== 6. 安全与防护 ====="
echo "--- SELinux ---"
getenforce 2>/dev/null || echo "(no getenforce)"
echo "--- 防火墙 ---"
systemctl is-active firewalld 2>/dev/null || true
systemctl is-active iptables 2>/dev/null || true
firewall-cmd --state 2>/dev/null || true
echo "--- iptables 规则条数 ---"
iptables -S 2>/dev/null | wc -l

echo
echo "===== 7. 外网出口检测 ====="
for u in https://get.k3s.io https://rancher-mirror.rancher.cn https://registry.cn-hangzhou.aliyuncs.com/v2/ https://pypi.tuna.tsinghua.edu.cn/simple/ https://github.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null)
  echo "$u -> HTTP ${code:-fail}"
done

echo
echo "===== 8. 内核模块与 cgroup ====="
echo "cgroup version: $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
lsmod 2>/dev/null | grep -E 'overlay|br_netfilter|nf_conntrack' || echo "(modules not loaded)"
echo "--- kernel parameters ---"
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward 2>/dev/null

echo
echo "===== 9. 时间同步 ====="
timedatectl 2>/dev/null | head -5 || date
