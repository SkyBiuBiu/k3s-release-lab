# 02 · 部署 K3s 与 ingress-nginx

> 原始日志：[`../logs/03-install-deps.txt`](../logs/03-install-deps.txt)、[`../logs/04-install-k3s.txt`](../logs/04-install-k3s.txt)、
> [`../logs/05-verify-k3s.txt`](../logs/05-verify-k3s.txt)、[`../logs/13-fix-k8s-mirror.txt`](../logs/13-fix-k8s-mirror.txt)
> 对应脚本：[`../scripts/03-install-deps.sh`](../scripts/03-install-deps.sh)、[`../scripts/04-install-k3s.sh`](../scripts/04-install-k3s.sh)、
> [`../scripts/10-install-ingress-nginx.sh`](../scripts/10-install-ingress-nginx.sh)

勘测（见 [01 环境勘测](01-environment-probe.md)）暴露了两个镜像仓库的坑，这一步的核心就是**先把镜像加速配好，再装 K3s**。
顺序反了的话，K3s 装完会卡在 `ImagePullBackOff`。

---

## 一、补齐系统依赖

```bash
dnf -y install iptables-nft conntrack-tools socat tar openssl
```

| 包 | 为什么必需 |
|---|---|
| `iptables-nft` | kube-proxy 用 nftables 后端下发 Service 转发规则 |
| `conntrack-tools` | kube-proxy 需要 `conntrack` 命令清理连接跟踪表 |
| `socat` | K3s 的端口转发（port-forward）依赖它 |
| `tar` / `openssl` | K3s 安装脚本解包与证书生成 |

---

## 二、写镜像加速配置（关键步骤）

**必须在安装 K3s 之前**写好 `/etc/rancher/k3s/registries.yaml`：

```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
  registry.k8s.io:
    endpoint:
      - "https://k8s.m.daocloud.io"
```

**为什么两个都要配？**

- `docker.io` —— 勘测中 `index.docker.io` / `registry-1.docker.io` / `auth.docker.io` 全部 `000`，
  演示镜像 `hashicorp/http-echo` 就在这个仓库，不配就拉不下来。
- `registry.k8s.io` —— 这个更隐蔽：`/v2/` 握手是通的（返回 401），看着"没问题"，
  但真正请求 manifest 时它返回 **307 重定向**到 `*.pkg.dev`，而该域名被拒。
  所以 K3s 系统组件和 ingress-nginx 的镜像都拿不到。

> 排查过程留痕：第一次装 ingress-nginx 时控制器一直 `ImagePullBackOff`，
> 用下面的命令才定位到重定向问题：
> ```bash
> curl -sv --max-time 10 https://registry.k8s.io/v2/ 2>&1 | grep -Ei 'connected|SSL|HTTP/'
> # → TCP 通、TLS 通、HTTP/2 401 —— 单看这一步会误判为正常
> ```
> 补上 `registry.k8s.io` 的加速端点并重启 K3s 后，镜像立刻可拉。

---

## 三、安装 K3s

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.36.4+k3s1" \
  INSTALL_K3S_SYMLINK=force \
  INSTALL_K3S_NAME="" \
  INSTALL_K3S_EXEC="server \
      --disable traefik \
      --write-kubeconfig-mode 644 \
      --node-name k3s-lab \
      --kubelet-arg=fail-swap-on=false" \
  sh -s -
```

参数逐个说明：

| 参数 | 作用 | 为什么这么选 |
|---|---|---|
| `INSTALL_K3S_VERSION=v1.36.4+k3s1` | 锁定版本 | 勘测时 stable 通道的版本，避免安装过程中版本漂移 |
| `INSTALL_K3S_SYMLINK=force` | 强制创建 `kubectl`/`crictl` 等软链 | 方便直接敲 `kubectl` |
| `INSTALL_K3S_EXEC="server …"` | 传入 k3s server 的启动参数 | 见下行 |
| `--disable traefik` | **禁用内置 Traefik** | 本实验统一用 ingress-nginx 做入口。Traefik 也会占用 80/443，留着会冲突 |
| `--write-kubeconfig-mode 644` | kubeconfig 权限放宽 | 允许非 root 用户读取（实验便利性；生产环境应保持 600） |
| `--node-name k3s-lab` | 指定节点名 | 便于日志与文档对应 |
| `--kubelet-arg=fail-swap-on=false` | 允许 Swap 存在 | 该机有 2 GiB Swap，默认 kubelet 会拒绝启动 |

**关于 SELinux**：该机 SELinux 为 `Enforcing`。K3s 安装脚本会自动从 Rancher 源安装
`k3s-selinux`（实际装上的是 `el9` 版本的策略包）并加载策略，节点正常 `Ready`。

实测结论：**SELinux Enforcing 下 K3s 可以正常工作**，无需关闭。保持 Enforcing 更安全。

---

## 四、安装结果校验

```
# kubectl get nodes -o wide
NAME      STATUS   ROLES           AGE    VERSION        INTERNAL-IP       OS-IMAGE                        CONTAINER-RUNTIME
k3s-lab   Ready    control-plane   3m9s   v1.36.4+k3s1   192.168.100.128   Rocky Linux 10.0 (Red Quartz)   containerd://2.3.4-k3s1.36

