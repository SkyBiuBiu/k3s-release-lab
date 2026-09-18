# K3s 发布策略实验：Service 与 Ingress 实现蓝绿 / 灰度发布

在单节点 K3s 集群上，用**同一套工作负载**做两组对照实验，把「蓝绿发布」和「灰度发布」在
**Service 层**与 **Ingress 层**的实现方式、能力边界和适用场景彻底跑通。

> 一句话结论：**Service 层只能做「粗粒度按比例」的流量分配；要做精确权重、请求头 / Cookie 定向，
> 必须把切换点上移到 Ingress。**

---

## 一、实验环境

| 项目 | 内容 |
|---|---|
| 目标主机 | `192.168.100.128`（root，网卡 `ens33`，4 vCPU / 3.5 GiB / 66 GiB） |
| 操作系统 | Rocky Linux 10.0 (Red Quartz)，内核 `6.12.0-55.12.1.el10_0.x86_64`，SELinux `Enforcing` |
| 硬件规格 | 4 vCPU / 3.5 GiB 内存 / 66 GiB 磁盘 |
| 容器运行时 | 由 K3s 内置 containerd 提供（**宿主机无独立 Docker**） |
| K3s 版本 | `v1.36.4+k3s1`（单节点，`--disable traefik`） |
| Ingress 控制器 | ingress-nginx `1.12.1`（静态 baremetal 清单，改为 `LoadBalancer` 暴露） |
| 演示镜像 | `hashicorp/http-echo:0.2.3`（回显固定文本，便于区分版本） |
| 访问域名 | `web.lab.local`（用 `curl -H "Host: ..."` 模拟，无需改 hosts） |

### 网络约束与镜像加速（本实验最关键的坑）

探测发现目标机的出网能力是**不完整**的：

| 镜像仓库 | 可达性 | 结论 |
|---|---|---|
| `docker.io`（含 index / registry-1 / auth） | ❌ 全部超时 | **必须配镜像加速**，否则连演示镜像都拉不下来 |
| `registry.k8s.io` | ⚠️ 仅 API 可达 | 它只是**重定向器**，实际 manifest 302 到 `*.pkg.dev`，该域名被拒 → **也要加速** |
| `quay.io` / `ghcr.io` | ✅ | 可用 |
| `raw.githubusercontent.com` | ❌ | 清单文件改由本地下载后上传 |

因此 `registries.yaml` 必须同时为 `docker.io` 和 `registry.k8s.io` 配置加速端点，详见
[`docs/02-install-k3s-and-ingress.md`](docs/02-install-k3s-and-ingress.md)。

---

## 二、目录结构

```
k3s-release-lab/
├── README.md                      # 本文件：总览 + 快速复现
├── docs/
│   ├── 01-environment-probe.md    # 环境勘测记录（含原始探测输出）
│   ├── 02-install-k3s-and-ingress.md  # K3s 安装、镜像加速、ingress-nginx 部署
│   ├── 03-service-blue-green-canary.md # 实验组一：Service 蓝绿 + 灰度
│   └── 04-ingress-blue-green-canary.md # 实验组二：Ingress 蓝绿 + 灰度
├── manifests/
│   ├── 00-namespace.yaml          # release-lab 命名空间
│   ├── app/                       # 两个版本的工作负载 + 每版本一个 Service
│   │   ├── 10-deployment-blue.yaml
│   │   ├── 11-deployment-green.yaml
│   │   └── 12-service-per-version.yaml
│   ├── service-lab/               # 实验组一入口 Service
│   │   ├── 20-entry-bluegreen.yaml    # selector 带 version → 可整体切换（蓝绿）
│   │   └── 21-entry-canary.yaml       # selector 不带 version → 按副本比分配流量（灰度）
│   └── ingress-lab/               # 实验组二 Ingress 规则
│       ├── 30-ingress-bluegreen.yaml      # 改后端 Service 名 → 蓝绿
│       ├── 31-ingress-canary-weight.yaml  # canary-weight → 权重灰度
│       ├── 32-ingress-canary-header.yaml  # canary-by-header → 定向灰度
│       └── 33-ingress-canary-cookie.yaml  # canary-by-cookie → 粘性灰度
├── scripts/
│   ├── 00-probe.sh                # 系统 / 资源 / 网络 / 端口 勘测
│   ├── 01-probe-registry.sh       # 镜像仓库可达性逐个探测
│   ├── 02-probe-prereq.sh         # 依赖包与清单下载源探测
│   ├── 03-install-deps.sh         # 补齐 K3s 运行依赖
│   ├── 04-install-k3s.sh          # 安装 K3s（含镜像加速）
│   ├── 05-verify-k3s.sh           # 集群就绪校验 + 镜像加速验证
│   ├── 10-install-ingress-nginx.sh # 部署 ingress-nginx 并暴露宿主 80/443
│   ├── 12-probe-mirrors.sh        # 备用镜像源探测
│   ├── 13-fix-k8s-mirror.sh       # 修复 registry.k8s.io 加速
│   ├── 20-service-lab.sh          # 实验组一：一键跑完 Service 蓝绿 + 灰度
│   └── 30-ingress-lab.sh          # 实验组二：一键跑完 Ingress 四个场景
├── vendor/                        # 无法在线拉取的清单，本地留存
│   └── ingress-nginx-1.12.1.yaml
└── logs/                          # 每次执行的完整过程留痕
```

