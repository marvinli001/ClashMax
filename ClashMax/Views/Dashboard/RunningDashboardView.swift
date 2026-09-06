import Pow
import SwiftUI

struct RunningDashboardView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  // Owned by AppModel so the Current Node card repaints from the retained
  // snapshot when the user returns to the dashboard tab (see ProxiesView).
  private let currentNodeCoordinator: ProxySearchCoordinator
  @State private var selectedProxyGroupName: String?
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat

  init(
    currentNodeCoordinator: ProxySearchCoordinator,
    state: DashboardRuntimeState,
    namespace: Namespace.ID,
    reduceMotion: Bool,
    availableWidth: CGFloat
  ) {
    self.currentNodeCoordinator = currentNodeCoordinator
    self.state = state
    self.namespace = namespace
    self.reduceMotion = reduceMotion
    self.availableWidth = availableWidth
  }

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
    if appModel.runtimeDataLoading, snapshot.unfilteredGroups.isEmpty { return true }
    if !snapshot.hasResolved, !appModel.visibleProxyGroups.isEmpty { return true }
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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
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
          GridItem(.flexible(minimum: 120), spacing: 8),
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
        .background(tint.opacity(0.12), in: SurfaceRadius.shape(SurfaceRadius.chip))

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
       let preferred = groups.first(where: { $0.name == preferredName })
    {
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
  @Environment(AppModel.self) private var appModel
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
        .disabled(!appModel.canControlRuntimeProxies || !currentNodeSupportsDelayTesting(in: group))
        .help(nodeDelayTestHelp(group: group))
      }
    }
    .disabled(!appModel.canControlRuntimeProxies)
  }

  /// Reserved outbounds (REJECT / PASS …) can be *selected* as a group's node but never answer a
  /// delay probe, so the button is disabled instead of firing a request that always fails.
  private func currentNodeSupportsDelayTesting(in group: ProxyGroup) -> Bool {
    guard let node = DashboardProxySelectionState.currentNode(in: group) else { return false }
    return node.supportsDelayTesting
  }

  private func nodeDelayTestHelp(group: ProxyGroup) -> String {
    guard appModel.canControlRuntimeProxies else { return appModel.proxyRuntimeActionMessage }
    guard currentNodeSupportsDelayTesting(in: group) else {
      return String(localized: "Built-in outbounds have no connection to measure.")
    }
    return String(localized: "Test current node delay")
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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardSectionHeader(title: "Running Status", symbolName: "desktopcomputer")

      TimelineView(.periodic(from: Date(), by: 1)) { context in
        HStack(spacing: 10) {
          RuntimeStat(title: "Uptime", value: dashboardDurationString(from: appModel.sessionStartedAt, now: context.date), tint: .cyan)
          RuntimeStat(title: "Connections", value: "\(runtimeData.connections.count)", tint: .orange)
          RuntimeStat(title: "Memory", value: memoryValue, tint: .green)
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

  /// The core's own `/memory` reading. Until the first real frame arrives there is nothing to
  /// report, and an em dash says that honestly where "0 B" would have claimed a measurement.
  private var memoryValue: String {
    runtimeData.memorySample.hasReading ? runtimeData.memorySample.formattedInUse : "—"
  }
}

private struct NetworkStatusCard: View {
  @Environment(AppModel.self) private var appModel

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
  @Environment(AppModel.self) private var appModel

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

        if appModel.hasResidualSystemProxy {
          Button {
            appModel.disableResidualSystemProxy()
          } label: {
            Image(systemName: "xmark.shield")
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canDisableResidualSystemProxy)
          .help("Disable residual System Proxy")
        }
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
    let base = "\(diagnostics.passCount)/\(diagnostics.warnCount)/\(diagnostics.failCount)"
    // Only widen the tile when something was actually downgraded, so the segments always
    // account for every listed check.
    return diagnostics.infoCount > 0 ? "\(base)/\(diagnostics.infoCount)" : base
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
    case .info:
      return .blue
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
    case .info:
      return "info.circle.fill"
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
    case .info:
      return .blue
    case .skipped:
      return .secondary
    }
  }
}

private struct NetworkExtensionDiagnosticsRuntimeCard: View {
  @Environment(AppModel.self) private var appModel

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
      event.sourceAppSigningIdentifier,
    ]
    .compactMap(\.self)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    return context.isEmpty ? event.message : context
  }
}

