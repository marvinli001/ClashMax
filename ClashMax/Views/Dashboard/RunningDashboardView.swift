import SwiftUI

struct RunningDashboardView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  let currentNodeCoordinator: ProxySearchCoordinator
  let state: DashboardRuntimeState
  let availableWidth: CGFloat
  @State private var selectedProxyGroupName: String?
  @State private var metricsVisible = true

  var body: some View {
    let groups = currentNodeCoordinator.snapshot.unfilteredGroups
    let group = DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: selectedProxyGroupName)
    let node = group.flatMap(DashboardProxySelectionState.currentNode)
    let loading = state.usesOperationalLayout && groups.isEmpty
      && (state.isStarting || appModel.runtimeDataLoading || (!currentNodeCoordinator.snapshot.hasResolved && !appModel.visibleProxyGroups.isEmpty))
    let compact = availableWidth < DashboardLayoutMetrics.runningPairColumnsBreakpoint
    let entrance = state.isStarting || appModel.sessionStartedAt.map { Date().timeIntervalSince($0) < 3 } == true

    VStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
      HomeHeroCard(state: state, compact: compact, groups: groups, group: group, node: node,
                   isLoading: loading, selectedGroupName: $selectedProxyGroupName)
        .modifier(RuntimeContentEntrance(delay: 0, isEnabled: entrance))

      if case let .crashed(message) = state {
        HStack(alignment: .top, spacing: 12) {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button(String(localized: "Show Logs")) { appModel.selectedSection = .logs }
          Button(String(localized: "Status")) { appModel.selectedSection = .status }
        }
        .font(.callout)
        .padding(HomeMetrics.cardPadding)
        .homeCard()
      }

      HomeControlCard(state: state, compact: compact)
        .modifier(RuntimeContentEntrance(delay: 0.04, isEnabled: entrance))

      if appModel.proxyRoutingMode == .tun {
        TunDiagnosticsAttentionRow(availableWidth: availableWidth)
      }
      if appModel.proxyRoutingMode == .neProxy {
        NetworkExtensionAttentionRow(availableWidth: availableWidth)
      }

      if appModel.profileStore.activeProfile != nil {
        HomeMetricGrid(compact: compact, live: state.usesOperationalLayout)
          .modifier(RuntimeContentEntrance(delay: 0.08, isEnabled: entrance))
          .onScrollVisibilityChange(threshold: 0.1) { metricsVisible = $0 }

        if state.usesOperationalLayout {
          Group {
            if groups.isEmpty, !loading {
              TrafficRuntimeCard(showRates: !metricsVisible, starting: state.isStarting)
            } else {
              DashboardResponsivePair(availableWidth: availableWidth) {
                TrafficRuntimeCard(showRates: !metricsVisible, starting: state.isStarting)
              } trailing: {
                ProxyGroupsRuntimeCard(groups: groups, trackedGroup: group?.name)
              }
            }
          }
          .modifier(RuntimeContentEntrance(delay: 0.12, isEnabled: entrance))

          HomeDestinationsCard(compact: compact)
            .modifier(RuntimeContentEntrance(delay: 0.16, isEnabled: entrance))
        }
      }
    }
    .task {
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .initial)
    }
    .onChange(of: appModel.proxyPageSettings.sortOrder) { _, _ in
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .sort)
    }
    .onChange(of: ProxySearchInputSignature(groups: appModel.visibleProxyGroups, providers: runtimeData.proxyProviders)) { _, _ in
      currentNodeCoordinator.submit(appModel.proxySearchInput(searchText: ""), reason: .data)
    }
  }
}

private struct HomeHeroCard: View {
  @Environment(AppModel.self) private var appModel
  let state: DashboardRuntimeState
  let compact: Bool
  let groups: [ProxyGroup]
  let group: ProxyGroup?
  let node: ProxyNode?
  let isLoading: Bool
  @Binding var selectedGroupName: String?
  @State private var addingSubscription = false

