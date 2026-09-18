# 01 · 环境勘测记录

> 原始日志：[`../logs/00-probe.txt`](../logs/00-probe.txt)、[`../logs/01-probe-registry.txt`](../logs/01-probe-registry.txt)
> 对应脚本：[`../scripts/00-probe.sh`](../scripts/00-probe.sh)、[`../scripts/01-probe-registry.sh`](../scripts/01-probe-registry.sh)

动手前先摸清底细，避免"装到一半发现某个前提不成立"。勘测分四步：系统资源 → 网络出口 → 端口占用 → 镜像仓库可达性。

---

## 一、主机与系统

```
# 命令
hostname; uname -r; cat /etc/os-release; nproc; free -h; df -h /; getenforce

# 关键输出
localhost.localdomain
6.12.0-55.12.1.el10_0.x86_64
NAME="Rocky Linux"
VERSION="10.0 (Red Quartz)"
CPU(s): 4
Mem:  total 3.5Gi   used 487Mi   free 3.0Gi
/dev/mapper/rl-root   66G  2.4G   63G   4% /
Enforcing
```

| 项目 | 实测值 | 对实验的影响 |
|---|---|---|
| 发行版 | Rocky Linux 10.0 (Red Quartz)，`el10` | 需要 `el10` 的 SELinux 策略包，见下文 |
| 内核 | `6.12.0-55.12.1.el10_0.x86_64` | 满足 K3s 要求，`cgroup2fs` 已启用 |
| CPU / 内存 | 4 vCPU / 3.5 GiB（Swap 2 GiB，未使用） | 跑 10 个 http-echo Pod + ingress-nginx 绰绰有余 |
| 磁盘 | 66 GiB，仅用 4% | 充足 |
| SELinux | **`Enforcing`** | ⚠️ 关键项，见下文 |
| 网络 | `ens33` = `192.168.100.128/24`，网关 `192.168.100.2` | 实验访问地址 |
| 时间同步 | `Asia/Shanghai`，已同步 | 证书/日志时间可信 |

---

## 二、已有运行时与集群

```
absent: docker      absent: podman     absent: crictl
absent: ctr         absent: kubectl    absent: helm      absent: k3s
--- 相关 systemd 单元 ---
(none)
```

**结论**：这是一台"干净"的机器，没有任何容器运行时和 K8s 组件。
→ 不需要清理旧环境，K3s 会自带 containerd，直接装即可。

## 三、端口占用

```
80 / 443 / 6443 / 8080 → (these ports are free)
--- 防火墙 ---
inactive
inactive
--- iptables 规则条数 ---
0
```

**结论**：80 / 443 空闲 → ingress-nginx 可以直接抢占宿主端口做入口，不需要先杀掉别的 Web 服务。
防火墙未启用、iptables 无规则 → 不会有"服务起来了但外部访问不通"的假故障。

---

## 四、外网出口能力

```
https://get.k3s.io                        -> HTTP 200     ✅ K3s 安装脚本可下载
https://github.com                        -> HTTP 200     ✅
https://registry.cn-hangzhou.aliyuncs.com -> HTTP 401     ✅ 可达（401 = 需要认证，但网络通）
https://rancher-mirror.rancher.cn         -> HTTP 403     ⚠️ 国内 K3s 镜像站受限
https://pypi.tuna.tsinghua.edu.cn         -> HTTP 000     ❌ 清华 PyPI 源不通
```

**结论**：安装脚本走官方 `get.k3s.io` 即可，无需换国内镜像。

---

## 五、镜像仓库可达性（本实验最关键的一步）

判断标准：向 `/v2/` 发请求，返回 **401/200 = 网络可达**；返回 **000 = 不可达**。

