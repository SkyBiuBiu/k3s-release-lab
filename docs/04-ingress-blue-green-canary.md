# 04 · 实验组二：通过 Ingress 实现蓝绿发布与灰度发布

> 原始日志：[`../logs/30-ingress-lab.txt`](../logs/30-ingress-lab.txt)
> 一键复现：[`../scripts/30-ingress-lab.sh`](../scripts/30-ingress-lab.sh)
> 相关清单：[`../manifests/ingress-lab/`](../manifests/ingress-lab/)

---

## 一、实验设计

实验组一证明了 Service 层的天花板：**只能按 Pod 数量比做粗粒度概率分配，无法定向**。
本组把切换点上移到 **Ingress（ingress-nginx）**，验证四个场景：

| 场景 | 机制 | 语义 |
|---|---|---|
| A 蓝绿 | 改 `backend.service.name` | 原子全量切换 |
| B 权重灰度 | `canary-weight` 注解 | 概率分配，精度 1% |
| C 请求头灰度 | `canary-by-header` 注解 | **确定性定向** |
| D Cookie 灰度 | `canary-by-cookie` 注解 | **粘性定向** |

### 前置条件

```
--- ingress-nginx 控制器 ---
ingress-nginx-controller-5fbc654b9-n8jvm   1/1   Running

--- IngressClass ---
NAME    CONTROLLER             AGE
nginx   k8s.io/ingress-nginx   26m

--- 后端 Service 与端点 ---
NAME        TYPE        CLUSTER-IP      PORT(S)
web-blue    ClusterIP   10.43.218.198   80/TCP
web-green   ClusterIP   10.43.181.92    80/TCP
  web-blue endpoints  = 10.42.0.37 10.42.0.38 10.42.0.39 10.42.0.40 10.42.0.41
  web-green endpoints = 10.42.0.19 10.42.0.28 10.42.0.29 10.42.0.33 10.42.0.35

--- 控制器在线确认（无匹配 Ingress 时应返回 404）---
    HTTP 404
```

所有请求统一走宿主 80 端口，用 `Host: web.lab.local` 头匹配 Ingress 规则：

```bash
curl -s -H "Host: web.lab.local" http://127.0.0.1/
```

> 之所以用 `-H "Host: ..."` 而不是改 hosts 文件，是为了在脚本里端到端留痕、可复制执行。
> 真实浏览器访问只需在客户端 hosts 里加一行 `192.168.100.128  web.lab.local`。

### 金丝雀机制的核心语义（ingress-nginx）

```
同一个 host + path 上：
  ┌─ 主 Ingress（无 canary 注解）      → 稳定版本，默认承接全部流量
  └─ 金丝雀 Ingress（canary: "true"） → 新版本，按规则抢走一部分流量

匹配优先级：canary-by-header  >  canary-by-cookie  >  canary-weight
```

---

## 二、场景 A：Ingress 层蓝绿发布

### 切换点 = Ingress 的后端 Service 名

```yaml
spec:
  rules:
    - host: web.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-blue      # ← 切换点：改成 web-green
                port:
                  number: 80
```

### 执行与现象

```bash
# 基线
kubectl -n release-lab apply -f manifests/ingress-lab/30-ingress-bluegreen.yaml
for i in $(seq 1 50); do curl -s -H "Host: web.lab.local" http://127.0.0.1/; echo; done | sort | uniq -c

# 发布
kubectl -n release-lab patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-green"}]'

# 回滚
kubectl -n release-lab patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-blue"}]'
```

| 阶段 | Ingress 后端 | 实测结果 |
|---|---|---|
| 发布前 | `web-blue` | BLUE 50 次 **100.0%** |
| 发布后 | `web-green` | GREEN 50 次 **100.0%** |
| 回滚后 | `web-blue` | BLUE 50 次 **100.0%** |

```
  --- 当前 Ingress 与后端 ---
NAME   CANARY   WEIGHT   BACKEND
web    <none>   <none>   web-blue     ← 发布前
web    <none>   <none>   web-green    ← 发布后
web    <none>   <none>   web-blue     ← 回滚后
```

**★ 结论：与 Service 层蓝绿同构 —— 都是"原子全量"，区别只在切换点。**

| | Service 层蓝绿 | Ingress 层蓝绿 |
|---|---|---|
| 切换点 | `Service.spec.selector.version` | `Ingress.backend.service.name` |
| 语义 | 整体换一批 Pod | 整体换一个后端 Service |
| 回滚 | 改 selector | 改后端名 |

**★ 选择依据**：当两个版本**各有独立 Service**（如本实验的 `web-blue` / `web-green`）时，
Ingress 层改后端名更自然；当只有一个共享 Service 时，Service 层改 selector 更直接。

