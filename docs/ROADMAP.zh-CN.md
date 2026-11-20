# ClashMax 发展路线图

[English](ROADMAP.md) | **简体中文**

> 本文与英文版逐节对应；出现不一致时，以英文版为准。

**状态核对：2026-11-17**，依据源码版本 `9fe49fa`。
本次仅核对源码和文档，未运行应用、测试或真实网络检查。
应用和内核版本分别以 [project.yml](../project.yml) 与[内核 manifest](../Resources/Core/mihomo-manifest.json) 为准，不在这里重复维护。

本文区分已有实现、尚缺实现和人工验收记录。**已有实现不等于人工验收通过或发布就绪。**
保留原有条目 ID，便于源码注释、测试和历史记录继续引用。

环境与规则见[开发指南](DEVELOPMENT.md)，观察与签核见[人工验收计划](MANUAL_TEST_PLAN.md)，
签名安装包门禁见[发布指南](RELEASE.md)。旧实现决策与实测依据保存在[历史路线图](archive/ROADMAP-2026-11-17.zh-CN.md)。

## 1. 定位

ClashMax 是原生 macOS 代理客户端，重点解释 Mihomo 实际做了什么：哪条规则胜出、
配置是否生效，以及怎样修复具体的代理、DNS 或路由故障。控件围绕用户问题设计；
任意 Mihomo key 通过共用运行时片段覆盖。

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