/// The first thing the Status page has to answer, computed once from the runtime facts so the
/// headline, the summary sentence and the tint can never disagree with each other. Pure so tests can
/// pin the wording of each state.
struct StatusOverview: Equatable {
  enum Tone: Equatable {
    case running
    case attention
    case failure
    case idle
  }

  let headline: String
  let detail: String
  let systemImage: String
  let tone: Tone

  init(
    isRunning: Bool,
    previewRuntimeActive: Bool,
    coreStatus: CoreStatus,
    isStarting: Bool,
    routingMode: ProxyRoutingMode,
    systemProxyEnabled: Bool,
    tunEnabled: Bool,
    networkExtensionEnabled: Bool,
    readinessIssue: String?
  ) {
    let captureActive = systemProxyEnabled || tunEnabled || networkExtensionEnabled
    if case let .crashed(message) = coreStatus {
      headline = String(localized: "Core crashed")
      detail = message
      systemImage = "exclamationmark.triangle.fill"
      tone = .failure
      return
    }
    if isStarting {
      headline = String(localized: "Starting")
      detail = String(format: String(localized: "Bringing up the core with %@ routing."), routingMode.displayName)
      systemImage = "clock.arrow.circlepath"
      tone = .attention
      return
    }
    if isRunning, captureActive {
      headline = String(format: String(localized: "Traffic is routed through ClashMax via %@"), routingMode.displayName)
      detail = String(localized: "The core is running and the selected capture mode is active.")
      systemImage = "checkmark.shield.fill"
      tone = .running
      return
    }
    if isRunning {
      headline = String(localized: "Core is running, but no traffic is captured")
      detail = String(format: String(localized: "%@ is not enabled yet, so apps still connect directly."), routingMode.displayName)
      systemImage = "exclamationmark.shield"
      tone = .attention
      return
    }
    if previewRuntimeActive {
      headline = String(localized: "Preview core is running for delay tests")
      detail = String(localized: "It listens on loopback only. Traffic is not captured until you start ClashMax.")
      systemImage = "wand.and.stars"
      tone = .idle
      return
    }
    if let readinessIssue {
      headline = String(localized: "Cannot start")
      detail = readinessIssue
      systemImage = "exclamationmark.triangle.fill"
      tone = .attention
      return
    }
    headline = String(localized: "Stopped")
    detail = String(format: String(localized: "Start ClashMax to route traffic via %@."), routingMode.displayName)
    systemImage = "stop.circle"
    tone = .idle
  }
}

/// The on-demand sections of the Status page.
enum StatusDetailSection: String, CaseIterable, Identifiable {
  case runtime
  case dns
  case ruleOverlay
  case helper
  case tun
  case networkExtension

  var id: String { rawValue }

  /// Which sections open by default: the runtime facts always, and a diagnostics section only when
  /// it is both relevant to the selected routing mode and reporting something to look at. Everything
  /// healthy and unrelated stays folded.
  static func defaultExpanded(
    routingMode: ProxyRoutingMode,
    helperHasIssue: Bool,
    tunHasIssue: Bool,
    networkExtensionHasIssue: Bool
  ) -> Set<StatusDetailSection> {
    var expanded: Set<StatusDetailSection> = [.runtime]
    if routingMode == .tun, helperHasIssue {
      expanded.insert(.helper)
    }
    if routingMode == .tun, tunHasIssue {
      expanded.insert(.tun)
    }
    if routingMode == .neProxy, networkExtensionHasIssue {
      expanded.insert(.networkExtension)
    }
    return expanded
  }
}

/// Keeps the Status page's Attention list free of the same problem twice: the generic last error is
/// dropped when a specific item already carries its text (or it carries theirs).
enum StatusAttentionDeduplication {
  static func isRedundant(lastError: String, specificMessages: [String]) -> Bool {
    let error = lastError.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !error.isEmpty else { return true }
    return specificMessages.contains { message in
      let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty else { return false }
      return error.localizedCaseInsensitiveContains(message) || message.localizedCaseInsensitiveContains(error)
    }
  }
}

/// One thing that needs the user's attention, with the recovery the app already offers for it.
private struct StatusAttentionItem: Identifiable {
  enum Action {
    case repairHelper
    case openHelperSettings
    case repairTunDNS
    case repairTunRouting
    case disableResidualSystemProxy
    case showSection(StatusDetailSection)