---

## 三、场景 B：Ingress 层灰度 —— 按权重（canary-weight）

### 配置

```yaml
# 金丝雀 Ingress
metadata:
  name: web-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"   # ← 唯一需要改的数字
```

**递进只需改一个注解：**

```bash
kubectl -n release-lab annotate ingress web-canary --overwrite \
  nginx.ingress.kubernetes.io/canary-weight="50"
```

### 实测结果（每档 100 次请求）

| 配置权重 | 理论 green 占比 | **实测 blue** | **实测 green** | 偏差 |
|---|---|---|---|---|
| 20 | 20% | 80 次 (80.0%) | **20 次 (20.0%)** | 0% |
| 50 | 50% | 54 次 (54.0%) | **46 次 (46.0%)** | -4% |
| 80 | 80% | 25 次 (25.0%) | **75 次 (75.0%)** | -5% |
| 100 | 100% | 0 次 | **100 次 (100.0%)** | 0% |

### 现象与结论

**★ 现象 1：权重是"概率"而不是"路由"。**

设 50% 时实测 46%，设 80% 时实测 75% —— 都在配置值附近小幅波动。
这是**正常现象**：`canary-weight` 的作用是"以 N% 的概率把请求交给金丝雀"，
而不是"精确地每 100 个请求分 N 个过去"。样本量越大越贴近配置值。

**★ 现象 2：粒度是 1%，与 Pod 数量无关。**

这是相比实验组一的**本质提升**：
Service 层要表达 10% 就得配 9:1 的副本（10 个 Pod）；Ingress 层写 `canary-weight: "10"` 就行，
哪怕后端只有 1 个 Pod。**可以做到 1% 这种细粒度**，不需要堆副本。

**★ 现象 3：`weight: "100"` 等价于完成全量发布。**

推到 100 后 100% 流量走新版本。此时通常的做法是：
把主 Ingress 的后端直接改成新版本，然后**删掉金丝雀 Ingress**（`kubectl delete ingress web-canary`），
把发布态的临时配置清理干净。

---

## 四、场景 C：Ingress 层灰度 —— 按请求头定向（确定性）

### 配置

```yaml
metadata:
  name: web-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
    nginx.ingress.kubernetes.io/canary-by-header-value: "always"
    nginx.ingress.kubernetes.io/canary-weight: "0"     # 显式置 0，避免残留上个场景的权重
```

### 实测结果（每档 30 次请求）

| 请求 | 实测结果 |
|---|---|
| 不带 `X-Canary` 头 | BLUE 30 次 **100.0%** |
| 带 `X-Canary: always` | GREEN 30 次 **100.0%** |
| 带 `X-Canary: other`（值不匹配） | BLUE 30 次 **100.0%** |

```
  --- 当前 Ingress 与后端 ---
NAME         CANARY   WEIGHT   BACKEND
web          <none>   <none>   web-blue
web-canary   true     0        web-green
```

### 现象与结论

**★ 现象：这是"定向"而不是"比例"。**

- 带正确头的请求 → **100%** 走新版本，**与权重无关**（权重已置 0，但仍命中）；
- 不带该头、或值不匹配的请求 → **100%** 走旧版本。

头值不匹配（`other`）时**不会**掉进权重规则随机分配，而是干净地回落到主 Ingress。
这一点在做定向灰度时很关键：**普通用户完全不会受影响**。

**★ 适用场景**

- 内部测试账号、QA 同学先行验证
- 移动端真机联调（App 内注入固定头）
- 给某个合作方 / 特定客户端开白名单

**★ 与权重灰度的本质区别**

| | 权重灰度 | 请求头灰度 |
|---|---|---|
| 语义 | 概率（谁碰上算谁的） | **路由（谁能进谁进）** |
| 可预测性 | 不可预测，只能看统计 | **完全确定** |
| 影响面 | 真实用户也会被抽中 | 只影响带头的客户端 |

---

## 五、场景 D：Ingress 层灰度 —— 按 Cookie 定向（粘性）

### 配置

```yaml
metadata:
  name: web-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-by-cookie: "canary_user"
    nginx.ingress.kubernetes.io/canary-weight: "0"
```

### 实测结果（每档 30 次请求）

| 请求 | 实测结果 |
|---|---|
| 不带 Cookie | BLUE 30 次 **100.0%** |
| `Cookie: canary_user=always` | GREEN 30 次 **100.0%** |
| `Cookie: canary_user=never` | BLUE 30 次 **100.0%** |

```bash
curl -s -H "Host: web.lab.local" -b "canary_user=always" http://127.0.0.1/
```

### 现象与结论