  var body: some View {
    let hasProfile = appModel.profileStore.activeProfile != nil
    let missing = group.map(DashboardProxySelectionState.hasMissingSelection) ?? false
    let probe = DashboardProxySelectionState.automaticDelayProbeKey(
      sessionStartedAt: appModel.sessionStartedAt, isRunning: state.isRunning,
      canControlRuntimeProxies: appModel.canControlRuntimeProxies, group: group, node: node
    )
    VStack(alignment: .leading, spacing: compact ? 8 : 12) {
      HStack(spacing: 10) {
        statusChip
        if !appModel.profileStore.profiles.isEmpty { profileMenu }
        Spacer(minLength: 4)
        runtimeMenu
      }
      if hasProfile {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
          : AnyLayout(HStackLayout(alignment: .center, spacing: 24))
        layout {
          VStack(alignment: .leading, spacing: 8) {
            nodeContent(missing: missing)
            if let failure = appModel.activeStartValidationFailure {
              recovery(message: failure, section: .profiles)
            } else if case let .blocked(reason) = state {
              recovery(message: localizedRuntimeText(reason), section: .status)
            } else if appModel.previewRuntimeActive {
              Text("Preview runtime is active. System traffic is not captured.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          HomeExitWell(compact: compact, running: state.isRunning, currentGroup: group, currentNode: node, hasMissingSelection: missing)
            .frame(minWidth: 220, maxWidth: compact ? .infinity : 320)
        }
      } else {
        Text("Add a profile to start ClashMax.")
          .font(.system(size: 24, weight: .semibold))
        HStack {
          Button(String(localized: "Import YAML…")) { appModel.importLocalProfile() }
          Button(String(localized: "Add Subscription…")) { addingSubscription = true }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(HomeMetrics.heroPadding)
    .homeCard()
    .task(id: probe) {
      guard probe != nil, let group, let node, node.resolvedDelayState != .testing else { return }
      appModel.testDelay(in: group, for: node)
    }
    .sheet(isPresented: $addingSubscription) {
      AddSubscriptionSheet(onCancel: { addingSubscription = false }, onAdded: { addingSubscription = false })
    }
  }

  @ViewBuilder private var statusChip: some View {
    if appModel.profileStore.activeProfile == nil {
      HomeChip(text: String(localized: "No Profile"), dot: true)
    } else if appModel.activeStartValidationFailure != nil, !state.isStarting {
      HomeChip(text: String(localized: "Validation failed"), tone: .red, dot: true)
    } else {
      switch state {
      case .running: HomeChip(text: String(localized: "Running"), tone: .green, dot: true)
      case .starting: HomeChip(text: String(localized: "Starting"), busy: true)
      case .crashed: HomeChip(text: String(localized: "Crashed"), tone: .red, dot: true)
      case .blocked: HomeChip(text: String(localized: "Unable to start"), tone: .orange, dot: true)
      case .stopped where appModel.previewRuntimeActive: HomeChip(text: String(localized: "Preview runtime"), dot: true)
      case .stopped: HomeChip(text: String(localized: "Stopped"), dot: true)
      }
    }
  }

  @ViewBuilder private func nodeContent(missing: Bool) -> some View {
    if let group, missing {
      let message = selectionUnavailableMessage(group: group)
      Text("Selected node unavailable").font(.system(size: 24, weight: .semibold))
      HStack {
        groupMenu(group)
        HomeChip(text: String(localized: "Unavailable"), symbol: "exclamationmark.triangle", tone: .orange)
        Button(String(localized: "Refresh")) {
          if appModel.canControlRuntimeProxies { appModel.reloadRuntimeData() }
          else { _ = appModel.profileCoordinator.refreshPreview() }
        }
      }
      Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else if let group, let node {
      DashboardNodePickerButton(group: group, currentNode: node, hero: true)
      HStack(spacing: 6) {
        groupMenu(group)
        HomeChip(text: DashboardProxySelectionState.typeLabel(for: node))
        Button { appModel.testDelay(in: group, for: node) } label: {
          DashboardDelayBadge(state: node.resolvedDelayState, showsSymbol: true)
        }
        .buttonStyle(.plain)
        .disabled(!appModel.canControlRuntimeProxies || !node.supportsDelayTesting || node.resolvedDelayState == .testing)
        .help(nodeDelayTestHelp(node: node))
      }
    } else if isLoading {
      ClashMaxCurrentNodeSkeleton(isCompact: compact)
    } else {
      Text("This profile has no switchable proxy groups.").font(.headline)
      Button(String(localized: "Profiles")) { appModel.selectedSection = .profiles }
    }
  }

  private func recovery(message: String, section: AppSection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button(section == .profiles ? String(localized: "Profiles") : String(localized: "Show in Status")) {
        appModel.selectedSection = section
      }
      .buttonStyle(.link)
    }
  }

  private var profileMenu: some View {
    let profiles = appModel.profileStore.profiles
    let name = appModel.profileStore.activeProfile?.name ?? String(localized: "No Profile")
    return PopUpSelectionButton(
      selection: appModel.profileStore.activeProfileID,
      items: { profiles.map { PopUpSelectionItem(value: $0.id, title: $0.name) } },
      onSelect: { id in
        if let profile = profiles.first(where: { $0.id == id }) { appModel.selectProfile(profile) }
      }
    ) {
      HStack(spacing: 5) {
        Text(name).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
      }
      .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
      .frame(maxWidth: 360, alignment: .leading)
    }
    .buttonStyle(.plain)
    .disabled(state.isStarting)
    .help(name)
    .accessibilityLabel("Profile")
    .accessibilityValue(name)
  }

  private var runtimeMenu: some View {
    Menu {
      Button("Check AI services") { appModel.aiServiceCheckRequest = AIServiceCheckRequest() }
        .disabled(!appModel.isRunning)
      Stepper(value: Binding(get: { appModel.overrides.mixedPort }, set: { appModel.setMixedPort($0) }), in: 1024...65535) {
        Text("Mixed Port: \(String(appModel.overrides.mixedPort))")
      }
      Divider()
      Button(String(localized: "Settings")) { appModel.selectedSection = .settings }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help("Runtime settings").accessibilityLabel("Runtime settings")
  }

  private func groupMenu(_ group: ProxyGroup) -> some View {
    PopUpSelectionButton(
      selection: group.name,
      items: { DashboardProxySelectionState.selectableGroups(from: groups).map { PopUpSelectionItem(value: $0.name, title: $0.name) } },
      onSelect: { selectedGroupName = $0 }
    ) {
      HomeChip(text: group.name, symbol: "square.stack.3d.up")
    }
    .buttonStyle(.plain)
    .help(group.name)
    .accessibilityLabel("Proxy Group").accessibilityValue(group.name)
  }

  private func selectionUnavailableMessage(group: ProxyGroup) -> String {
    guard let selected = group.selected, !selected.isEmpty else {
      return String(localized: "Refresh runtime data or check the active profile's proxy-groups.")
    }
    return String(format: String(localized: "\"%@\" isn't in the current runtime data for %@. Refresh runtime data, or check the profile/provider for a mismatch."),
                  selected, group.name)
  }

  private func nodeDelayTestHelp(node: ProxyNode) -> String {
    if !node.supportsDelayTesting { return String(localized: "Built-in outbounds have no connection to measure.") }
    if !appModel.canControlRuntimeProxies { return appModel.proxyRuntimeActionMessage }
    return String(localized: "Test current node delay")
  }
}

/// The resolved group, selected node and measured exit shown in the Home header.
struct DashboardHeaderRoute: Equatable {
  enum Exit: Equatable {
    /// No probe has run yet, or it failed with nothing to fall back on; the line leaves exit out.
    case unknown
    case checking
    case located(String)
  }

  let groupName: String?
  let nodeName: String?
  let exit: Exit

  init(group: ProxyGroup?, node: ProxyNode?, hasMissingSelection: Bool, exit: PublicIPInfoState) {
    groupName = group?.name
    // A missing selection is reported by the Current Node card; repeating a stale name here would
    // claim a route the core is not using.
    nodeName = hasMissingSelection ? nil : Self.trimmed(node?.name ?? group?.selected)
    self.exit = Self.exit(from: exit)
  }

  static func exit(from state: PublicIPInfoState) -> Exit {
    if let info = state.info, let place = location(of: info) { return .located(place) }
    return state.isLoading ? .checking : .unknown
  }

  /// "Tokyo, Japan", falling back to the country alone or its code.
  static func location(of info: PublicIPInfo) -> String? {
    let country = trimmed(info.countryName) ?? trimmed(info.countryCode)
    let city = trimmed(info.city)
    switch (city, country) {
    case let (city?, country?) where city != country: return "\(city), \(country)"
    case let (_, country?): return country
    case let (city?, nil): return city
    default: return nil
    }
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
}

private struct HomeControlCard: View {
  @Environment(AppModel.self) private var appModel
  let state: DashboardRuntimeState
  let compact: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 22) {
      if compact {
        VStack(alignment: .leading, spacing: 8) {
          HStack { captureLabel.frame(width: 94, alignment: .leading); capturePicker }
          HStack { modeLabel.frame(width: 94, alignment: .leading); modePicker }
        }
      } else {
        VStack(alignment: .leading, spacing: 7) { captureLabel; capturePicker }
        VStack(alignment: .leading, spacing: 7) { modeLabel; modePicker }
      }
      Spacer(minLength: 0)
      HomePowerButton(state: state)
    }
    .frame(maxHeight: .infinity, alignment: .center)
    .padding(HomeMetrics.cardPadding)
    .homeCard()
  }

  private var captureLabel: some View {
    Label("Traffic capture", systemImage: "network").font(.caption).foregroundStyle(.secondary)
  }

  private var modeLabel: some View {
    Label("Run mode", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
  }

  private var capturePicker: some View {
    HStack(spacing: 8) {
      // Every change still goes through `requestProxyRoutingMode`, which owns the confirmation and
      // the TUN helper guidance; the capsule only draws the choice.
      GlassSegmentedPicker(
        title: "Traffic capture",
        options: ProxyRoutingMode.allCases.map { .init(value: $0, title: $0.displayName, systemImage: $0.symbolName) },
        selection: appModel.proxyRoutingMode,
        onSelect: { appModel.requestProxyRoutingMode($0) }
      )
      ProxyRoutingSettingsButton()
    }
    .disabled(state.isStarting)
  }

  private var modePicker: some View {
    GlassSegmentedPicker(
      title: "Run mode",
      options: RunMode.allCases.map { .init(value: $0, title: $0.displayName) },
      selection: appModel.overrides.mode,
      onSelect: { appModel.requestMode($0) }
    )
    .disabled(state.isStarting)
  }
}

enum HomePowerState: Equatable {
  case start, stop, starting, restart, blocked

  init(state: DashboardRuntimeState, canStop: Bool, readinessIssue: String?) {
    if state.isStarting { self = .starting }
    else if canStop { self = .stop }
    else if readinessIssue != nil { self = .blocked }
    else if case .crashed = state { self = .restart }
    else { self = .start }
  }

  var title: LocalizedStringResource {
    switch self {
    case .start, .blocked: "Start"
    case .stop: "Stop"
    case .starting: "Starting…"
    case .restart: "Restart"
    }
  }

  var tint: Color {
    switch self {
    case .start, .starting: .accentColor
    case .stop: .green
    case .restart: .red
    case .blocked: .gray
    }
  }
}

private struct HomePowerButton: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false
  let state: DashboardRuntimeState

  var body: some View {
    let issue = appModel.readinessIssue.map(localizedRuntimeText)
    let power = HomePowerState(state: state, canStop: appModel.canStopRuntime, readinessIssue: issue)
    let action = power == .stop ? String(localized: "Stop ClashMax") : String(localized: "Start ClashMax")
    Button {
      appModel.canStopRuntime ? appModel.stop() : appModel.start()
    } label: {
      HStack(spacing: 10) {
        ZStack {
          if power == .stop {
            Circle().strokeBorder(.green.opacity(0.22), lineWidth: 3).frame(width: 44, height: 44)
          }
          core(power)
        }
        .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(power.title).font(.callout.weight(.semibold))
          if power == .stop {
            let start = appModel.sessionStartedAt
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(verbatim: dashboardDurationString(from: start, now: context.date))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          } else {
            let detail = power == .blocked ? shortReadinessIssue : appModel.profileStore.activeProfile?.name
            Text(detail ?? String(localized: "Ready"))
              .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle).help(power == .blocked ? issue ?? "" : detail ?? "")
          }
        }
        .frame(minWidth: 64, maxWidth: 112, alignment: .leading)
      }
      .padding(EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 16))
      .background { if hovered { Capsule().fill(.primary.opacity(0.035)) } }
      .homeWell(Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(HomePowerButtonStyle())
    .disabled(power == .starting || power == .blocked)
    .onHover { hovered = $0 }
    .help(power == .blocked ? issue ?? action : action)
    .accessibilityLabel(action)
    .accessibilityValue(power == .blocked ? issue ?? "" : String(localized: power.title))
  }

  private var shortReadinessIssue: String {
    if appModel.profileStore.activeProfile == nil { return String(localized: "No Profile") }
    if appModel.proxyRoutingMode == .tun, appModel.readinessIssue == appModel.tunHelperPreparationState.message {
      return String(localized: "TUN helper unavailable")
    }
    return String(localized: "No Core")
  }

  private func core(_ power: HomePowerState) -> some View {
    ZStack {
      if #available(macOS 26, *), !reduceTransparency {
        Circle().fill(power.tint)
          .glassEffect(.regular.tint(power.tint).interactive(), in: Circle())
      } else {
        Circle().fill(power.tint).shadow(color: power.tint.opacity(0.35), radius: 6, y: 2)
      }
      if power == .starting {
        ProgressView().controlSize(.small).tint(.white)
      } else {
        Image(systemName: power == .restart ? "arrow.clockwise" : "power")
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
          .symbolEffect(.bounce, options: .nonRepeating, value: !reduceMotion && power == .stop)
      }
    }
    .frame(width: 38, height: 38)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: power)
  }
}

private struct HomePowerButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
      .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.2), value: configuration.isPressed)
  }
}

