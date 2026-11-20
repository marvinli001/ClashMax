# ClashMax Home v2 — SwiftUI 实现任务

你要在 ClashMax（原生 macOS 15+ SwiftUI 的 Mihomo 客户端）里实现首页（Home / `AppSection.home`）的 v2 重设计。设计方向已经和作者确认，下面是完整规格。先通读本文件，再读列出的源码，然后直接动手实现；不要停在"给出计划"。

---

## 0. 开工前必须做的事（硬性）

1. **读仓库根目录的 `AGENTS.md`**，并遵守其中全部规则。与本任务最相关的几条：
   - 先 `git status`。工作区里**已经有未提交的改动**，其中 `ClashMax/Views/Dashboard/RunningDashboardView.swift`、`TrafficSparkline.swift`、`CoreVisualView.swift`、`ContentView.swift` 等都有别人的修改（例如 `DashboardHeaderRoute` / `DashboardHeaderRouteLine`、`TrafficSeriesColor`）。**在这些改动的基础上继续改，不要 reset / checkout / 覆盖 / 整文件格式化。** 只改本任务需要的地方。
   - 不要 commit、不要 push，除非作者明确要求。
   - 不碰签名、entitlements、`project.yml` 的签名/依赖设置。
   - 加载骨架屏只能用 `ClashMax/Views/LoadingSkeletons.swift` 里的共享原语（`ClashMaxSkeletonBar` / `ClashMaxSkeletonRow` / `ClashMaxCurrentNodeSkeleton` 等），且**只用于真正的异步加载**；已停止、空、失败、恢复状态绝不能用骨架屏代替。
   - 状态必须显式：stopped / starting / running / crashed / blocked(readiness issue) / no profile / preview runtime / validation failed，每种都有明确文案和可操作的恢复动作。
   - 不得复制任何闭源项目（尤其 `666OS/ClashMac`）的代码、素材或 UI；FlClash / Clash Verge 只作视觉参考，不搬代码。
   - SwiftFormat 用 `.swiftformat` 里 `--minversion` 钉死的版本，**只格式化你改过的 Swift 文件**（显式列文件路径），不要跑会把别人未提交文件也选进去的 `--fix`。
2. **新增的用户可见字符串**必须同时进 `Resources/Localizable.xcstrings`（en + zh-Hans）。CLI xcodebuild 不会自动刷新源 xcstrings，需要手动加 key；插值字符串的 key 形如 `"Peak %@"`。改完跑 `script/localization_gate.sh` 和 `script/localization_new_key_gate.sh`。别忘了 `LocalizationTests` 会检查陈旧/缺失 key。

---

## 1. 必读源码（实现前先读）