**★ 现象：与请求头的差别在于"粘性"。**

请求头需要**客户端每次请求都主动加**；而 Cookie 由浏览器自动携带，
用户一次被种上 `canary_user=always` 后，**后续所有请求都会持续命中新版本**，
用户自己完全无感知。

**★ 适用场景**：让一批用户**长期停留在灰度版本**上做观察式灰度
（观察真实用户行为、埋点、性能表现），而不是"每次请求随机决定"。

**★ 反向用途**：`canary_user=never` 可以把特定用户**永久排除**在灰度之外，
作为紧急兜底手段。

---

## 六、四个场景横向对照

| 场景 | 关键注解 | 实测结论 | 语义类型 |
|---|---|---|---|
| A 蓝绿 | 无（改 `backend`） | 100% / 100% 原子切换 | 全量 |
| B 权重 | `canary-weight` | 20→20%, 50→46%, 80→75%, 100→100% | **概率** |
| C 请求头 | `canary-by-header` + `-header-value` | 带头 100% 绿，不带头 100% 蓝 | **确定性路由** |
| D Cookie | `canary-by-cookie` | Cookie=always 走绿，其余走蓝 | **粘性定向** |

**★ 优先级（务必记住）**：`canary-by-header` > `canary-by-cookie` > `canary-weight`

当多个规则同时配置时，高优先级命中则直接决定去向，不再看低优先级。
实践中建议：**一次只用一个规则**，并在切换规则时把其它规则的注解显式置 0 / 删除，
避免上一场景的配置残留造成"现象诡异"。

---

## 七、完整操作清单（可直接复制执行）

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=release-lab
H='Host: web.lab.local'
M=/opt/k3s-release-lab/manifests/ingress-lab

# ---------- 场景 A：蓝绿 ----------
kubectl -n $NS apply -f $M/30-ingress-bluegreen.yaml
for i in $(seq 1 50); do curl -s -H "$H" http://127.0.0.1/; echo; done | sort | uniq -c
kubectl -n $NS patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-green"}]'
for i in $(seq 1 50); do curl -s -H "$H" http://127.0.0.1/; echo; done | sort | uniq -c
kubectl -n $NS patch ingress web --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"web-blue"}]'

# ---------- 场景 B：权重灰度 ----------
kubectl -n $NS apply -f $M/31-ingress-canary-weight.yaml
for w in 20 50 80 100; do
  kubectl -n $NS annotate ingress web-canary --overwrite \
    nginx.ingress.kubernetes.io/canary-weight="$w"
  sleep 5
  echo "--- weight=$w ---"
  for i in $(seq 1 100); do curl -s -H "$H" http://127.0.0.1/; echo; done | sort | uniq -c
done

# ---------- 场景 C：请求头定向 ----------
kubectl -n $NS apply -f $M/32-ingress-canary-header.yaml
for i in $(seq 1 30); do curl -s -H "$H" http://127.0.0.1/; echo; done | sort | uniq -c
for i in $(seq 1 30); do curl -s -H "$H" -H 'X-Canary: always' http://127.0.0.1/; echo; done | sort | uniq -c

# ---------- 场景 D：Cookie 定向 ----------
kubectl -n $NS apply -f $M/33-ingress-canary-cookie.yaml
for i in $(seq 1 30); do curl -s -H "$H" -b 'canary_user=always' http://127.0.0.1/; echo; done | sort | uniq -c
for i in $(seq 1 30); do curl -s -H "$H" -b 'canary_user=never'  http://127.0.0.1/; echo; done | sort | uniq -c

# ---------- 收尾：删金丝雀，回纯蓝基线 ----------
kubectl -n $NS delete ingress web-canary --ignore-not-found
kubectl -n $NS apply -f $M/30-ingress-bluegreen.yaml
```

---

## 八、重要提醒：`canary-*` 注解是控制器私有的

本组全部场景依赖 **ingress-nginx 的 `nginx.ingress.kubernetes.io/canary-*` 注解**，
它们**不是 K8s 标准**，换一个 Ingress 控制器就会失效：

| 控制器 | 灰度实现方式 |
|---|---|
| ingress-nginx | `canary-*` 注解（本实验） |
| Traefik | `TraefikService` + `IngressRoute` CRD，权重写在 CRD 里 |
| APISIX | `ApisixRoute` CRD + `plugins` 中的 `traffic-split` |
| 云厂商（CLB / ALB / Nginx Ingress 商业版） | 各有自己的注解或控制台配置 |

**结论**：需要**跨环境可移植**的发布策略时，不要把 `canary-*` 当作标准能力写进规范，
应抽象成"入口层灰度"这一能力项，再按实际控制器落地。