struct DashboardRuntimeMetric: Identifiable, Equatable {
  enum Kind {
    case download, upload, connections, memory, runMode, mixedPort, proxyGroups, nodes
  }

  static let placeholder = "—"
  let kind: Kind
  let value: String
  var unit: String?
  var numericValue: Double?
  var detail: String?
  var id: Kind { kind }

  var title: LocalizedStringResource {
    switch kind {
    case .download: "Download"
    case .upload: "Upload"
    case .connections: "Connections"
    case .memory: "Core Memory"
    case .runMode: "Run mode"
    case .mixedPort: "Mixed Port"
    case .proxyGroups: "Proxy Groups"
    case .nodes: "Nodes"
    }
  }

  var symbolName: String {
    switch kind {
    case .download: "arrow.down"
    case .upload: "arrow.up"
    case .connections: "network"
    case .memory: "memorychip"
    case .runMode: "arrow.triangle.branch"
    case .mixedPort: "number"
    case .proxyGroups: "square.stack.3d.up"
    case .nodes: "server.rack"
    }
  }

  static func launchFacts(runMode: String, mixedPort: Int, groupCount: Int, nodeCount: Int, coreVersion: String?) -> [Self] {
    [
      Self(kind: .runMode, value: runMode),
      Self(kind: .mixedPort, value: String(mixedPort)),
      Self(kind: .proxyGroups, value: groupCount.formatted()),
      Self(kind: .nodes, value: nodeCount.formatted(), detail: coreVersion),
    ]
  }