| 文件 | 你需要知道的 |
|---|---|
| `ClashMax/Views/Dashboard/DashboardView.swift` | Home 根视图：`GeometryReader` + `ScrollView` + `RunningDashboardView`，`DashboardLayoutMetrics.pagePadding / dashboardMaxWidth` |
| `ClashMax/Views/Dashboard/RunningDashboardView.swift` (~2.5k 行) | 现在的 Home：`RunningHeaderCard`（profileMenu / routingMenu / 运行设置菜单 / Start-Stop）、`DashboardHeaderRoute(+Line)`、`DashboardRuntimeNumbers` + `DashboardRuntimeMetric`（含 `launchFacts`）、`CurrentProxyRuntimeCard`（含 `DashboardNodePickerButton` 节点选择 popover、自动测延迟 `.task(id:)`）、`TrafficRuntimeCard`、`ProxyGroupsRuntimeCard`、`TunDiagnosticsAttentionRow`、`NetworkExtensionAttentionRow`、`RuntimeContentEntrance`。`StatusView` 也在这个文件里但属于 Status 页，**不要动**。 |
| `ClashMax/Views/Dashboard/DashboardComponents.swift` | `SurfaceRadius`、`DashboardLayoutMetrics`、`RunModePicker`、`ProxyRoutingModePicker`、`ProxyRoutingSettingsButton`、`CardSurface` / `TileSurface`（`.cardSurface` / `.tileSurface`）、`DashboardCardModifier` / `.dashboardCard()` |
| `ClashMax/Views/Dashboard/PublicIPInfoCard.swift` | 出口 IP：`maskedAddress` + 显示全部开关、`PublicIPProxyEffectPresentation`（代理效果判定）、`PublicIPInfoDetail` |
| `ClashMax/Views/Dashboard/TrafficSparkline.swift` | `TrafficChartGeometry`、`TrafficSeriesShape`、`TrafficSparkline`、`DashboardTrafficSparkline`、`TrafficSeriesColor`（download 蓝 / upload 橙） |
| `ClashMax/Views/NativeInputs.swift` | `RuntimePrimaryActionStyle`（macOS 26 用 `.glass/.glassProminent`）、`PopUpSelectionButton` |
| `ClashMax/Views/ProxiesView.swift` | `ProxyDelayDisplay`（延迟文案 + tone 颜色，Home 必须和 Proxies 页同一套判定） |
| `ClashMax/Views/ContentView.swift` | 工具栏 `RunModePicker`（规则/全局/直连）和非 Home 页才显示的 Start/Stop |
| `ClashMax/Views/UIRefreshFixture.swift` | 合成数据 fixture，用来截图验收（见第 6 节） |
| `ClashMax/Models/CoreModels.swift` | `ProxyRoutingMode`（systemProxy / tun / neProxy）、`RunMode`、`TrafficTotals`、`CoreMemorySample`（**macOS 上 osLimit 恒为 0，不能画"占上限百分比"**）、`ConnectionSnapshot`（`host`、`exitNode`、`upload`/`download`、`chain`） |
| `ClashMax/Stores/AppModel.swift` / `RuntimeDataStore.swift` | `start()` / `stop()` / `canStopRuntime` / `readinessIssue` / `requestProxyRoutingMode(_:)` / `requestMode(_:)` / `overrides.mode` / `sessionStartedAt` / `publicIPInfoState`；`runtimeData.trafficHistory / trafficSample / trafficTotals / memorySample / connections` |
| `ClashMaxTests/PageSimplificationTests.swift`、`DashboardRuntimeStateTests.swift`、`MenuBarPanelLayoutTests.swift` | 现有 Home 相关断言（如 `DashboardHeaderRoute`）。改结构时同步更新测试，别删测试来"变绿"。 |

---

## 2. 设计目标（为什么改）

现在的 Home 问题：同一信息重复 2–3 次（"组 → 节点"在顶部、当前节点卡、代理组卡各一次；出口位置两次；上下行速率两次），数字没有趋势，Start/Stop 视觉上像禁用，控件分散，下半部分卡片高低不齐。

v2 的原则：
- **每条信息只出现一次**，层级从"我现在走哪条线、是否生效" → "怎么控制" → "跑得怎么样" → "细节"。
- **大气、有立体感**：大号节点名、大号数字、卡片有轻微抬起的阴影、卡片内部用比卡片深一级的"凹槽（well）"承载次级信息——参考 FlClash 那种分层，但用 macOS 原生尺度（不要它的花瓣形按钮、超大圆角、彩虹配色）。
- **安静**：一个强调色 + 语义色（上行橙、下行蓝、成功绿、警告橙、错误红），不给每张卡配一个颜色。

---

## 3. 布局（从上到下）

