import SwiftUI

enum MenuBarPanelLayout {
  /// Control Center's panel width — the native analog for a rich menu bar panel.
  static let width: CGFloat = 320
  /// Inset between the content and the system panel's own edge. `MenuBarExtra`'s
  /// window style already draws the rounded, blurred panel on macOS 26, so this
  /// is the *only* chrome the app contributes — no second card, no border.
  static let padding: CGFloat = 12
  /// One width for every trailing control in the panel's control rows — Run Mode,
  /// Profile, and each proxy-group selector. Shared so the popups line up on both
  /// edges instead of each sizing to its own content, and generous enough that a
  /// typical node name ("[vless]JP Nano") reads in full next to its delay chip.
  ///
  /// It is a fixed width, not a minimum: it doubles as the cap that keeps an
  /// overlong subscription node name truncating *inside* the popup instead of
  /// widening the row and squeezing the group name out of the panel.
  static let trailingControlWidth: CGFloat = 162
  static let trailingControlCornerRadius: CGFloat = 5
  static let statusCornerRadius: CGFloat = 8
  static let trafficChartHeight: CGFloat = 52
  static let footerButtonMinWidth: CGFloat = 0
  static let plannedWidthRange: ClosedRange<CGFloat> = 300 ... 330
}

/// The whole panel presented by `MenuBarExtra(...).menuBarExtraStyle(.window)`.
///
/// The panel background is the system's, not the app's: on macOS 26 the window
/// style already renders the rounded, blurred, light/dark-adaptive menu bar
/// panel with its own shadow, exactly like Control Center and Wi-Fi. So this
/// view contributes content and padding only. An earlier version wrapped the
/// content in its own `NSVisualEffectView` card (rounded rect + separator
/// border + outer margin), which stacked a second panel inside the system one
/// and read as a double background — do not reintroduce a full-panel background
/// here; only nested sections (status chip, controls) get their own material.
struct MenuBarView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @Environment(AppUpdateController.self) private var appUpdateController

  var body: some View {
    let runtime = MenuBarRuntimePresentation(appModel: appModel)

    VStack(alignment: .leading, spacing: 8) {
      MenuBarHeader(
        runtime: runtime,
        profileName: activeProfileName,
        ownerName: appModel.runtimeOwner.menuBarDisplayName
      )

      VStack(spacing: 6) {
        Button {
          runRuntime()
        } label: {
          Label(primaryActionTitle, systemImage: primaryActionSymbol)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle)
        .controlSize(.regular)
        .disabled(primaryActionDisabled)
        .help(runtime.detail ?? primaryActionTitle)

        MenuBarStatusMessage(runtime: runtime)
      }

      Divider()

      if runtime.showsTraffic {
        MenuBarTrafficSection(
          sample: runtimeData.trafficSample,
          history: runtimeData.trafficHistory
        )

        Divider()
      }

      VStack(spacing: 7) {
        MenuBarProxyModeSelector()

        MenuBarControlRow(title: String(localized: "Run Mode"), systemImage: "slider.horizontal.3") {
          MenuBarSelectionMenu {
            ForEach(RunMode.allCases) { mode in
              Button {
                appModel.requestMode(mode)
              } label: {
                Label(
                  mode.displayName,
                  systemImage: mode == appModel.overrides.mode
                    ? "checkmark.circle.fill"
                    : mode.menuBarSymbolName
                )
              }
            }
          } value: {
            Label(
              appModel.overrides.mode.displayName,
              systemImage: appModel.overrides.mode.menuBarSymbolName
            )
          }
        }

        MenuBarControlRow(title: String(localized: "Profile"), systemImage: "rectangle.stack") {
          MenuBarSelectionMenu {
            ForEach(appModel.profileStore.profiles) { profile in
              Button {
                appModel.selectProfile(profile)
              } label: {
                Label(
                  profile.name,
                  systemImage: profile.id == appModel.profileStore.activeProfileID
                    ? "checkmark.circle.fill"
                    : profile.menuBarSymbolName
                )
              }
            }
          } value: {
            Label(activeProfileName, systemImage: activeProfileSymbolName)
          }
          .disabled(appModel.profileStore.profiles.isEmpty)
        }

        ForEach(nodeSelectorGroups) { group in
          MenuBarGroupSelectionRow(group: group, systemImage: MenuBarNodeSelection.groupSymbolName)
        }

        MenuBarControlRow(title: systemProxyToggleTitle, systemImage: "network.badge.shield.half.filled") {
          Toggle("", isOn: Binding(
            get: { appModel.systemProxyEnabled },
            set: { appModel.setSystemProxyEnabled($0) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
        }
        .disabled(appModel.proxyRoutingMode != .systemProxy)
        .help(
          appModel.proxyRoutingMode == .systemProxy
            ? String(localized: "System Proxy")
            : String(localized: "System Proxy requires System Proxy routing.")
        )
      }

      if !appModel.pinnedMenuBarProxyGroups.isEmpty {
        Divider()

        MenuBarPinnedGroupsSection(groups: appModel.pinnedMenuBarProxyGroups)
      }

      Divider()

      VStack(spacing: 5) {
        HStack(spacing: 5) {
          Button {
            appModel.updateActiveSubscription()
          } label: {
            MenuBarFooterButtonLabel(title: "Update Subscription", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(!(appModel.profileStore.activeProfile?.isSubscription ?? false))

          Button {
            appModel.updateAllSubscriptions()
          } label: {
            MenuBarFooterButtonLabel(title: "Update All", systemImage: "arrow.triangle.2.circlepath.circle")
          }
          .disabled(!appModel.profileStore.profiles.contains(where: \.isSubscription))
        }

        HStack(spacing: 5) {
          Button {
            appModel.testDelayForAllProxyGroups()
          } label: {
            MenuBarFooterButtonLabel(title: "Test All", systemImage: "waveform.path.ecg")
          }
          .disabled(!appModel.canControlRuntimeProxies || appModel.visibleProxyGroups.isEmpty)

          Button {
            appModel.updateAllProxyProviders()
            appModel.updateAllRuleProviders()
          } label: {
            MenuBarFooterButtonLabel(title: "Providers", systemImage: "shippingbox")
          }
          .disabled(!appModel.canControlRuntimeProxies)
        }

        HStack(spacing: 5) {
          CheckForUpdatesButton(updateController: appUpdateController, fillsWidth: true)

          Button {
            AppDelegate.showMainWindow()
          } label: {
            MenuBarFooterButtonLabel(title: "Open Main Window", systemImage: "macwindow")
          }
        }

        HStack(spacing: 5) {

          Button {
            NSApp.terminate(nil)
          } label: {
            MenuBarFooterButtonLabel(title: "Quit", systemImage: "power")
          }
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .font(.caption)
    }
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
  }

  private var activeProfileName: String {
    appModel.profileStore.activeProfile?.name ?? String(localized: "No Profile")
  }

  private var activeProfileSymbolName: String {
    appModel.profileStore.activeProfile?.menuBarSymbolName ?? "rectangle.stack"
  }

  private var nodeSelectorGroups: [ProxyGroup] {
    MenuBarNodeSelection.selectorGroups(
      from: appModel.visibleProxyGroups,
      runMode: appModel.overrides.mode,
      excludingPinned: appModel.pinnedMenuBarProxyGroups.map(\.name)
    )
  }

  private var primaryActionDisabled: Bool {
    if appModel.canStopRuntime { return false }
    if appModel.dashboardRuntimeState.isStarting { return true }
    return appModel.readinessIssue != nil
  }

  private var primaryActionTitle: String {
    appModel.canStopRuntime ? String(localized: "Stop Core") : String(localized: "Start Core")
  }

  private var primaryActionSymbol: String {
    appModel.canStopRuntime ? "stop.fill" : "play.fill"
  }

  private var systemProxyToggleTitle: String {
    appModel.systemProxyEnabled
      ? String(localized: "Stop Proxy Gateway")
      : String(localized: "Start Proxy Gateway")
  }

  private func runRuntime() {
    guard !primaryActionDisabled else { return }
    if appModel.canStopRuntime {
      appModel.stop()
    } else {
      appModel.start()
    }
  }
}

struct MenuBarRuntimePresentation {
  let title: String
  let detail: String?
  let symbolName: String
  let tint: Color
  let showsTraffic: Bool

  @MainActor
  init(appModel: AppModel) {
    self.init(
      previewRuntimeActive: appModel.previewRuntimeActive,
      dashboardRuntimeState: appModel.dashboardRuntimeState,
      runtimeOwner: appModel.runtimeOwner,
      tunnelCoreRunning: appModel.tunnelCoreRunning,
      isRunning: appModel.isRunning,
      hasActiveProfile: appModel.profileStore.activeProfile != nil,
      missingBundledCore: appModel.readinessIssue == AppError.missingBundledCore.description,
      readinessIssue: appModel.readinessIssue
    )
  }

  init(
    previewRuntimeActive: Bool = false,
    dashboardRuntimeState: DashboardRuntimeState,
    runtimeOwner: RuntimeOwner,
    tunnelCoreRunning: Bool = false,
    isRunning: Bool = false,
    hasActiveProfile: Bool = true,
    missingBundledCore: Bool = false,
    readinessIssue: String? = nil
  ) {
    if previewRuntimeActive {
      title = String(localized: "Preview")
      detail = String(localized: "Preview runtime is active.")
      symbolName = "eye"
      tint = .blue
      showsTraffic = false
      return
    }

    switch dashboardRuntimeState {
    case let .crashed(message):
      title = String(localized: "Crashed")
      detail = message
      symbolName = "xmark.octagon.fill"
      tint = .red
      showsTraffic = false
      return
    case .starting:
      title = String(localized: "Starting")
      detail = String(localized: "Core is starting.")
      symbolName = "arrow.triangle.2.circlepath"
      tint = .orange
      showsTraffic = false
      return
    default:
      break
    }

    if runtimeOwner == .networkExtension {
      title = String(localized: "Running NE")
      detail = String(localized: "Network Extension owns transparent proxy routing.")
      symbolName = "network"
      tint = .green
      showsTraffic = true
    } else if tunnelCoreRunning || runtimeOwner == .tunnel {
      title = String(localized: "Running TUN")
      detail = String(localized: "TUN helper owns VPN-style routing.")
      symbolName = "point.topleft.down.curvedto.point.bottomright.up"
      tint = .green
      showsTraffic = true
    } else if isRunning || dashboardRuntimeState.isRunning {
      title = String(localized: "Running")
      detail = String(localized: "User-mode core is running.")
      symbolName = "shield.lefthalf.filled"
      tint = .green
      showsTraffic = true
    } else if !hasActiveProfile {
      title = String(localized: "No Profile")
      detail = String(localized: "Select a profile to start ClashMax.")
      symbolName = "doc.badge.plus"
      tint = .secondary
      showsTraffic = false
    } else if missingBundledCore {
      title = String(localized: "No Core")
      detail = String(localized: "Bundled Mihomo core is unavailable.")
      symbolName = "externaldrive.badge.xmark"
      tint = .red
      showsTraffic = false
    } else if let readinessIssue {
      title = String(localized: "Needs Setup")
      detail = readinessIssue
      symbolName = "exclamationmark.triangle.fill"
      tint = .orange
      showsTraffic = false
    } else {
      title = String(localized: "Stopped")
      detail = String(localized: "Profile and core are ready.")
      symbolName = "shield"
      tint = .secondary
      showsTraffic = false
    }
  }
}

/// Builds the compact upload/download labels shown on the menu bar status item.
///
/// Reuses `TrafficSample.format(_:)` so the units stay consistent with the rest of
/// the app, and keeps the "only while running with live data" decision in one
/// testable place. Returns `nil` when the menu bar should show its icon alone.
enum MenuBarTrafficStatusLabel {
  struct Lines: Equatable {
    let upload: String
    let download: String
  }

  static func lines(showsTraffic: Bool, hasTrafficData: Bool, sample: TrafficSample) -> Lines? {
    guard showsTraffic, hasTrafficData else { return nil }
    return Lines(
      upload: "↑\(compact(sample.upload))",
      download: "↓\(compact(sample.download))"
    )
  }

  static func text(showsTraffic: Bool, hasTrafficData: Bool, sample: TrafficSample) -> String? {
    guard let statusLines = lines(showsTraffic: showsTraffic, hasTrafficData: hasTrafficData, sample: sample) else {
      return nil
    }
    return "\(statusLines.upload)\n\(statusLines.download)"
  }

  /// Reuses `TrafficSample.format` so the menu bar units stay consistent with the
  /// rest of the app, then strips the internal number/unit spacing so the status
  /// item keeps narrow rows (Discussion #20). This is the
  /// same unit rule, not a second one.
  private static func compact(_ bytesPerSecond: Int) -> String {
    TrafficSample.format(bytesPerSecond).replacingOccurrences(of: " ", with: "")
  }
}

/// Single row that merges the former "Proxy Routing" picker and the "Quick" icon
/// strip into one control. Each option is an icon plus a short label (System / TUN
/// / NE) and selecting one calls the same `appModel.requestProxyRoutingMode(_:)`
/// the quick buttons used, so the proxy state machine, TUN/NE/System Proxy
/// behavior, and runtime config are unchanged. Internal (not private) so layout
/// tests can render it directly.
struct MenuBarProxyModeSelector: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    MenuBarControlRow(
      title: String(localized: "Proxy Mode"),
      systemImage: appModel.proxyRoutingMode.symbolName
    ) {
      HStack(spacing: 8) {
        ForEach(ProxyRoutingMode.allCases) { mode in
          Button {
            appModel.requestProxyRoutingMode(mode)
          } label: {
            MenuBarProxyModeOptionLabel(mode: mode)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(appModel.proxyRoutingMode == mode ? Color.accentColor : Color.secondary)
          .help(mode.displayName)
        }
      }
    }
  }
}

/// Trailing label for one proxy-mode option: the routing mode's icon and a short,
/// fixed abbreviation. The enclosing button tints it (accent when selected,
/// secondary otherwise), matching the old quick-button highlight. The labels stay
/// English so they read the same in both locales. Internal so layout tests can
/// size the row without an `AppModel`.
struct MenuBarProxyModeOptionLabel: View {
  let mode: ProxyRoutingMode

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: mode.symbolName)
      Text(verbatim: MenuBarProxyModeOptionLabel.shortLabel(for: mode))
    }
    .font(.caption)
    .lineLimit(1)
    .fixedSize()
  }

  static func shortLabel(for mode: ProxyRoutingMode) -> String {
    switch mode {
    case .systemProxy: "System"
    case .tun: "TUN"
    case .neProxy: "NE"
    }
  }
}

/// Decides which proxy groups the menu bar node-selection popup offers.
///
/// Mirrors the proxies page: only Selector groups accept manual selection, and
/// the built-in GLOBAL group is only actionable while Mihomo runs in global
/// mode. Groups without selectable nodes would render an empty menu, so they
/// are dropped as well. Profile order is preserved.
enum MenuBarNodeSelection {
  static let globalGroupName = "GLOBAL"

  /// Stable fallback symbol for a selector-group row. The runtime model does not
  /// expose a per-group icon yet (Discussion #20 treats icons as non-blocking), so
  /// this reuses the glyph the Proxies navigator already uses for selectable groups.
  static let groupSymbolName = "point.3.connected.trianglepath.dotted"

  static func selectorGroups(
    from groups: [ProxyGroup],
    runMode: RunMode,
    excludingPinned pinnedNames: [String] = []
  ) -> [ProxyGroup] {
    let pinned = Set(pinnedNames.map { $0.lowercased() })
    return groups.filter { group in
      guard group.allowsManualProxySelection else { return false }
      guard group.nodes.contains(where: \.isSelectable) else { return false }
      if pinned.contains(group.name.lowercased()) { return false }
      if group.name == globalGroupName {
        return runMode == .global
      }
      return true
    }
  }

  /// Name shown as the group's current selection in its menu-bar row. Mirrors the
  /// dashboard's issue-#14 resolution: a configured selection wins, otherwise the
  /// first selectable node, otherwise a neutral "Select" placeholder.
  static func currentSelectionLabel(for group: ProxyGroup) -> String {
    if let selected = group.selected, !selected.isEmpty {
      return selected
    }
    if let first = group.nodes.first(where: \.isSelectable) {
      return first.name
    }
    return String(localized: "Select")
  }

  /// Delay status for the group's current node, reusing the Proxies-page
  /// `ProxyDelayDisplay` semantics and the dashboard's `currentNode` resolution so
  /// all three surfaces agree. Unresolvable selections render as `.unknown`.
  static func currentDelayDisplay(for group: ProxyGroup) -> ProxyDelayDisplay {
    let state = DashboardProxySelectionState.currentNode(in: group)?.resolvedDelayState ?? .unknown
    return ProxyDelayDisplay(state: state)
  }

  /// Title for a node row inside a group menu: the node name plus its delay,
  /// reusing `ProxyDelayDisplay`. The `Unknown` state is omitted so large node
  /// menus stay readable; measured/testing/timeout/error are always shown.
  static func nodeMenuTitle(for node: ProxyNode) -> String {
    let state = node.resolvedDelayState
    if case .unknown = state {
      return node.name
    }
    return "\(node.name) · \(ProxyDelayDisplay(state: state).label)"
  }
}

/// One flat row per manually-selectable group. Replaces the old nested
/// "Node Selection" entry so each group's current node, delay, and node list are
/// one click closer (Discussion #20). Node lists stay inside a native `Menu` so a
/// group with hundreds of nodes still scrolls natively.
private struct MenuBarGroupSelectionRow: View {
  @Environment(AppModel.self) private var appModel
  let group: ProxyGroup
  let systemImage: String

  var body: some View {
    MenuBarControlRow(title: group.name, systemImage: systemImage) {
      MenuBarSelectionMenu {
        MenuBarGroupNodeButtons(group: group)
      } value: {
        MenuBarGroupSelectionLabel(
          selectedNode: MenuBarNodeSelection.currentSelectionLabel(for: group),
          delay: MenuBarNodeSelection.currentDelayDisplay(for: group)
        )
      }
      .disabled(!appModel.canSelectProxyNodesFromMenuBar || group.nodes.filter(\.isSelectable).isEmpty)
    }
  }
}

private struct MenuBarGroupNodeButtons: View {
  @Environment(AppModel.self) private var appModel
  let group: ProxyGroup

  var body: some View {
    ForEach(group.nodes.filter(\.isSelectable)) { node in
      Button {
        appModel.selectProxy(
          group: group,
          node: node,
          closeOldConnections: appModel.proxyPageSettings.closesOldConnectionsAfterSwitch
        )
      } label: {
        Label(
          MenuBarNodeSelection.nodeMenuTitle(for: node),
          systemImage: node.name == group.selected ? "checkmark.circle.fill" : "circle"
        )
      }
    }
  }
}

private struct MenuBarPinnedGroupsSection: View {
  let groups: [ProxyGroup]

  var body: some View {
    VStack(spacing: 7) {
      ForEach(groups.prefix(MenuBarPinnedGroupSettings.maximumPinnedGroups)) { group in
        MenuBarGroupSelectionRow(group: group, systemImage: "pin.fill")
      }
    }
  }
}

struct MenuBarHeader: View {
  let runtime: MenuBarRuntimePresentation
  let profileName: String
  let ownerName: String

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(runtime.tint.opacity(0.16))
        Image("ClashMaxMonoLogo")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 15, height: 15)
          .foregroundStyle(runtime.tint)
      }
      .frame(width: 26, height: 26)

      VStack(alignment: .leading, spacing: 2) {
        Text("ClashMax")
          .font(.headline)
          .lineLimit(1)

        Text(profileName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Text(String(format: String(localized: "Owner: %@"), ownerName))
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)

      Spacer(minLength: 6)

      Text(runtime.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(runtime.tint)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(runtime.tint.opacity(0.12), in: Capsule())
    }
  }
}

