# ClashMax 发展路线图

[English](ROADMAP.md) | **简体中文**

> 本文是 [`ROADMAP.md`](ROADMAP.md) 的中文版本，内容与英文版逐节对应。两者出现不一致时，以英文版为准。

**状态：** 草案 2026-08-14 · 维护者 [@marvinli001](https://github.com/marvinli001) ·
应用 1.0.22，内置 Mihomo [v1.19.29](../Resources/Core/mihomo-manifest.json)

本文记录 **ClashMax 要往哪里走、以及为什么**，并且写成可以对着代码树逐条核对的形式。它不是许愿单。
下面点名的每一处缺口，都是在 2026-08-14 通过实际阅读仓库验证过的；每一个提出的 issue 都带有可以用一条命令
或一张截图演示的验收标准。

Bug 修复、已提交的 issue、Mihomo 版本升级属于日常维护，**刻意**不写进本文。本文讨论的是 ClashMax 存在的
*意义*。

---

## 1. 定位

其他所有 Mihomo 客户端比拼的都是 **暴露了多少内核开关**。

ClashMax 应该比拼的是 **解释内核到底在干什么**。

这不是空想——代码库本来就长成这个样子。下面这些子系统在 ClashX、Clash Verge Rev、mihomo-party 中都没有
对应物：

| 能力 | 位置 |
| --- | --- |
| 把"流量*为什么*没走代理"分类到具体的 `Cause` | [`ClashMax/Models/ProxyEffectDiagnostics.swift`](../ClashMax/Models/ProxyEffectDiagnostics.swift) |
| 模拟给定 host 会命中哪条规则 | [`ClashMax/Models/CoreModels.swift`](../ClashMax/Models/CoreModels.swift) 中的 `RuleMatchSimulator` |
| 在应用前，以 diff 形式展示这次改动最终会生成什么运行时 YAML | [`EffectiveRuntimeConfigBuilder.swift`](../ClashMax/Services/EffectiveRuntimeConfigBuilder.swift)、Routing 页 |
| 报告用户刚做的改动到底生效了没有 | [`RuntimeApplyOutcomeBanner.swift`](../ClashMax/Views/RuntimeApplyOutcomeBanner.swift) |
| 标记订阅偷偷塞进来的危险 key | [`CoreModels.swift`](../ClashMax/Models/CoreModels.swift) 中的 `ProviderOptionsRisk` |
| 独立于内核，直接检查实时 TUN 路由 / DNS 状态与系统代理状态 | [`TunRuntimeInspector.swift`](../ClashMax/Services/TunRuntimeInspector.swift)、[`SystemProxyController.swift`](../ClashMax/Services/SystemProxyController.swift) |

**路线图就是：把这件事做成产品本身，而不是一个附带功能。**

---

## 2. 设计原则——三个层次

本节具有规范效力。它回答的是那个反复出现的问题：*"怎样既保持易上手，又抬高高级用户的上限？"*

### 2.1 我们拒绝的模式：基础 / 高级开关

不要加全局的"简单模式 / 高级模式"开关，也不要加一个"高级"分区去堆放所有塞不进别处的东西。三个理由：

1. **它逼用户给自己分类。** 一个人卡住的那一刻，恰恰就是他不知道自己的问题属于哪一层的那一刻。
2. **高级层会变成垃圾场。** 每一个我们没设计好的界面都会被丢进去，最后它比它本想让人逃离的东西还难用。
3. **这是一场打不赢的军备竞赛。** Mihomo 增加配置 key 的速度比我们设计开关的速度快，而我们每加一个开关，
   都会稀释所有人的首次使用体验。

### 2.2 按"用户手里握着什么"分层，而不是按难度分层

| 层次 | 用户手里握着什么 | 界面形态 | 已有基础 |
| --- | --- | --- | --- |
| **L1——症状** | *"坏了 / 很慢"* | 一个结论加**一个修复按钮**。不出现 Mihomo 术语。 | `ProxyEffectDiagnostics`、`TunRuntimeInspector`、`PublicIPInfoCard`、`ExternalControlHealthChecker` |
| **L2——意图** | *"我想让 X 走 Y"* | 场景化表单：一个 app、一个网站、一个网络。同样不出现 Mihomo 术语。 | [`QuickRule.swift`](../ClashMax/Models/QuickRule.swift)、`NetworkPolicyRule`、Connections 行菜单 |
| **L3——真相** | *"我知道我要改哪个 key"* | 最终 YAML：可见、可打补丁、可 diff、可回滚。完整的 Mihomo 术语。 | `RuntimeSnippet`、`EffectiveRuntimeConfigBuilder`、`RuntimeSnippetLibraryStore` |

### 2.3 两条不变量

**INV-1——一份真相，两个入口。**
L1 的修复按钮和 L2 的意图表单，必须写入 L3 用户手工编辑的*同一份*表示。全应用只有一个规则模型、一个片段
存储、一个运行时 YAML 构建器。任何为"简单版"引入平行存储格式的功能一律否决。

> 快速规则已经是这么设计的。引自
> [`QuickRule.swift`](../ClashMax/Models/QuickRule.swift)：快速规则*"存放在普通的运行时片段里，并且在
> Routing 页中保持完全可编辑，因此应用中只有一种规则表示、一种存储格式"*。把它推广开，而不要每个功能重新
> 发明一遍。

**INV-2——逃生舱是一等公民，不是兜底。**
高级用户的上限不来自更多 UI 开关，而来自 **看得见 / 改得动 / 退得回**：

- 完全展开后的运行时 YAML 始终可查看；
- 任何 key 都可以被用户片段覆盖，包括 ClashMax 根本没有 UI 的 key；
- 每次应用都先展示 diff；
- 应用失败会自动回滚，并说明原因。

满足 INV-2 之后，**ClashMax 的上限就等于 Mihomo 的上限**，而 UI 不会膨胀。明天 Mihomo 发布一个新 key，
高级用户当天就能用上，我们什么都不用发。

**为什么这同样有利于新手：** 因为有 INV-1，新手按下修复按钮之后，可以*去看那个按钮写了什么*。应用在教它
自己的配置语言，而不是把它藏在一堵墙后面。新手就地成长为高级用户。

### 2.4 任何新配置界面的评审清单

在新增一个设置、一个开关或一个页面之前，先回答完这五个问题：

- [ ] **这属于哪一层？** 如果答案是"L1 和 L3 都算"，那它其实是两个功能。
- [ ] **如果是 L1：唯一的那个修复按钮是什么？它写入哪个片段？**
- [ ] **如果是 L2：它复用现有的规则 / 片段模型，还是又发明了一个？**（INV-1）
- [ ] **如果是 L3：通用覆盖路径是不是已经能到达它？** 如果是，就不要为它做专门 UI。
- [ ] **用户能不能看到最终的 YAML diff，并把它退回去？**（INV-2）

一个只有高级用户需要、且通用片段覆盖已经够得着的 key，就是**已完成**——为它单独做一个开关，是 L1 质量的
倒退。

---

## 3. ClashMax 的现状

### 3.1 规模，2026-08-14 实测

| 结论 | 如何核对 |
| --- | --- |
| 89 个源文件，约 6.17 万行，覆盖 app、helper、Network Extension、共享代码 | `find ClashMax Shared ClashMaxHelper ClashMaxNetworkExtension -name '*.swift' \| wc -l` |
| 44 个测试文件，约 3.8 万行，1131 个 XCTest 用例 + 5 个 Swift Testing 用例 | `grep -rhoE 'func test[A-Za-z0-9_]*' ClashMaxTests \| sort -u \| wc -l` |
| `en` 与 `zh-Hans` 各 1277 个本地化 key | [`Resources/Localizable.xcstrings`](../Resources/Localizable.xcstrings) |
| 测试在公开 CI 中运行 | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |

### 3.2 Mihomo 能力覆盖缺口

ClashMax 已经在用的 Mihomo 控制 API 端点，来自
[`MihomoAPIClient.swift`](../ClashMax/Services/MihomoAPIClient.swift)：`/`、`/configs`、
`/connections`、`/logs`、`/providers/proxies`、`/providers/rules`、`/proxies`、`/restart`、
`/rules`、`/traffic`、`/version`。

缺口，按优先级排列：

| 缺口 | 核实状态 | 后果 |
| --- | --- | --- |
| **`sniffer`** | **全仓 0 命中。** 更糟的是：连接解码器会用目标 IP 回填缺失的域名（[`MihomoAPIClient.swift:448`](../ClashMax/Services/MihomoAPIClient.swift#L448)），导致下游没有任何一处能区分"无域名连接"和"有域名连接" | 直连 IP 打开的连接（硬编码 IP 的 app、部分 CDN、QUIC）不携带域名，因此 `DOMAIN-SUFFIX` 规则无法命中它们。用户的感受是*"我写的规则不生效"*——而我们的诊断说不出原因，因为这个事实在诊断之前就已经被销毁了。参见 [A1](#a1sniffer把内核从未看到的域名找回来) |
| **`/dns/query`** | 未实现 | 无法回答"这个域名到底被哪个 nameserver 解析成了什么"。在我们本来能端到端讲完的路由故事中间留了一个洞。 |
| **`/cache/fakeip/flush`** | 未实现 | fake-ip 映射脏了只能靠重启内核清除。 |
| **`/group/{name}/delay`** | 未实现 | 批量测速是逐节点打的，而内核有整组接口。 |
| **`geox-url`、`geo-auto-update`、`geodata-mode`** | 仅出现在 ClashX 迁移 key 白名单中（[`ClashXMigrationParser.swift:748`](../ClashMax/Services/ClashXMigrationParser.swift#L748)）——认得，但不支持 | GeoIP/GeoSite 数据库无法更新，geo 类规则会悄悄过期。 |
| **`/configs/geo`、`/memory`** | 未实现 | 没有应用内 geo 数据库刷新；没有内核内存遥测。 |
| **`tcp-concurrent`、`global-client-fingerprint`、`find-process-mode`、`keep-alive-interval`、`ntp`、`experimental`、`global-ua`、`interface-name`** | 全仓 0 命中 | 高级用户会撞到硬天花板。**按 INV-2，解法是通用覆盖路径，而不是八个新开关。** |
| **`listeners`** | 只被当作订阅风险 key 剥离 | 入站监听（给局域网其他设备用）不可用。这需要一个明确的决定，而不是一个默认值。 |

### 3.3 已经建到一半的原生 macOS 优势

| 资产 | 状态 | 缺的那一块 |
| --- | --- | --- |
| `PROCESS-NAME` / `PROCESS-PATH` 规则类型 | 规则枚举中已存在（[`CoreModels.swift:2492`](../ClashMax/Models/CoreModels.swift#L2492)） | 没有 app 选择器。用户只能凭记忆手打进程名。 |
| 实时连接的进程路径与图标 | 已可用（[`ConnectionsView.swift:578`](../ClashMax/Views/ConnectionsView.swift#L578)） | 没有接到规则创建上。 |
| `NetworkPolicyRule`——按 SSID 的策略 | 可切换路由模式、系统代理、开机自启（[`CoreModels.swift:5580`](../ClashMax/Models/CoreModels.swift#L5580)） | 不能切换**配置文件**或**规则集**。触发条件仅限 SSID。 |
| `NetworkEnvironmentMonitor`、`WiFiNetworkInfo` | 实时 SSID 与网络路径监控 | 只被策略匹配和诊断消费。 |

---

## 4. 四条主线

四条主线。A、B、C 交付产品价值；D 是让 A、B、C 负担得起的那笔税。

Issue ID 是稳定的 slug，不是 GitHub 编号，因此可以按任意顺序提交。

---

### 主线 A——把诊断做成产品本身

**目标：** 在一个界面里端到端回答一个问题：*"对这条连接，从域名到出口 IP，每一步到底发生了什么？"*

这就是护城河。这里的一切都是 L1，而每个修复按钮都写入一个 L3 可见的片段。

#### A1——sniffer：把内核从未看到的域名找回来

**优先级：最高。主线 A 的其他所有事项都排在它后面。**

主线 A 的其他每一项，解释的都是内核*做出*的决定。这一项针对的是内核*无法做出*的决定。直连 IP 打开的连接
不携带域名，因此对它而言，每一条 `DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD` 和 `GEOSITE` 规则在结构
上都不可达。用户写了一条正确的规则，而它永远不会触发。ClashMax 目前没有任何一个界面能说出原因——这使它
同时成为最大的内核缺口，和产品赖以立足的诊断故事里最大的一个洞。

##### A1.0——验证了什么，对着什么验证的

内置 Mihomo v1.19.29（`Resources/Core/mihomo`），核实于 2026-08-14：

| 结论 | 证据 |
| --- | --- |
| 内核接受完整的 sniffer schema | 对一份带有 `enable`、`override-destination`、`force-dns-mapping`、`parse-pure-ip`、`sniff.{TLS,HTTP,QUIC}`（含 `ports` 与每协议的 `override-destination`）、`skip-domain`、`force-domain` 的配置执行 `mihomo -t -f` → *test is successful* |
| 嗅探**不需要** `dns:` 块 | 同一份配置在完全没有 `dns:` key 的情况下既能通过校验也能运行。与 issue #16 背后的 DNS 陷阱不同，这里不存在"因遗漏而失效"的失败模式需要防守 |
| 未知协议会给出清晰的失败 | `sniff: {BOGUS: {}}` → `level=error msg="not find the sniffer[BOGUS]"`，因此 preflight 能报出真正的原因，而不是那句通用结尾 |
| sniffer 支持热重载 | 对运行中的内核用 `PUT /configs?force=true` 加载一份 sniffer 关闭的配置，`/configs.sniffing` 从 `true` 变成了 `false`，无需重启 |
| **`GET /configs` 不返回 sniffer 块** | 响应里只暴露一个布尔值 `sniffing`。整个响应中没有任何 `sniffer` key |
| 连接 metadata 携带 `sniffHost` | 内核二进制中存在 `json:"sniffHost"`，旁边还有 `dnsMode`、`remoteDestination`、`specialProxy`、`inboundName`——这些 ClashMax **一个都没有**解码 |

在写任何代码之前，有两条结论就已经约束了设计：

1. 因为内核只报告 `sniffing: true|false`，所以**生成的运行时 YAML 是"到底在嗅探什么"的唯一真相来源**。
   不要为细节去建一条回读路径；按 INV-2，YAML 本来就是诚实的答案，再造一个答案只会多出一份需要同步的真相。
2. 因为 sniffer 支持热重载，所以 sniffer 编辑在
   [`RuntimeChangeApplyMode.swift`](../ClashMax/Models/RuntimeChangeApplyMode.swift) 中属于
   `.hotReload`，与 `.rules`、`.dns` 同列。它不能承诺一次它并不需要的重启。

##### A1.1——因此暴露出的阻塞性缺陷

[`MihomoAPIClient.swift:448`](../ClashMax/Services/MihomoAPIClient.swift#L448) 是这样解码连接 host 的：

```swift
host: metadata["host"] as? String ?? metadata["destinationIP"] as? String ?? "",
```

于是一条**不带域名**的连接，会以目标 IP 落在 `host` 字段里的形式被记录，而 `ConnectionSnapshot` 没有保留
任何标志来区分这两种情况。[`ConnectionsView.swift:137`](../ClashMax/Views/ConnectionsView.swift#L137)
在预填快速规则的地方记录了这个回退——但坍缩发生在它下面一层，也就是解码器里，因此**下游没有任何消费方能
区分"域名是 example.com"和"根本没有域名"**。

这正是这个缺口长期不可见的原因：Host 列永远都有个看起来说得过去的东西可显示。它同时也是一个硬前置条件。
在解码器停止丢弃这个区别之前，本项承诺的诊断根本无法计算，所以下面的 A1a 先单独发布。

##### A1a——不要再把事实丢掉（前置项，用户无感知）

- **范围：** `MihomoAPIClient.decodeConnections`、`ConnectionSnapshot`。不做 UI。
- **验收标准：**
  - [ ] `ConnectionSnapshot` 以类型化状态（而非靠字符串判断）区分三种情况：原生上报的域名、由嗅探恢复的
        域名（`sniffHost`）、以及完全没有域名。原始目标 IP 在每种情况下都仍然可取。
  - [ ] 解码 `sniffHost`、`dnsMode`、`remoteDestination`、`specialProxy`，并沿用
        `stringValue(for:in:)` 在别处已有的多拼写容忍。
  - [ ] Connections 表格的渲染与今天完全一致——IP 回退成为模型之上的*展示*选择，而不是解码器内部对事实的
        销毁。
  - [ ] `ConnectionsView` 中的 `connectionRuleHost` 改读新的类型化状态，不再从空字符串反推，第 137 行的
        注释随之迁移。
  - [ ] 解码器测试覆盖以下 fixture：有域名、无域名、有 `sniffHost` 且无 `host`、有 `sniffHost` 且同时有
        `host`、两者皆无。

##### A1b——生成并接管 `sniffer` 块（L3）

- **范围：** [`ConfigNormalizer.swift`](../ClashMax/Services/ConfigNormalizer.swift)、
  `RuntimeOverrides`、[`RuntimeSnippet.swift`](../ClashMax/Models/RuntimeSnippet.swift)、
  `EffectiveRuntimeConfigBuilder`。
- **形态：** 一个仿照 `TunDNSSettings` 的 `SnifferSettings` 值类型——带 `validationError`、
  `hasRuntimeOverlay`、`summary`、带默认值解码的 `Codable`——这样它是落进已有的 layer / diff / preflight
  机器里，而不是并排另起一套。
- **验收标准：**
  - [ ] `sniffer` 被生成进运行时 YAML，并在每一种 模板 × 路由模式 × DNS 覆盖 组合下通过 `mihomo -t`，
        包括 `providerBackedConfig` 里的 provider 模板路径。
  - [ ] 新增 `RuntimeSnippetPayloadKind.sniffer` 承载用户编辑，使 sniffer 改动就是普通存储里的一个普通
        片段：在 Routing 中可编辑、可与其他片段一起排序、可 diff——没有平行存储（INV-1）。
  - [ ] 当运行时正在承载用户流量时，`RuntimeChangeKind.sniffer` 解析为 `.hotReload`，否则为
        `.appliesOnNextStart`，与已验证的内核行为一致。
  - [ ] 校验在内核看到配置*之前*，就以明确的信息拒绝未知协议、格式错误的端口范围、以及空的 `sniff` map；
        当内核仍然拒绝某份配置时，界面呈现的文本取 `level=error msg=` 那一行。
  - [ ] Routing 的 diff 预览把 `sniffer` 块作为一个带标签的 layer 展示，就像今天展示 `dns-override` 那样。
  - [ ] 订阅自带的 `sniffer` 块经由已有的 runtime-merge 路径合并，并伴随一个明确、可见的保留或覆盖决定
        ——任何一个方向上都不能是静默覆盖。
  - [ ] 测试覆盖：关闭、按默认值开启、按每协议端口开启、订阅冲突、非法输入，以及 apply 模式的解析结果。

##### A1c——这一切存在的理由：那条诊断（L1）

路线图此前写的是*"`ProxyEffectDiagnostics` 增加一个 cause"*。那个归属是错的，本计划予以纠正：
`ProxyEffectDiagnosticsBuilder` 产出的是**基于单个 GeoIP 探测 host 的单一全局结论**，它根本没有连接输入。
把一个按连接维度的 cause 折进去，会把两种不同的作用域混为一谈。

- **范围：** 一个新的纯分类器——`ClashMax/Models/` 下的 `SnifferDiagnostics`——形态与
  `ProxyEffectDiagnosticsBuilder` 完全一致（`Input` 结构体 → 携带 `Status`、稳定 `Cause` 枚举、`Fact` 行、
  `recoveryActions`、`plainTextLines` 的 `Snapshot`），从而免费继承已有的测试与可复制报告约定。
- **需要分类的 cause：**

  | Cause | 含义 | 状态 |
  | --- | --- | --- |
  | `domainReported` | 连接原生携带域名，嗅探不参与 | pass |
  | `domainRecoveredBySniffing` | `sniffHost` 提供了规则实际匹配所用的域名 | pass |
  | `domainlessSnifferDisabled` | 无域名，嗅探关闭——**头号场景** | fail |
  | `domainlessProtocolNotCovered` | 无域名，嗅探开启，但该端口/协议不在 `sniff` map 里 | warn |
  | `domainlessNotSniffable` | 无域名，嗅探开启且覆盖了它，但什么也没恢复出来 | info |
  | `sniffedButNotOverridden` | 嗅探出了域名，但 `override-destination` 是关的 | warn |

- **验收标准：**
  - [ ] `sniffedButNotOverridden` 这一条必须先对着运行中的内核确认再发布——即 `override-destination: false`
        时是否会保留 `sniffHost` 但规则仍然按 IP 匹配。以内核的实际行为为准编码；不要发布一个描述文档而非
        观测结果的 cause。
  - [ ] 对无域名连接，结论要通过复用 `RuleMatchSimulator` 说出具体后果：*如果域名当时在，本会命中哪条域名
        规则*。缺了这句话的 cause 只是一个事实，不是一条诊断。
  - [ ] 每个非 pass 的 cause 都带一个修复动作，且该动作只做一件事：写入 A1b 的片段——开启嗅探、把它扩展到
        这个端口、或打开 `override-destination`。不要在设置里放裸开关（§2.4）。
  - [ ] 修复应用之后，已有的 `RuntimeApplyOutcomeBanner` 会报告结果；对同一目标的新连接重跑诊断会返回
        pass。闭环是看得见的。
  - [ ] 可从 Connections 行进入，也可从该连接的 Routing 解释进入——用户注意到问题时正站着的那两个地方。
  - [ ] 分类器保持纯函数并被完整覆盖：每个 cause 一个测试，外加"本会命中哪条规则"那句话的测试。

##### A1d——`sniffer` 的订阅可信度（并入 C1）

`sniffer` **不在** [`CoreModels.swift:805`](../ClashMax/Models/CoreModels.swift#L805) 的危险 key 集合里。
也就是说，订阅今天就可以下发 `skip-domain`、`force-domain` 或 `override-destination: false`，改变哪些
规则命中用户的流量，而界面上不会呈现任何提示。

- **验收标准：**
  - [ ] `sniffer` 以 `warning` 级别加入被扫描的 key 集合——它改变的是流量识别，不是局域网暴露面——并给出
        点明后果的信息，语气与现有的 `dns`、`tun` 条目一致。
  - [ ] 导入时的报告（C1）说明该订阅的 sniffer 块想改什么、以及 ClashMax 保留了什么。

##### A1e——回归与手工验证

- **验收标准：**
  - [ ] D2 的脚本把 sniffer 开启与关闭加入其 模板 × 模式 矩阵，使未来某次改变 schema 的内核升级会让构建
        失败。
  - [ ] `MANUAL_TEST_PLAN.md` 增加端到端条目，并在 A1 宣告完成之前签核：一个走硬编码 IP 的 app → 为它写的
        `DOMAIN-SUFFIX` 规则不触发 → 诊断点名缺失的域名以及本会命中的那条规则 → 按下修复按钮 → 规则现在
        触发了，并在 Connections 行的 chain 中得到确认。

##### A1 的完成定义

五个阶段全部完成，且 A1e 经人工签核。按 D3 中点名的那个反复出现的失败模式，*"测试通过，但从没亲眼看过"*
不足以关闭本项——这一项针对的恰恰是"当用户说他的规则不生效时，要相信他"。

#### A2——把 `/dns/query` 接进 DNS 解析面板

- **问题：** 路由故事中间有个洞。我们能展示规则，也能展示出口 IP，但展示不了 DNS 实际返回了什么。
- **验收标准：**
  - [ ] `MihomoAPIClient` 增加 `dnsQuery(name:type:)`。
  - [ ] 面板接受一个域名，并报告：哪个 nameserver 应答的、地址是什么、以及该应答是否来自 fake-ip。
  - [ ] 结果喂给 `RuleMatchSimulator`，使面板在一处呈现 *域名 → 地址 → 命中规则 → 组 → 节点*。
  - [ ] 可从 Connections 行针对该连接的域名进入。
  - [ ] 失败状态是明确的（内核未运行、DNS 已禁用、查询超时）。

#### A3——把清空 fake-ip 缓存做成 L1 修复动作

- **问题：** 目前 fake-ip 映射脏了只能重启内核。
- **验收标准：**
  - [ ] `MihomoAPIClient` 增加 `flushFakeIPCache()`。
  - [ ] 作为相关诊断上的修复动作出现，而不是一个光秃秃的按钮。
  - [ ] 当 `enhanced-mode` 不是 `fake-ip` 时禁用，并说明原因。

#### A4——连接路径回放

- **问题：** 诊断是按子系统切分的。没有人能看到一条连接的完整路径。
- **验收标准：**
  - [ ] 对选中的连接，以单一有序视图呈现：DNS 应答（A2）→ 命中规则 → 选中的组 → 实际节点 → 出口 IP。
  - [ ] 每一步都标明该值的来源（内核 API、实时探测、模拟），使模拟出来的一步永远不会被误当成观测到的一步。
  - [ ] 对来自最近连接缓冲区的已关闭连接同样有效，而不仅限于活跃连接。

#### A5——一键生成脱敏诊断包

- **问题：** issue 报告过来时都是*"它不工作"*。这是每个 issue 都要付一次的维护成本。
- **基础：** [`StructuredLogPrivacy.swift`](../Shared/StructuredLogPrivacy.swift)、
  `SanitizedLineAccumulator`——脱敏本来就已经是一条代码边界。
- **验收标准：**
  - [ ] 导出内容包括：应用/内核版本、有效运行时 YAML、全部诊断结论、近期日志、helper/TUN/系统代理状态、
        网络环境。
  - [ ] 每一个密钥、订阅 URL、凭据和 SSID 在任何内容落盘**之前**就已脱敏，并由针对写入方（而不是 UI）的
        测试来保证。
  - [ ] 文件写入之前，用户先看到确切的内容。
  - [ ] 在 `SECURITY.md` 与 issue 模板中被引用。

#### A6——通过 `/group/{name}/delay` 做批量测速

- **验收标准：**
  - [ ] 整组测速走组端点；单节点测速仍走逐节点接口。
  - [ ] issue #18 确立的批次状态语义（running / completed / partial / failed / cancelled）被原样保留。
  - [ ] 在 1000+ 节点的组上实测，并把结果记入 `MANUAL_TEST_PLAN.md`。

---

### 主线 B——原生 macOS 优势

**目标：** 交付那些原生 macOS 客户端能做、而跨平台 Electron 客户端无法廉价复制的东西。

#### B1——带真正 app 选择器的按应用分流

- **问题：** 规则类型已经存在，缺的是可操作的入口。这是 ClashMax 与 Surge 之间最大的一处差距。
- **验收标准：**
  - [ ] 选择器列出已安装应用的名称、图标与 bundle identifier，并生成正确的 `PROCESS-NAME` 或
        `PROCESS-PATH` 规则。
  - [ ] 从两个地方可达：Routing 编辑器，以及 Connections 行上的*"让这个 app 走…"*（图标与路径本来就在
        那儿）。
  - [ ] 生成的是写入普通片段的普通快速规则（INV-1）——不新增存储。
  - [ ] 应用之后，已有的 post-apply 结论说明现在是哪条规则胜出。
  - [ ] 帮助文本明确说明进程规则在什么情况下无法命中（例如流量经系统代理到达，而内核无法归因到进程）。

#### B2——场景化：推广 `NetworkPolicyRule`

- **问题：** 按 SSID 的策略能切换模式和系统代理，但切换不了配置文件或生效的规则集——而后者才是"在家 / 在
  公司 / 连热点 / 出差"真正需要的。触发条件也只有 SSID，因此以太网和手机共享网络完全不可见。
- **验收标准：**
  - [ ] 触发条件扩展到 SSID 之外：接口类型（Wi-Fi / 以太网 / 蜂窝）、指定网络、存在 VPN，以及作为显式兜底
        的"无匹配"。
  - [ ] 动作扩展到：选择配置文件、启用/禁用具名片段、选择代理组节点。
  - [ ] 同一时刻恰好有一个场景生效，优先级是确定的，且当前匹配的理由是可见的。
  - [ ] 迁移已有的 `NetworkPolicyRule` 值不改变行为，并由针对已持久化 fixture 的解码测试覆盖。
  - [ ] 场景切换会被呈现出来（菜单栏 / 通知）；静默重配置别人的网络是不可接受的。

#### B3——App Intents 与快捷指令

- **验收标准：**
  - [ ] 提供以下 intent：设置路由模式、选择配置文件、在组内选择节点、开关系统代理、开关 TUN、激活场景。
  - [ ] 每个 intent 都报告成功或具体失败；不允许任何一个静默空转。
  - [ ] 需要特权 helper 的 intent，以 UI 给出的同样可操作的指引失败，并复用 `HelperSetupGuidance`。
  - [ ] 在快捷指令 App 中手工验证，并记入 `MANUAL_TEST_PLAN.md`。

#### B4——控制中心小组件

- **验收标准：**
  - [ ] 可切换路由模式，并在应用之外展示实时状态。
  - [ ] 按 [`DEVELOPMENT.md`](DEVELOPMENT.md) 中的可用性纪律做 macOS 版本门控，并在更低版本上提供可用的
        退路。
  - [ ] 不能变成第二个真相来源：状态来自应用读取的同一个 store。

#### B5——Geo 数据库维护

- **问题：** `geox-url` / `geo-auto-update` / `geodata-mode` 被认得但不被支持，因此 geo 规则会漂移。
- **验收标准：**
  - [ ] 这三个 key 由应用管理并生成进运行时 YAML。
  - [ ] 通过 `/configs/geo` 手动刷新，且最近一次更新时间可见。
  - [ ] 下载失败或不完整时，绝不会留下一个损坏的数据库。
  - [ ] 默认 URL 有文档说明，并可在 L3 覆盖。

---

### 主线 C——订阅可信度

**目标：** 正视订阅的本质——**别人交给你的一份可执行配置**——并让这件事变得可见。

一份订阅可以改你的 DNS、开监听端口、重绑外部控制器。`ProviderOptionsRisk` 已经知道这一点；还没有任何
客户端把它当成一个正经功能来做。

#### C1——导入时的订阅审计报告

- **基础：** [`CoreModels.swift:805`](../ClashMax/Models/CoreModels.swift#L805) 中的
  `ProviderOptionsRisk`。
- **验收标准：**
  - [ ] 在导入时和更新时，给出一份大白话报告：这份订阅试图改什么、ClashMax 覆盖了什么、放行了什么。
  - [ ] 严重级别是可操作的——每个 `danger` 条目都点名具体后果。
  - [ ] 该报告之后仍可从配置文件处进入，而不只在导入时出现一次。
  - [ ] 至少覆盖现有的危险 key 集合，外加 `sniffer`（A1d）。

#### C2——订阅更新 diff

- **问题：** 上周还安全的订阅，可能在下一次更新时悄悄加一个危险 key。今天没有任何地方会呈现这件事。
- **验收标准：**
  - [ ] 每次更新都保存足以与上一次抓取做 diff 的信息。
  - [ ] 节点变动（新增/移除/改名）与**配置**变更分开汇总；只有后者能触发风险提示。
  - [ ] 新出现的危险 key 会阻止静默自动应用，并主动询问。
  - [ ] diff 存储有容量上限，并与其他一切一样做脱敏。

#### C3——就 `listeners` 做出决定

- **问题：** `listeners` 目前被当作风险直接剥离，没有后续路径——这是正确的默认值，和错误的终点。
- **验收标准：**
  - [ ] 在本文中写下一个决定：要么在 L3 经用户明确同意后支持，要么永久不支持并说明理由。
  - [ ] 若支持：局域网暴露按监听器逐个选择加入，出现在运行时 diff 中，并且绝不在无提示的情况下从订阅继承。

---

### 主线 D——工程可持续性

**目标：** 停止为上面每一个功能支付利息。它不是一个独立里程碑——与 A/B/C 交织进行，只改动当前功能已经碰到
的那部分。

#### D1——拆解 `AppModel`

- **问题：** [`AppModel.swift`](../ClashMax/Stores/AppModel.swift) 有 **8845 行**；
  [`SettingsView.swift`](../ClashMax/Views/SettingsView.swift) 有 **3085 行**。本路线图中的每个功能，落到
  那里都要交一笔税。
- **时机：** Observation 迁移刚完成，因此失效边界目前是被充分理解的。这种理解会衰减。
- **验收标准：**
  - [ ] 按领域拆分——运行时、路由、配置文件、诊断——并保持视图已经在消费的同一套公开接口。
  - [ ] 行为不变：完整测试套件在当前基线上通过，且不新增 skip。
  - [ ] 增量进行，一次一个领域，每一步都可独立回滚。
  - [ ] Observation 迁移的坑继续被尊重：`didSet` 在 `init` 中不会触发（预热钩子必须随属性一起搬家），
        以及结构化去重守卫是承重的。

#### D2——把 Mihomo 升级回归自动化

- **问题：** 今天验证一次内核升级要跨模板与模式手工进行。
- **验收标准：**
  - [ ] 有一个脚本对每一种 生成模板 × 路由模式 × DNS 覆盖 组合运行 `mihomo -t`，并以 `level=error msg=`
        那一行（而不是通用结尾）作为失败信息。
  - [ ] 在 CI 中针对内置内核运行。
  - [ ] 任何一个组合被新内核版本破坏，都会让构建失败，而不是被发布出去。

#### D3——补上手工验证的缺口

- **问题：** 这个项目历史上反复出现的模式是*"测试通过，但从没亲眼看过"*。已完成的若干功能都带着这条备注。
- **验收标准：**
  - [ ] `MANUAL_TEST_PLAN.md` 增加一份按版本的清单，覆盖自动化到不了的流程：菜单栏面板、TUN 授权、场景
        切换、快捷指令、app 选择器。
  - [ ] 上面每个路线图条目，只有在其手工条目签核后才标记为完成。

---

## 5. 排期

刻意保守——一次推进一条主线，D 穿插其中。

| 阶段 | 内容 | 为什么是这个顺序 |
| --- | --- | --- |
| **首先** | **A1a** | 一个不带 UI 的解码器修复，也是硬前置：在连接解码器停止把"没有域名"坍缩成"目标 IP"之前，A1c 的诊断根本算不出来。可以单独发布，一天的量。 |
| **然后** | **A1b + A1c + A1d** | 本文中优先级最高的一项，也是能验证整套论点的最小闭环：一个真实的内核缺口、一个真实的诊断缺口、一个修复按钮、不需要新的 UI 范式。如果三层模型是错的，这里能以最低代价暴露出来。 |
| **然后** | A2 | 路由故事的另一半。放在 A1 之后做，这样 DNS 面板里显示的域名和规则实际匹配所用的域名，是已知同一个值。 |
| **然后** | A3、A5、C1 | 低风险、高杠杆。A5 与 C1 都直接降低维护者负担；C1 吸收 A1d。 |
| **然后** | B1、A4 | B1 是最重磅的面向用户功能；A4 是让护城河变得显而易见的那个界面。B1 放在 A1 之后，免得进程规则成为第二个在无域名连接上失效的东西。 |
| **然后** | B2、C2 | 两者都是有状态的，需要先让前面的工作变得可信。 |
| **之后** | B3、B4、B5、A6、C3 | 有价值，但不承重。 |
| **贯穿始终** | D1、D2、D3 | 永远不作为独立里程碑。 |

---

## 6. 非目标

写在这里，是为了不再被反复拿出来讨论：

- **与 Clash Verge Rev / mihomo-party 的功能对等。** 开关数量不是 ClashMax 竞争的那条轴。
- **为每个 Mihomo key 都做一个开关。** 按 INV-2，答案是通用覆盖。
- **遥测或账号体系。** 与 [`DEVELOPMENT.md`](DEVELOPMENT.md) 中的 MVP 范围保持一致，不变。
- **机场节点收集、节点售卖，或内嵌 Sub-Store。**
- **任何运行时 AI 功能。** 与 [`CODEX_OSS_PLAN.md`](CODEX_OSS_PLAN.md) 一致：AI 是维护仓库的工具，
  永远不是随应用发布的功能。
- **Windows 或 Linux。** 整条主线 B 的论点就是"只对一个平台原生"本身就是优势。

---

## 7. 如何修改本文

- **§2 的原则具有规范效力。** 修改它们需要在本文中写下理由，而不是在某个 pull request 里开一次性例外。
- **§3 的缺口是带日期的结论。** 引用前请重新核实；它们截至 2026-08-14 为真。
- **§4 的主线是一个队列，不是合同。** 可以自由重排；但不要悄悄丢弃某一项——把它移到 §6 并说明理由。