```
┌───────────────────────────── ① 状态主卡 Hero ─────────────────────────────┐
│ ● 运行中   Example Workspace ⌄                                      (⋯)    │
│ Tokyo · Example 1                         ┌──── 出口 well ─────────────┐  │
│ [▤ Default] [VLESS] [⚡ 28 ms]             │ 🌐 出口        [代理生效 ›] │  │
│                                            │ [JP] Tokyo                 │  │
│                                            │ 203.xxx.xxx.42  👁         │  │
│                                            │ AS64496 · 1 分钟前   ↻     │  │
│                                            └────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────────── ② 控制卡 Control ─────────────────────────────┐
│ 流量接管                      运行模式                  ╭──────────────╮   │
│ [系统代理|TUN|网络扩展] ⚙     [规则|全局|直连]          │ (⏻)  停止     │   │
│                                                         │      1:00:14 │   │
│                                                         ╰──────────────╯   │
└────────────────────────────────────────────────────────────────────────────┘
┌─③ 下载 ──────┐ ┌─ 上传 ───────┐ ┌─ 连接 ───────┐ ┌─ 核心内存 ───┐
│ ↓ 下载  峰值14│ │ ↑ 上传        │ │ ⌁ 连接       │ │ ▣ 核心内存   │
│ 11.9 MB/s    │ │ 1.3 MB/s     │ │ 32           │ │ 48 MB        │
│ 本次 2.14 GB │ │ 本次 312 MB  │ │ ▇▇▇▇▇▇▇░░    │ │ mihomo 1.19… │
│▁▂▃▅▃▆▄▅▇ 面积 │ │▁▂▁▃▂▄▂▃▄ 面积 │ │ 代理26·直连6 │ │              │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
┌──── ④ 流量图 (60%) ─────────────────┐ ┌──── 代理组 (40%) ─────────────┐
│ 流量          ↓11.9 MB/s ↑1.3 MB/s  │ │ Default   Tokyo · Ex 1 ⌄  28ms│
│  (现有 DashboardTrafficSparkline)    │ │ Streaming Singapore… ⌄    35ms│
│                                      │ │ Development Auckland… ⌄   42ms│
└──────────────────────────────────────┘ └───────────────────────────────┘
┌──────────────────────── ⑤ 流量去向（当前连接）─────────────────────────────┐
│ 按域名                                  │ 按出口节点                        │
│ youtube.com   ████████████  851 MB      │ Tokyo · Ex 1  ██████████ 1.1 GB   │
│ github.com    ████          212 MB      │ DIRECT        ██         101 MB   │
│ …(最多 5 行)                            │ …(最多 5 行)                      │
└────────────────────────────────────────────────────────────────────────────┘
```

TUN / NE 诊断失败时，`TunDiagnosticsAttentionRow` / `NetworkExtensionAttentionRow` 仍然插在 ② 控制卡下面（只在失败时出现，保留现有逻辑）。崩溃横幅（`.crashed(message)`）放在 ① 和 ② 之间，保留 "显示日志 / 状态" 两个按钮。

**删除**：旧 `RunningHeaderCard` 的整体结构、`CurrentProxyRuntimeCard` 卡片外壳、`DashboardRuntimeNumbers` 的五格数字条、`PublicIPInfoCard` 作为独立卡片在 Home 上的使用（组件本身其他地方若有引用则保留）。**复用**它们内部的逻辑和子视图（profileMenu、节点选择 popover、自动测延迟、IP 打码、代理效果判定、metric 数据计算），不要重写数据层。

响应式：
- 内容宽 ≥ `DashboardLayoutMetrics.runningPairColumnsBreakpoint`(800)：如上。
- < 800：Hero 的出口 well 落到节点信息下方（全宽）；控制卡三段纵向堆叠或 `ViewThatFits` 两行；KPI 变 2×2；④ 两张卡上下堆叠；⑤ 两列变上下。
- 最小窗口 980×660 下首屏必须完整看到 ①②③，不出现横向截断；中文和超长 profile/节点名（fixture 的 `--long-text`）要 `lineLimit(1)` + 中间截断 + `.help` 显示全文。

---

## 4. 视觉规格（SwiftUI 落地）

### 4.1 Home 专用 token（加到 `DashboardComponents.swift`，只给 Home 用，别改 `SurfaceRadius.card` 影响其他页）

```swift
enum HomeMetrics {
  static let cardRadius: CGFloat = 14      // Hero / Control / KPI / 下方卡片
  static let wellRadius: CGFloat = 10      // 卡片内部凹槽
  static let sectionSpacing: CGFloat = 14  // 卡片之间纵向间距
  static let gridSpacing: CGFloat = 12     // 同一行卡片间距
  static let cardPadding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
  static let heroPadding = EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 18)
}
```

### 4.2 立体层级（关键）

三层：**页面底**（`windowBackgroundColor`，保持现有 `DashboardSceneBackground`）→ **卡片**（抬起）→ **well**（下沉）。

- `HomeCardStyle`（新 ViewModifier，取代 Home 上的 `.dashboardCard()`）：
  - 填充 `.cardSurface`（现有），形状 `RoundedRectangle(cornerRadius: HomeMetrics.cardRadius, style: .continuous)`。
  - 描边 0.5pt：浅色 `Color.black.opacity(0.07)`，深色 `Color.white.opacity(0.08)`；深色模式再加一条顶部 1pt 内高光（`LinearGradient` 白 0.06 → 0 的 strokeBorder，只在上半部可见），让卡片在深色下也"浮"起来。
  - 双层阴影（接触 + 扩散）：浅色 `.shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)` + `.shadow(color: .black.opacity(0.06), radius: 12, y: 4)`；深色 `.black.opacity(0.35), radius: 14, y: 6` 一层即可。阴影加在背景 shape 上（`.background { shape.fill(...).shadow(...) }`），不要加在内容上，否则文字也会有阴影。
  - 不要给整张卡加 Liquid Glass（现有注释已说明：玻璃只给浮在内容之上的 chrome 和可交互控件）。