struct MenuBarStatusMessage: View {
  let runtime: MenuBarRuntimePresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(runtime.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)

      if let detail = runtime.detail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(7)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: MenuBarPanelLayout.statusCornerRadius, style: .continuous))
  }
}

struct MenuBarInfoRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 15)

      Text(title)
        .foregroundStyle(.secondary)

      Spacer(minLength: 6)

      Text(value)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .font(.caption)
  }
}

struct MenuBarTrafficSection: View {
  let sample: TrafficSample
  let history: [TrafficSample]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MenuBarInfoRow(
        title: String(localized: "Traffic"),
        value: valueLabel,
        systemImage: "arrow.up.arrow.down"
      )

      TrafficSparkline(
        samples: chartSamples,
        inset: 4,
        downloadLineWidth: 1.8,
        uploadLineWidth: 1.6,
        baselineOpacity: 0.16
      )
      .frame(height: MenuBarPanelLayout.trafficChartHeight)
      .accessibilityLabel(Text("Traffic"))
      .accessibilityValue(Text(valueLabel))
    }
  }

  private var valueLabel: String {
    history.isEmpty ? String(localized: "Waiting for runtime data") : sample.shortLabel
  }

  private var chartSamples: [TrafficSample] {
    history.isEmpty ? Self.emptyChartSamples : history
  }

  private static let emptyChartSamples = Array(repeating: TrafficSample.zero, count: 6)
}