```
===== 容器镜像仓库 v2 探测 =====
registry.k8s.io                  -> 401   ✅ 可达
index.docker.io                  -> 000   ❌ 不可达
registry-1.docker.io             -> 000   ❌ 不可达
quay.io                          -> 401   ✅ 可达
ghcr.io                          -> 401   ✅ 可达
registry.cn-hangzhou.aliyuncs.com -> 401  ✅ 可达
registry.cn-beijing.aliyuncs.com  -> 401  ✅ 可达
docker.m.daocloud.io             -> 401   ✅ 可达
docker.1ms.run                   -> 401   ✅ 可达
mirror.ccs.tencentyun.com        -> 000   ❌ 不可达（仅腾讯云内网可用）

===== 实际拉取 manifest 实测 =====
--- docker.io/hashicorp/http-echo ---
token -> 000      ❌ 连 token 端点都握不上手
--- registry.k8s.io ingress-nginx controller ---
token -> 307      ⚠️ 能连上，但是重定向
```

### 两个必须解决的坑

**坑 1：`docker.io` 完全不通**

`index.docker.io` / `registry-1.docker.io` / `auth.docker.io` 三个域名全部超时（000）。
这意味着**连演示镜像 `hashicorp/http-echo` 都拉不下来**，K3s 自身也有一部分镜像来自 docker.io。

→ 解决办法：配置 `registries.yaml` 镜像加速，走 `docker.m.daocloud.io`。

**坑 2：`registry.k8s.io` 是"重定向器"，实际内容在另一个域名**

`registry.k8s.io/v2/` 能握手（401），但请求具体镜像的 manifest 时返回 **307 重定向**，
目标域名是 `*.pkg.dev`（Google Artifact Registry），而该域名在此网络下 `connection refused`。

这就是后面 ingress-nginx 镜像反复拉取失败的真实根因 —— 表面看 `registry.k8s.io` 是通的，
实际内容却拿不到。

诊断命令与现象：

```bash
# 直接测 TLS 与重定向
curl -sv --max-time 10 https://registry.k8s.io/v2/ 2>&1 | grep -Ei 'connected|SSL|HTTP/'
```

```
* Connected to registry.k8s.io (...) port 443
* SSL connection using TLSv1.3
< HTTP/2 401
```

握手是通的，所以光看这一步会误判为"没问题"。必须再往下拉一个真实 manifest 才能暴露重定向问题。

→ 解决办法：给 `registry.k8s.io` 也配置加速，走 `k8s.m.daocloud.io`。

---

## 六、依赖包与前置条件

```
# 命令
rpm -q iptables conntrack-tools socat tar openssl
```

结果：**缺少** `iptables-nft`、`conntrack-tools`、`socat`、`tar`、`openssl`。
这些都是 K3s 的运行必需依赖（kube-proxy 需要 iptables/conntrack，网络插件需要 socat）。

同时 `raw.githubusercontent.com` 不可达 → ingress-nginx 的官方静态清单
（在 GitHub raw 上）无法在目标机直接下载。

**对策**：清单改由本地下载后上传，并保留在 [`../vendor/`](../vendor/) 目录中。

---

## 七、勘测结论汇总

| 结论 | 依据 | 后续动作 |
|---|---|---|
| 机器干净，无历史包袱 | 无 docker/podman/k8s | 直接装 K3s |
| K3s 版本选 stable | `update.k3s.io` 显示 stable = `v1.36.4+k3s1` | 锁定该版本 |
| **必须配镜像加速** | docker.io 全 000，registry.k8s.io 重定向到不可达域名 | 写 `registries.yaml`，两个仓库都加速 |
| 需补依赖 | 缺 iptables/conntrack/socat/tar/openssl | 装 `iptables-nft` 等 |
| 清单本地化 | raw.githubusercontent.com 不通 | 下载到 `vendor/` 再上传 |
| SELinux 保持 Enforcing | 安装脚本会自动装策略包，实测不影响 K3s 运行 | 不关闭，保持安全基线 |
| 80/443 可直接用 | 端口全空、防火墙关闭 | ingress-nginx 走 LoadBalancer 绑宿主端口 |
