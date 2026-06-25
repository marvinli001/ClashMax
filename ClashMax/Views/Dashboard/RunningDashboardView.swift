import Pow
import SwiftUI

struct RunningDashboardView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @StateObject private var currentNodeCoordinator = ProxySearchCoordinator()
  @State private var selectedProxyGroupName: String?
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat

  var body: some View {
    let selection = resolvedCurrentSelection
    return VStack(spacing: 12) {
      RunningHeaderCard(
        state: state,
        namespace: namespace,
        reduceMotion: reduceMotion,
        availableWidth: availableWidth
      )

      DashboardResponsivePair(availableWidth: availableWidth) {
        CurrentProxyRuntimeCard(
          state: state,
          availableWidth: runtimeInfoCardWidth,
          resolvedGroups: currentNodeCoordinator.snapshot.unfilteredGroups,
          isLoading: currentNodeIsLoading,
          selectedGroupName: $selectedProxyGroupName
        )
      } trailing: {
        // Reuse the same off-main resolved group/node the Current Node card uses so the proxy-effect
        // check never re-expands providers on the SwiftUI hot path (issue #10 / #13 / #14).
        PublicIPInfoCard(
          availableWidth: runtimeInfoCardWidth,
          currentGroup: selection.group,
          currentNode: selection.node,
          hasMissingSelection: selection.hasMissingSelection
        )
      }
      .staggeredArrival(index: 0, reduceMotion: reduceMotion, trigger: state)

      LazyVGrid(columns: metricColumns, spacing: DashboardLayoutMetrics.dashboardGridSpacing) {
        DashboardMetricTile(
          title: "Download",
          value: TrafficSample.format(runtimeData.trafficSample.download),
          footnote: trafficFootnote,
          symbolName: "arrow.down",
          tint: .cyan,
          isLoading: showsInitialRuntimeSkeletons
        )
        DashboardMetricTile(
          title: "Upload",
          value: TrafficSample.format(runtimeData.trafficSample.upload),
          footnote: trafficFootnote,
          symbolName: "arrow.up",
          tint: .indigo,
          isLoading: showsInitialRuntimeSkeletons
        )
        DashboardMetricTile(
          title: "Connections",
          value: "\(runtimeData.connections.count)",
          footnote: runtimeData.connections.isEmpty ? "Waiting for runtime data" : "Live stream",
          symbolName: "network",
          tint: .orange,
          isLoading: (appModel.runtimeDataLoading || state.isStarting) && runtimeData.connections.isEmpty
        )
        DashboardMetricTile(
          title: "Rules",
          value: "\(runtimeData.rules.count)",
          footnote: runtimeData.rules.isEmpty ? "Waiting for runtime data" : "Loaded rules",
          symbolName: "list.bullet.rectangle",
          tint: .green,
          isLoading: (appModel.runtimeDataLoading || state.isStarting) && runtimeData.rules.isEmpty
        )
      }
      .staggeredArrival(index: 2, reduceMotion: reduceMotion, trigger: state)

      DashboardResponsivePair(availableWidth: availableWidth) {
        RunningStatusCard()
      } trailing: {
        NetworkStatusCard()
      }
      .staggeredArrival(index: 3, reduceMotion: reduceMotion, trigger: state)

      if appModel.proxyRoutingMode == .neProxy {
        NetworkExtensionDiagnosticsRuntimeCard()
          .staggeredArrival(index: 4, reduceMotion: reduceMotion, trigger: state)
      }
      if appModel.proxyRoutingMode == .tun {
        TunDiagnosticsRuntimeCard()
          .staggeredArrival(index: 4, reduceMotion: reduceMotion, trigger: state)
      }

      DashboardResponsivePair(availableWidth: availableWidth) {
        TrafficRuntimeCard(samples: chartSamples, isLoading: showsInitialRuntimeSkeletons)
      } trailing: {
        ProxyGroupsRuntimeCard()
      }
      .staggeredArrival(index: 5, reduceMotion: reduceMotion, trigger: state)

      DashboardResponsivePair(availableWidth: availableWidth) {
        ConnectionsRulesRuntimeCard()
      } trailing: {
        RecentLogsRuntimeCard()
      }
      .staggeredArrival(index: 6, reduceMotion: reduceMotion, trigger: state)
    }
    .task {
      // First population: resolve providers off-main so the dashboard never expands a large config
      // synchronously in the body (issue #10).
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .initial)
    }
    .onChange(of: appModel.proxyPageSettings.sortOrder) { _, _ in
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .sort)
    }
    .onChange(of: currentNodeDataSignature) { _, _ in
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .data)
    }
  }

  /// The provider-resolved current group/node (and whether the selection is missing) shared by the
  /// Current Node card and the public-IP proxy-effect check, so neither re-expands providers.
  private var resolvedCurrentSelection: (group: ProxyGroup?, node: ProxyNode?, hasMissingSelection: Bool) {
    let groups = DashboardProxySelectionState.selectableGroups(from: currentNodeCoordinator.snapshot.unfilteredGroups)
    let group = DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: selectedProxyGroupName)
    let node = group.flatMap(DashboardProxySelectionState.currentNode)
    let missing = group.map(DashboardProxySelectionState.hasMissingSelection) ?? false
    return (group, node, missing)
  }

  /// Watches the same group/provider fingerprint the Proxies page does, so the off-main resolve only
  /// reruns when something that affects the current node actually changed.
  private var currentNodeDataSignature: ProxySearchInputSignature {
    ProxySearchInputSignature(groups: appModel.visibleProxyGroups, providers: runtimeData.proxyProviders)
  }

  /// Shows the skeleton only during genuine async loading — while starting, while runtime data is
  /// loading with nothing resolved yet, or before the off-main pipeline has produced its first
  /// result for a non-empty config — never in place of the empty/recovery states (AGENTS.md).
  private var currentNodeIsLoading: Bool {
    if state.isStarting { return true }
    let snapshot = currentNodeCoordinator.snapshot
    if appModel.runtimeDataLoading && snapshot.unfilteredGroups.isEmpty { return true }
    if !snapshot.hasResolved && !appModel.visibleProxyGroups.isEmpty { return true }
    return false
  }

  private var metricColumns: [GridItem] {
    let count = if availableWidth < DashboardLayoutMetrics.metricTileTwoColumnBreakpoint {
      1
    } else if availableWidth < DashboardLayoutMetrics.metricTileSingleRowBreakpoint {
      2
    } else {
      4
    }
    return Array(
      repeating: GridItem(
        .flexible(minimum: DashboardLayoutMetrics.metricTileMinimumColumnWidth),
        spacing: DashboardLayoutMetrics.dashboardGridSpacing
      ),
      count: count
    )
  }

  private var trafficFootnote: String {
    runtimeData.trafficHistory.isEmpty ? "Waiting for runtime data" : "Live traffic"
  }

  private var runtimeInfoCardWidth: CGFloat {
    if availableWidth >= DashboardLayoutMetrics.runningPairColumnsBreakpoint {
      return max(0, (availableWidth - DashboardLayoutMetrics.dashboardGridSpacing) / 2)
    }
    return availableWidth
  }

  private var chartSamples: [TrafficSample] {
    runtimeData.trafficHistory.isEmpty ? [.zero, .zero, .zero, .zero, .zero, .zero] : runtimeData.trafficHistory
  }

  private var showsInitialRuntimeSkeletons: Bool {
    (appModel.runtimeDataLoading || state.isStarting)
      && runtimeData.proxyGroups.isEmpty
      && runtimeData.connections.isEmpty
      && runtimeData.rules.isEmpty
      && runtimeData.trafficHistory.isEmpty
  }
}