  static func live(sample: TrafficSample?, totals: TrafficTotals?, connectionCount: Int, memory: CoreMemorySample, coreVersion: String) -> [Self] {
    func rate(_ kind: Kind, _ value: Int?, _ total: Int?) -> Self {
      let parts = value.map(HomeRateParts.split)
      return Self(kind: kind, value: parts?.number ?? placeholder, unit: parts?.unit,
                  numericValue: value.map(Double.init), detail: sessionTotal(total))
    }
    let resident = memory.hasReading ? HomeRateParts.bytes(memory.inUse) : nil
    return [
      rate(.download, sample?.download, totals?.download),
      rate(.upload, sample?.upload, totals?.upload),
      Self(kind: .connections, value: connectionCount.formatted(), numericValue: Double(connectionCount)),
      Self(kind: .memory, value: resident?.number ?? placeholder, unit: resident?.unit,
           numericValue: memory.hasReading ? Double(memory.inUse) : nil, detail: coreVersion),
    ]
  }

  /// Mihomo resets these counters on every core restart, including a change of capture mode.
  static func sessionTotal(_ bytes: Int?) -> String {
    let value = bytes.map(TrafficSample.formatBytes) ?? placeholder
    return String(format: String(localized: "This session %@"), value)
  }
}

private struct HomeMetricGrid: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  let compact: Bool
  let live: Bool
  private static let core = BundledCoreInfo().versionSummary

  var body: some View {
    let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: HomeMetrics.gridSpacing), count: compact ? 2 : 4)
    LazyVGrid(columns: columns, spacing: HomeMetrics.gridSpacing) {
      ForEach(metrics) { metric in
        HomeMetricCard(metric: metric, compact: compact, live: live)
      }
    }
  }

  private var metrics: [DashboardRuntimeMetric] {
    if live {
      return DashboardRuntimeMetric.live(
        sample: runtimeData.trafficHistory.isEmpty ? nil : runtimeData.trafficSample, totals: runtimeData.trafficTotals,
        connectionCount: runtimeData.connections.count, memory: runtimeData.memorySample, coreVersion: Self.core
      )
    }
    let groups = appModel.visibleProxyGroups
    let nodeCount = Set(groups.flatMap { $0.nodes.filter(\.isSelectable).map(\.name) }).count
    return DashboardRuntimeMetric.launchFacts(runMode: appModel.overrides.mode.displayName, mixedPort: appModel.overrides.mixedPort,
                                              groupCount: DashboardProxySelectionState.selectableGroups(from: groups).count,
                                              nodeCount: nodeCount, coreVersion: Self.core)
  }
}

private struct HomeMetricCard: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let metric: DashboardRuntimeMetric
  let compact: Bool
  let live: Bool
  @State private var hovered = false

  var body: some View {
    if metric.kind == .connections {
      Button { appModel.selectedSection = .connections } label: { card }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Connections")
    } else {
      card
    }
  }

  private var card: some View {
    let direction: KeyPath<TrafficSample, Int>? = switch metric.kind {
    case .download: \.download
    case .upload: \.upload
    default: nil
    }
    let color: Color = switch metric.kind {
    case .download: TrafficSeriesColor.download
    case .upload: TrafficSeriesColor.upload
    default: .secondary
    }
    let history = direction.map { key in runtimeData.trafficHistory.map { $0[keyPath: key] } } ?? []
    // Every live card shares one skeleton — label, number, one caption, then a 34 pt band at the
    // bottom — so the four numbers and captions sit on the same lines across the row and no card
    // ends in dead space. Launch facts have no band and centre their text in the card instead.
    return VStack(alignment: .leading, spacing: 0) {
      if !live { Spacer(minLength: 0) }
      VStack(alignment: .leading, spacing: compact ? 2 : 4) {
        HStack(spacing: 4) {
          Image(systemName: metric.symbolName).foregroundStyle(color)
          Text(metric.title).lineLimit(1)
          Spacer(minLength: 2)
          if let peak = history.max() {
            let caption = String(format: String(localized: "Peak %@"), TrafficSample.format(peak))
            Text(caption).font(.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8).help(caption)
          } else if metric.kind == .connections {
            Image(systemName: "chevron.right").font(.caption2).opacity(hovered ? 1 : 0)
          }
        }
        .font(.callout).foregroundStyle(.secondary)

        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(metric.value)
            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
            .contentTransition(reduceMotion ? .identity : .numericText(value: metric.numericValue ?? 0))
            .lineLimit(1).minimumScaleFactor(0.75)
          if let unit = metric.unit {
            Text(verbatim: unit).font(.callout).foregroundStyle(.secondary)
          }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: metric.numericValue)

        if let caption {
          Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.85).help(caption)
        }
      }
      .padding(.top, live ? (compact ? 10 : HomeMetrics.cardPadding.top) : 0)
      .padding(.horizontal, HomeMetrics.cardPadding.leading)
      Spacer(minLength: 0)
      if live {
        band(direction: direction, history: history, color: color)
          .frame(height: 34)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: live ? (compact ? 114 : 136) : (compact ? 78 : 98))
    .homeCard()
    .contentShape(SurfaceRadius.shape(HomeMetrics.cardRadius))
    .accessibilityElement(children: .combine)
  }

  private var caption: String? {
    guard metric.kind == .connections, live else { return metric.detail }
    let totals = runtimeData.trafficDestinations
    return totals.reject == 0
      ? String(localized: "Proxy \(totals.proxy) · Direct \(totals.direct)")
      : String(localized: "Proxy \(totals.proxy) · Direct \(totals.direct) · Rejected \(totals.reject)")
  }

  @ViewBuilder
  private func band(direction: KeyPath<TrafficSample, Int>?, history: [Int], color: Color) -> some View {
    if direction != nil {
      HomeRateSparkline(values: history.suffix(60), color: color)
    } else if metric.kind == .memory {
      let readings = runtimeData.memoryHistory
      if readings.count > 1 {
        // Memory moves a few percent at most; drawn from zero it would be a flat line pinned to the
        // top. Lift the baseline under the lowest reading so the drift is visible.
        let low = readings.min() ?? 0
        let high = readings.max() ?? 0
        let baseline = max(0, low - max(high - low, high / 40))
        HomeRateSparkline(values: readings.suffix(60).map { $0 - baseline }[...], color: .gray)
      }
    } else if metric.kind == .connections {
      connectionBar
        .padding(.horizontal, HomeMetrics.cardPadding.leading)
        .frame(maxHeight: .infinity, alignment: .center)
    }
  }

  private var connectionBar: some View {
    let totals = runtimeData.trafficDestinations
    return GeometryReader { bounds in
      let width = bounds.size.width / CGFloat(max(1, totals.count))
      HStack(spacing: 0) {
        Rectangle().fill(.secondary).frame(width: width * CGFloat(totals.proxy))
        Rectangle().fill(.tertiary).frame(width: width * CGFloat(totals.direct))
        Rectangle().fill(.red.opacity(0.6)).frame(width: width * CGFloat(totals.reject))
      }
    }
    .frame(height: 6).homeWell(Capsule()).clipShape(Capsule())
  }
}

