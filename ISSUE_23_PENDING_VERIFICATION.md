# Issue 23 Pending Verification

## 修复目标

- GitHub Issue: https://github.com/marvinli001/ClashMax/issues/23
- 问题：日志页和 Dashboard 最近日志卡片会把正常启动生命周期记录显示为 `ERROR`，并且长 runtime config path / controller message 在最近日志卡片中难以扫读。
- 补充回归：按本次要求，后续也需要确认运行中菜单栏/面板刷新没有回退到旧的卡住状态。
- 预期：正常启动、清理旧进程、检查端口、启动 core、controller ready 等生命周期事件显示为 `INFO`；真实失败仍显示为 `ERROR`；长日志在 Dashboard 与日志页中保持紧凑但可读。

## 本次已修改文件

- `ClashMax/Stores/AppModel.swift`
- `ClashMax/Views/LogsView.swift`
- `ClashMax/Views/Dashboard/RunningDashboardView.swift`
- `ISSUE_23_PENDING_VERIFICATION.md`

## 本次修复内容

- `AppModel.publishStartupDiagnostics(level:)` 不再把整批启动诊断按同一个等级发布；即使启动后续步骤失败，已成功的生命周期诊断也会按 `INFO` 发布。
- 端口占用、controller readiness 失败、core tail、启动前退出等诊断仍按 `ERROR` 发布。
- Mihomo SIGTERM 后需要 SIGKILL 的诊断按 `WARN` 发布，避免与真正启动失败混在一起。
- 日志页和 Dashboard 最近日志卡片共用同一套等级颜色规则，`ERROR`/`FATAL`/`PANIC` 为红色，`WARN` 为橙色，`DEBUG`/`TRACE` 为紫色。
- Dashboard 最近日志的长消息改为最多两行、中间截断，并提供 hover 完整内容，避免长路径把卡片挤成不可扫读的半截文本。
- 日志页长消息也改为中间截断并提供 hover 完整内容。

## 本次未执行的验证

- 未运行 `xcodebuild test`。
- 未运行 Xcode、Xcode build、Xcode test。
- 未运行 Swift/XCTest 相关测试命令。
- 原因：当前机器没有 Xcode 开发环境，且本次按要求只做代码层面的修复与静态审查。

## 已做的静态检查

- 读取 GitHub Issue #23 正文和评论；该 issue 当前没有评论。
- 审查了启动诊断发布链路：`CoreProcessController.startupDiagnostics` -> `AppModel.publishStartupDiagnostics(level:)` -> `RuntimeDataStore.appendLog` -> `LogsView` / `RecentLogsRuntimeCard`。
- 审查了 Dashboard 当前节点/运行态刷新签名，未发现本次 issue 范围内需要修改的漏项。
- 运行了 `git diff --check`，未发现本次改动的空白错误。

## 待运行自动化验证

在有 Xcode 环境的机器上运行：

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

建议优先关注这些测试文件是否通过：

- `ClashMaxTests/CoreProcessControllerTests.swift`
- `ClashMaxTests/DashboardRuntimeStateTests.swift`
- `ClashMaxTests/RuntimeDataStoreTests.swift`
- `ClashMaxTests/MenuBarRuntimePresentationTests.swift`
- `ClashMaxTests/MenuBarPanelLayoutTests.swift`

建议后续补充的自动化覆盖：

- 启动流程后续步骤失败时，`Validating runtime config`、`Using Mihomo core`、`Launching Mihomo with config`、`Mihomo controller ready` 仍发布为 `INFO`。
- 端口占用、readiness failed、core tail 等真实失败诊断仍发布为 `ERROR`，且 Error 过滤能筛出 `fatal` / `panic`。
- Dashboard 最近日志卡片使用和日志页一致的等级颜色，并允许长路径中间截断到两行。

## 待运行手动验收

1. 启动 ClashMax，选择一个可用 profile。
2. 分别在 System Proxy、TUN、Network Extension 可用模式下启动核心。
3. 打开日志页面，确认正常启动流程显示为 `INFO`，没有被批量标成 `ERROR`。
4. 人为制造真实错误，例如占用 controller/mixed port 或使用无效 runtime 配置，确认错误仍显示为 `ERROR` 并能被 Error 过滤筛出。
5. 回到 Dashboard 最近日志卡片，确认长 runtime config path / controller message 可扫读，hover 能看到完整内容，卡片布局不被破坏。
6. 展开菜单栏面板并保持 60 秒以上，确认运行中的状态、流量数值和图表持续刷新。
7. 在运行中触发 runtime reload，确认 Dashboard、日志页和菜单栏面板继续更新，不停在旧数据。

预期结果：

- 正常生命周期日志不再污染 Error 过滤结果。
- 真正错误仍明确可见、可过滤。
- Dashboard 最近日志紧凑可读，长路径不会横向撑坏或只露出不可判断的末尾。
- 菜单栏/面板刷新回归不复现。