private struct RunningHeaderCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Group {
        if availableWidth >= 820 {
          HStack(spacing: 16) {
            headerVisual
            statusBlock
            Spacer(minLength: 12)
            runControls
          }
        } else {
          VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
              headerVisual
              statusBlock
            }
            runControls
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }

      runtimeInfoPanel
    }
    .padding(16)
    .dashboardCard(interactive: true)
  }

  private var headerVisual: some View {
    CoreVisualView(state: state, reduceMotion: reduceMotion)
      .frame(width: availableWidth >= 820 ? 96 : 72, height: availableWidth >= 820 ? 96 : 72)
      .matchedGeometryEffect(id: "core-visual", in: namespace)
  }

  private var statusBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Label(statusTitle, systemImage: state.isStarting ? "clock.arrow.circlepath" : "shield.lefthalf.filled")
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(state.isStarting ? .cyan : .green)
          .contentTransition(.symbolEffect)

        if state.isStarting {
          ProgressView()
            .controlSize(.small)
        }
      }
      .lineLimit(1)
      .minimumScaleFactor(0.75)

      if availableWidth >= 620 {
        HStack(spacing: 8) {
          statusPills
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          statusPills
        }
      }
    }
  }

  @ViewBuilder
  private var statusPills: some View {
    DashboardStatusPill(
      title: "Profile",
      value: appModel.profileStore.activeProfile?.name ?? "None",
      symbolName: "doc.text",
      tint: .cyan
    )
    .matchedGeometryEffect(id: "profile-summary", in: namespace)

    DashboardStatusPill(
      title: "Mode",
      value: appModel.currentRuntimeOverrides.mode.displayName,
      symbolName: "switch.2",
      tint: .purple
    )
    .matchedGeometryEffect(id: "mode-control", in: namespace)

    DashboardStatusPill(
      title: "Controller",
      value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)",
      symbolName: "lock.shield",
      tint: .green
    )
  }

  private var runControls: some View {
    VStack(alignment: availableWidth >= 820 ? .trailing : .leading, spacing: 10) {
      Button {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
          appModel.stop()
        }
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .frame(minWidth: 96)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .help(state.isStarting ? "Stop starting runtime" : "Stop ClashMax")
      .matchedGeometryEffect(id: "primary-run-control", in: namespace)

      HStack(spacing: 8) {
        DashboardStatusPill(
          title: "Proxy",
          value: appModel.proxyRoutingMode.displayName,
          symbolName: appModel.proxyRoutingMode.symbolName,
          tint: appModel.systemProxyEnabled || appModel.tunEnabled || appModel.networkExtensionEnabled ? .green : .secondary
        )
      }
    }
  }

  private var runtimeInfoPanel: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        runtimeInfoItems
      }

      LazyVGrid(
        columns: [
          GridItem(.flexible(minimum: 120), spacing: 8),
          GridItem(.flexible(minimum: 120), spacing: 8)
        ],
        alignment: .leading,
        spacing: 8
      ) {
        runtimeInfoItems
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dashboardInsetSurface()
  }

  @ViewBuilder
  private var runtimeInfoItems: some View {
    DashboardMiniInfoItem(
      title: "Groups",
      value: "\(runtimeData.proxyGroups.count)",
      symbolName: "point.3.connected.trianglepath.dotted",
      tint: .cyan
    )
    DashboardMiniInfoItem(
      title: "Connections",
      value: "\(runtimeData.connections.count)",
      symbolName: "network",
      tint: .orange
    )
    DashboardMiniInfoItem(
      title: "Rules",
      value: "\(runtimeData.rules.count)",
      symbolName: "list.bullet.rectangle",
      tint: .green
    )
    DashboardMiniInfoItem(
      title: "Controller",
      value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)",
      symbolName: "lock.shield",
      tint: .purple
    )
  }

  private var statusTitle: String {
    state.isStarting ? "Starting Runtime" : appModel.statusSummary
  }
}

private struct DashboardMiniInfoItem: View {
  let title: String
  let value: String
  let symbolName: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(value)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DashboardResponsivePair<Leading: View, Trailing: View>: View {
  let availableWidth: CGFloat
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    if availableWidth >= DashboardLayoutMetrics.runningPairColumnsBreakpoint {
      HStack(alignment: .top, spacing: DashboardLayoutMetrics.dashboardGridSpacing) {
        leading
        trailing
      }
    } else {
      VStack(alignment: .leading, spacing: DashboardLayoutMetrics.dashboardGridSpacing) {
        leading
        trailing
      }
    }
  }
}

enum DashboardProxySelectionState {
  static func selectableGroups(from groups: [ProxyGroup]) -> [ProxyGroup] {
    groups.filter { group in
      group.allowsManualProxySelection && !group.nodes.filter(\.isSelectable).isEmpty
    }
  }

  static func resolvedGroup(from groups: [ProxyGroup], preferredName: String?) -> ProxyGroup? {
    let groups = selectableGroups(from: groups)
    if let preferredName,
       let preferred = groups.first(where: { $0.name == preferredName }) {
      return preferred
    }
    return groups.first
  }

  static func currentNode(in group: ProxyGroup) -> ProxyNode? {
    // A configured selection must resolve to that exact node. If the named node is absent (e.g. a
    // provider-backed member that has not been expanded yet, or a profile/provider mismatch) do NOT
    // fall back to the first selectable node — that is what surfaced DIRECT as the dashboard's
    // current node while the selector group actually pointed at a Korea node (issue #14). Only an
    // unset selection falls back to the first selectable node.
    if let selected = group.selected, !selected.isEmpty {
      return group.nodes.first(where: { $0.name == selected })
    }
    return group.nodes.first(where: \.isSelectable)
  }

  /// `true` when the group has a named selection that is not present among its (resolved) nodes.
  /// The dashboard uses this to show an explicit refresh/recovery state instead of a misleading
  /// node or a loading skeleton (issue #14).
  static func hasMissingSelection(in group: ProxyGroup) -> Bool {
    guard let selected = group.selected, !selected.isEmpty else { return false }
    return !group.nodes.contains(where: { $0.name == selected })
  }

  static func delayLabel(for node: ProxyNode?) -> String {
    guard let delay = node?.delay else { return "No delay" }
    return "\(delay) ms"
  }

  static func typeLabel(for node: ProxyNode?) -> String {
    guard let type = node?.type, !type.isEmpty else { return "Proxy" }
    switch type.lowercased() {
    case "hysteria2":
      return "Hysteria2"
    case "vless":
      return "VLESS"
    case "direct":
      return "Direct"
    default:
      return type.capitalized
    }
  }
}