---

## 三、快速复现

按顺序执行即可，全程约 15 分钟。

```bash
# 0) 前置（脚本内会自带，此处仅列出实际命令）
#    假设已 root 登录目标机，且仓库已同步到 /opt/k3s-release-lab

# 1) 环境勘测（可选，用于留痕）
bash /opt/k3s-release-lab/scripts/00-probe.sh
bash /opt/k3s-release-lab/scripts/01-probe-registry.sh

# 2) 补齐依赖 + 安装 K3s
bash /opt/k3s-release-lab/scripts/03-install-deps.sh
bash /opt/k3s-release-lab/scripts/04-install-k3s.sh

# 3) 校验集群 + 镜像加速
bash /opt/k3s-release-lab/scripts/05-verify-k3s.sh

# 4) 部署 ingress-nginx（暴露宿主 80/443）
bash /opt/k3s-release-lab/scripts/10-install-ingress-nginx.sh

# 5) 实验组一：Service 蓝绿 + 灰度
bash /opt/k3s-release-lab/scripts/20-service-lab.sh

# 6) 实验组二：Ingress 蓝绿 + 灰度（4 个场景）
bash /opt/k3s-release-lab/scripts/30-ingress-lab.sh
```

> 从 Windows 侧同步代码到目标机（本实验使用的方式，供参考）：
> ```bash
> tar czf _upload.tgz --exclude=./logs --exclude=./.git -C k3s-release-lab .
> scp _upload.tgz root@192.168.100.128:/tmp/
> ssh root@192.168.100.128 "mkdir -p /opt/k3s-release-lab && tar xzf /tmp/_upload.tgz -C /opt/k3s-release-lab"
> ```

---

## 四、两组实验的核心结论对照

| 维度 | 实验组一：Service 层 | 实验组二：Ingress 层 |
|---|---|---|
| **蓝绿切换点** | `Service.spec.selector` 的 `version` 标签 | `Ingress.spec.rules[].http.paths[].backend.service.name` |
| **蓝绿粒度** | 全量、原子 | 全量、原子 |
| **灰度实现** | 靠**副本数配比**（selector 不带 `version`，两个版本共享后端） | `canary-weight` 注解 |
| **灰度粒度** | `1 / 总副本数`，10 个 Pod 只能表达 10% 的整数倍 | **1% 起任意精度**，与 Pod 数量无关 |
| **灰度精确性** | 概率性，短窗口波动明显 | 概率性，但配置即权重，波动更小 |
| **定向能力** | ❌ 无（无法按请求头 / Cookie / 用户） | ✅ 请求头、Cookie 均可定向 |
| **回滚成本** | 改 selector / 改副本数 | 改一个注解或删掉 canary Ingress |
| **额外依赖** | 无，纯原生对象 | 依赖具体 Ingress 控制器的注解扩展（非 K8s 标准） |

**选型建议**

1. **只需要「新版本全量替换」** → Service 层蓝绿，最简单、零依赖、语义清晰。
2. **需要「先放一小股流量试水，且比例要细」** → Ingress 层 `canary-weight`。
3. **需要「指定测试账号 / 真机联调先走新版本」** → Ingress 层 `canary-by-header`（确定性，不影响真实用户）。
4. **需要「让一批用户长期停在灰度版本做观察」** → Ingress 层 `canary-by-cookie`（粘性，浏览器自动保持）。
5. **跨控制器可移植性优先** → 权重灰度用 Ingress，但要知道 `canary-*` 是 **ingress-nginx 私有注解**；
   换控制器（Traefik / APISIX / 云厂商 Ingress）需要改用各自的 CRD 或注解，语义会变。

---

## 五、过程留痕

每次脚本执行的完整输出（含每条命令与其实际现象）都保存在 `logs/` 下，
文档中的现象表格均直接取自这些原始日志，未做二次修饰。