- `HomeWellStyle`：填充 `.tileSurface`（现有：浅色 `primary.opacity(0.035)`，深色 `.quinary`），`wellRadius`，**无描边、无阴影**。用于出口区、电源胶囊底座、分段控件底座、流量去向的进度条轨道。
- 禁止卡片套卡片（well 不是卡片：没有边框和阴影）。

### 4.3 字体

- Hero 节点名：`.system(size: 24, weight: .semibold)`，`lineLimit(1)`，`minimumScaleFactor(0.75)`，`truncationMode(.middle)`。
- KPI 大数字：`.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()`，单位单独 `Text` 用 `.callout` + `.secondary`，基线对齐（`HStack(alignment: .firstTextBaseline, spacing: 3)`）；数字变化用现有 `.contentTransition(.numericText(value:))` + 0.2s easeOut（reduceMotion 时无动画；uptime 不做滚动动画——沿用现有规则）。
- 卡片标题/标签：`.callout` + `.secondary`，前面一个 SF Symbol（上行/下行箭头分别用 `TrafficSeriesColor.upload/.download` 着色，其余 `.secondary`）。
- 辅助说明：`.caption` + `.secondary`；更次要（时间戳）用 `.tertiary`。
- 出口城市：`.title3.weight(.semibold)`；IP：`.callout.monospaced()`。

### 4.4 Chip（胶囊标签）

统一 `HomeChip(text:, symbol:, tone:)`：`.caption.weight(.medium)`，padding 水平 9 / 垂直 3，`Capsule()`；tone 为 neutral 时底 `.tileSurface`、字 `.secondary`；success/warning/danger 时底 `tone.opacity(0.14)`、字 tone。延迟 chip 的 tone 必须来自 `ProxyDelayDisplay(state:).tone`，和 Proxies 页一致。状态 chip（运行中）左侧 6pt 圆点。

---

## 5. 各区块详细行为

### ① 状态主卡 Hero

左列（`VStack(alignment: .leading, spacing: 8)`）：
1. 顶行：状态 chip（运行中=绿点+success；启动中=`ProgressView().controlSize(.mini)`+"正在启动"；已停止=灰点+neutral "已停止"；崩溃=红 "已崩溃"；blocked=橙 "无法启动"；预览运行=neutral "预览运行"）+ profile 选择器（复用 `profileMenu` 的 `PopUpSelectionButton`，但字号降为 `.callout`、`.secondary`，带 `chevron.up.chevron.down`）。右上角放现有的"运行设置"`ellipsis.circle` 菜单（AI 服务检查、Mixed Port 步进、设置）。
2. 节点名（大标题）。**点击节点名打开现有 `DashboardNodePickerButton` 的节点列表 popover**（懒加载，1600 节点不卡——保留它的实现原因），即节点名本身就是切换入口；hover 时出现 `chevron.down` 和轻微背景。
3. chip 行：组名（`square.stack.3d.up`，点击是 `PopUpSelectionButton` 选择 Hero 跟踪哪个组 = 原 `selectedProxyGroupName`）、节点类型（`DashboardProxySelectionState.typeLabel`）、延迟 chip（点击 = `appModel.testDelay(in:for:)`，测速中显示 mini ProgressView；不支持测速的内置出站禁用并给 `.help`）。
4. 保留 `CurrentProxyRuntimeCard` 里的自动测延迟 `.task(id: automaticDelayProbeKey(...))` 逻辑，挂到 Hero 上。
5. 选中节点缺失（`hasMissingSelection`）时：标题显示 "所选节点不可用" + warning chip + 刷新按钮，复用现有 `selectionUnavailableMessage` 文案。没有可选组：显示 "此配置没有可切换的代理组" + "配置" 按钮。加载中：`ClashMaxCurrentNodeSkeleton`。