private struct CurrentProxyRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel
  let state: DashboardRuntimeState
  let availableWidth: CGFloat
  /// Provider-resolved + sorted groups supplied by `RunningDashboardView` (shares the Proxies page's
  /// off-main pipeline). The card never resolves providers itself, so the heavy expansion stays off
  /// the SwiftUI body hot path (issue #10 / #14).
  let resolvedGroups: [ProxyGroup]
  /// `true` only during genuine async runtime/pipeline loading, so the skeleton never replaces a
  /// failure/recovery or empty state (AGENTS.md).
  let isLoading: Bool
  @Binding var selectedGroupName: String?

  var body: some View {
    let groups = DashboardProxySelectionState.selectableGroups(from: resolvedGroups)
    let group = DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: selectedGroupName)
    let node = group.flatMap(DashboardProxySelectionState.currentNode)

    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        DashboardSectionHeader(
          title: "Current Node",
          symbolName: "location.circle",
          trailing: appModel.canControlRuntimeProxies ? "Runtime" : nil
        )

        Button {
          appModel.reloadRuntimeData()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!appModel.canControlRuntimeProxies || state.isStarting)
        .help("Refresh runtime proxy groups")
      }

      if let group, let node {
        currentNodeSummary(group: group, node: node)

        HStack(alignment: .bottom, spacing: 10) {
          groupControl(groups: groups)
            .frame(minWidth: 112, idealWidth: 150, maxWidth: 180)
            .layoutPriority(1)
          nodeControl(group: group)
            .frame(minWidth: 0, maxWidth: .infinity)
            .layoutPriority(2)
        }
      } else if isLoading {
        ClashMaxCurrentNodeSkeleton(isCompact: availableWidth < 460)
      } else if let group, DashboardProxySelectionState.hasMissingSelection(in: group) {
        // A node is selected but absent from the resolved data (runtime not yet refreshed, or a
        // profile/provider mismatch). Surface an explicit recovery state — never DIRECT, never a
        // skeleton — and keep the refresh affordance above (issue #14).
        selectionUnavailableView(group: group)
      } else {
        DashboardEmptyRuntimeView(
          title: "No selectable proxy groups",
          symbolName: "point.3.connected.trianglepath.dotted",
          message: "Refresh runtime data or check the active profile's proxy-groups."
        )
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: availableWidth < 460 ? 190 : 210, alignment: .topLeading)
    .dashboardCard(interactive: true)
  }

  private func selectionUnavailableView(group: ProxyGroup) -> some View {
    DashboardEmptyRuntimeView(
      title: "Selected node unavailable",
      symbolName: "exclamationmark.triangle",
      message: selectionUnavailableMessage(group: group)
    )
  }

  private func selectionUnavailableMessage(group: ProxyGroup) -> String {
    guard let selected = group.selected, !selected.isEmpty else {
      return "Refresh runtime data or check the active profile's proxy-groups."
    }
    return "\"\(selected)\" isn't in the current runtime data for \(group.name). Refresh runtime data, or check the profile/provider for a mismatch."
  }

  private func currentNodeSummary(group: ProxyGroup, node: ProxyNode) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "shield.lefthalf.filled")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(.green)
        .frame(width: 42, height: 42)
        .background(.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 4) {
        Text(node.name)
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.68)
        HStack(spacing: 6) {
          Text(group.name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(DashboardProxySelectionState.typeLabel(for: node))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.12), in: Capsule())
        }
      }

      Spacer(minLength: 12)

      Text(DashboardProxySelectionState.delayLabel(for: node))
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .foregroundStyle(node.delay == nil ? Color.secondary : Color.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background((node.delay == nil ? Color.secondary : Color.green).opacity(0.13), in: Capsule())
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dashboardInsetSurface()
  }

  private func groupControl(groups: [ProxyGroup]) -> some View {
    DashboardLabeledControl(title: "Proxy Group") {
      Picker("Proxy Group", selection: groupSelection(groups: groups)) {
        ForEach(groups) { group in
          Text(group.name).tag(Optional(group.name))
        }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      .controlSize(.small)
    }
  }

  private func nodeControl(group: ProxyGroup) -> some View {
    DashboardLabeledControl(title: "Node") {
      HStack(spacing: 8) {
        Picker("Node", selection: nodeSelection(group: group)) {
          ForEach(group.nodes.filter(\.isSelectable)) { node in
            Text(node.name).tag(node.name)
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)

        Button {
          guard let node = DashboardProxySelectionState.currentNode(in: group) else { return }
          appModel.testDelay(for: node)
        } label: {
          Image(systemName: "speedometer")
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!appModel.canControlRuntimeProxies)
        .help(appModel.canControlRuntimeProxies ? "Test current node delay" : appModel.proxyRuntimeActionMessage)
      }
    }
    .disabled(!appModel.canControlRuntimeProxies)
  }

  private func groupSelection(groups: [ProxyGroup]) -> Binding<String?> {
    Binding(
      get: {
        DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: selectedGroupName)?.name
      },
      set: { selectedGroupName = $0 }
    )
  }

  private func nodeSelection(group: ProxyGroup) -> Binding<String> {
    Binding(
      get: { DashboardProxySelectionState.currentNode(in: group)?.name ?? "" },
      set: { nodeName in
        guard let node = group.nodes.first(where: { $0.name == nodeName }) else { return }
        appModel.selectProxy(group: group, node: node)
      }
    )
  }
}

private struct DashboardLabeledControl<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct RunningStatusCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardSectionHeader(title: "Running Status", symbolName: "desktopcomputer")

      TimelineView(.periodic(from: Date(), by: 1)) { context in
        HStack(spacing: 10) {
          RuntimeStat(title: "Uptime", value: dashboardDurationString(from: appModel.sessionStartedAt, now: context.date), tint: .cyan)
          RuntimeStat(title: "Connections", value: "\(runtimeData.connections.count)", tint: .orange)
          RuntimeStat(title: "Memory", value: "Runtime", tint: .green)
        }
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(title: "Core", value: appModel.statusSummary)
      RuntimeLine(title: "Profile", value: appModel.profileStore.activeProfile?.name ?? "None")
      RuntimeLine(title: "Mixed Port", value: "\(appModel.currentRuntimeOverrides.mixedPort)")
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
    .dashboardCard()
  }
}

private struct NetworkStatusCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardSectionHeader(title: "Network Status", symbolName: "globe")

      HStack(spacing: 10) {
        RuntimeStat(title: "API", value: "Bearer", tint: .green)
        RuntimeStat(title: "Mode", value: appModel.currentRuntimeOverrides.mode.displayName, tint: .purple)
        RuntimeStat(title: "LAN", value: appModel.currentRuntimeOverrides.allowLan ? "On" : "Off", tint: .orange)
        RuntimeStat(title: "IPv6", value: appModel.currentRuntimeOverrides.ipv6Enabled ? "On" : "Off", tint: .cyan)
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(
        title: "Controller",
        value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)"
      )
      RuntimeLine(title: "Proxy", value: proxyRoutingDetail)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
    .dashboardCard()
  }

  private var proxyRoutingDetail: String {
    switch appModel.proxyRoutingMode {
    case .systemProxy:
      appModel.systemProxyEnabled ? "System Proxy 127.0.0.1:\(appModel.currentRuntimeOverrides.mixedPort)" : "System Proxy ready"
    case .tun:
      appModel.tunEnabled ? "TUN helper controlled" : "TUN ready"
    case .neProxy:
      appModel.networkExtensionEnabled
        ? "NE transparent proxy controlled - System Proxy off - TUN helper untouched"
        : "NE transparent proxy ready - System Proxy off - TUN helper untouched"
    }
  }
}

