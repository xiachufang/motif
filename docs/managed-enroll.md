# Motif — 托管 Headscale 入网（enrollment broker）

> 本文档定义 motif **托管控制平面**下的「无感入网」契约：用户只登录 motif 账号，设备自动加入 motif 运营的 Headscale tailnet，全程不出现 Tailscale / Headscale / control URL / auth key 等概念。
>
> 这条托管路与 [`tailscale.md`](./tailscale.md) 描述的**手动**入网路（用户自填 control URL + 浏览器 OAuth / `tskey-…`）**并存**，不替换。底层 tsnet 嵌入层（`motif-tailscale` / `TailscaleManager` / `motif-net`）两条路完全复用——区别只在 **control URL 与 auth key 的来源**：
>
> | | control URL | auth key | needsAuth 行为 |
> |---|---|---|---|
> | 手动（[`tailscale.md`](./tailscale.md)，保留） | 用户填（空=Tailscale SaaS / 或自填 Headscale） | 浏览器 OAuth / 粘贴 `tskey-…` | 弹 Safari（现状） |
> | 托管（本文档，新增） | broker 返回 | broker 现铸 preauth，静默注入 | **静默 re-enroll**，不弹任何东西 |
>
> 阅读前提：[`tailscale.md`](./tailscale.md) §3–§6（嵌入式 tsnet 架构、auth & state）。

---

## 1. 信任模型（三层，互不替代）

沿用 [`tailscale.md`](./tailscale.md) non-goal #2 的分层，托管路在最上面多接一层「账号 → 入网票」的桥：

| 层 | 凭证 | 谁验 | 失效后果 |
|---|---|---|---|
| **身份** | motif session token | broker | 重新登录 motif 账号（**唯一**会冒泡给用户的 auth，框成「登录 motif」，不提 Tailscale） |
| **入网** | Headscale preauth key（broker 现铸，单次、短时效） | Headscale control plane | 静默 re-enroll 领新 key |
| **应用** | motifd Bearer token | motifd | 401，按 motif 现有 auth 处理 |

broker 持有的 Headscale admin API key **只在服务端**，绝不下发到 App。App 永远只看到 `{control_url, preauth_key}`，对「背后是 Headscale」无感。

---

## 2. 租户模型：一个 motif 账号 = 一个 Headscale user

Headscale 是**单 tailnet** 实例，没有一等公民的 tenant。隔离靠 **user + ACL**：

- 每个 motif 账号在 Headscale 里映射成一个 user，命名 `acct-<accountId>`（稳定、不可猜）。
- 该账号的所有设备（手机、motifd）都用**该 user 名下**现铸的 preauth key 注册 → 自动归属同一 user。
- 隔离由下面的 ACL 保证：每个 user 只能连自己 user 的节点，跨账号默认拒绝。
- **不使用 ACL tag**：`autogroup:self` 不匹配 tagged 设备（tag 会顶替 user 身份），两者互斥；角色（client/server）信息改放 broker 侧 DB + hostname 约定（`motifd-*`），**不进 tailnet tag**。

MagicDNS 命名因此变成 `motif-ios.acct-<id>.<base_domain>`，天然带账号前缀。

---

## 3. ACL 模板

Headscale **默认 allow-all**（省略 `acls`/`grants` 即全互通），所以**必须显式 default-deny + 单条 self 规则**。整张策略是**账号无关的静态文件**，新增账号不需要改 ACL：

```jsonc
// Headscale policy（database 模式下可经 API 热更，或文件 + SIGHUP reload）
{
  "acls": [
    // 每个 user 只能访问"同一 user 自己的"节点；跨账号无规则 = 默认拒绝。
    // autogroup:self 的语义正是"src 与 dst 是同一登录用户的设备"。
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self:*"] }
  ]
}
```

> ⚠️ **规模化 fallback**：`autogroup:self` 的 filter 规则是**按节点编译**而非全局，大规模部署会拖慢 coordinator。账号数上规模后改成 broker **按账号生成显式规则**（语义等价，性能更好）：
>
> ```jsonc
> { "action": "accept", "src": ["acct-7f3a@"], "dst": ["acct-7f3a@:*"] },
> { "action": "accept", "src": ["acct-9b1c@"], "dst": ["acct-9b1c@:*"] }
> // …每账号一对，broker 在建/删账号时重生成并推送
> ```
>
> 注意 user 名后的 `@` 是**强制**的，漏了存不进去。两种写法都**不依赖 tag**，可平滑切换。

端口收窄（只放 motifd 的 7777）在 user 隔离已经成立的前提下属于 nice-to-have；要做就得引入角色 tag，与 `autogroup:self` 冲突，**默认不做**，靠 Bearer 兜应用层。

---

## 4. `/enroll` 契约

设备（iOS app 或 motifd）凭 motif token 申请入网；broker 在该账号的 Headscale user 下现铸 preauth key 并返回。

### 请求