struct MenuBarControlRow<Control: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder var control: Control

  var body: some View {
    HStack(spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

      control
        .controlSize(.small)
        .layoutPriority(1)
    }
  }
}

/// Value shown by a group-selection row's `MenuBarSelectionMenu`: the current node
/// plus a compact delay chip that reuses the Proxies-page `ProxyDelayDisplay`
/// semantics and colors. The node name is the only part allowed to give up space,
/// so a long subscription name truncates inside the shared control column instead
/// of pushing the delay — or the group name — off the row (Discussion #20).
struct MenuBarGroupSelectionLabel: View {
  let selectedNode: String
  let delay: ProxyDelayDisplay

  var body: some View {
    HStack(spacing: 5) {
      Text(selectedNode)
        .lineLimit(1)
        .truncationMode(.middle)

      Text(delay.label)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(delay.tone.color)
        .lineLimit(1)
        .fixedSize()
    }
  }
}

struct MenuBarFooterButtonLabel: View {
  let title: LocalizedStringKey
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .lineLimit(1)
      .truncationMode(.tail)
      .minimumScaleFactor(0.78)
      .frame(minWidth: MenuBarPanelLayout.footerButtonMinWidth, maxWidth: .infinity)
  }
}

private extension AppModel {
  /// Same gate the proxies page uses for node selection: live runtime control,
  /// or offline preview selection that is persisted for the next start.
  var canSelectProxyNodesFromMenuBar: Bool {
    canControlRuntimeProxies || canSelectProxyOffline
  }
}