private struct TunDiagnosticsRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        DashboardSectionHeader(title: "TUN Diagnostics", symbolName: "point.topleft.down.curvedto.point.bottomright.up")
        Spacer()
        Button {
          appModel.refreshTunDiagnostics()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh TUN diagnostics")

        Button {
          appModel.repairTunDNS()
        } label: {
          Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.borderless)
        .disabled(!appModel.canRepairTunDNS)
        .help("Repair TUN system DNS")

        Button {
          appModel.repairTunRouting()
        } label: {
          Image(systemName: "network")
        }
        .buttonStyle(.borderless)
        .disabled(!appModel.canRepairTunRouting)
        .help("Repair TUN routing")
      }

      HStack(spacing: 10) {
        RuntimeStat(title: "Helper", value: helperPIDText, tint: appModel.tunEnabled ? .green : .secondary)
        RuntimeStat(title: "Stack", value: appModel.currentRuntimeOverrides.tunSettings.stack.displayName, tint: .cyan)
        RuntimeStat(title: "Checks", value: diagnosticCounterText, tint: diagnosticTint)
        RuntimeStat(title: "DNS", value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled ? "Fake IP" : "Profile", tint: .orange)
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(title: "Controller", value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)")
      RuntimeLine(title: "Device", value: appModel.currentRuntimeOverrides.tunSettings.normalizedDevice)
      RuntimeLine(title: "DNS Hijack", value: appModel.currentRuntimeOverrides.tunSettings.normalizedDNSHijack.joined(separator: ", "))
      RuntimeLine(
        title: "Fake IP Range",
        value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled
          ? appModel.currentRuntimeOverrides.tunSettings.normalizedFakeIPRange
          : "Off"
      )
      RuntimeLine(
        title: "System DNS",
        value: appModel.currentRuntimeOverrides.tunSettings.systemDNSOverrideEnabled ? appModel.tunSystemDNSState.displayName : "Off"
      )
      if let dnsError = appModel.tunSystemDNSState.errorMessage {
        RuntimeLine(title: "DNS Repair", value: dnsError)
      }
      RuntimeLine(title: "Last Check", value: lastUpdateText)
      if let issue = appModel.tunDiagnostics.primaryIssue {
        RuntimeLine(title: "Primary Issue", value: issue.message)
      }
      ForEach(Array(appModel.tunDiagnostics.checks.prefix(appModel.developerMode ? 8 : 4))) { check in
        TunDiagnosticCheckRow(check: check)
      }
      if appModel.developerMode, let helperLog = appModel.helperLogs.last {
        RuntimeLine(title: "Helper Log", value: helperLog)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
    .dashboardCard()
  }

  private var helperPIDText: String {
    guard let pid = appModel.tunHelperPID else {
      return appModel.tunEnabled ? "Running" : "Ready"
    }
    return "#\(pid)"
  }

  private var diagnosticCounterText: String {
    let diagnostics = appModel.tunDiagnostics
    guard !diagnostics.checks.isEmpty else { return "Waiting" }
    return "\(diagnostics.passCount)/\(diagnostics.warnCount)/\(diagnostics.failCount)"
  }

  private var lastUpdateText: String {
    let updatedAt = appModel.tunDiagnostics.updatedAt
    return updatedAt == Date.distantPast ? "Waiting" : updatedAt.formatted(date: .omitted, time: .standard)
  }

  private var diagnosticTint: Color {
    switch appModel.tunDiagnostics.overallStatus {
    case .pass:
      return .green
    case .warn:
      return .orange
    case .fail:
      return .red
    case .skipped:
      return .secondary
    }
  }
}

private struct TunDiagnosticCheckRow: View {
  let check: TunDiagnosticCheck

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(check.title)
            .foregroundStyle(.primary)
          Spacer(minLength: 8)
          Text(check.status.displayName)
            .foregroundStyle(tint)
        }
        Text(check.detail ?? check.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .font(.callout)
  }

  private var symbolName: String {
    switch check.status {
    case .pass:
      return "checkmark.circle.fill"
    case .warn:
      return "exclamationmark.triangle.fill"
    case .fail:
      return "xmark.octagon.fill"
    case .skipped:
      return "minus.circle"
    }
  }

  private var tint: Color {
    switch check.status {
    case .pass:
      return .green
    case .warn:
      return .orange
    case .fail:
      return .red
    case .skipped:
      return .secondary
    }
  }
}

private struct NetworkExtensionDiagnosticsRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardSectionHeader(title: "NE Diagnostics", symbolName: "network")

      HStack(spacing: 10) {
        RuntimeStat(title: "TCP", value: "\(diagnostics.activeTCPBridgeCount)", tint: .cyan)
        RuntimeStat(title: "UDP", value: "\(diagnostics.activeUDPBridgeCount)", tint: .indigo)
        RuntimeStat(title: "DNS", value: "\(diagnostics.dnsCaptureCount)", tint: .orange)
        RuntimeStat(title: "SOCKS Fail", value: "\(diagnostics.socksHandshakeFailureCount)", tint: diagnostics.socksHandshakeFailureCount > 0 ? .red : .green)
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(title: "Excluded CIDR", value: "\(appModel.networkExtensionRoutingSettings.effectiveRouteExcludeCIDRs.count)")
      RuntimeLine(title: "DNS Runtime", value: appModel.networkExtensionRoutingSettings.dnsFakeIPEnabled ? "Fake IP" : "Profile default")
      RuntimeLine(title: "DNS Capture", value: appModel.networkExtensionRoutingSettings.dnsCaptureEnabled ? "127.0.0.1:\(appModel.networkExtensionRoutingSettings.normalizedDNSListenPort)" : "Off")
      RuntimeLine(title: "System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
      if let dnsError = appModel.networkExtensionSystemDNSState.errorMessage {
        RuntimeLine(title: "DNS Repair", value: dnsError)
      }
      RuntimeLine(title: "Last Update", value: lastUpdateText)
      if let event = diagnostics.recentBypasses.last {
        RuntimeLine(title: "Last Bypass", value: eventSummary(event))
      }
      if let event = diagnostics.recentErrors.last {
        RuntimeLine(title: "Last Error", value: eventSummary(event))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
    .dashboardCard()
  }

  private var diagnostics: NetworkExtensionDiagnosticsSnapshot {
    appModel.networkExtensionController.diagnostics
  }

  private var lastUpdateText: String {
    diagnostics.updatedAt == Date.distantPast ? "Waiting" : diagnostics.updatedAt.formatted(date: .omitted, time: .standard)
  }

  private func eventSummary(_ event: NetworkExtensionDiagnosticEvent) -> String {
    let context = [
      event.flowProtocol?.displayName,
      event.remoteEndpoint,
      event.sourceAppSigningIdentifier
    ]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return context.isEmpty ? event.message : context
  }
}

struct StatusView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Status",
      subtitle: "Runtime facts, diagnostics, logs, and repair."
    ) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          statusActions
        }
        VStack(alignment: .leading, spacing: 8) {
          statusActions
        }
      }
    } content: {
      GeometryReader { proxy in
        ScrollView {
          VStack(spacing: 12) {
            StatusRuntimeOverviewCard()

            StatusDNSCard()
            StatusRuleOverlayCard()

            StatusHelperDiagnosticsCard()

            if showsTunDiagnostics && showsNetworkExtensionDiagnostics {
              StatusResponsivePair(availableWidth: proxy.size.width) {
                StatusTunDiagnosticsCard()
              } trailing: {
                StatusNetworkExtensionDiagnosticsCard()
              }
            } else if showsTunDiagnostics {
              StatusTunDiagnosticsCard()
            } else if showsNetworkExtensionDiagnostics {
              StatusNetworkExtensionDiagnosticsCard()
            }

            RecentLogsRuntimeCard()
          }
          .frame(maxWidth: 1080)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var showsTunDiagnostics: Bool {
    appModel.proxyRoutingMode == .tun || appModel.tunEnabled || appModel.tunnelCoreRunning
  }

  private var showsNetworkExtensionDiagnostics: Bool {
    appModel.proxyRoutingMode == .neProxy || appModel.networkExtensionController.vpnStatus.isActive
  }

  private var statusActions: some View {
    Group {
      Button {
        refreshStatus()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }

      Button {
        appModel.copyRuntimeDiagnostics()
      } label: {
        Label("Copy Diagnostics", systemImage: "doc.on.doc")
      }

      Button {
        appModel.openRuntimeLogs()
      } label: {
        Label("Open Logs", systemImage: "terminal")
      }

      Button {
        appModel.openLogsFolder()
      } label: {
        Label("Open Log Folder", systemImage: "folder")
      }
    }
  }

  private func refreshStatus() {
    appModel.refreshHelperStatus()
    appModel.refreshNetworkExtensionStatus()
    appModel.refreshTunDiagnostics()
    if appModel.isCoreRunning {
      appModel.reloadRuntimeData()
    }
  }
}

private struct StatusResponsivePair<Leading: View, Trailing: View>: View {
  let availableWidth: CGFloat
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    StatusEqualHeightPairLayout(
      axis: availableWidth >= DashboardLayoutMetrics.runningPairColumnsBreakpoint ? .horizontal : .vertical,
      spacing: DashboardLayoutMetrics.dashboardGridSpacing
    ) {
      leading
      trailing
    }
  }
}

private struct StatusEqualHeightPairLayout: Layout {
  let axis: Axis
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard !subviews.isEmpty else { return .zero }

    switch axis {
    case .horizontal:
      let totalWidth = max(0, proposal.width ?? subviews.reduce(CGFloat.zero) { partial, subview in
        partial + subview.sizeThatFits(.unspecified).width
      } + spacing * CGFloat(max(0, subviews.count - 1)))
      let itemWidth = max(0, (totalWidth - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(subviews.count))
      let itemHeight = equalizedHeight(for: subviews, width: itemWidth)
      return CGSize(width: totalWidth, height: itemHeight)

    case .vertical:
      let totalWidth = max(0, proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
      let itemHeight = equalizedHeight(for: subviews, width: totalWidth)
      return CGSize(
        width: totalWidth,
        height: itemHeight * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1))
      )
    }
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    guard !subviews.isEmpty else { return }

    switch axis {
    case .horizontal:
      let itemWidth = max(0, (bounds.width - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(subviews.count))
      let itemHeight = equalizedHeight(for: subviews, width: itemWidth)
      for (index, subview) in subviews.enumerated() {
        subview.place(
          at: CGPoint(x: bounds.minX + CGFloat(index) * (itemWidth + spacing), y: bounds.minY),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: itemWidth, height: itemHeight)
        )
      }

    case .vertical:
      let itemHeight = equalizedHeight(for: subviews, width: bounds.width)
      for (index, subview) in subviews.enumerated() {
        subview.place(
          at: CGPoint(x: bounds.minX, y: bounds.minY + CGFloat(index) * (itemHeight + spacing)),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: bounds.width, height: itemHeight)
        )
      }
    }
  }

  private func equalizedHeight(for subviews: Subviews, width: CGFloat) -> CGFloat {
    subviews
      .map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
      .max() ?? 0
  }
}