```
POST /v1/enroll
Authorization: Bearer <motif-session-token>
Content-Type: application/json

{
  "device": {
    "role":        "client" | "server",  // 仅 broker 侧记录 + 命名，不进 tailnet tag
    "hostname":    "motif-ios",           // 期望的 tailnet 主机名（advisory，broker 可去重改写）
    "device_id":   "<stable-per-install-uuid>", // 幂等 + 撤销 + 去重的 key
    "os":          "iOS 18.4",            // 可选，诊断用
    "app_version": "1.2.0"                // 可选
  }
}
```

### 响应 `200`

```jsonc
{
  "control_url":     "https://hs.motif.io",
  "preauth_key":     "<headscale-preauth>",  // 单次、短时效；客户端用完即弃，勿持久化
  "tailnet_user":    "acct-7f3a",            // 该账号的 headscale user
  "key_expires_at":  "2026-05-31T12:10:00Z", // RFC3339；仅 key 注册窗口，非节点寿命
  "reusable":        false,
  "ephemeral":       false,
  "base_domain":     "motif.ts.net",         // MagicDNS 后缀，解析提示用
  "min_reenroll_secs": 30                    // 客户端两次 re-enroll 的最小间隔（防风暴）
}
```

### 错误

| 码 | 含义 | 客户端行为 |
|---|---|---|
| `401` | motif token 无效/过期 | **唯一**冒泡给用户：提示「重新登录 motif」（账号层，不提 Tailscale） |
| `403` | 账号无权 / 设备数超限 / role 不允许 | 展示 broker 的 `message`，不重试 |
| `409` | hostname / device_id 冲突 | broker 应已自行去重；客户端用响应里改写后的值 |
| `429` | re-enroll 过于频繁 | 尊重 `Retry-After`，退避 |
| `503` | Headscale 不可用 | 指数退避静默重试，期间停在 `.degraded`，**不**打扰用户 |

### broker 铸 key 的参数（落到 Headscale API）

`POST /api/v1/preauthkey`（Bearer = broker 的 admin API key）：

```jsonc
{
  "user":       "acct-7f3a",
  "reusable":   false,                       // 单设备单次注册
  "ephemeral":  false,                       // 节点持久——与 App 的 Configuration(ephemeral:false)
                                             // 及 tsnet 1.94 Loopback 兼容性顾虑一致（见 tailscale.md §12）
  "expiration": "<now + 10min, RFC3339>",     // 必须显式传！不传 = 0001-01-01 = 永不过期（坑）
  "aclTags":    []                            // 留空——租户隔离靠 user，不靠 tag（见 §2）
}
```

---

## 5. 节点生命周期 / 何时 re-enroll

关键区分：**preauth key 寿命 ≠ 节点寿命**。

- key 只在**首次注册**那 ~10 分钟有效；注册成功后节点凭 state 目录里的 machine key 持久存在，**正常冷启动不需要再调 broker**（tsnet 直接从 state 恢复 → `.running`）。
- 因为 `ephemeral=false`，节点离线后**不会**被 Headscale 自动移除，便于「列我的服务器」时也能看到离线机器。
- 触发 **静默 re-enroll**（拿缓存 motif token 重新 `/enroll` → 新 key → 重启 tsnet）的情形：
  1. 全新安装 / state 目录被清
  2. 节点 key 过期（受 Headscale `max_key_duration` 影响——**建议服务器节点关闭过期或设长周期**，作为运维 knob）
  3. 管理端把节点删了
  4. tsnet 上报 `NeedsLogin`（`.motifAccount` source 下拦截，**绝不弹浏览器**）
- 只有当 **motif token 本身也失效**（broker 返回 401）时，才升级成账号层的「重新登录 motif」。

---

## 6. `/servers` 目录（发现离线服务器）

netmap 只反映**当前在线**的 peer；要让用户看到「我的服务器」即使此刻离线，broker 维护账号→服务器目录：

```
GET /v1/servers
Authorization: Bearer <motif-session-token>

200 →
{
  "servers": [
    { "device_id": "...", "display_name": "我的 Mac",
      "tailnet_hostname": "motifd-mac.acct-7f3a.motif.ts.net",
      "last_seen": "2026-05-31T11:59:00Z" }
  ]
}
```

客户端把这份目录与 `discoverPeers()`（[`tailscale.md`](./tailscale.md) §7.1 同源逻辑）的在线信息合并：目录给「有哪些 + 友好名」，netmap 给「现在通不通」。

服务器注册友好名：

```
PUT /v1/servers/{device_id}
Authorization: Bearer <motif-session-token>
{ "display_name": "我的 Mac" }
```

---

## 7. motifd（服务器）侧入网

motifd 同样要一个 motif token 才能 `/enroll`（role=server）。两种取得方式：

1. **device-code（交互、推荐）**：`motifd login` 打印一次性短码 + URL，用户在任意浏览器确认；motifd 拿到长效 server token 存本地，之后全自动。
2. **headless token**：CI / 容器经 env（如 `MOTIF_ACCOUNT_TOKEN`）注入预签发的 machine token。