右列：出口 well（宽 ≥ 220，`HomeWellStyle`，内边距 12/14）：
- 标题行："出口" + 代理效果 chip（`PublicIPProxyEffectPresentation`：通过=success "代理生效"，警告/失败对应 tone，点击打开现有 `PublicIPInfoDetail` 的诊断内容，用 popover）+ 刷新按钮（`arrow.clockwise`，borderless）。
- 国家码徽章（`.caption.weight(.semibold)`，well 内再用 `.cardSurface` 小圆角 6 底，算作凸起的小标签）+ 城市/国家（用 `DashboardHeaderRoute.location(of:)`）。
- 打码 IP + 眼睛按钮（复用 `maskedAddress` / `showsFullIP` 逻辑）。
- `ASN · 相对时间`（`Text(date, style: .relative)` 或现有格式）。
- 状态：未运行 → "启动后检测出口"（quiet，不用骨架屏）；检测中且无旧值 → 骨架条；失败 → 失败原因 + 重试按钮。

把现有 `DashboardHeaderRoute` 类型保留（测试在用），可以继续用它给 Hero 提供 group/node/exit 文案。

### ② 控制卡 Control

`HStack(alignment: .bottom, spacing: 18)`，三段，每段上方一个小标签（`.caption` `.secondary`，带图标）：

1. **流量接管**：原生 `Picker(.segmented)`，选项 `ProxyRoutingMode.allCases`，每项 `Label(mode.displayName, systemImage: mode.symbolName)`；绑定 get `appModel.proxyRoutingMode`、set `appModel.requestProxyRoutingMode($0)`（**必须走 request，保留它的确认/helper 引导流程**）。右侧紧跟现有 `ProxyRoutingSettingsButton()`。启动中禁用。
2. **运行模式**：复用 `RunModePicker`，绑定 `appModel.overrides.mode` / `appModel.requestMode($0)`。同时在 `ContentView` 工具栏里**仅在 Home 页隐藏** `RunModePicker`（与现有"Home 不显示工具栏 Start/Stop"同一个 `if appModel.selectedSection != .home` 处理），避免一屏两个。
3. **电源胶囊 `HomePowerButton`**（右对齐，`Spacer` 推到最右）——这是本页唯一主操作，要精致：
   - 结构：`Button` 包一个胶囊：底座 `HomeWellStyle` 形状为 `Capsule()`，内边距 leading 5 / trailing 16 / vertical 5；左侧 38pt 圆形"按钮核"，右侧两行文字（标题 `.callout.weight(.semibold)`，副标题 `.caption.monospacedDigit()` `.secondary`）。
   - 状态映射：
     - 运行中：核 = 绿色实心圆（`Color.green`），外圈 3pt `Color.green.opacity(0.22)` 光环，图标 `power` 白色；标题 "停止"，副标题 = 运行时长（`TimelineView(.periodic(from:by: 1))`，只包住副标题，别让整卡每秒重算）。
     - 已停止且可启动：核 = `Color.accentColor` 实心，标题 "启动"，副标题 = 当前 profile 名或 "就绪"。
     - 启动中：核内 `ProgressView().controlSize(.small)`，标题 "正在启动…"，禁用。
     - 崩溃：核 = 红色，图标 `arrow.clockwise`，标题 "重新启动"。
     - readinessIssue 不为 nil 且不可停止：禁用，核灰色，副标题显示简短原因，`.help` 给完整原因（不要藏安全相关细节）。
   - macOS 26 且非 `reduceTransparency`：按钮核用 `.glassEffect(.regular.tint(<状态色>).interactive(), in: Circle())`；否则用实心填充 + `.shadow(color: 状态色.opacity(0.35), radius: 6, y: 2)`。用 `if #available(macOS 26, *)` 包，保持 macOS 15 可编译。
   - 交互：按下 `scaleEffect(0.96)` + `.spring(duration: 0.25, bounce: 0.2)`（自定义 `ButtonStyle` 读 `configuration.isPressed`）；hover 时底座略提亮；状态切换时图标 `.symbolEffect(.bounce, value: isRunning)`，核颜色用 `.animation(.easeInOut(duration: 0.25))` 过渡。全部在 `accessibilityReduceMotion` 时关闭动画。
   - 动作：`appModel.canStopRuntime ? appModel.stop() : appModel.start()`（与现有一致）。无障碍：`accessibilityLabel` "停止 ClashMax" / "启动 ClashMax"，`.help` 同。
   - 原 `CoreVisualView` 在 Home 上不再需要单独的 52pt 状态图标（状态由 chip + 电源核表达）；如果删掉它的使用，确认没有测试依赖，`CoreVisualView.swift` 文件本身不要删（有未提交改动，且可能别处在用）。