    var title: String {
      switch self {
      case .repairHelper: String(localized: "Repair Helper")
      case .openHelperSettings: String(localized: "Open System Settings")
      case .repairTunDNS: String(localized: "Repair DNS")
      case .repairTunRouting: String(localized: "Repair Routing")
      case .disableResidualSystemProxy: String(localized: "Disable System Proxy")
      case .showSection: String(localized: "Show Details")
      }
    }
  }

  let id: String
  let title: String
  let message: String
  let isError: Bool
  let actions: [Action]
}

struct StatusView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var expandedSections: Set<StatusDetailSection> = [.runtime]
  @State private var hasResolvedDefaultExpansion = false

  var body: some View {
    let overview = overview
    let attention = attentionItems
    AdaptivePage(title: "Status") {
      Button {
        refreshStatus()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh helper, extension and TUN diagnostics")

      Button {
        appModel.copyRuntimeDiagnostics()
      } label: {
        Label("Copy Diagnostics", systemImage: "doc.on.doc")
      }
      .help("Copy a redacted diagnostics report")

      moreMenu
    } content: {
      Form {
        Section {
          StatusOverviewRow(overview: overview)
          LabeledContent("Mode", value: appModel.proxyRoutingMode.displayName)
          LabeledContent("Profile", value: appModel.profileStore.activeProfile?.name ?? String(localized: "None"))
          LabeledContent("Core", value: coreText)
          LabeledContent("Run Mode", value: appModel.currentRuntimeOverrides.mode.displayName)
        }

        // Only present while something is actually wrong: the overview row above already says the
        // runtime is healthy, so an "all clear" group would repeat it. Every real problem still lands
        // here, each once, with its recovery next to it.
        if !attention.isEmpty {
          Section("Attention") {
            ForEach(attention) { item in
              attentionRow(item)
            }
          }
        }

        section(.runtime, title: "Runtime") {
          runtimeRows
        }
        section(.dns, title: "DNS") {
          dnsRows
        }
        section(.ruleOverlay, title: "Rule Overlay") {
          ruleOverlayRows
        }
        section(.helper, title: "Helper") {
          helperRows
        }
        if showsTunDiagnostics {
          section(.tun, title: "TUN Diagnostics") {
            tunRows
          }
        }
        if showsNetworkExtensionDiagnostics {
          section(.networkExtension, title: "NE Diagnostics") {
            networkExtensionRows
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: 1_080)
      .frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      appModel.refreshHelperRegistrationStatus()
      guard !hasResolvedDefaultExpansion else { return }
      hasResolvedDefaultExpansion = true
      expandedSections = StatusDetailSection.defaultExpanded(
        routingMode: appModel.proxyRoutingMode,
        helperHasIssue: helperHasIssue,
        tunHasIssue: appModel.tunDiagnostics.overallStatus == .warn || appModel.tunDiagnostics.overallStatus == .fail,
        networkExtensionHasIssue: !appModel.networkExtensionController.diagnostics.recentErrors.isEmpty
          || appModel.networkExtensionSystemDNSState.errorMessage != nil
      )
    }
  }

  // MARK: - Actions

  private var moreMenu: some View {
    Menu {
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

      Divider()

      Button("Repair Helper") {
        appModel.repairHelperRegistration()
      }
      Button("Open Helper Approval Settings") {
        appModel.openHelperApprovalSettings()
      }

      if showsTunDiagnostics {
        Divider()
        Button("Refresh TUN Diagnostics") {
          appModel.refreshTunDiagnostics()
        }
        Button("Repair TUN System DNS") {
          appModel.repairTunDNS()
        }
        .disabled(!appModel.canRepairTunDNS)
        Button("Repair TUN Routing") {
          appModel.repairTunRouting()
        }
        .disabled(!appModel.canRepairTunRouting)
      }

      if appModel.hasResidualSystemProxy {
        Divider()
        Button("Disable Residual System Proxy") {
          appModel.disableResidualSystemProxy()
        }
        .disabled(!appModel.canDisableResidualSystemProxy)
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("Logs and repair actions")
  }

  private func refreshStatus() {
    appModel.refreshHelperStatus()
    appModel.refreshHelperRegistrationStatus()
    appModel.refreshNetworkExtensionStatus()
    appModel.refreshTunDiagnostics()
    if appModel.isCoreRunning {
      appModel.reloadRuntimeData()
    }
  }

  private func perform(_ action: StatusAttentionItem.Action) {
    switch action {
    case .repairHelper:
      appModel.repairHelperRegistration()
    case .openHelperSettings:
      appModel.openHelperApprovalSettings()
    case .repairTunDNS:
      appModel.repairTunDNS()
    case .repairTunRouting:
      appModel.repairTunRouting()
    case .disableResidualSystemProxy:
      appModel.disableResidualSystemProxy()
    case let .showSection(section):
      expandedSections.insert(section)
    }
  }

  // MARK: - Overview and attention

  private var overview: StatusOverview {
    StatusOverview(
      isRunning: appModel.isRunning,
      previewRuntimeActive: appModel.previewRuntimeActive,
      coreStatus: appModel.coreController.status,
      isStarting: appModel.dashboardRuntimeState.isStarting,
      routingMode: appModel.proxyRoutingMode,
      systemProxyEnabled: appModel.systemProxyEnabled,
      tunEnabled: appModel.tunEnabled,
      networkExtensionEnabled: appModel.networkExtensionEnabled,
      readinessIssue: appModel.readinessIssue
    )
  }

  /// Every problem the page knows about, each exactly once and each with its recovery next to it.
  /// Folding a section never hides one of these.
  private var attentionItems: [StatusAttentionItem] {
    var items: [StatusAttentionItem] = []
    if let readinessIssue = appModel.readinessIssue {
      items.append(StatusAttentionItem(
        id: "readiness",
        title: String(localized: "Cannot start"),
        message: readinessIssue,
        isError: false,
        actions: []
      ))
    }
    items.append(contentsOf: diagnosticAttentionItems)
    // The generic last error comes after the specific items and only when it says something they
    // do not: a failed DNS repair, for instance, already stands there with its Repair button, so
    // repeating its text as "Last Error" would show the same problem twice.
    if let error = appModel.lastError,
       !StatusAttentionDeduplication.isRedundant(lastError: error, specificMessages: items.map(\.message))
    {
      items.append(StatusAttentionItem(
        id: "last-error",
        title: String(localized: "Last Error"),
        message: error,
        isError: true,
        actions: []
      ))
    }
    return items
  }

  private var diagnosticAttentionItems: [StatusAttentionItem] {
    var items: [StatusAttentionItem] = []
    if appModel.proxyRoutingMode == .tun || appModel.tunEnabled, helperHasIssue {
      items.append(StatusAttentionItem(
        id: "helper",
        title: String(localized: "TUN helper needs attention"),
        message: appModel.tunHelperStatusDetail.message,
        isError: false,
        actions: appModel.tunHelperStatusDetail.requiresApproval
          ? [.openHelperSettings, .repairHelper, .showSection(.helper)]
          : [.repairHelper, .showSection(.helper)]
      ))
    }
    if let dnsError = appModel.tunSystemDNSState.errorMessage {
      items.append(StatusAttentionItem(
        id: "tun-dns",
        title: String(localized: "TUN system DNS repair needed"),
        message: dnsError,
        isError: true,
        actions: appModel.canRepairTunDNS ? [.repairTunDNS] : [.showSection(.tun)]
      ))
    }
    if showsTunDiagnostics, let issue = appModel.tunDiagnostics.primaryIssue {
      items.append(StatusAttentionItem(
        id: "tun-\(issue.id)",
        title: issue.title,
        message: issue.detail ?? issue.message,
        isError: issue.status == .fail,
        actions: appModel.canRepairTunRouting ? [.repairTunRouting, .showSection(.tun)] : [.showSection(.tun)]
      ))
    }
    if let dnsError = appModel.networkExtensionSystemDNSState.errorMessage {
      items.append(StatusAttentionItem(
        id: "ne-dns",
        title: String(localized: "NE system DNS repair needed"),
        message: dnsError,
        isError: true,
        actions: [.showSection(.networkExtension)]
      ))
    }
    if appModel.hasResidualSystemProxy {
      items.append(StatusAttentionItem(
        id: "residual-proxy",
        title: String(localized: "System Proxy still points at a stale port"),
        message: String(localized: "macOS still has a System Proxy configured for a ClashMax port that is not the current one."),
        isError: false,
        actions: appModel.canDisableResidualSystemProxy ? [.disableResidualSystemProxy] : []
      ))
    }
    return items
  }

  private var helperHasIssue: Bool {
    let detail = appModel.tunHelperStatusDetail
    return detail.requiresApproval || detail.migrationRequired || detail.fingerprintMatches == false
      || (detail.registered && !detail.xpcReachable) || detail.serviceStatus == .notFound
  }

  private func attentionRow(_ item: StatusAttentionItem) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(item.title)
          .fontWeight(.medium)
      } icon: {
        Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(item.isError ? Color.red : Color.orange)
      }
      Text(item.message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if !item.actions.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
            Button(action.title) {
              perform(action)
            }
          }
        }
        .controlSize(.small)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
  }

  // MARK: - Sections

  private func section<Content: View>(
    _ section: StatusDetailSection,
    title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Section(isExpanded: expansionBinding(section)) {
      content()
    } header: {
      Text(title)
    }
  }

  private func expansionBinding(_ section: StatusDetailSection) -> Binding<Bool> {
    Binding(
      get: { expandedSections.contains(section) },
      set: { isExpanded in
        if isExpanded {
          expandedSections.insert(section)
        } else {
          expandedSections.remove(section)
        }
      }
    )
  }

  @ViewBuilder
  private var runtimeRows: some View {
    let overrides = appModel.currentRuntimeOverrides
    LabeledContent("State", value: localizedRuntimeText(appModel.statusSummary))
    LabeledContent("Controller", value: "\(overrides.externalControllerHost):\(overrides.externalControllerPort)")
    LabeledContent("Controller Secret", value: RuntimeDiagnosticsReport.redactedSecret)
    LabeledContent("Mixed Port", value: "\(overrides.mixedPort)")
    LabeledContent("System Proxy", value: onOff(appModel.systemProxyEnabled))
    LabeledContent("TUN", value: onOff(appModel.tunEnabled))
    LabeledContent("NE Proxy", value: onOff(appModel.networkExtensionEnabled))
    LabeledContent("Logs") {
      HStack(spacing: 10) {
        Text(String.localizedStringWithFormat(NSLocalizedString("%lld retained", comment: ""), Int64(runtimeData.logs.count)))
          .foregroundStyle(.secondary)
        Button("Open Logs") {
          appModel.openRuntimeLogs()
        }
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private var dnsRows: some View {
    let tun = appModel.currentRuntimeOverrides.tunSettings
    LabeledContent("Routing", value: appModel.proxyRoutingMode.displayName)
    LabeledContent("TUN DNS Mode", value: tun.dnsFakeIPEnabled ? String(localized: "Fake IP") : String(localized: "Profile"))
    LabeledContent("TUN System DNS", value: tun.systemDNSOverrideEnabled ? appModel.tunSystemDNSState.displayName : String(localized: "Off"))
    LabeledContent("DNS Hijack", value: tun.normalizedDNSHijack.joined(separator: ", "))
    LabeledContent("Fake IP Range", value: tun.dnsFakeIPEnabled ? tun.normalizedFakeIPRange : String(localized: "Off"))
    LabeledContent("Nameserver", value: summarized(tun.dns.nameserver))
    LabeledContent("Fallback", value: summarized(tun.dns.fallback))
    LabeledContent("NE System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
  }

  @ViewBuilder
  private var ruleOverlayRows: some View {
    let overlay = appModel.ruleOverlaySettings
    LabeledContent("Status", value: overlay.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
    LabeledContent("Before", value: "\(overlay.prependRules.count)")
    LabeledContent("After", value: "\(overlay.appendRules.count)")
    LabeledContent("Disabled", value: "\(overlay.disabledRuleMatchers.count)")
    LabeledContent("Runtime Source", value: String(localized: "Generated runtime YAML"))
    LabeledContent("Profile YAML", value: String(localized: "Unchanged"))
    if let validationError = overlay.validationError {
      LabeledContent("Validation") {
        Text(validationError)
          .foregroundStyle(.red)
      }
    }
    ForEach(Array((overlay.prependRules + overlay.appendRules).prefix(4))) { rule in
      LabeledContent(rule.kind.displayName) {
        Text(rule.runtimeRule)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    ForEach(Array(overlay.disabledRuleMatchers.prefix(4))) { matcher in
      LabeledContent(String(format: String(localized: "Disable %@"), matcher.mode.displayName)) {
        Text(matcher.normalizedPattern)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  @ViewBuilder
  private var helperRows: some View {
    let detail = appModel.tunHelperStatusDetail
    LabeledContent("Registered", value: yesNo(detail.registered))
    LabeledContent("Approval", value: detail.requiresApproval ? String(localized: "Required") : String(localized: "Clear"))
    LabeledContent("XPC", value: detail.xpcReachable ? String(localized: "Reachable") : String(localized: "Unreachable"))
    LabeledContent("Running", value: runningText(detail))
    LabeledContent("Service", value: detail.serviceStatus.displayName)
    LabeledContent("Fingerprint", value: fingerprintText(detail))
    LabeledContent("Protocol", value: protocolText(detail))
    LabeledContent("Helper Build", value: detail.helperBuildVersion ?? String(localized: "Unknown"))
    LabeledContent("Launchctl", value: latestLaunchctlStatus)
    LabeledContent("Last Exit", value: latestExitSummary ?? String(localized: "Unknown"))
    LabeledContent("Message") {
      Text(detail.message)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
    HStack(spacing: 8) {
      Button("Repair Helper") {
        appModel.repairHelperRegistration()
      }
      Button("Open Helper Approval Settings") {
        appModel.openHelperApprovalSettings()
      }
    }
    .controlSize(.small)
  }

  @ViewBuilder
  private var tunRows: some View {
    let tun = appModel.currentRuntimeOverrides.tunSettings
    let diagnostics = appModel.tunDiagnostics
    LabeledContent("Helper", value: helperPIDText)
    LabeledContent("Stack", value: tun.stack.displayName)
    LabeledContent("Checks", value: diagnosticCounterText(diagnostics))
    LabeledContent("Device", value: tun.normalizedDevice)
    LabeledContent("Last Check", value: diagnostics.updatedAt == Date.distantPast
      ? String(localized: "Waiting")
      : diagnostics.updatedAt.formatted(date: .omitted, time: .standard))
    if appModel.developerMode, let helperLog = appModel.helperLogs.last {
      LabeledContent("Helper Log") {
        Text(helperLog)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(2)
          .truncationMode(.middle)
      }
    }
    ForEach(Array(diagnostics.checks.prefix(appModel.developerMode ? 8 : 4))) { check in
      StatusTunDiagnosticCheckRow(check: check)
    }
    HStack(spacing: 8) {
      Button("Refresh TUN Diagnostics") {
        appModel.refreshTunDiagnostics()
      }
      Button("Repair TUN System DNS") {
        appModel.repairTunDNS()
      }
      .disabled(!appModel.canRepairTunDNS)
      Button("Repair TUN Routing") {
        appModel.repairTunRouting()
      }
      .disabled(!appModel.canRepairTunRouting)
    }
    .controlSize(.small)
  }

  @ViewBuilder
  private var networkExtensionRows: some View {
    let diagnostics = appModel.networkExtensionController.diagnostics
    let routing = appModel.networkExtensionRoutingSettings
    LabeledContent("TCP", value: "\(diagnostics.activeTCPBridgeCount)")
    LabeledContent("UDP", value: "\(diagnostics.activeUDPBridgeCount)")
    LabeledContent("DNS", value: "\(diagnostics.dnsCaptureCount)")
    LabeledContent("SOCKS Fail") {
      Text("\(diagnostics.socksHandshakeFailureCount)")
        .foregroundStyle(diagnostics.socksHandshakeFailureCount > 0 ? Color.red : Color.primary)
    }
    LabeledContent("Excluded CIDR", value: "\(routing.effectiveRouteExcludeCIDRs.count)")
    LabeledContent("DNS Runtime", value: routing.dnsFakeIPEnabled ? String(localized: "Fake IP") : String(localized: "Profile default"))
    LabeledContent("DNS Capture", value: routing.dnsCaptureEnabled ? "127.0.0.1:\(routing.normalizedDNSListenPort)" : String(localized: "Off"))
    LabeledContent("System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
    LabeledContent("Last Update", value: diagnostics.updatedAt == Date.distantPast
      ? String(localized: "Waiting")
      : diagnostics.updatedAt.formatted(date: .omitted, time: .standard))
    if let event = diagnostics.recentBypasses.last {
      LabeledContent("Last Bypass", value: eventSummary(event))
    }
    if let event = diagnostics.recentErrors.last {
      LabeledContent("Last Error") {
        Text(eventSummary(event))
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - Facts

  private var showsTunDiagnostics: Bool {
    appModel.proxyRoutingMode == .tun || appModel.tunEnabled || appModel.tunnelCoreRunning
  }

  private var showsNetworkExtensionDiagnostics: Bool {
    appModel.proxyRoutingMode == .neProxy || appModel.networkExtensionController.vpnStatus.isActive
  }

  /// In TUN mode the helper owns the core process, so `coreController` reports stopped while the
  /// tunnel is up; naming the owner keeps the row from contradicting the headline.
  private var coreText: String {
    if appModel.tunnelCoreRunning {
      return String(localized: "Running via helper")
    }
    if appModel.previewRuntimeActive {
      return String(localized: "Preview")
    }
    return appModel.coreController.status.displayName
  }

  private func onOff(_ value: Bool) -> String {
    value ? String(localized: "On") : String(localized: "Off")
  }

  private func yesNo(_ value: Bool) -> String {
    value ? String(localized: "Yes") : String(localized: "No")
  }

  private func summarized(_ values: [String]) -> String {
    values.isEmpty ? String(localized: "Profile") : values.prefix(3).joined(separator: ", ")
  }

  private func runningText(_ detail: TunnelHelperStatusDetail) -> String {
    if let pid = detail.pid {
      return "PID \(pid)"
    }
    return yesNo(detail.running)
  }

  private func fingerprintText(_ detail: TunnelHelperStatusDetail) -> String {
    guard detail.fingerprintRecorded else {
      return String(localized: "Not Recorded")
    }
    switch detail.fingerprintMatches {
    case true:
      return String(localized: "Match")
    case false:
      return String(localized: "Mismatch")
    case nil:
      return String(localized: "Unknown")
    }
  }

  private func protocolText(_ detail: TunnelHelperStatusDetail) -> String {
    guard let version = detail.protocolVersion else {
      return detail.migrationRequired ? String(localized: "Missing") : String(localized: "Unknown")
    }
    return detail.migrationRequired ? String(format: String(localized: "v%lld Needs Repair"), Int64(version)) : "v\(version)"
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
    } ?? String(localized: "Unknown")
  }

  private var helperPIDText: String {
    guard let pid = appModel.tunHelperPID else {
      return appModel.tunEnabled ? String(localized: "Running") : String(localized: "Ready")
    }
    return "#\(pid)"
  }

  private func diagnosticCounterText(_ diagnostics: TunDiagnosticsSnapshot) -> String {
    guard !diagnostics.checks.isEmpty else { return String(localized: "Waiting") }
    let base = "\(diagnostics.passCount)/\(diagnostics.warnCount)/\(diagnostics.failCount)"
    // Only widen the value when something was actually downgraded, so the segments always
    // account for every listed check.
    return diagnostics.infoCount > 0 ? "\(base)/\(diagnostics.infoCount)" : base
  }

  private func eventSummary(_ event: NetworkExtensionDiagnosticEvent) -> String {
    let context = [
      event.flowProtocol?.displayName,
      event.remoteEndpoint,
      event.sourceAppSigningIdentifier,
    ]
    .compactMap(\.self)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    return context.isEmpty ? event.message : context
  }
}

private struct StatusOverviewRow: View {
  let overview: StatusOverview

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: overview.systemImage)
        .font(.title2)
        .foregroundStyle(tint)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(overview.headline)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        Text(overview.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    switch overview.tone {
    case .running: .green
    case .attention: .orange
    case .failure: .red
    case .idle: .secondary
    }
  }
}

private struct StatusTunDiagnosticCheckRow: View {
  let check: TunDiagnosticCheck

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text(check.status.displayName)
          .foregroundStyle(tint)
        Text(check.detail ?? check.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .lineLimit(3)
      }
    } label: {
      Label {
        Text(check.title)
      } icon: {
        Image(systemName: symbolName)
          .foregroundStyle(tint)
      }
    }
  }

  private var symbolName: String {
    switch check.status {
    case .pass:
      return "checkmark.circle.fill"
    case .warn:
      return "exclamationmark.triangle.fill"
    case .fail:
      return "xmark.octagon.fill"
    case .info:
      return "info.circle.fill"
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
    case .info:
      return .blue
    case .skipped:
      return .secondary
    }
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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData

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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData

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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData

  var body: some View {
    let visibleLogs = runtimeData.visibleLogs(
      developerMode: appModel.developerMode,
      logLevel: appModel.selectedLogLevel
    )

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
                .foregroundStyle(LogLevelStyle.color(for: entry.level))
                .frame(width: 56, alignment: .leading)
              Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.message)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
    .dashboardCard()
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