拿到 token 后 motifd：`/enroll`(role=server) → `setControlURL`+tsnet up（复用 `--tailscale-control-url` 那条已有路径，URL 来自响应而非命令行）→ `PUT /v1/servers/{id}` 注册友好名。对运维者而言唯一动作是跑一次 `motifd login`。

---

## 8. 客户端缓存什么

| 项 | 存哪 | 说明 |
|---|---|---|
| motif session token | Keychain | 身份凭证 |
| `device_id` | Keychain / UserDefaults | 稳定 per-install UUID，幂等 + 撤销 |
| `control_url` | UserDefaults（复用现有 `tailscaleControlURL`） | 冷启动可先 `setControlURL` 让 tsnet 从 state 恢复，**无需先调 broker** |
| `enrollmentSource` = `.motifAccount`/`.manual` | UserDefaults（**新增**） | 决定 needsAuth 分叉与 UI 文案 |
| preauth_key | **不存** | 单次用完即弃 |

state 目录隔离已由 `statePath(for: controlURL)`（[`tailscale.md`](./tailscale.md) §6.2 / `TailscaleManager.swift`）按 control URL 自动隔离——托管 Headscale 与手动 SaaS 各占一份，来回切不互相清。

---

## 9. 安全 / 隔离测试清单（上线前必过）

- [ ] **跨账号不可见**：账号 A 的设备 `tailscale status` / netmap 里**看不到**账号 B 的任何节点，dial B 的 IP 直接被 ACL 拒。
- [ ] **default-deny 生效**：故意清空 ACL 验证不是 allow-all（Headscale 省略 acls = 全通，必须确认策略已加载）。
- [ ] **key 一次性**：同一 preauth key 二次注册被拒（`reusable=false`）。
- [ ] **key 过期**：超过 `expiration` 的 key 无法注册。
- [ ] **token 撤销**：吊销 motif token 后 `/enroll`/`/servers` 立即 401。
- [ ] **device_id 去重**：同 device_id 重复 enroll 不在 Headscale 留下僵尸节点（broker 先清旧节点再发新 key）。
- [ ] **broker admin key 不外泄**：抓包确认 App ↔ broker 流量里只有 preauth，无 admin API key。

---

## 10. 决策记录

1. **节点过期策略 → 不靠节点过期做安全，靠 token 撤销。**
   `max_key_duration` 全局设长或关（Headscale 只能 tailnet 级，无法 per-user）。真正的安全边界是 **撤销 motif token → broker 拒绝 re-enroll（401/403）并删除该 Headscale 节点**。无人值守的 motifd 不会因 key 过期掉线；客户端即便过期也静默 re-enroll 无感。§5 的「服务器节点关闭过期」据此确定。

2. **device_id → 自生成 UUID 存 Keychain，不用 `identifierForVendor`。**
   IDFV 首次解锁前为 nil、整厂 App 卸光会重置，太脆。Keychain UUID 重装后通常仍在（broker 复用旧节点）；若 Keychain 被清则生成新 id、旧节点交给 broker 的离线 GC 回收（§9 去重项）。

3. **DERP → 上线先用 Tailscale 公共 DERP（Headscale 默认），自建进路线图。**
   多数连接靠 NAT 直连成功，DERP 仅兜底中继。自建要多区域部署 + 运维，触发信号为量级 / ToS / 区域延迟。⚠️ 用 Tailscale 公共 DERP 配非 Tailscale 控制平面属 ToS 灰区，规模化前复核。

4. **motif 账号体系 → 独立 identity 服务签发可离线校验的 JWT。**
   token 形态：`{ sub: <accountId>, exp, iat }`，identity 私钥签名；broker **验签不回源**（无 introspection 往返）。登录方式 **Sign in with Apple（iOS 上架要求）+ GitHub OAuth（开发者受众）**。计费/配额 v1 先免费档 + 设备上限，在 `/enroll` 的 `403` 里兜。account 产品内部实现不在本文档范围。

5. **`autogroup:self` → 显式规则切换：按可观测信号，不拍脑袋数字。**
   监控 coordinator 的策略重编译 / netmap 生成 **p95 延迟**，越过阈值（≈ >500ms）或节点数 > ~500（先到为准）即让 broker 改用 §3 的生成式 per-user 显式规则。两种写法语义等价、均不依赖 tag，可热切换。

### 仍待定（依赖外部进展）

- [ ] Headscale 策略热更：用 database 模式经 API 推，还是文件 + SIGHUP reload——取决于部署版本是否支持 policy API。
- [ ] identity 服务的具体选型（自建 vs Clerk/WorkOS 等）与 JWT 轮转/吊销列表机制。

---

## 11. 与已有文档的关系

- [`tailscale.md`](./tailscale.md)：嵌入式 tsnet 层 + 手动入网路的事实标准。本文档**复用**其 tsnet/state/discovery 机制，只新增「账号→preauth」的 broker 桥；§12 关于 Headscale 兼容的开放项由本文档承接托管场景。
- [`prd.md`](./prd.md) §3 / §7：托管路是 §7 部署示例之外、面向「装了就能用」终端用户的第三种接入形态。