# 系统组件
coredns-54996dc9b4-7h8n5                  1/1   Running   10.42.0.3   k3s-lab
local-path-provisioner-77b9867795-dzb4m   1/1   Running   10.42.0.2   k3s-lab
metrics-server-6dc596dfb8-bvgnw           1/1   Running   10.42.0.4   k3s-lab
```

> 注意：节点上**没有** Traefik Pod —— 这是 `--disable traefik` 生效的证据。

### 验证镜像加速是否真的生效

不能"看配置写了就算"，要实际拉一个镜像：

```bash
kubectl run mirror-test --image=hashicorp/http-echo:0.2.3 --restart=Never -- sleep 3600
kubectl describe pod mirror-test | sed -n '/Events:/,$p'
```

```
Normal  Scheduled  3s   Successfully assigned default/mirror-test to k3s-lab
Normal  Pulling    3s   Pulling image "hashicorp/http-echo:0.2.3"
Normal  Pulled     1s   Successfully pulled image "hashicorp/http-echo:0.2.3" in 1.941s
                        (1.941s including waiting). Image size: 1535358 bytes.
```

**1.941 秒拉取成功** —— 走的是 `docker.m.daocloud.io` 加速通道，加速配置确认生效。

---

## 五、部署 ingress-nginx

### 5.1 选型说明

| 候选 | 为什么没用 |
|---|---|
| K3s 内置 Traefik | 灰度要靠 `IngressRoute` / `TraefikService` 这类 CRD，偏离 K8s 原生 Ingress 语义 |
| **ingress-nginx** ✅ | 用**注解**即可表达按权重 / 请求头 / Cookie 灰度，与主流云上 Ingress 控制器语义一致，便于横向对照 |

### 5.2 应用清单

清单来自官方 baremetal 静态部署文件，因 `raw.githubusercontent.com` 不通，
已在本地下载并存入 `vendor/`：

```bash
kubectl apply -f /opt/k3s-release-lab/vendor/ingress-nginx-1.12.1.yaml
```

清单内含：

| 组件 | 镜像 |
|---|---|
| Controller | `registry.k8s.io/ingress-nginx/controller:v1.12.1` |
| 准入 Webhook 证书生成 Job | `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.2` |

### 5.3 暴露到宿主 80/443

baremetal 清单默认给的是 **NodePort**（30080/30443），访问要带端口号，不方便。
改成 `LoadBalancer` 后，K3s 自带的 **servicelb（klipper-lb）** 会起一个 DaemonSet，
用 `hostPort` 把 80/443 直接绑到宿主：

```bash
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p '{"spec":{"type":"LoadBalancer"}}'
```

生效后：

```
NAME                       TYPE           EXTERNAL-IP       PORT(S)
ingress-nginx-controller   LoadBalancer   192.168.100.128   80:31371/TCP,443:30492/TCP

# servicelb 自动创建的 DaemonSet
daemonset.apps/svclb-ingress-nginx-controller-bdb1c323   1/1/1
pod/svclb-ingress-nginx-controller-bdb1c323-5fnzh        2/2  Running
```

### 5.4 连通性验证

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1/
```

```
HTTP 404
```

**这个 404 是"正常"的**：`404` 是 ingress-nginx 在"控制器在线、但没有匹配到任何 Ingress 规则"时返回的默认后端响应。
如果控制器没起来，会是 `curl: (7) Failed to connect`。所以**看到 404 恰恰证明入口链路已经通了**。

---

## 六、本阶段的坑与对策汇总

| 现象 | 根因 | 对策 |
|---|---|---|
| K3s 组件 `ImagePullBackOff` | `docker.io` 完全不通 | `registries.yaml` 配 `docker.m.daocloud.io` |
| ingress-nginx 反复拉取失败 | `registry.k8s.io` 307 重定向到不可达的 `*.pkg.dev` | 追加 `registry.k8s.io` → `k8s.m.daocloud.io` |
| 准入 Job 卡住导致控制器起不来 | 上一条的连带后果（Job 拉不到 `kube-webhook-certgen`） | 修好镜像源后删除卡住的 Job 与 Pod，重新 apply |
| 重装后 80/443 仍不监听 | 重新 apply 清单把 Service 覆盖回 NodePort | 重新 patch 为 `LoadBalancer` |
| 无法在线下载清单 | `raw.githubusercontent.com` 不可达 | 本地下载 → 存入 `vendor/` → 上传目标机 |
