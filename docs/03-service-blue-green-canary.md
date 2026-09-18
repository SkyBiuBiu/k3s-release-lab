# 03 · 实验组一：通过 Service 实现蓝绿发布与灰度发布

> 原始日志：[`../logs/20-service-lab.txt`](../logs/20-service-lab.txt)
> 一键复现：[`../scripts/20-service-lab.sh`](../scripts/20-service-lab.sh)
> 相关清单：[`../manifests/app/`](../manifests/app/)、[`../manifests/service-lab/`](../manifests/service-lab/)

---

## 一、实验设计

本组实验的全部机关都在 **一个 Service 的 `spec.selector` 怎么写**上。两个场景共用同一套工作负载。

### 标签体系（整套实验的地基）

| 标签 | 取值 | 语义 |
|---|---|---|
| `app: web` | 固定 | "属于同一个应用" —— 决定哪些 Pod 算同一批流量池 |
| `version` | `blue` / `green` | "属于哪个版本" —— 决定蓝绿切换的着力点 |

```
Deployment web-blue   → Pod labels: app=web, version=blue    (5 副本, 返回 "BLUE v1.0 (stable)")
Deployment web-green  → Pod labels: app=web, version=green   (5 副本, 返回 "GREEN v2.0 (canary)")
```

### 两个入口 Service 的差异

| Service | selector | 命中的后端 | 用于 |
|---|---|---|---|
| `web-bg`（NodePort 30081） | `app=web, version=blue` | **只有一个版本** | 场景 A：蓝绿 |
| `web-ratio`（NodePort 30082） | `app=web`（**故意不带 version**） | **两个版本都在** | 场景 B：灰度 |

准备的 Deployment 之外，还有两个 ClusterIP Service（`web-blue` / `web-green`）只选中各自版本，
它们是实验组二 Ingress 的后端，本组不使用。

### 基线状态

```
NAME        TYPE        PORT   NODEPORT   SELECTOR
web-bg      NodePort    80     30081      map[app:web version:blue]
web-blue    ClusterIP   80     <none>     map[app:web version:blue]
web-green   ClusterIP   80     <none>     map[app:web version:green]
web-ratio   NodePort    80     30082      map[app:web]

--- 各 Service 的 Endpoints 数量 ---
  web-blue     5 个
  web-green    5 个
  web-bg       5 个      ← 只挂蓝
  web-ratio    10 个     ← 蓝 5 + 绿 5，两个版本都在
```

> 观察点：`web-bg` 与 `web-ratio` 的 **Endpoints 数量差了一倍**，这正是后续所有现象的根源。

---

## 二、场景 A：Service 层蓝绿发布

### A1 基线（selector = blue）

```bash
for i in $(seq 1 50); do curl -s http://127.0.0.1:30081/; echo; done | sort | uniq -c
```

```
  [基线] 发 50 次请求：
      BLUE v1.0 (stable)               50 次  100.0%
```

### A2 执行发布：切换 selector

```bash
kubectl -n release-lab patch svc web-bg \
  -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
```

```
service/web-bg patched
切换后 selector  = {"app":"web","version":"green"}
切换后 endpoints = 10.42.0.16 10.42.0.17 10.42.0.18 10.42.0.19 10.42.0.20
```

```bash
for i in $(seq 1 50); do curl -s http://127.0.0.1:30081/; echo; done | sort | uniq -c
```

```
  [发布后] 发 50 次请求：
      GREEN v2.0 (canary)              50 次  100.0%
```

### A3 回滚：selector 切回 blue

```bash
kubectl -n release-lab patch svc web-bg \
  -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
```

```
  [回滚后] 发 50 次请求：
      BLUE v1.0 (stable)               50 次  100.0%
```

### 现象与结论

| 阶段 | 结果 | 说明 |
|---|---|---|
| 基线 | BLUE 50/50 | 100% 走旧版本 |
| 发布 | GREEN 50/50 | **一次性全量切到新版本** |
| 回滚 | BLUE 50/50 | 一次性全量切回 |

**★ 核心现象：切换是"瞬时、全量、无中间态"的。**

一次 `patch` 命令，Endpoints 列表就整体换成了另一批 Pod IP，流量随之 100% 转向。
整个过程不存在"一半新一半旧"的过渡区间 —— **这正是蓝绿发布的定义**。

**★ 蓝绿的本质 = 用"整体替换"换取"回滚的确定性"**，代价是：

- **没有观察期**。新版本上线第一天就承接 100% 流量，一旦有 bug 就是全量故障。
- 需要**双倍资源**，新旧两套环境必须同时在线。

---

## 三、场景 B：Service 层灰度发布

### 原理

`web-ratio` 的 selector 是 `app=web`（不带 `version`），所以**蓝绿两批 Pod 同时出现在它的 Endpoints 里**。
kube-proxy 默认对后端做**随机转发**，于是：

```
某版本拿到的流量占比 ≈ 该版本 Pod 数 / 后端 Pod 总数
```

灰度比例完全由**副本数配比**控制。以下是实测的 6 档递进，每档发 100 次请求统计：