private struct StatusFactGrid<Content: View>: View {
  let minimumColumnWidth: CGFloat
  let spacing: CGFloat
  let content: Content

  init(
    minimumColumnWidth: CGFloat = 108,
    spacing: CGFloat = 8,
    @ViewBuilder content: () -> Content
  ) {
    self.minimumColumnWidth = minimumColumnWidth
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    StatusFactFlowLayout(
      minimumItemWidth: minimumColumnWidth,
      spacing: spacing
    ) {
      content
    }
  }
}

private struct StatusFactFlowLayout: Layout {
  let minimumItemWidth: CGFloat
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard !subviews.isEmpty else { return .zero }

    let availableWidth = proposal.width ?? unconstrainedWidth(for: subviews)
    let rows = rows(for: subviews, availableWidth: availableWidth)
    let height = rows.reduce(CGFloat.zero) { partial, row in
      partial + row.height
    } + spacing * CGFloat(max(0, rows.count - 1))

    return CGSize(
      width: proposal.width ?? rows.map(\.width).max() ?? 0,
      height: height
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    var y = bounds.minY

    for row in rows(for: subviews, availableWidth: bounds.width) {
      var x = bounds.minX

      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y),
          anchor: .topLeading,
          proposal: ProposedViewSize(width: item.size.width, height: row.height)
        )
        x += item.size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private func rows(for subviews: Subviews, availableWidth: CGFloat) -> [FlowRow] {
    let usableWidth = max(0, availableWidth)
    let rowCounts = rowCounts(itemCount: subviews.count, availableWidth: usableWidth)
    var rows: [FlowRow] = []

    var startIndex = 0
    for rowCount in rowCounts {
      let itemWidth = widthForRow(itemCount: rowCount, availableWidth: usableWidth)
      var items: [FlowItem] = []
      var rowHeight: CGFloat = 0

      for index in startIndex ..< startIndex + rowCount {
        let measuredSize = subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
        items.append(FlowItem(index: index, size: CGSize(width: itemWidth, height: measuredSize.height)))
        rowHeight = max(rowHeight, measuredSize.height)
      }

      let rowWidth = itemWidth * CGFloat(rowCount) + spacing * CGFloat(max(0, rowCount - 1))
      rows.append(FlowRow(items: items, width: rowWidth, height: rowHeight))
      startIndex += rowCount
    }

    return rows
  }

  private func rowCounts(itemCount: Int, availableWidth: CGFloat) -> [Int] {
    guard itemCount > 0 else { return [] }

    let maximumColumns = maximumColumns(itemCount: itemCount, availableWidth: availableWidth)
    let rowCount = Int(ceil(Double(itemCount) / Double(maximumColumns)))
    let baseCount = itemCount / rowCount
    let extraCount = itemCount % rowCount

    return (0 ..< rowCount).map { rowIndex in
      baseCount + (rowIndex < extraCount ? 1 : 0)
    }
  }

  private func maximumColumns(itemCount: Int, availableWidth: CGFloat) -> Int {
    guard availableWidth > 0 else { return 1 }

    let columns = Int(floor((availableWidth + spacing) / (minimumItemWidth + spacing)))
    return max(1, min(itemCount, columns))
  }

  private func widthForRow(itemCount: Int, availableWidth: CGFloat) -> CGFloat {
    guard itemCount > 0 else { return 0 }

    let reservedSpacing = spacing * CGFloat(max(0, itemCount - 1))
    return max(0, (availableWidth - reservedSpacing) / CGFloat(itemCount))
  }

  private func unconstrainedWidth(for subviews: Subviews) -> CGFloat {
    minimumItemWidth * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1))
  }

  private struct FlowItem {
    let index: Int
    let size: CGSize
  }

  private struct FlowRow {
    let items: [FlowItem]
    let width: CGFloat
    let height: CGFloat
  }
}