private extension RuntimeOwner {
  var menuBarDisplayName: String {
    switch self {
    case .stopped:
      String(localized: "Stopped")
    case .user:
      String(localized: "User Mode")
    case .tunnel:
      String(localized: "TUN Helper")
    case .networkExtension:
      String(localized: "NE Proxy")
    case .preview:
      String(localized: "Preview")
    }
  }
}

private extension RunMode {
  var menuBarSymbolName: String {
    switch self {
    case .rule:
      "list.bullet.rectangle"
    case .global:
      "globe"
    case .direct:
      "arrow.right.circle"
    }
  }
}

private extension Profile {
  var menuBarSymbolName: String {
    isSubscription ? "arrow.triangle.2.circlepath.circle" : "doc.text"
  }
}

/// The panel's one trailing control: a pull-down menu drawn as a fixed-width
/// popup button. Run Mode, Profile, and every proxy-group selector use it, so the
/// three rows line up on both edges and no value can widen its row.
///
/// It is deliberately not a stock `Picker`/`Menu` bezel. A macOS popup button
/// sizes itself to its own content and a SwiftUI frame can only *compress* it,
/// never stretch it — measured: `.frame(width:)` leaves a short picker at its
/// intrinsic width and centers it, and a `Menu` discards its label's layout
/// entirely (an overlong node name grew the bezel instead of truncating). Routing
/// the menu through a custom `ButtonStyle` is what moves the layout from AppKit
/// back into SwiftUI, which is where the shared width becomes ours to set.
struct MenuBarSelectionMenu<Content: View, Value: View>: View {
  @ViewBuilder var content: Content
  @ViewBuilder var value: Value

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: 4) {
        value
          .lineLimit(1)

        Spacer(minLength: 2)

        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .font(.subheadline)
    }
    .menuStyle(.button)
    .buttonStyle(MenuBarSelectionMenuStyle())
    .menuIndicator(.hidden)
    .frame(width: MenuBarPanelLayout.trailingControlWidth)
  }
}

/// Draws the popup-button bezel `MenuBarSelectionMenu` needs. Being a custom
/// style is the point — see that type — so keep the frame/padding here rather
/// than reaching for a stock bordered style.
private struct MenuBarSelectionMenuStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Bezel(configuration: configuration)
  }

  private struct Bezel: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    private var shape: RoundedRectangle {
      RoundedRectangle(cornerRadius: MenuBarPanelLayout.trailingControlCornerRadius, style: .continuous)
    }

    var body: some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: shape)
        .contentShape(shape)
        .opacity(opacity)
    }

    private var opacity: Double {
      guard isEnabled else { return 0.45 }
      return configuration.isPressed ? 0.75 : 1
    }
  }
}
