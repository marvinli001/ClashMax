import Pow
import SwiftUI

struct RunningDashboardView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var selectedProxyGroupName: String?
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat

  var body: some View {
    VStack(spacing: 12) {
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
          selectedGroupName: $selectedProxyGroupName
        )
      } trailing: {
        PublicIPInfoCard(availableWidth: runtimeInfoCardWidth)
      }
      .staggeredArrival(index: 0, reduceMotion: reduceMotion, trigger: state)

      LazyVGrid(columns: metricColumns, spacing: DashboardLayoutMetrics.dashboardGridSpacing) {
        DashboardMetricTile(
          title: "Download",
          value: TrafficSample.format(appModel.trafficSample.download),
          footnote: trafficFootnote,
          symbolName: "arrow.down",
          tint: .cyan
        )
        DashboardMetricTile(
          title: "Upload",
          value: TrafficSample.format(appModel.trafficSample.upload),
          footnote: trafficFootnote,
          symbolName: "arrow.up",
          tint: .indigo
        )
        DashboardMetricTile(
          title: "Connections",
          value: "\(appModel.connections.count)",
          footnote: appModel.connections.isEmpty ? "Waiting for runtime data" : "Live stream",
          symbolName: "network",
          tint: .orange
        )
        DashboardMetricTile(
          title: "Rules",
          value: "\(appModel.rules.count)",
          footnote: appModel.rules.isEmpty ? "Waiting for runtime data" : "Loaded rules",
          symbolName: "list.bullet.rectangle",
          tint: .green
        )
      }
      .staggeredArrival(index: 2, reduceMotion: reduceMotion, trigger: state)

      DashboardResponsivePair(availableWidth: availableWidth) {
        RunningStatusCard()
      } trailing: {
        NetworkStatusCard()
      }
      .staggeredArrival(index: 3, reduceMotion: reduceMotion, trigger: state)

      DashboardResponsivePair(availableWidth: availableWidth) {
        TrafficRuntimeCard(samples: chartSamples)
      } trailing: {
        ProxyGroupsRuntimeCard()
      }
      .staggeredArrival(index: 4, reduceMotion: reduceMotion, trigger: state)

      DashboardResponsivePair(availableWidth: availableWidth) {
        ConnectionsRulesRuntimeCard()
      } trailing: {
        RecentLogsRuntimeCard()
      }
      .staggeredArrival(index: 5, reduceMotion: reduceMotion, trigger: state)
    }
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
    appModel.trafficHistory.isEmpty ? "Waiting for runtime data" : "Live traffic"
  }

  private var runtimeInfoCardWidth: CGFloat {
    if availableWidth >= DashboardLayoutMetrics.runningPairColumnsBreakpoint {
      return max(0, (availableWidth - DashboardLayoutMetrics.dashboardGridSpacing) / 2)
    }
    return availableWidth
  }

  private var chartSamples: [TrafficSample] {
    appModel.trafficHistory.isEmpty ? [.zero, .zero, .zero, .zero, .zero, .zero] : appModel.trafficHistory
  }
}

private struct RunningHeaderCard: View {
  @EnvironmentObject private var appModel: AppModel
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat

  var body: some View {
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
      value: appModel.overrides.mode.displayName,
      symbolName: "switch.2",
      tint: .purple
    )
    .matchedGeometryEffect(id: "mode-control", in: namespace)