private struct StatusFactTile: View {
  let title: String
  let value: String
  var tint: Color = .primary
  var valueLineLimit = 1
  var isProminent = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(LocalizedStringKey(title))
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Text(localizedValue)
        .font(valueFont)
        .foregroundStyle(tint)
        .lineLimit(valueLineLimit)
        .minimumScaleFactor(isProminent ? 0.68 : 0.76)
        .truncationMode(.middle)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: isProminent ? 62 : 52, maxHeight: .infinity, alignment: .topLeading)
    .statusFactSurface()
    .help(localizedValue)
    .accessibilityElement(children: .combine)
  }

  private var localizedValue: String {
    localizedRuntimeText(value)
  }

  private var valueFont: Font {
    isProminent ? .system(.title3, design: .rounded).weight(.semibold) : .callout.weight(.semibold)
  }
}

private struct DashboardInsetSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    content
      .background(.insetSurface, in: shape)
      .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 1))
  }
}

private extension View {
  func dashboardInsetSurface() -> some View {
    modifier(DashboardInsetSurfaceModifier())
  }

  func statusFactSurface() -> some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    return background(.tileSurface, in: shape)
      .overlay(shape.strokeBorder(.separator.opacity(0.7), lineWidth: 0.75))
  }
}

private struct StatusRuntimeOverviewCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Runtime Status", symbolName: "waveform.path.ecg.rectangle")

      StatusFactGrid(minimumColumnWidth: 108) {
        StatusFactTile(title: "State", value: appModel.statusSummary, tint: statusTint, isProminent: true)
        StatusFactTile(title: "Mode", value: appModel.proxyRoutingMode.displayName, tint: .cyan, isProminent: true)
        StatusFactTile(title: "Profile", value: appModel.profileStore.activeProfile?.name ?? "None", tint: .orange, isProminent: true)
        StatusFactTile(title: "Core", value: appModel.coreController.status.displayName, tint: coreTint, isProminent: true)
      }

      StatusFactGrid(minimumColumnWidth: 96) {
        StatusFactTile(title: "Controller", value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)")
        StatusFactTile(title: "Controller Secret", value: RuntimeDiagnosticsReport.redactedSecret)
        StatusFactTile(title: "Run Mode", value: appModel.currentRuntimeOverrides.mode.displayName)
        StatusFactTile(title: "System Proxy", value: appModel.systemProxyEnabled ? "Enabled" : "Not Enabled")
        StatusFactTile(title: "TUN", value: appModel.tunEnabled ? "Enabled" : "Not Enabled")
        StatusFactTile(title: "NE Proxy", value: appModel.networkExtensionEnabled ? "Enabled" : "Not Enabled")
        if let readinessIssue = appModel.readinessIssue {
          StatusFactTile(title: "Readiness", value: readinessIssue, valueLineLimit: 2)
        }
        if let error = appModel.lastError {
          StatusFactTile(title: "Last Error", value: error, tint: .red, valueLineLimit: 2)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .dashboardCard()
  }

  private var statusTint: Color {
    appModel.isRunning ? .green : .secondary
  }

  private var coreTint: Color {
    switch appModel.coreController.status {
    case .running:
      return .green
    case .crashed:
      return .red
    case .starting, .restarting:
      return .orange
    case .stopped:
      return .secondary
    }
  }
}