### ③ KPI 四卡（等宽 `Grid` 或 `HStack` + `.frame(maxWidth: .infinity)`，同高）

公共结构：标签行（图标 + 标题 + 右侧可选 caption）→ 大数字 → 辅助一行 → 底部可视化。卡高统一（`fixedSize(vertical)` + `maxHeight: .infinity`，参考现有 `DashboardResponsivePair` 的同高做法）。

1. **下载**：数字 = `TrafficSample.format(trafficSample.download)` 拆成"数值 + 单位"两段（写一个纯函数 `HomeRateParts.split(_:)` 并加单测；别解析本地化字符串，最好从字节数直接算）；右上 caption "峰值 X"（窗口内 `trafficHistory` 最大值）；辅助行 "本次 X"（`trafficTotals?.download`，沿用 `DashboardRuntimeMetric.sessionTotal` 的语义：随内核重启归零）。底部**贴边**面积迷你图：高 34，左右下无内边距（卡片 `clipShape` 保证圆角裁切），用最近 ≤60 个样本，线 1.6pt `TrafficSeriesColor.download`，面积 `LinearGradient(download.opacity(0.20) → 0.02)`。优先复用 `TrafficSeriesShape` / `TrafficChartGeometry`，不够用再写一个小 `Shape`。
2. **上传**：同上，橙色。
3. **连接**：数字 = `connections.count`；可视化 = 6pt 高分段条：代理 / 直连 / 拒绝 三段（按 `connection.exitNode` 是 `DIRECT` / `REJECT*` 归类，其余算代理；分类写成纯函数并加单测），代理段用 `.secondary`，直连 `.tertiary`，拒绝 `.red.opacity(0.6)`；辅助行 "代理 26 · 直连 6"（拒绝为 0 时不显示）。点击整卡跳转 `appModel.selectedSection = .connections`（卡片 hover 时显示 `chevron.right` 提示）。
4. **核心内存**：数字 = `memorySample.formattedInUse`（无读数显示 "—"）；辅助行 = 核心版本；**不要画百分比进度条**（`osLimit` 在 macOS 恒为 0）。可选：在 `RuntimeDataStore` 加一个 ≤60 的内存样本环形缓冲，底部画同款迷你线（中性色）；若加，记得在内核停止时清空，并补单测。

**停止状态**：KPI 行改为 4 个"启动信息"小卡（quiet，无迷你图）：运行模式、Mixed Port、代理组数、节点数（核心版本放到内存卡位置），数据来自现有 `DashboardRuntimeMetric.launchFacts`。没有 profile 时整个 KPI 行和 ④⑤ 都不显示，Hero 变成导入引导（现有 "导入 YAML…" + "添加订阅…"，后者 `.borderedProminent`）。

### ④ 流量图 + 代理组

- 流量卡：复用 `TrafficRuntimeCard` / `DashboardTrafficSparkline`，换成 `HomeCardStyle`；标题行右侧放实时 ↓/↑（删掉底部重复的 legend）；图高约 150。
- 代理组卡：基于 `ProxyGroupsRuntimeCard` / `DashboardProxyGroupsSummary`（最多 6 行 + "还有 N 个" 跳 Proxies）。每行：组名（`.callout.weight(.medium)`）、当前节点（`.secondary`，点击打开该组的节点 popover 直接切换）、延迟 chip、`chevron.right`（跳 Proxies 并定位该组，沿用现有行为）。Hero 正在跟踪的组那一行用 well 底色高亮。行高 30，行间 hairline 分隔，不要每行一个圆角卡。

### ⑤ 流量去向（新增）