private struct HomeRateSparkline: View {
  let values: ArraySlice<Int>
  let color: Color

  var body: some View {
    let points = values.map(Double.init)
    let scale = 1 / Double(max(values.max() ?? 0, TrafficChartGeometry.minimumCeiling))
    let line = TrafficSeriesShape(values: points, newestSequence: points.count - 1, slotCount: 60,
                                  head: Double(points.count - 1), scale: scale, smoothing: 0.2, isClosed: false, edgeInset: 0)
    var area = line
    area.isClosed = true
    return ZStack {
      area.fill(LinearGradient(colors: [color.opacity(0.20), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
      line.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }
    .accessibilityHidden(true)
  }
}

/// Two cards side by side, as tall as each other. `fixedSize` lets the row settle on its tallest
/// card's ideal height, and every card fills that height (`maxHeight: .infinity`) — so the pair
/// never leaves one card ending 80 points above the other. Narrow windows stack them unchanged.
private struct DashboardResponsivePair<Leading: View, Trailing: View>: View {
  let availableWidth: CGFloat
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    if availableWidth >= DashboardLayoutMetrics.runningPairColumnsBreakpoint {
      HStack(alignment: .top, spacing: HomeMetrics.gridSpacing) {
        leading
          .frame(width: (availableWidth - HomeMetrics.gridSpacing) * 0.6)
        trailing
      }
      .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: HomeMetrics.gridSpacing) {
        leading
        trailing
      }
    }
  }
}

/// What the dashboard's Proxy Groups card lists: the first `limit` groups in the order it is given,
/// plus how many it left out. The caller passes groups in profile order — the dashboard's resolved
/// snapshot of `AppModel.visibleProxyGroups`, the same list the Proxies page shows — never the raw
/// `/proxies` groups, whose order changes per launch.
struct DashboardProxyGroupsSummary: Equatable {
  static let rowLimit = 6

  let rows: [ProxyGroup]
  let hiddenCount: Int

  init(groups: [ProxyGroup], limit: Int = rowLimit) {
    rows = Array(groups.prefix(max(0, limit)))
    hiddenCount = groups.count - rows.count
  }
}

enum DashboardProxySelectionState {
  static func selectableGroups(from groups: [ProxyGroup]) -> [ProxyGroup] {
    groups.filter { group in
      group.allowsManualProxySelection && (group.nodes.contains(where: \.isSelectable) || hasMissingSelection(in: group))
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

  /// The key the dashboard probes the current node's delay under: once per runtime session and
  /// per group/node, and only while the runtime can actually answer. `nil` means "nothing to do",
  /// so a `task(id:)` keyed on it stays idle rather than firing on every unrelated repaint.
  static func automaticDelayProbeKey(
    sessionStartedAt: Date?,
    isRunning: Bool,
    canControlRuntimeProxies: Bool,
    group: ProxyGroup?,
    node: ProxyNode?
  ) -> String? {
    guard isRunning, canControlRuntimeProxies,
          let sessionStartedAt,
          let group,
          let node,
          node.supportsDelayTesting
    else { return nil }
    return "\(sessionStartedAt.timeIntervalSinceReferenceDate)|\(group.name)|\(node.id)"
  }

  static func typeLabel(for node: ProxyNode?) -> String {
    guard let type = node?.type, !type.isEmpty else { return String(localized: "Proxy") }
    switch type.lowercased() {
    case "hysteria2":
      return "Hysteria2"
    case "vless":
      return "VLESS"
    case "easytier":
      return "EasyTier"
    case "zerotier":
      return "ZeroTier"
    case "direct":
      return String(localized: "Direct")
    default:
      // The core reports adapter types in their own casing (`URLTest`, `WireGuard`, `AnyTLS`);
      // `capitalized` would flatten those to "Urltest". Only an all-lowercase type gets a capital.
      return type.contains(where: \.isUppercase) ? type : type.capitalized
    }
  }
}

private struct DashboardNodePickerButton: View {
  @Environment(AppModel.self) private var appModel
  let group: ProxyGroup
  let currentNode: ProxyNode
  var hero = false
  @State private var isPresented = false
  @State private var hovered = false

  var body: some View {
    Button { isPresented.toggle() } label: {
      HStack(spacing: 4) {
        Text(currentNode.name)
          .font(hero ? .system(size: 24, weight: .semibold) : .callout)
          .foregroundStyle(hero ? .primary : .secondary)
          .lineLimit(1).minimumScaleFactor(hero ? 0.75 : 1).truncationMode(.middle)
        if appModel.proxySelectionInFlightGroups.contains(group.id) {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .opacity(!hero || hovered || isPresented ? 1 : 0)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background { if hovered { RoundedRectangle(cornerRadius: 5).fill(.tileSurface) } }
    .onHover { hovered = $0 }
    .disabled(!group.allowsManualProxySelection || appModel.proxySelectionInFlightGroups.contains(group.id))
    .help(currentNode.name)
    .accessibilityLabel("Choose a node").accessibilityValue(currentNode.name)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      // Only the open popover builds searchable rows, including for groups with thousands of nodes.
      if isPresented {
        DashboardNodePickerPopover(
          group: group, currentNodeName: currentNode.name,
          canSelect: appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline,
          onSelect: { node in
            isPresented = false
            appModel.selectProxy(group: group, node: node)
          },
          onOpenInProxies: {
            isPresented = false
            appModel.openProxies(focusingGroup: group.name)
          }
        )
      }
    }
  }
}

/// Which of a group's nodes the Current Node popover lists for a search: the selectable ones, in
/// the order the Proxies page shows them, filtered with the Proxies page's own query syntax.
enum DashboardNodePickerFilter {
  static func nodes(in group: ProxyGroup, matching searchText: String) -> [ProxyNode] {
    let query = ProxySearchQuery(rawValue: searchText)
    return group.nodes.filter { node in
      node.isSelectable && (query.isEmpty || query.matches(group: group, node: node))
    }
  }
}

private struct DashboardNodePickerPopover: View {
  let group: ProxyGroup
  let currentNodeName: String
  let canSelect: Bool
  let onSelect: (ProxyNode) -> Void
  let onOpenInProxies: () -> Void
  @State private var searchText = ""

  var body: some View {
    let nodes = DashboardNodePickerFilter.nodes(in: group, matching: searchText)

    VStack(spacing: 0) {
      TextField("Search Nodes", text: $searchText, prompt: Text("Search Nodes"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        // Return takes the first match, so type-to-filter then Return never needs the mouse.
        .onSubmit {
          if canSelect, let first = nodes.first {
            onSelect(first)
          }
        }
        .padding(10)

      Divider()

      if nodes.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(nodes) { node in
                DashboardNodePickerRow(node: node, isCurrent: node.name == currentNodeName) {
                  onSelect(node)
                }
                .disabled(!canSelect)
                .id(node.id)
              }
            }
          }
          .accessibilityLabel("Nodes")
          .task {
            guard nodes.first?.name != currentNodeName,
                  let current = nodes.first(where: { $0.name == currentNodeName }) else { return }
            await Task.yield()
            if !Task.isCancelled { proxy.scrollTo(current.id, anchor: .center) }
          }
        }
      }

      Divider()

      HStack(spacing: 8) {
        Text(String.localizedStringWithFormat(NSLocalizedString("%lld nodes", comment: ""), Int64(nodes.count)))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer(minLength: 8)
        Button(String(localized: "Open in Proxies"), action: onOpenInProxies)
          .controlSize(.small)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
    }
    .frame(width: 340, height: 420)
  }
}

private struct DashboardNodePickerRow: View {
  let node: ProxyNode
  let isCurrent: Bool
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    // The same verdict and colour as the Proxies list.
    let delay = ProxyDelayDisplay(state: node.resolvedDelayState)
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)
          .opacity(isCurrent ? 1 : 0)
          .frame(width: 14)
          .accessibilityHidden(true)
        Text(node.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(node.name)
        Spacer(minLength: 8)
        Text(delay.localizedLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(delay.tone.color)
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background { if hovered { Rectangle().fill(.tileSurface) } }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }
}

/// Which TUN checks Home raises: only a warning or a failure. A passing, informational or skipped
/// check, and a run that has not produced checks yet, raise nothing — the status strip already says
/// TUN is on, and the full list lives on the Status page.
enum DashboardTunAttention {
  static func issues(in diagnostics: TunDiagnosticsSnapshot) -> [TunDiagnosticCheck] {
    diagnostics.checks.filter { $0.status == .fail || $0.status == .warn }
  }

  /// "TUN Route (Fail), System DNS (Warn)", failures first, in the user's language.
  static func summary(of issues: [TunDiagnosticCheck]) -> String {
    let ordered = issues.filter { $0.status == .fail } + issues.filter { $0.status != .fail }
    return ordered
      .map { String(format: String(localized: "%@ (%@)"), localizedRuntimeText($0.title), $0.status.localizedDisplayName) }
      .formatted(.list(type: .and, width: .narrow))
  }
}

/// A single compact warning on Home, with the recoveries the app already has for it next to it.
private struct DashboardAttentionRow<Actions: View>: View {
  let isError: Bool
  let title: String
  let detail: String?
  let availableWidth: CGFloat
  @ViewBuilder var actions: Actions

  var body: some View {
    Group {
      if availableWidth >= 820 {
        HStack(alignment: .center, spacing: 12) {
          message
          Spacer(minLength: 12)
          actionButtons
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          message
          actionButtons
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .homeCard()
  }

  private var message: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
        }
      }
    } icon: {
      Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isError ? Color.red : Color.orange)
    }
  }

  private var actionButtons: some View {
    HStack(spacing: 12) {
      actions
    }
    .buttonStyle(.link)
    .font(.callout)
    .fixedSize()
  }
}

private struct TunDiagnosticsAttentionRow: View {
  @Environment(AppModel.self) private var appModel
  let availableWidth: CGFloat