| 档位 | 副本配比 blue:green | 后端 Pod 总数 | 理论比例 | **实测 blue** | **实测 green** |
|---|---|---|---|---|---|
| B1 | 5 : 5 | 10 | 50% | 47 次 (47.0%) | 53 次 (53.0%) |
| B2 | 9 : 1 | 10 | 10% | 87 次 (87.0%) | 13 次 (13.0%) |
| B3 | 7 : 3 | 10 | 30% | 75 次 (75.0%) | 25 次 (25.0%) |
| B4 | 5 : 5 | 10 | 50% | 47 次 (47.0%) | 53 次 (53.0%) |
| B5 | 1 : 9 | 10 | 90% | 8 次 (8.0%) | 92 次 (92.0%) |
| B6 | 0 : 10 | 10 | 100% | 0 次 | 100 次 (100.0%) |

操作命令（每档只有这两条）：

```bash
kubectl -n release-lab scale deploy/web-blue  --replicas=9
kubectl -n release-lab scale deploy/web-green --replicas=1
# 然后对 30082 打 100 次请求统计
```

### 现象与结论

**★ 现象 1：比例只由副本数配比决定，无法指定精确权重。**

想把 10% 的流量给新版本，唯一办法是"凑出 9:1 的副本比"，而不是写一行 `weight: 10`。

**★ 现象 2：分辨率 = `1 / 总副本数`。**

10 个 Pod 的情况下，可表达的比例只有 10%、20%、30% … 这样的整数倍。
**做不到 1%、2% 这种细粒度**（除非把 Pod 数堆到 100 个，成本不现实）。

**★ 现象 3：实测值与理论值存在波动。**

B1 目标 50% 实测 47%，B3 目标 30% 实测 25%。
原因是 **kube-proxy 是随机（无状态）转发**，100 次采样下的统计涨落属正常。
样本量越大越贴近理论值，但**小流量下"今天 20% 明天 35%"是常态**。

**★ 现象 4：完全无法定向。**

无法表达"带 `X-User: tester` 的请求走新版本"或"某个用户固定在灰度版本"。
只有一个全局概率，没有"谁"的概念。

**★ Service 层灰度的能力边界**

| 能力 | 支持 | 说明 |
|---|---|---|
| 按比例粗调 | ✅ | 分辨率 = `1/总副本数` |
| 精确权重（如 1%） | ❌ | 需要堆 Pod 数量，不现实 |
| 按请求头定向 | ❌ | 四层转发，看不到 HTTP 头 |
| 按 Cookie / 用户定向 | ❌ | 同上 |
| 粘性会话 | ❌ | 无会话概念，每次请求独立随机 |

**★ 结论：Service 层适合"粗粒度按比例"的灰度；要做精确权重和定向引流，必须把切换点上移到 Ingress —— 见实验组二。**

---

## 四、完整操作清单（可直接复制执行）

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ---------- 部署基础工作负载 ----------
kubectl apply -f /opt/k3s-release-lab/manifests/00-namespace.yaml
kubectl apply -f /opt/k3s-release-lab/manifests/app/
kubectl apply -f /opt/k3s-release-lab/manifests/service-lab/
kubectl -n release-lab rollout status deploy/web-blue  --timeout=180s
kubectl -n release-lab rollout status deploy/web-green --timeout=180s

# ---------- 场景 A：蓝绿 ----------
# 1. 基线（全蓝）
for i in $(seq 1 50); do curl -s http://127.0.0.1:30081/; echo; done | sort | uniq -c
# 2. 发布（全绿）
kubectl -n release-lab patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
for i in $(seq 1 50); do curl -s http://127.0.0.1:30081/; echo; done | sort | uniq -c
# 3. 回滚（全蓝）
kubectl -n release-lab patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
for i in $(seq 1 50); do curl -s http://127.0.0.1:30081/; echo; done | sort | uniq -c

# ---------- 场景 B：灰度（改副本比 = 改灰度比例）----------
kubectl -n release-lab scale deploy/web-blue  --replicas=9   # 约 90% 走旧版本
kubectl -n release-lab scale deploy/web-green --replicas=1   # 约 10% 走新版本
sleep 4
for i in $(seq 1 100); do curl -s http://127.0.0.1:30082/; echo; done | sort | uniq -c

# ---------- 收尾回基线 ----------
kubectl -n release-lab patch svc web-bg -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
kubectl -n release-lab scale deploy/web-blue  --replicas=5
kubectl -n release-lab scale deploy/web-green --replicas=5
```

---

## 五、与原计划的差异说明

- 场景 B 原计划用"标签微调实现灰度"，实际采用**同一 `app` 标签 + 副本数配比**的方式。
  原因：这是 Service 层唯一**语义正确**的灰度高实现 —— 给 Pod 打中间态标签（如 `version=canary`）本质是搬用 Ingress 的思路，
  而 Service 的转发是四层、无状态随机的，标签怎么打最终仍只归结为"后端 Pod 数量比"。
  因此直接用副本比来表达比例，更贴近 Service 层的真实能力边界。
- 全部场景均使用 NodePort（30081/30082）直接从节点 `127.0.0.1` 验证，
  不引入 Ingress，保证本组结论**只由 Service 层决定**，与实验组二形成干净的对照。