private struct StatusDNSCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Effective DNS", symbolName: "server.rack")

      StatusFactGrid(minimumColumnWidth: 112) {
        StatusFactTile(title: "Routing", value: appModel.proxyRoutingMode.displayName)
        StatusFactTile(title: "TUN DNS Mode", value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled ? "Fake IP" : "Profile", tint: .orange)
        StatusFactTile(
          title: "TUN System DNS",
          value: appModel.currentRuntimeOverrides.tunSettings.systemDNSOverrideEnabled ? appModel.tunSystemDNSState.displayName : "Off"
        )
        StatusFactTile(
          title: "DNS Hijack",
          value: appModel.currentRuntimeOverrides.tunSettings.normalizedDNSHijack.joined(separator: ", "),
          valueLineLimit: 2
        )
        StatusFactTile(
          title: "Fake IP Range",
          value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled
            ? appModel.currentRuntimeOverrides.tunSettings.normalizedFakeIPRange
            : "Off"
        )
        StatusFactTile(title: "Nameserver", value: summarized(appModel.currentRuntimeOverrides.tunSettings.dns.nameserver), valueLineLimit: 2)
        StatusFactTile(title: "Fallback", value: summarized(appModel.currentRuntimeOverrides.tunSettings.dns.fallback), valueLineLimit: 2)
        StatusFactTile(title: "NE System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
        if let dnsError = appModel.tunSystemDNSState.errorMessage ?? appModel.networkExtensionSystemDNSState.errorMessage {
          StatusFactTile(title: "DNS Repair", value: dnsError, tint: .red, valueLineLimit: 2)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .dashboardCard()
  }

  private func summarized(_ values: [String]) -> String {
    values.isEmpty ? "Profile" : values.prefix(3).joined(separator: ", ")
  }
}

private struct StatusRuleOverlayCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Rule Overlay", symbolName: "list.bullet.rectangle")

      StatusFactGrid(minimumColumnWidth: 96) {
        StatusFactTile(
          title: "Status",
          value: appModel.ruleOverlaySettings.enabled ? "Enabled" : "Disabled",
          tint: appModel.ruleOverlaySettings.enabled ? .green : .secondary,
          isProminent: true
        )
        StatusFactTile(
          title: "Before",
          value: "\(appModel.ruleOverlaySettings.prependRules.count)",
          tint: .cyan,
          isProminent: true
        )
        StatusFactTile(
          title: "After",
          value: "\(appModel.ruleOverlaySettings.appendRules.count)",
          tint: .orange,
          isProminent: true
        )
        StatusFactTile(
          title: "Disabled",
          value: "\(appModel.ruleOverlaySettings.disabledRuleMatchers.count)",
          tint: .red,
          isProminent: true
        )
      }

      StatusFactGrid(minimumColumnWidth: 132) {
        StatusFactTile(title: "Runtime Source", value: "Generated runtime YAML", valueLineLimit: 2)
        StatusFactTile(title: "Profile YAML", value: "Unchanged")
        if let validationError = appModel.ruleOverlaySettings.validationError {
          StatusFactTile(title: "Validation", value: validationError, tint: .red, valueLineLimit: 2)
        }
        ForEach(Array((appModel.ruleOverlaySettings.prependRules + appModel.ruleOverlaySettings.appendRules).prefix(4))) { rule in
          StatusFactTile(title: rule.kind.displayName, value: rule.runtimeRule, valueLineLimit: 2)
        }
        ForEach(Array(appModel.ruleOverlaySettings.disabledRuleMatchers.prefix(4))) { matcher in
          StatusFactTile(title: "Disable \(matcher.mode.displayName)", value: matcher.normalizedPattern, valueLineLimit: 2)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .dashboardCard()
  }
}

private struct StatusHelperDiagnosticsCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        DashboardSectionHeader(title: "Helper Diagnostics", symbolName: "checkmark.shield")
        Spacer()
        Button {
          appModel.repairHelperRegistration()
        } label: {
          Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.borderless)
        .help("Repair Helper")

        Button {
          appModel.openHelperApprovalSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Open helper approval settings")
      }

      StatusFactGrid(minimumColumnWidth: 108) {
        StatusFactTile(title: "Registered", value: yesNo(appModel.tunHelperStatusDetail.registered), tint: appModel.tunHelperStatusDetail.registered ? .green : .secondary, isProminent: true)
        StatusFactTile(title: "Approval", value: appModel.tunHelperStatusDetail.requiresApproval ? "Required" : "Clear", tint: appModel.tunHelperStatusDetail.requiresApproval ? .orange : .green, isProminent: true)
        StatusFactTile(title: "XPC", value: appModel.tunHelperStatusDetail.xpcReachable ? "Reachable" : "Unreachable", tint: appModel.tunHelperStatusDetail.xpcReachable ? .green : .secondary, isProminent: true)
        StatusFactTile(title: "Running", value: runningText, tint: appModel.tunHelperStatusDetail.running ? .green : .secondary, isProminent: true)
      }

      StatusFactGrid {
        StatusFactTile(title: "Service", value: appModel.tunHelperStatusDetail.serviceStatus.displayName)
        StatusFactTile(title: "Fingerprint", value: fingerprintText)
        StatusFactTile(title: "Protocol", value: protocolText)
        StatusFactTile(title: "Helper Build", value: appModel.tunHelperStatusDetail.helperBuildVersion ?? "Unknown")
        StatusFactTile(title: "Launchctl", value: latestLaunchctlStatus, valueLineLimit: 2)
        StatusFactTile(title: "Last Exit", value: latestExitSummary ?? "Unknown", valueLineLimit: 2)
        StatusFactTile(title: "Safe Paths", value: "Bundled core, runtime config, and work directory validated", valueLineLimit: 2)
        StatusFactTile(title: "Message", value: appModel.tunHelperStatusDetail.message, valueLineLimit: 2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .dashboardCard()
    .onAppear {
      appModel.refreshHelperRegistrationStatus()
    }
  }

  private func yesNo(_ value: Bool) -> String {
    value ? "Yes" : "No"
  }

  private var runningText: String {
    if let pid = appModel.tunHelperStatusDetail.pid {
      return "PID \(pid)"
    }
    return yesNo(appModel.tunHelperStatusDetail.running)
  }

  private var fingerprintText: String {
    guard appModel.tunHelperStatusDetail.fingerprintRecorded else {
      return "Not Recorded"
    }
    switch appModel.tunHelperStatusDetail.fingerprintMatches {
    case true:
      return "Match"
    case false:
      return "Mismatch"
    case nil:
      return "Unknown"
    }
  }

  private var protocolText: String {
    guard let version = appModel.tunHelperStatusDetail.protocolVersion else {
      return appModel.tunHelperStatusDetail.migrationRequired ? "Missing" : "Unknown"
    }
    return appModel.tunHelperStatusDetail.migrationRequired ? "v\(version) Needs Repair" : "v\(version)"
  }

  private var latestExitSummary: String? {
    appModel.helperLogs.reversed().first { line in
      line.localizedCaseInsensitiveContains("mihomo exited with code")
        || line.localizedCaseInsensitiveContains("last exit code")
    }
  }

  private var latestLaunchctlStatus: String {
    appModel.helperLogs.reversed().first { line in
      line.localizedCaseInsensitiveContains("state =")
        || line.localizedCaseInsensitiveContains("job state =")
    } ?? "Unknown"
  }
}

private struct StatusTunDiagnosticsCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        DashboardSectionHeader(title: "TUN Diagnostics", symbolName: "point.topleft.down.curvedto.point.bottomright.up")
        Spacer()
        Button {
          appModel.refreshTunDiagnostics()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh TUN diagnostics")

        Button {
          appModel.repairTunDNS()
        } label: {
          Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.borderless)
        .disabled(!appModel.canRepairTunDNS)
        .help("Repair TUN system DNS")

        Button {
          appModel.repairTunRouting()
        } label: {
          Image(systemName: "network")
        }
        .buttonStyle(.borderless)
        .disabled(!appModel.canRepairTunRouting)
        .help("Repair TUN routing")
      }

      StatusFactGrid(minimumColumnWidth: 108) {
        StatusFactTile(title: "Helper", value: helperPIDText, tint: appModel.tunEnabled ? .green : .secondary, isProminent: true)
        StatusFactTile(title: "Stack", value: appModel.currentRuntimeOverrides.tunSettings.stack.displayName, tint: .cyan, isProminent: true)
        StatusFactTile(title: "Checks", value: diagnosticCounterText, tint: diagnosticTint, isProminent: true)
        StatusFactTile(title: "DNS", value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled ? "Fake IP" : "Profile", tint: .orange, isProminent: true)
      }

      StatusFactGrid {
        StatusFactTile(title: "Controller", value: "\(appModel.currentRuntimeOverrides.externalControllerHost):\(appModel.currentRuntimeOverrides.externalControllerPort)")
        StatusFactTile(title: "Device", value: appModel.currentRuntimeOverrides.tunSettings.normalizedDevice)
        StatusFactTile(
          title: "DNS Hijack",
          value: appModel.currentRuntimeOverrides.tunSettings.normalizedDNSHijack.joined(separator: ", "),
          valueLineLimit: 2
        )
        StatusFactTile(
          title: "Fake IP Range",
          value: appModel.currentRuntimeOverrides.tunSettings.dnsFakeIPEnabled
            ? appModel.currentRuntimeOverrides.tunSettings.normalizedFakeIPRange
            : "Off"
        )
        StatusFactTile(
          title: "System DNS",
          value: appModel.currentRuntimeOverrides.tunSettings.systemDNSOverrideEnabled ? appModel.tunSystemDNSState.displayName : "Off"
        )
        StatusFactTile(title: "Last Check", value: lastUpdateText)
        if let dnsError = appModel.tunSystemDNSState.errorMessage {
          StatusFactTile(title: "DNS Repair", value: dnsError, tint: .red, valueLineLimit: 2)
        }
        if let issue = appModel.tunDiagnostics.primaryIssue {
          StatusFactTile(title: "Primary Issue", value: issue.message, tint: .orange, valueLineLimit: 2)
        }
        if appModel.developerMode, let helperLog = appModel.helperLogs.last {
          StatusFactTile(title: "Helper Log", value: helperLog, valueLineLimit: 2)
        }
      }

      if !appModel.tunDiagnostics.checks.isEmpty {
        VStack(spacing: 8) {
          ForEach(Array(appModel.tunDiagnostics.checks.prefix(appModel.developerMode ? 8 : 4))) { check in
            StatusTunDiagnosticCheckTile(check: check)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 252, maxHeight: .infinity, alignment: .topLeading)
    .dashboardCard()
  }

  private var helperPIDText: String {
    guard let pid = appModel.tunHelperPID else {
      return appModel.tunEnabled ? "Running" : "Ready"
    }
    return "#\(pid)"
  }

  private var diagnosticCounterText: String {
    let diagnostics = appModel.tunDiagnostics
    guard !diagnostics.checks.isEmpty else { return "Waiting" }
    return "\(diagnostics.passCount)/\(diagnostics.warnCount)/\(diagnostics.failCount)"
  }

  private var lastUpdateText: String {
    let updatedAt = appModel.tunDiagnostics.updatedAt
    return updatedAt == Date.distantPast ? "Waiting" : updatedAt.formatted(date: .omitted, time: .standard)
  }

  private var diagnosticTint: Color {
    switch appModel.tunDiagnostics.overallStatus {
    case .pass:
      return .green
    case .warn:
      return .orange
    case .fail:
      return .red
    case .skipped:
      return .secondary
    }
  }
}

private struct StatusTunDiagnosticCheckTile: View {
  let check: TunDiagnosticCheck

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 16, height: 18)

      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(check.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(check.status.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
        }

        Text(check.detail ?? check.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .minimumScaleFactor(0.78)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .statusFactSurface()
  }

  private var symbolName: String {
    switch check.status {
    case .pass:
      return "checkmark.circle.fill"
    case .warn:
      return "exclamationmark.triangle.fill"
    case .fail:
      return "xmark.octagon.fill"
    case .skipped:
      return "minus.circle"
    }
  }

  private var tint: Color {
    switch check.status {
    case .pass:
      return .green
    case .warn:
      return .orange
    case .fail:
      return .red
    case .skipped:
      return .secondary
    }
  }
}

private struct StatusNetworkExtensionDiagnosticsCard: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "NE Diagnostics", symbolName: "network")

      StatusFactGrid(minimumColumnWidth: 96) {
        StatusFactTile(title: "TCP", value: "\(diagnostics.activeTCPBridgeCount)", tint: .cyan, isProminent: true)
        StatusFactTile(title: "UDP", value: "\(diagnostics.activeUDPBridgeCount)", tint: .indigo, isProminent: true)
        StatusFactTile(title: "DNS", value: "\(diagnostics.dnsCaptureCount)", tint: .orange, isProminent: true)
        StatusFactTile(title: "SOCKS Fail", value: "\(diagnostics.socksHandshakeFailureCount)", tint: diagnostics.socksHandshakeFailureCount > 0 ? .red : .green, isProminent: true)
      }

      StatusFactGrid {
        StatusFactTile(title: "Excluded CIDR", value: "\(appModel.networkExtensionRoutingSettings.effectiveRouteExcludeCIDRs.count)")
        StatusFactTile(title: "DNS Runtime", value: appModel.networkExtensionRoutingSettings.dnsFakeIPEnabled ? "Fake IP" : "Profile default")
        StatusFactTile(title: "DNS Capture", value: appModel.networkExtensionRoutingSettings.dnsCaptureEnabled ? "127.0.0.1:\(appModel.networkExtensionRoutingSettings.normalizedDNSListenPort)" : "Off")
        StatusFactTile(title: "System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
        StatusFactTile(title: "Last Update", value: lastUpdateText)
        if let dnsError = appModel.networkExtensionSystemDNSState.errorMessage {
          StatusFactTile(title: "DNS Repair", value: dnsError, tint: .red, valueLineLimit: 2)
        }
        if let event = diagnostics.recentBypasses.last {
          StatusFactTile(title: "Last Bypass", value: eventSummary(event), valueLineLimit: 2)
        }
        if let event = diagnostics.recentErrors.last {
          StatusFactTile(title: "Last Error", value: eventSummary(event), tint: .red, valueLineLimit: 2)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 252, maxHeight: .infinity, alignment: .topLeading)
    .dashboardCard()
  }

  private var diagnostics: NetworkExtensionDiagnosticsSnapshot {
    appModel.networkExtensionController.diagnostics
  }

  private var lastUpdateText: String {
    diagnostics.updatedAt == Date.distantPast ? "Waiting" : diagnostics.updatedAt.formatted(date: .omitted, time: .standard)
  }

  private func eventSummary(_ event: NetworkExtensionDiagnosticEvent) -> String {
    let context = [
      event.flowProtocol?.displayName,
      event.remoteEndpoint,
      event.sourceAppSigningIdentifier
    ]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return context.isEmpty ? event.message : context
  }
}