    DashboardStatusPill(
      title: "Controller",
      value: "\(appModel.overrides.externalControllerHost):\(appModel.overrides.externalControllerPort)",
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
          tint: appModel.systemProxyEnabled || appModel.tunEnabled ? .green : .secondary
        )
      }
    }
  }

  private var statusTitle: String {
    state.isStarting ? "Starting Runtime" : appModel.statusSummary
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
    groups.filter { !$0.nodes.filter(\.isSelectable).isEmpty }
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
    if let selected = group.selected,
       let node = group.nodes.first(where: { $0.name == selected }) {
      return node
    }
    return group.nodes.first(where: \.isSelectable)
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
  @Binding var selectedGroupName: String?

  var body: some View {
    let groups = DashboardProxySelectionState.selectableGroups(from: appModel.proxyGroups)
    let group = DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: selectedGroupName)
    let node = group.flatMap(DashboardProxySelectionState.currentNode)
    let compact = availableWidth < 700

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

        if compact {
          VStack(alignment: .leading, spacing: 10) {
            groupControl(groups: groups)
            nodeControl(group: group)
          }
        } else {
          HStack(alignment: .bottom, spacing: 12) {
            groupControl(groups: groups)
            nodeControl(group: group)
          }
        }
      } else {
        DashboardEmptyRuntimeView(
          title: state.isStarting ? "Waiting for runtime data" : "No selectable proxy groups",
          symbolName: state.isStarting ? "hourglass" : "point.3.connected.trianglepath.dotted",
          message: state.isStarting
            ? "Node selection becomes available after the controller is ready."
            : "Refresh runtime data or check the active profile's proxy-groups."
        )
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: availableWidth < 460 ? 190 : 210, alignment: .topLeading)
    .dashboardCard(interactive: true)
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
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
    }
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

        Button {
          guard let node = DashboardProxySelectionState.currentNode(in: group) else { return }
          appModel.testDelay(for: node)
        } label: {
          Image(systemName: "speedometer")
        }
        .buttonStyle(.borderless)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DashboardSectionHeader(title: "Running Status", symbolName: "desktopcomputer")

      TimelineView(.periodic(from: Date(), by: 1)) { context in
        HStack(spacing: 10) {
          RuntimeStat(title: "Uptime", value: dashboardDurationString(from: appModel.sessionStartedAt, now: context.date), tint: .cyan)
          RuntimeStat(title: "Connections", value: "\(appModel.connections.count)", tint: .orange)
          RuntimeStat(title: "Memory", value: "Runtime", tint: .green)
        }
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(title: "Core", value: appModel.statusSummary)
      RuntimeLine(title: "Profile", value: appModel.profileStore.activeProfile?.name ?? "None")
      RuntimeLine(title: "Mixed Port", value: "\(appModel.overrides.mixedPort)")
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
        RuntimeStat(title: "Mode", value: appModel.overrides.mode.displayName, tint: .purple)
        RuntimeStat(title: "LAN", value: appModel.overrides.allowLan ? "On" : "Off", tint: .orange)
      }

      Divider()
        .opacity(0.24)

      RuntimeLine(title: "Controller", value: "\(appModel.overrides.externalControllerHost):\(appModel.overrides.externalControllerPort)")
      RuntimeLine(title: "Proxy", value: proxyRoutingDetail)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
    .dashboardCard()
  }

  private var proxyRoutingDetail: String {
    switch appModel.proxyRoutingMode {
    case .systemProxy:
      appModel.systemProxyEnabled ? "System Proxy 127.0.0.1:\(appModel.overrides.mixedPort)" : "System Proxy ready"
    case .tun:
      appModel.tunEnabled ? "TUN helper controlled" : "TUN ready"
    }
  }
}

private struct TrafficRuntimeCard: View {
  let samples: [TrafficSample]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Traffic", symbolName: "waveform.path.ecg")

      DashboardTrafficSparkline(samples: samples)
        .frame(height: 178)

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

      if appModel.proxyGroups.isEmpty {
        DashboardEmptyRuntimeView(title: "Waiting for runtime data", symbolName: "hourglass")
      } else {
        VStack(spacing: 8) {
          ForEach(Array(appModel.proxyGroups.prefix(6))) { group in
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Connections", symbolName: "network", trailing: "\(appModel.rules.count) rules")

      if appModel.connections.isEmpty {
        DashboardEmptyRuntimeView(title: "Waiting for runtime data", symbolName: "network.slash")
      } else {
        VStack(spacing: 8) {
          ForEach(Array(appModel.connections.prefix(6))) { connection in
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

  var body: some View {
    let visibleLogs = appModel.userVisibleLogs

    VStack(alignment: .leading, spacing: 12) {
      DashboardSectionHeader(title: "Recent Logs", symbolName: "terminal", trailing: "\(visibleLogs.count)")

      if visibleLogs.isEmpty {
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
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct RuntimeLine: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .font(.callout)
  }
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