- 数据：`runtimeData.connections`（**当前打开的连接**，标题注明"当前连接"，不要写成"今日/本次"，避免误导）。纯函数 `HomeTrafficDestinations.make(from:limit: 5)` → 两个列表：按 `host` 聚合 upload+download、按 `exitNode` 聚合；降序；空 host 归入 "(IP 直连)" 或用 destination IP。加单测（聚合、排序、limit、空输入）。
- 行：名称（`lineLimit(1)` 中间截断）+ 右侧字节数（`TrafficSample.formatBytes`，`.caption.monospacedDigit()`）+ 下方 3pt 进度条（轨道 well 色，填充 `.secondary`，宽度 = 该行 / 第一行）。
- 计算放在视图 body 之外：连接数可能上千，按 `connections` 变化用 `.task(id:)` 或在 store 里节流计算后缓存，避免每次重绘都 O(n) 聚合。
- 无连接时显示 quiet 空状态 "暂无活动连接"（不是骨架屏）。

### 入场动画

保留 `RuntimeContentEntrance`（只在刚启动 3 秒内生效），顺序：Hero 0 → Control 0.04 → KPI 0.08 → ④ 0.12 → ⑤ 0.16。`reduceMotion` 时关闭。

---

## 6. 验收（必须实际跑，按结果如实汇报 PASS / FAIL / BLOCKED / NOT RUN）

1. **构建**（DerivedData 不要放在仓库里，`~/Documents` 下会因 iCloud 扩展属性导致签名问题）：
   ```bash
   xcodebuild build -project ClashMax.xcodeproj -scheme ClashMax -configuration Debug -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/ClashMax-Tmp CODE_SIGNING_ALLOWED=NO
   ```
   若新增 Swift 文件需要 `xcodegen generate`，先确认它会保留作者在 Xcode UI 里的签名设置；不能确认就把新类型写进现有文件。
2. **聚焦测试**：新加的纯函数测试 + 受影响的测试类：
   ```bash
   xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/ClashMax-Tmp CODE_SIGNING_ALLOWED=NO -only-testing:ClashMaxTests/PageSimplificationTests -only-testing:ClashMaxTests/DashboardRuntimeStateTests -only-testing:ClashMaxTests/LocalizationTests -only-testing:ClashMaxTests/MenuBarPanelLayoutTests
   ```
   通过后再跑一次全量（改动涉及多文件）。基线：全量此前为全绿；若有失败，先对照 `git stash` 前的基线判断是不是你引入的，不要把别人的失败算到自己头上，也不要为了变绿删断言。
3. **截图验收**（合成数据 fixture，不连真实内核，不改系统代理）：
   ```bash
   APP=~/Library/Developer/Xcode/DerivedData/ClashMax-Tmp/Build/Products/Debug/ClashMax.app/Contents/MacOS/ClashMax
   "$APP" --ui-fixture --production --page home                 # 运行中，1180×760
   "$APP" --ui-fixture --production --page home --dark
   "$APP" --ui-fixture --production --page home --stopped
   "$APP" --ui-fixture --production --page home --starting
   "$APP" --ui-fixture --production --page home --crashed --long-text
   "$APP" --ui-fixture --production --page home --minimum       # 980×660
   "$APP" --ui-fixture --production --page home --wide
   "$APP" --ui-fixture --production --page home --empty
   "$APP" --ui-fixture --production --page home --animate-start # 观察 停止→启动中→运行 的过渡
   "$APP" --ui-fixture --production --page home -AppleLanguages "(zh-Hans)"
   ```
   加 `--capture <path.png>` 可自动截图（需要终端有"屏幕录制"权限；没有就手动截或说明 BLOCKED）。逐张检查：信息无重复、深浅色都有层级、最小窗口首屏完整、中文不截断、长名称中间省略、电源按钮四种状态正确。
4. **自查清单**（汇报里逐条回答）：
   - 组→节点、出口、上下行速率在页面上各只出现一次？
   - 工具栏在 Home 上不再有运行模式分段控件，其他页仍有？
   - 切换流量接管仍走 `requestProxyRoutingMode`（TUN helper 引导流程未被绕过）？
   - 1600 节点的组打开节点 popover 不卡（仍是懒加载）？
   - 停止/空/失败状态没有骨架屏？
   - 只格式化了自己改的文件？`git diff --stat` 里没有误伤别人的未提交改动？
   - 新字符串 en + zh-Hans 都有，localization gate 通过？

---

## 7. 交付

最后汇报：改了哪些文件（为什么）、新增了哪些类型、测试与截图结果（附截图路径）、未验证项与原因、任何与本规格不同的决定及理由。不要 commit。