第二条在 2026-08-29 才真正成立。承载它的是 **Raw YAML** 片段载荷
（[`RawYAMLPatch.swift`](../ClashMax/Models/RawYAMLPatch.swift)）——Routing 页上与规则、DNS、嗅探并列的
一种普通片段类型，走的是与其他片段完全相同的保存、预检、diff 与回滚路径。它在**所有应用托管键之后**合并
（[`ConfigNormalizer.swift`](../ClashMax/Services/ConfigNormalizer.swift)），而旧的按配置文件的
"Runtime Merge YAML" 字段从来做不到这一点：它合并发生在那些写入*之前*，所以 `mode`、`tun.*`、
`dns.enable` 和 geo 相关键始终会盖过它；它的编辑器也已随开发者模式开关一起从配置编辑面板移除（已有该
字段的配置仍会生效）。只有
`mixed-port`、`external-controller`（及其变体）和 `secret` 会被拒绝，而拒绝它们恰恰是在**服务** INV-2，
而不是给它设上限：这些正是应用用来应用、校验和回滚的通道，每一个在设置里都已经有自己的控件，一旦某个补丁
把它们挪走，应用就再也无法回滚这个补丁本身。配置文件自带的入站监听键（`port`、`socks-port`、
`redir-port`、`tproxy-port`）不会被拒绝，而是在每一层（包括原始补丁）都被删除并写入应用日志
（issue #33）：Mihomo 会先于 mixed 监听器打开这些监听，所以一个同时声明了 `port: 7890` 的订阅会
先占住应用的端口，`mixed-port` 永远起不来。配置文件自带的其他控制器监听（`external-controller-tls`、
`-unix`、`-pipe`）也以同样方式从配置文件这一层删除并写入应用日志（2026-10-01，见 [C1](archive/ROADMAP-2026-11-17.zh-CN.md#c1导入时的订阅审计报告)）：unix socket
不校验密钥，所以带着它的订阅等于把内核交给了这台 Mac 上的每一个进程。

满足 INV-2 之后，**ClashMax 的上限就等于 Mihomo 的上限**，而 UI 不会膨胀。明天 Mihomo 发布一个新 key，
高级用户当天就能用上，我们什么都不用发。

**为什么这同样有利于新手：** 因为有 INV-1，新手按下修复按钮之后，可以*去看那个按钮写了什么*。应用在教它
自己的配置语言，而不是把它藏在一堵墙后面。新手就地成长为高级用户。

### 2.4 任何新配置界面的评审清单

在新增一个设置、一个开关或一个页面之前，先回答完这五个问题：

- **这属于哪一层？** 如果答案是"L1 和 L3 都算"，那它其实是两个功能。
- **如果是 L1：唯一的那个修复按钮是什么？它写入哪个片段？**
- **如果是 L2：它复用现有的规则 / 片段模型，还是又发明了一个？**（INV-1）
- **如果是 L3：通用覆盖路径是不是已经能到达它？** 如果是，就不要为它做专门 UI。自 2026-08-29 起，
      对一个普通 Mihomo key 而言，诚实的答案就是"能"——一个 Raw YAML 片段就够得着。
- **用户能不能看到最终的 YAML diff，并把它退回去？**（INV-2）

一个只有高级用户需要、且通用片段覆盖已经够得着的 key，就是**已完成**——为它单独做一个开关，是 L1 质量的
倒退。

## 3. 已有实现

下列条目已有源码实现。剩余人工观察在 §5 跟踪，不再写成缺少功能代码。
原始探测结果与验收理由保留在历史快照。

| ID | 已实现能力 | 当前源码 |
| --- | --- | --- |
| [A1](archive/ROADMAP-2026-11-17.zh-CN.md#a1sniffer把内核从未看到的域名找回来) | 嗅探配置、域名来源解码、域名可见性诊断与一键修复；A1e 签核仍未关闭 | [SnifferDiagnostics](../ClashMax/Models/SnifferDiagnostics.swift)、[SnifferSettings](../ClashMax/Models/SnifferSettings.swift) |
| [A2](archive/ROADMAP-2026-11-17.zh-CN.md#a2把-dnsquery-接进-dns-解析面板) | 内核 DNS 查询、应答/TTL/否定结果与规则模拟；API 不报告应答的上游 nameserver | [DNSResolutionDiagnostics](../ClashMax/Models/DNSResolutionDiagnostics.swift)、[MihomoAPIClient](../ClashMax/Services/MihomoAPIClient.swift) |
| [A3](archive/ROADMAP-2026-11-17.zh-CN.md#a3把清空-fake-ip-缓存做成-l1-修复动作) | fake-ip 诊断与缓存清空动作 | [FakeIPDiagnostics](../ClashMax/Models/FakeIPDiagnostics.swift) |
| [A5](archive/ROADMAP-2026-11-17.zh-CN.md#a5一键生成脱敏诊断包) | 脱敏诊断包预览、复制与文件导出 | [DiagnosticBundle](../ClashMax/Models/DiagnosticBundle.swift)、[DiagnosticBundleSheet](../ClashMax/Views/DiagnosticBundleSheet.swift) |
| [A6](archive/ROADMAP-2026-11-17.zh-CN.md#a6通过-groupnamedelay-做批量测速) | 整组测速、受限调度、取消与逐节点兜底 | [ProxyDelayTestCoordinator](../ClashMax/Stores/ProxyDelayTestCoordinator.swift) |
| [A7](archive/ROADMAP-2026-11-17.zh-CN.md#a7tun-dns-modemihomo-v11933) | TUN `dns-mode` 校验、托管与状态报告 | [ConfigNormalizer](../ClashMax/Services/ConfigNormalizer.swift)、[RuntimeDiagnosticsStore](../ClashMax/Stores/RuntimeDiagnosticsStore.swift) |
| [B1](archive/ROADMAP-2026-11-17.zh-CN.md#b1带真正-app-选择器的按应用分流) | 已安装 App 选择器、覆盖整个 bundle 的进程规则、从连接创建规则 | [AppProcessRule](../ClashMax/Models/AppProcessRule.swift)、[ConnectionsView](../ClashMax/Views/ConnectionsView.swift) |
| [B3](archive/ROADMAP-2026-11-17.zh-CN.md#b3app-intents-与快捷指令) | 十个 App Intent 动作；九个 App Shortcut，为未来场景动作保留一个名额 | [ClashMaxAppIntents](../ClashMax/App/ClashMaxAppIntents.swift)、[ClashMaxIntentExecutor](../ClashMax/App/ClashMaxIntentExecutor.swift) |
| [B5](archive/ROADMAP-2026-11-17.zh-CN.md#b5geo-数据库维护) | Geo 设置、文件清单、过期诊断与更新动作 | [GeoDatabaseStore](../ClashMax/Stores/GeoDatabaseStore.swift) |
| [C1](archive/ROADMAP-2026-11-17.zh-CN.md#c1导入时的订阅审计报告) / [C3](archive/ROADMAP-2026-11-17.zh-CN.md#c3就-listeners-做出决定) | 导入/更新审计、配置页入口、继承监听器授权与实际暴露诊断 | [SubscriptionAudit](../ClashMax/Models/SubscriptionAudit.swift)、[ListenerExposure](../ClashMax/Models/ListenerExposure.swift) |
| [D2](archive/ROADMAP-2026-11-17.zh-CN.md#d2把-mihomo-升级回归自动化) | 内置内核预检矩阵与架构检查已接入 CI；CI 安装并强制要求固定内核 | [CI](../.github/workflows/ci.yml)、[CoreRuntimePreflightTests](../ClashMaxTests/CoreRuntimePreflightTests.swift)、[BundledCoreArchitectureTests](../ClashMaxTests/BundledCoreArchitectureTests.swift) |
| UI 焕新 | 原生工作区、九个页面、检查器/Sheet、SwiftUIX 输入适配与 320 pt 菜单栏内容 | [ContentView](../ClashMax/Views/ContentView.swift)、[NativeInputs](../ClashMax/Views/NativeInputs.swift)、[历史方案](UI_REFRESH_PLAN.md) |
| Observation 迁移 | Store/服务使用 `@Observable` 与类型化环境访问，原 Combine 观察转发已替换 | [AppModel](../ClashMax/Stores/AppModel.swift)、[历史设计](superpowers/specs/2026-08-03-observable-migration-design.md) |

### 保留的运行时决策

- 新安装的 TUN 栈默认继续使用 **Mixed**，保留已有选择。
  [v1.19.32 记录](MIHOMO_1_19_32.md)说明了为何没有跟随上游改默认值。
- 保留应用托管的系统 DNS 覆盖；开启时将 TUN `dns-mode` 固定为 `disabled`，Raw YAML 片段仍按已有规则覆盖。
  维护者的 [2026-10-25 决定](archive/ROADMAP-2026-11-17.zh-CN.md#a7tun-dns-modemihomo-v11933)继续有效，本次整理不重新决策。
- 仅支持应用托管的内置 Mihomo 渠道。其他渠道须先具备 manifest、完整性校验、Helper 允许列表、UI 状态与回滚。

## 4. 未完成工作

四组功能仍开放：A4、B2 及其依赖的 B3 场景动作、B4、C2。
D1/D3 属于工程与验收工作。结构化日志另列，因为它已有基础设施，但产品尚未端到端实现。

### A4——连接路径回放

已有连接历史、内核上报规则/chain、规则解释、DNS 查询与公网 IP 诊断，但尚未串成针对一条连接的完整有序回放。

- [ ] 对选中连接呈现：DNS 应答 → 命中规则 → 代理组 → 实际节点 → 出口 IP。
- [ ] 标注内核上报、实时探测或模拟的来源、时间，以及不可得的数据。
- [ ] 支持保留的已关闭连接；现在发起的 DNS/IP 探测不能被展示成旧连接建立时的观测。

### B2——场景化：推广 `NetworkPolicyRule`

[NetworkPolicyRule](../ClashMax/Models/CoreModels.swift) 仍按 SSID 匹配，控制路由模式、系统代理和运行时自动启动，不能选择配置、片段或节点。

- [ ] 触发条件扩展到接口类型、指定网络、VPN 存在与明确的无匹配兜底。
- [ ] 动作扩展到选择配置、启停具名片段、选择代理组节点。
- [ ] 同时恰好有一个场景生效，优先级确定，匹配理由可见。
- [ ] 旧 SSID 策略解码迁移不改变行为，并以持久化 fixture 测试覆盖。
- [ ] 切换通过菜单栏或通知呈现。

### B3——App Intents 与快捷指令：场景动作

- [ ] B2 有场景模型后，增加**激活场景**，使用已保留的 App Shortcut 名额。

其余十个动作已有实现。Shortcuts.app 与冷启动后台拉起的观察归入 §5 人工验收，不再作为十个待开发动作。

### B4——控制中心小组件

当前工程没有 Widget target 或控制中心实现。

- [ ] 在应用之外切换路由模式并展示实时状态。
- [ ] 对新 macOS API 做版本门控，保留 macOS 15 部署目标的实用途径。
- [ ] 消费同一份应用状态，不新增第二个真相来源。

### C2——订阅更新 diff

[ProfileStore](../ClashMax/Stores/ProfileStore.swift) 预检后替换订阅，
[ProfileCoordinator](../ClashMax/Stores/ProfileOperationsStore.swift) 随后审计。
旧原文只用于写入失败回滚，尚未成为有历史存储、用户可见 diff 或风险确认门禁。

- [ ] 保留有容量上限且脱敏的信息，与上次抓取比较。
- [ ] 节点新增/删除/改名与配置变化分开汇总。
- [ ] 新增危险 key 时阻止静默应用，要求用户决策。
- [ ] diff 存储有界、脱敏，保留已经生效的 C1/C3 保护。

### D1——拆解 `AppModel`

**进行中。** 配置操作、系统代理、诊断、Geo、出口代理端点、网络策略和测速已有独立 Store/Coordinator。
旧的整块行数已过时；继续拆分前先核对当前所有权。

- [ ] 随当前工作继续拆运行时与路由职责，保持视图消费的公开接口。
- [ ] 每次领域拆分可独立回滚；跨领域抽取时用完整套件对照基线，不新增 skip。
- [ ] 保留初始化预热（`didSet` 在 `init` 不触发）、结构化去重和有意使用的 `@ObservationIgnored` 高频状态。

### D3——补上手工验证的缺口

[已跟踪的每次发版清单](MANUAL_TEST_PLAN.md#per-release-checklist)已经建立。
剩余工作是执行，并记录被验版本的实际观察。

- [ ] 完成 §5 尚缺的功能与签名安装包观察。
- [ ] 记录日期、应用/内核版本、macOS/架构、实际现象与证据后，才标记人工验收通过。
- [ ] 未运行、受阻的门禁保持相应状态；单元测试和 fixture 截图不能代替。

### 相关设计——结构化日志拆分

**基础设施部分实现，端到端实现仍开放。** 已有共享 producer、脱敏器、行累积器和工程保护脚本。
应用仍使用 `RuntimeDataStore.logs`，计划中的 recorder、应用/运行时独立 Store、JSONL 轮转持久化和双通道查看器尚缺。

保留[已确认设计](superpowers/specs/2026-07-28-structured-logging-design.md)与
[实施计划](superpowers/plans/2026-07-28-structured-logging.md)作为独立事项。
恢复实施前重新核对步骤与基线；旧勾选、行号和测试数量不代表当前状态。

## 5. 仓库中仍缺的人工签核

此表记录缺少签核，不能据此断言从未有人用过功能。本次 2026-11-17 文档整理没有执行新的人工验收。

| 范围 | 仍需观察 | 入口 |
| --- | --- | --- |
| A1e | 真实无域名连接 → 原因诊断 → 修复 → 新连接命中域名规则 | [A1](MANUAL_TEST_PLAN.md#a1--a-domainless-connection-is-diagnosed-and-repaired-end-to-end) |
| A2 / A3 / B5 | 真实 DNS 结果及否定/失败状态、fake-ip 修复适用性、Geo 文件与更新结果 | [人工计划](MANUAL_TEST_PLAN.md) |
| A5 / B1 / B3 / C1 / C3 | 导出预览字节一致、App/辅助进程分流、快捷指令结果与冷启动、审计入口与监听器授权 | [每次发版清单](MANUAL_TEST_PLAN.md#per-release-checklist)及各功能条目 |
| A6 | 大组测速滚动、取消、每个节点终态与诊断计数 | [A6](MANUAL_TEST_PLAN.md#a6--whole-group-delay-testing-on-a-group-of-1000-nodes)；传输层实测已有记录 |
| 原生 UI | macOS 15 外观、真实 MenuBarExtra、键盘焦点、输入法、VoiceOver 与系统辅助功能开关 | [UI 验收](MANUAL_TEST_PLAN.md#native-ui-acceptance) |
| 签名联动 | 已安装 Helper/NE、TUN/DNS/路由恢复、切网、睡眠唤醒及 UDP/QUIC | [发布指南](RELEASE.md)、[TUN 矩阵](TUN_SMOKE_TEST.md) |

保留 A1 的关闭条件：A1a–A1d 已实现，但 **A1e 签核后才能验收关闭 A1**。
整组测速传输实测、源测试、签名数据面验收分别记录证据。

## 6. 非目标

- 与其他 Mihomo 客户端比开关数量，或为每个 Mihomo key 单独做控件。
- 遥测、账号、节点收集/售卖、订阅分析或内嵌 Sub-Store。
- 运行时 AI 功能；[维护提案](CODEX_OSS_PLAN.md)讨论的是仓库工作。
- Windows 或 Linux 移植。

现有 Sparkle 更新仍可维护；历史 MVP 排除项不代表要删除已存在的更新能力。

## 7. 更新规则

- §2 继续具有规范效力；改变原则须在这里记录理由。
- 链接当前符号/文件，避免维护易失效的行数；注明源码核对日期，版本固定值留在原有源文件。
- 分别记录实现与验收。人工观察只有取得记录证据才勾选。
- 移动条目保留 ID；可重排，删除事项须在 §6 写明理由。
- 保留原有依赖顺序：先补 A1e，再 A4；B2/C2 在诊断基础之后；B3 场景动作依赖 B2，B4 排后；D1/D3 随涉及领域推进。
- 实测契约、安全决策和带日期的结果保存在[英文归档](archive/ROADMAP-2026-11-17.md)与
  [中文归档](archive/ROADMAP-2026-11-17.zh-CN.md)。旧未勾选框是历史状态，不是另一份活跃队列。