  var body: some View {
    let issues = DashboardTunAttention.issues(in: appModel.tunDiagnostics)
    let dnsRepairError = appModel.tunSystemDNSState.errorMessage
    if !issues.isEmpty || dnsRepairError != nil {
      DashboardAttentionRow(
        isError: issues.contains { $0.status == .fail } || dnsRepairError != nil,
        title: title(issues: issues),
        detail: dnsRepairError ?? issues.first.map { $0.detail ?? $0.message },
        availableWidth: availableWidth
      ) {
        if dnsRepairError != nil || issues.contains(where: { $0.suggestedRepair == .systemDNS }) {
          Button(String(localized: "Repair DNS")) {
            appModel.repairTunDNS()
          }
          .disabled(!appModel.canRepairTunDNS)
        }

        if issues.contains(where: { $0.suggestedRepair == .routing }) {
          Button(String(localized: "Repair Routing")) {
            appModel.repairTunRouting()
          }
          .disabled(!appModel.canRepairTunRouting)
        }

        if appModel.hasResidualSystemProxy {
          Button(String(localized: "Disable System Proxy")) {
            appModel.disableResidualSystemProxy()
          }
          .disabled(!appModel.canDisableResidualSystemProxy)
        }

        Button(String(localized: "Show in Status")) {
          appModel.selectedSection = .status
        }
      }
    }
  }

  private func title(issues: [TunDiagnosticCheck]) -> String {
    guard !issues.isEmpty else { return String(localized: "TUN system DNS repair needed") }
    return String(format: String(localized: "TUN checks need attention: %@"), DashboardTunAttention.summary(of: issues))
  }
}

/// Connection errors are recent events, not a persistent failure of the whole extension. The
/// cumulative counters and older events remain available in Status; DNS repair errors persist.
struct DashboardNetworkExtensionAttention {
  static let recentErrorInterval = NetworkExtensionDiagnosticsSnapshot.recentErrorDisplayInterval

  let dnsError: String?
  let latestError: NetworkExtensionDiagnosticEvent?

  init(diagnostics: NetworkExtensionDiagnosticsSnapshot, dnsError: String?, now: Date) {
    self.dnsError = dnsError
    latestError = diagnostics.latestRecentError(now: now)
  }

  var needsAttention: Bool { dnsError != nil || latestError != nil }
  var isError: Bool { dnsError != nil }
}

/// The NE counterpart of `TunDiagnosticsAttentionRow`. The clock expires transient warnings even
/// when an idle extension has stopped publishing new diagnostics.
///
/// The body must emit nothing when there is nothing to show. A `TimelineView` wrapper is a view of
/// its own even with empty content, so the Home `VStack` gave it a slot and a second section gap
/// above the metrics whenever NE Proxy was the capture mode. The expiry clock therefore lives in a
/// task on the visible row: it re-evaluates the body, which drops the row once its error ages out.
private struct NetworkExtensionAttentionRow: View {
  @Environment(AppModel.self) private var appModel
  let availableWidth: CGFloat
  @State private var expiryTick = 0