private struct TrafficRuntimeCard: View {
  let samples: [TrafficSample]
  let isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Traffic", symbolName: "waveform.path.ecg")

      if isLoading {
        ClashMaxChartSkeleton()
          .frame(height: 178)
      } else {
        DashboardTrafficSparkline(samples: samples)
          .frame(height: 178)
      }

      HStack(spacing: 16) {
        LegendDot(title: "Download", color: .cyan)
        LegendDot(title: "Upload", color: .indigo)
        Spacer()
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    .dashboardCard()
  }
}

private struct ProxyGroupsRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        DashboardSectionHeader(title: "Proxy Groups", symbolName: "point.3.connected.trianglepath.dotted")
        Button {
          appModel.reloadRuntimeData()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh")
      }

      if runtimeData.proxyGroups.isEmpty, appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting {
        ClashMaxSkeletonList(rows: 4, showsLeadingIcon: true, trailingWidth: 58)
      } else if runtimeData.proxyGroups.isEmpty {
        DashboardEmptyRuntimeView(title: "Waiting for runtime data", symbolName: "hourglass")
      } else {
        VStack(spacing: 8) {
          ForEach(Array(runtimeData.proxyGroups.prefix(6))) { group in
            HStack(spacing: 10) {
              Image(systemName: "circle.grid.cross")
                .foregroundStyle(.cyan)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                  .lineLimit(1)
                Text(group.selected ?? "No selection")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Text(group.type)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
    .dashboardCard()
  }
}

private struct ConnectionsRulesRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Connections", symbolName: "network", trailing: "\(runtimeData.rules.count) rules")

      if runtimeData.connections.isEmpty, appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting {
        ClashMaxSkeletonList(rows: 4, showsLeadingIcon: false, trailingWidth: 52)
      } else if runtimeData.connections.isEmpty {
        DashboardEmptyRuntimeView(title: "Waiting for runtime data", symbolName: "network.slash")
      } else {
        VStack(spacing: 8) {
          ForEach(Array(runtimeData.connections.prefix(6))) { connection in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(connection.host)
                  .lineLimit(1)
                Text(connection.rule ?? connection.network)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Text(TrafficSample.format(connection.download + connection.upload))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.cyan)
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
    .dashboardCard()
  }
}

private struct RecentLogsRuntimeCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    let visibleLogs = runtimeData.visibleLogs(developerMode: appModel.developerMode)

    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Recent Logs", symbolName: "terminal", trailing: "\(visibleLogs.count)")

      if visibleLogs.isEmpty, appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting {
        ClashMaxSkeletonList(rows: 4, showsLeadingIcon: false, trailingWidth: nil)
      } else if visibleLogs.isEmpty {
        DashboardEmptyRuntimeView(title: "Waiting for runtime data", symbolName: "text.alignleft")
      } else {
        VStack(spacing: 8) {
          ForEach(Array(visibleLogs.suffix(6))) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(entry.level.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 56, alignment: .leading)
              Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
    .dashboardCard()
  }

  private func levelColor(_ level: String) -> Color {
    switch level.lowercased() {
    case "error":
      return .red
    case "warning", "warn":
      return .orange
    case "debug":
      return .purple
    default:
      return .secondary
    }
  }
}

private struct RuntimeStat: View {
  let title: LocalizedStringResource
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(localizedRuntimeText(value))
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct RuntimeLine: View {
  let title: LocalizedStringResource
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(localizedRuntimeText(value))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .font(.callout)
  }
}

private func localizedRuntimeText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private struct LegendDot: View {
  let title: String
  let color: Color

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private extension View {
  func staggeredArrival(index: Int, reduceMotion: Bool, trigger: DashboardRuntimeState) -> some View {
    modifier(StaggeredArrivalModifier(index: index, reduceMotion: reduceMotion, trigger: trigger))
  }
}

private struct StaggeredArrivalModifier: ViewModifier {
  let index: Int
  let reduceMotion: Bool
  let trigger: DashboardRuntimeState

  func body(content: Content) -> some View {
    content
      .phaseAnimator([false, true], trigger: trigger) { view, phase in
        view
          .opacity(phase ? 1 : 0.72)
          .offset(y: reduceMotion ? 0 : (phase ? 0 : 10))
      } animation: { _ in
        reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.28).delay(Double(index) * 0.05)
      }
  }
}