  var body: some View {
    let _ = expiryTick
    let attention = DashboardNetworkExtensionAttention(
      diagnostics: appModel.networkExtensionController.diagnostics,
      dnsError: appModel.networkExtensionSystemDNSState.errorMessage,
      now: Date()
    )
    if attention.needsAttention {
      DashboardAttentionRow(
        isError: attention.isError,
        title: attention.dnsError != nil
          ? String(localized: "NE system DNS repair needed")
          : String(localized: "NE Proxy reported an error"),
        detail: attention.dnsError ?? attention.latestError.map(eventSummary),
        availableWidth: availableWidth
      ) {
        Button(String(localized: "Show in Status")) {
          appModel.selectedSection = .status
        }
      }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5))
          expiryTick &+= 1
        }
      }
    }
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
    return context.isEmpty ? event.message : "\(event.message) — \(context)"
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
    case openAuditReport(Profile.ID)

    var title: String {
      switch self {
      case .repairHelper: String(localized: "Repair Helper")
      case .openHelperSettings: String(localized: "Open System Settings")
      case .repairTunDNS: String(localized: "Repair DNS")
      case .repairTunRouting: String(localized: "Repair Routing")
      case .disableResidualSystemProxy: String(localized: "Disable System Proxy")
      case .showSection: String(localized: "Show Details")
      case .openAuditReport: String(localized: "Open Audit Report")
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

      Button {
        appModel.isDiagnosticBundleSheetPresented = true
      } label: {
        Label("Export Diagnostic Bundle…", systemImage: "archivebox")
      }
      .help("Preview and save one redacted file to attach to a bug report")

      moreMenu
    } content: {
      Form {
        Section {
          StatusOverviewRow(overview: overview)
          LabeledContent("Mode", value: appModel.proxyRoutingMode.displayName)
          LabeledContent("Profile", value: appModel.profileStore.activeProfile?.name ?? String(localized: "None"))
          LabeledContent("Core", value: coreText)
          LabeledContent("Run Mode", value: appModel.currentRuntimeOverrides.mode.displayName)
          LabeledContent("Runtime Owner", value: appModel.runtimeOwner.menuBarDisplayName)
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

      Button(String(localized: "Repair Helper")) {
        appModel.repairHelperRegistration()
      }
      Button(String(localized: "Open Helper Approval Settings")) {
        appModel.openHelperApprovalSettings()
      }

      if showsTunDiagnostics {
        Divider()
        Button(String(localized: "Refresh TUN Diagnostics")) {
          appModel.refreshTunDiagnostics()
        }
        Button(String(localized: "Repair TUN System DNS")) {
          appModel.repairTunDNS()
        }
        .disabled(!appModel.canRepairTunDNS)
        Button(String(localized: "Repair TUN Routing")) {
          appModel.repairTunRouting()
        }
        .disabled(!appModel.canRepairTunRouting)
      }

      if appModel.hasResidualSystemProxy {
        Divider()
        Button(String(localized: "Disable Residual System Proxy")) {
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
    case let .openAuditReport(profileID):
      appModel.presentAuditReport(for: profileID)
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
    // Roadmap C1: a background update never opens a sheet, so what it brought in waits here.
    for profile in appModel.profilesNeedingAuditReview {
      items.append(StatusAttentionItem(
        id: "audit-\(profile.id.uuidString)",
        title: String(localized: "Subscription needs review"),
        message: String(
          format: String(localized: "%@ asks for settings that need your review. Open its audit report from the profile."),
          profile.name
        ),
        isError: false,
        actions: [.openAuditReport(profile.id)]
      ))
    }
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
      var actions: [StatusAttentionItem.Action] = []
      if issue.suggestedRepair == .systemDNS, appModel.canRepairTunDNS {
        actions.append(.repairTunDNS)
      } else if issue.suggestedRepair == .routing, appModel.canRepairTunRouting {
        actions.append(.repairTunRouting)
      }
      actions.append(.showSection(.tun))
      items.append(StatusAttentionItem(
        id: "tun-\(issue.id)",
        title: issue.title,
        message: issue.detail ?? issue.message,
        isError: issue.status == .fail,
        actions: actions
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
        Button(String(localized: "Open Logs")) {
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
    LabeledContent("TUN dns-mode", value: tunCoreDNSModeLabel)
    LabeledContent("DNS Hijack", value: tun.normalizedDNSHijack.joined(separator: ", "))
    LabeledContent("Fake IP Range", value: tun.dnsFakeIPEnabled ? tun.normalizedFakeIPRange : String(localized: "Off"))
    LabeledContent("Nameserver", value: summarized(tun.dns.nameserver))
    LabeledContent("Fallback", value: summarized(tun.dns.fallback))
    LabeledContent("NE System DNS", value: appModel.networkExtensionSystemDNSState.displayName)
  }

  /// The core's own value names a config key, so it stays verbatim; only "default" is translated.
  private var tunCoreDNSModeLabel: String {
    guard appModel.tunEnabled, let mode = appModel.activeTunDNSMode else {
      return String(localized: "Default")
    }
    return mode
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
      Button(String(localized: "Repair Helper")) {
        appModel.repairHelperRegistration()
      }
      Button(String(localized: "Open Helper Approval Settings")) {
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
    if tun.stack == .mips {
      LabeledContent("TCP Congestion Control", value: appModel.activeTunCongestionController ?? String(localized: "Unknown"))
    }
    LabeledContent("Checks", value: diagnosticCounterText(diagnostics))
    LabeledContent("Device", value: tun.normalizedDevice)
    LabeledContent("Last Check", value: diagnostics.updatedAt == Date.distantPast
      ? String(localized: "Waiting")
      : diagnostics.updatedAt.formatted(date: .omitted, time: .standard))
    ForEach(diagnostics.checks) { check in
      StatusTunDiagnosticCheckRow(check: check)
    }
    HStack(spacing: 8) {
      Button(String(localized: "Refresh TUN Diagnostics")) {
        appModel.refreshTunDiagnostics()
      }
      Button(String(localized: "Repair TUN System DNS")) {
        appModel.repairTunDNS()
      }
      .disabled(!appModel.canRepairTunDNS)
      Button(String(localized: "Repair TUN Routing")) {
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
    if let omitted = runtimeData.processRoutePlan.omissionSummary(appliedAt: runtimeData.processRoutesAppliedAt) {
      Text(omitted).foregroundStyle(.secondary)
    }
    if let date = diagnostics.lastUncertainProcessAttribution {
      LabeledContent("App attribution may be imprecise", value: [DiagnosticFactSource.log.title, date.formatted(date: .abbreviated, time: .standard)].joined(separator: " · "))
    }
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
        Text(check.status.localizedDisplayName)
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

private struct TrafficRuntimeCard: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  let showRates: Bool
  let starting: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Label("Traffic", systemImage: "waveform.path.ecg").font(.callout).foregroundStyle(.secondary)
        Spacer(minLength: 2)
        legend("Download", symbol: "arrow.down", color: TrafficSeriesColor.download, value: runtimeData.trafficSample.download)
        legend("Upload", symbol: "arrow.up", color: TrafficSeriesColor.upload, value: runtimeData.trafficSample.upload)
      }
      if starting || appModel.runtimeDataLoading, runtimeData.trafficHistory.isEmpty {
        ClashMaxChartSkeleton().frame(height: 150)
      } else {
        DashboardTrafficSparkline(samples: runtimeData.trafficHistory, sampleCount: runtimeData.trafficSampleCount,
                                  animatesEntrance: appModel.sessionStartedAt.map { Date().timeIntervalSince($0) < 3 } == true)
          .frame(height: 150)
      }
    }
    .padding(HomeMetrics.cardPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .homeCard()
  }

  private func legend(_ title: LocalizedStringResource, symbol: String, color: Color, value: Int) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).foregroundStyle(color)
      if showRates, !runtimeData.trafficHistory.isEmpty {
        Text(TrafficSample.format(value))
      } else {
        Text(title)
      }
    }
    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    .help(Text(verbatim: TrafficSample.format(value)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(title)).accessibilityValue(TrafficSample.format(value))
  }
}

private struct ProxyGroupsRuntimeCard: View {
  @Environment(AppModel.self) private var appModel
  let groups: [ProxyGroup]
  let trackedGroup: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Proxy Groups", systemImage: "square.stack.3d.up").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button { appModel.reloadRuntimeData() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).disabled(!appModel.canControlRuntimeProxies)
          .help("Refresh runtime proxy groups")
      }
      if groups.isEmpty {
        ClashMaxSkeletonList(rows: 3, showsLeadingIcon: false, trailingWidth: 45)
      } else {
        let summary = DashboardProxyGroupsSummary(groups: groups)
        VStack(spacing: 0) {
          ForEach(summary.rows) { group in
            DashboardProxyGroupRow(group: group, tracked: group.name == trackedGroup)
            if group.id != summary.rows.last?.id { Divider().opacity(0.5) }
          }
        }
        if summary.hiddenCount > 0 {
          Button("\(summary.hiddenCount) more groups") { appModel.openProxies() }
            .buttonStyle(.link).font(.caption)
        }
      }
    }
    .padding(HomeMetrics.cardPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .homeCard()
  }
}

private struct DashboardProxyGroupRow: View {
  @Environment(AppModel.self) private var appModel
  let group: ProxyGroup
  /// The group the Home hero follows. Its row is tinted, and keeps its node and delay like every
  /// other row — a list whose first entry reads "Current Node" with no name looks unloaded.
  let tracked: Bool

  var body: some View {
    let node = DashboardProxySelectionState.currentNode(in: group)
    HStack(spacing: 6) {
      Text(group.name).font(.callout.weight(.medium))
        .lineLimit(1).truncationMode(.middle).help(group.name)
      if let node, group.allowsManualProxySelection {
        DashboardNodePickerButton(group: group, currentNode: node)
      } else {
        let name = node?.name ?? group.selected ?? String(localized: "No selection")
        Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(name)
      }
      Spacer(minLength: 0)
      if let node {
        DashboardDelayBadge(state: node.resolvedDelayState).fixedSize()
      }
      Button { appModel.openProxies(focusingGroup: group.name) } label: {
        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          .frame(width: 18, height: 26).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help("Show \(group.name) in Proxies")
      .accessibilityLabel(Text("Show \(group.name) in Proxies"))
    }
    .padding(.horizontal, 6).frame(height: 30)
    .background { if tracked { RoundedRectangle(cornerRadius: HomeMetrics.wellRadius).fill(.tileSurface) } }
  }
}

private struct DashboardDelayBadge: View {
  let state: ProxyDelayState
  var showsSymbol = false

  var body: some View {
    let display = ProxyDelayDisplay(state: state)
    HomeChip(text: display.localizedLabel, symbol: showsSymbol ? "bolt" : nil,
             tone: display.tone == .unavailable ? nil : display.tone.color, busy: state == .testing)
  }
}

private struct HomeDestinationsCard: View {
  @Environment(RuntimeDataStore.self) private var runtimeData
  let compact: Bool

  var body: some View {
    let destinations = runtimeData.trafficDestinations
    VStack(alignment: .leading, spacing: 12) {
      Label("Traffic destinations · current connections", systemImage: "arrow.triangle.branch")
        .font(.callout).foregroundStyle(.secondary)
      if destinations.count == 0 {
        Text("No open connections").font(.callout).foregroundStyle(.secondary)
      } else {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
          : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
        layout {
          column("By domain", rows: destinations.domains)
          column("By exit node", rows: destinations.exits)
        }
      }
    }
    .padding(HomeMetrics.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .homeCard()
  }

  private func column(_ title: LocalizedStringResource, rows: [HomeTrafficDestinations.Row]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      ForEach(rows) { row in
        VStack(spacing: 3) {
          HStack {
            Text(row.name).font(.callout).lineLimit(1).truncationMode(.middle).help(row.name)
            Spacer(minLength: 8)
            Text(TrafficSample.formatBytes(row.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
          GeometryReader { proxy in
            let fraction = CGFloat(row.bytes) / CGFloat(max(1, rows.first?.bytes ?? 0))
            Capsule().fill(.secondary).frame(width: proxy.size.width * fraction)
          }
          .frame(height: 3).homeWell(Capsule()).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private func localizedRuntimeText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private struct RuntimeContentEntrance: ViewModifier {
  let delay: Double
  let isEnabled: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  func body(content: Content) -> some View {
    let animate = isEnabled && !reduceMotion
    content
      .opacity(animate && !appeared ? 0 : 1)
      .offset(y: animate && !appeared ? 8 : 0)
      .task(id: animate) {
        guard animate else { appeared = false; return }
        withAnimation(.spring(duration: 0.42, bounce: 0.06).delay(delay)) {
          appeared = true
        }
      }
  }
}
