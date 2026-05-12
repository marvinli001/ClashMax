import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var searchText = ""
  @State private var sortOrder: ProxyNodeSort = .name
  @State private var expandedGroupIDs: Set<String>?

  var body: some View {
    let groups = filteredGroups(from: appModel.visibleProxyGroups)
    let searchQuery = normalizedSearchQuery
    let visibleExpandedGroupIDs = ProxyGroupExpansionPolicy.resolvedExpansion(
      current: expandedGroupIDs,
      groups: groups,
      searchQuery: searchQuery
    )
    let listAnimationState = ProxyGroupListAnimationState(
      groups: groups,
      expandedGroupIDs: visibleExpandedGroupIDs,
      searchQuery: searchQuery,
      sortOrder: sortOrder
    )
    let isStarting = appModel.dashboardRuntimeState.isStarting
    let canStart = ProxiesPageActionState.canStart(
      isRunning: appModel.isRunning,
      hasActiveProfile: appModel.profileStore.activeProfile != nil,
      isStarting: isStarting,
      readinessIssue: appModel.readinessIssue
    )

    AdaptivePage(
      title: "Proxies",
      subtitle: subtitle(for: groups)
    ) {
      if !appModel.isRunning, appModel.profileStore.activeProfile != nil {
        Button {
          appModel.start()
        } label: {
          Label(isStarting ? "Starting" : "Start", systemImage: isStarting ? "clock.arrow.circlepath" : "play.fill")
        }
        .disabled(!canStart)
      }
      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(!ProxiesPageActionState.canRefresh(isStarting: isStarting))
    } content: {
      if groups.isEmpty {
        CenteredUnavailableState(
          title: "No proxy groups",
          systemImage: "point.3.connected.trianglepath.dotted",
          message: appModel.proxyGroupsUnavailableMessage
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          proxyControls

          if let notice = ProxyPreviewNoticeKind.resolve(
            developerMode: appModel.developerMode,
            previewRuntimeActive: appModel.previewRuntimeActive,
            isShowingProxyPreview: appModel.isShowingProxyPreview
          ) {
            ProxyPreviewNotice(icon: notice.icon, message: notice.message)
          }

          if ProxyPageVisibilityPolicy.showsProviderSummary(
            developerMode: appModel.developerMode,
            providerCount: runtimeData.proxyProviders.count
          ) {
            ProxyProviderList(providers: runtimeData.proxyProviders)
          }

          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(groups) { group in
                ProxyGroupCard(
                  group: group,
                  showsDeveloperDetails: appModel.developerMode,
                  isExpanded: visibleExpandedGroupIDs.contains(group.id),
                  isSearchActive: !searchQuery.isEmpty
                ) {
                  toggleExpansion(for: group, visibleGroups: groups)
                }
              }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(ProxyInteractionAnimation.list(reduceMotion: reduceMotion), value: listAnimationState)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .onAppear {
      appModel.enterPreviewRuntime()
    }
    .onDisappear {
      Task { @MainActor in
        await appModel.leavePreviewRuntime()
      }
    }
    .onChange(of: appModel.visibleProxyGroups.map(\.id) + runtimeData.proxyGroups.map(\.id)) { _, _ in
      appModel.enterPreviewRuntime()
      withAnimation(ProxyInteractionAnimation.list(reduceMotion: reduceMotion)) {
        expandedGroupIDs = ProxyGroupExpansionPolicy.retainedExpansion(
          current: expandedGroupIDs,
          groups: appModel.visibleProxyGroups
        )
      }
    }
  }

  private func subtitle(for groups: [ProxyGroup]) -> String {
    if groups.isEmpty {
      return "Proxy groups load from the active profile and runtime."
    }
    if appModel.previewRuntimeActive {
      return "\(groups.count) groups · preview core"
    }
    if appModel.isShowingProxyPreview {
      return "\(groups.count) preview groups"
    }
    return "\(groups.count) groups"
  }

  private var proxyControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        TextField("Search", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)
        sortPicker
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Search", text: $searchText)
          .textFieldStyle(.roundedBorder)
        sortPicker
      }
    }
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortOrder) {
      ForEach(ProxyNodeSort.allCases) { order in
        Text(order.displayName).tag(order)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
  }

  private var normalizedSearchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func filteredGroups(from groups: [ProxyGroup]) -> [ProxyGroup] {
    let query = normalizedSearchQuery.lowercased()
    return groups.compactMap { group in
      var group = group
      let nodes = sortedNodes(group.nodes)
      if query.isEmpty || group.name.lowercased().contains(query) {
        group.nodes = nodes
        return group
      }
      group.nodes = nodes.filter { node in
        node.name.lowercased().contains(query) || node.type.lowercased().contains(query)
      }
      return group.nodes.isEmpty ? nil : group
    }
  }

  private func sortedNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
    switch sortOrder {
    case .name:
      return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    case .delay:
      return nodes.sorted {
        let first = $0.delay ?? Int.max
        let second = $1.delay ?? Int.max
        if first == second {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return first < second
      }
    case .type:
      return nodes.sorted {
        let comparison = $0.type.localizedStandardCompare($1.type)
        if comparison == .orderedSame {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return comparison == .orderedAscending
      }
    }
  }

  private func toggleExpansion(for group: ProxyGroup, visibleGroups: [ProxyGroup]) {
    guard normalizedSearchQuery.isEmpty else { return }
    let currentExpansion = ProxyGroupExpansionPolicy.resolvedExpansion(
      current: expandedGroupIDs,
      groups: visibleGroups,
      searchQuery: normalizedSearchQuery
    )
    withAnimation(ProxyInteractionAnimation.expansion(reduceMotion: reduceMotion)) {
      expandedGroupIDs = ProxyGroupExpansionPolicy.toggled(groupID: group.id, in: currentExpansion)
    }
  }
}

private enum ProxyNodeSort: String, CaseIterable, Equatable, Identifiable {
  case name
  case delay
  case type

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .name: "Name"
    case .delay: "Delay"
    case .type: "Type"
    }
  }
}

private struct ProxyGroupListAnimationState: Equatable {
  let groupIDs: [String]
  let expandedGroupIDs: [String]
  let nodeIDsByGroup: [[String]]
  let selections: [String]
  let searchQuery: String
  let sortOrder: ProxyNodeSort

  init(
    groups: [ProxyGroup],
    expandedGroupIDs: Set<String>,
    searchQuery: String,
    sortOrder: ProxyNodeSort
  ) {
    self.groupIDs = groups.map(\.id)
    self.expandedGroupIDs = expandedGroupIDs.sorted()
    self.nodeIDsByGroup = groups.map { group in
      group.nodes.map(\.id)
    }
    self.selections = groups.map { group in
      group.selected ?? ""
    }
    self.searchQuery = searchQuery
    self.sortOrder = sortOrder
  }
}

private struct ProxyNodeGridAnimationState: Equatable {
  let nodeIDs: [String]
  let selected: String?

  init(group: ProxyGroup) {
    nodeIDs = group.nodes.map(\.id)
    selected = group.selected
  }
}

enum ProxyPageVisibilityPolicy {
  static func showsProviderSummary(developerMode: Bool, providerCount: Int) -> Bool {
    developerMode && providerCount > 0
  }
}

enum ProxyGroupExpansionPolicy {
  static func resolvedExpansion(
    current: Set<String>?,
    groups: [ProxyGroup],
    searchQuery: String
  ) -> Set<String> {
    let groupIDs = Set(groups.map(\.id))
    guard !groupIDs.isEmpty else { return [] }
    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return groupIDs
    }
    guard let current else {
      return defaultExpandedIDs(for: groups)
    }
    let retained = current.intersection(groupIDs)
    if !current.isEmpty && retained.isEmpty {
      return defaultExpandedIDs(for: groups)
    }
    return retained
  }

  static func retainedExpansion(current: Set<String>?, groups: [ProxyGroup]) -> Set<String>? {
    guard let current else { return nil }
    let groupIDs = Set(groups.map(\.id))
    let retained = current.intersection(groupIDs)
    if !current.isEmpty && retained.isEmpty {
      return defaultExpandedIDs(for: groups)
    }
    return retained
  }

  static func toggled(groupID: String, in expansion: Set<String>) -> Set<String> {
    var next = expansion
    if next.contains(groupID) {
      next.remove(groupID)
    } else {
      next.insert(groupID)
    }
    return next
  }

  private static func defaultExpandedIDs(for groups: [ProxyGroup]) -> Set<String> {
    let selectedGroupIDs = groups.compactMap { group in
      group.selected == nil ? nil : group.id
    }
    if !selectedGroupIDs.isEmpty {
      return Set(selectedGroupIDs)
    }
    return groups.first.map { [$0.id] } ?? []
  }
}

private struct ProxyProviderList: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  let providers: [ProxyProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(providers) { provider in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.name)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(providerSubtitle(provider))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 12)
          if let updatedAt = provider.updatedAt {
            Text(updatedAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button {
            appModel.healthCheckProvider(provider)
          } label: {
            if runtimeData.providerHealthChecksInFlight.contains(provider.id) {
              Image(systemName: "clock.arrow.circlepath")
            } else {
              Image(systemName: "waveform.path.ecg")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || runtimeData.providerHealthChecksInFlight.contains(provider.id))
          .help("Run provider health check")
          .accessibilityLabel("Run health check for \(provider.name)")
        }
        .padding(.vertical, 4)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(ProxySurface.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(ProxySurface.border, lineWidth: 1)
    }
  }

  private func providerSubtitle(_ provider: ProxyProvider) -> String {
    let vehicle = provider.vehicleType.map { " \($0)" } ?? ""
    return "\(provider.type)\(vehicle) - \(provider.proxies.count) nodes"
  }
}

private struct ProxyGroupCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let group: ProxyGroup
  let showsDeveloperDetails: Bool
  let isExpanded: Bool
  let isSearchActive: Bool
  let onToggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        onToggle()
      } label: {
        groupHeader
      }
      .buttonStyle(.plain)
      .help(groupHeaderHelp)
      .accessibilityLabel(groupHeaderAccessibilityLabel)

      if isExpanded {
        expandedContent
          .transition(ProxyInteractionAnimation.expansionTransition(reduceMotion: reduceMotion))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ProxySurface.group, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(ProxySurface.border, lineWidth: 1)
    }
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
        .padding(.horizontal, 12)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10, alignment: .topLeading)],
        alignment: .leading,
        spacing: 10
      ) {
        ForEach(group.nodes) { node in
          ProxyNodeCard(group: group, node: node)
            .transition(ProxyInteractionAnimation.nodeTransition(reduceMotion: reduceMotion))
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .animation(
        ProxyInteractionAnimation.list(reduceMotion: reduceMotion),
        value: ProxyNodeGridAnimationState(group: group)
      )
    }
    .clipped()
  }

  private var groupHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 12)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .animation(ProxyInteractionAnimation.chevron(reduceMotion: reduceMotion), value: isExpanded)

      Image(systemName: "point.3.connected.trianglepath.dotted")
        .foregroundStyle(.cyan)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(group.name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          if showsDeveloperDetails {
            ProxyTypeBadge(text: group.type)
          }
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            nodeCountLabel
            selectedLabel
            selectedDelayLabel
          }

          VStack(alignment: .leading, spacing: 3) {
            nodeCountLabel
            selectedLabel
            selectedDelayLabel
          }
        }
      }

      Spacer(minLength: 12)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var groupHeaderHelp: String {
    if isSearchActive {
      return "Search results expand matching groups automatically."
    }
    return "Toggle \(group.name)"
  }

  private var groupHeaderAccessibilityLabel: String {
    return "\(isExpanded ? "Collapse" : "Expand") \(group.name)"
  }

  private var nodeCountLabel: some View {
    Label("\(group.nodes.count) nodes", systemImage: "circle.grid.2x2")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var selectedLabel: some View {
    Group {
      if let selected = group.selected {
        Label(selected, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.secondary)
      } else {
        Label("No selection", systemImage: "circle")
          .foregroundStyle(.tertiary)
      }
    }
    .font(.caption)
    .lineLimit(1)
  }

  private var selectedDelayLabel: some View {
    Group {
      if let selectedNode = group.nodes.first(where: { $0.name == group.selected }) {
        let delayDisplay = ProxyDelayDisplay(delay: selectedNode.delay)
        Text(delayDisplay.label)
          .foregroundStyle(delayDisplay.tone.color)
      } else {
        EmptyView()
      }
    }
    .font(.caption.monospacedDigit())
    .lineLimit(1)
  }
}

private struct ProxyNodeCard: View {
  @EnvironmentObject private var appModel: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState private var isPressing = false
  let group: ProxyGroup
  let node: ProxyNode

  var body: some View {
    let canSelect = group.allowsManualProxySelection
      && node.isSelectable
      && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let canTest = node.isSelectable && appModel.canControlRuntimeProxies
    let delayDisplay = ProxyDelayDisplay(delay: node.delay)
    let isSelected = group.selected == node.name

    ZStack(alignment: .topTrailing) {
      Button {
        withAnimation(ProxyInteractionAnimation.selection(reduceMotion: reduceMotion)) {
          appModel.selectProxy(group: group, node: node)
        }
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(isSelected ? .green : .secondary)
              .frame(width: 16)
              .scaleEffect(isSelected ? 1.04 : 1)
              .animation(ProxyInteractionAnimation.selection(reduceMotion: reduceMotion), value: isSelected)

            Text(node.name)
              .font(.callout.weight(isSelected ? .semibold : .regular))
              .foregroundStyle(node.isSelectable ? .primary : .secondary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 20)
          }

          HStack(spacing: 8) {
            ProxyTypeBadge(text: node.type, isSelectable: node.isSelectable)
            Spacer(minLength: 8)
            Text(delayDisplay.label)
              .font(.caption.monospacedDigit())
              .foregroundStyle(delayDisplay.tone.color)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(!canSelect)
      .help(selectionHelp(canSelect: canSelect))

      Button {
        appModel.testDelay(for: node)
      } label: {
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.system(size: 13, weight: .medium))
          .frame(width: 20, height: 20)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(!canTest)
      .help(canTest ? "Test delay" : "Preview core needs a moment to come up before delay testing.")
      .accessibilityLabel("Test delay for \(node.name)")
      .padding(.top, 7)
      .padding(.trailing, 7)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .scaleEffect(nodeScale(canSelect: canSelect))
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(ProxySurface.node)
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(nodeInteractionTint(isSelected: isSelected, canSelect: canSelect))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(
          nodeBorder(isSelected: isSelected, canSelect: canSelect),
          lineWidth: isSelected || (isPressing && canSelect) ? 1.2 : 1
        )
    }
    .simultaneousGesture(pressGesture(isEnabled: canSelect))
    .animation(ProxyInteractionAnimation.press(reduceMotion: reduceMotion), value: isPressing)
    .animation(ProxyInteractionAnimation.selection(reduceMotion: reduceMotion), value: isSelected)
  }

  private func nodeScale(canSelect: Bool) -> Double {
    guard canSelect, isPressing, !reduceMotion else { return 1 }
    return 0.992
  }

  private func selectionHelp(canSelect: Bool) -> String {
    if canSelect {
      return "Select \(node.name)"
    }
    if !group.allowsManualProxySelection {
      return "\(group.name) is managed automatically by Mihomo."
    }
    return appModel.proxyRuntimeActionMessage
  }

  private func nodeInteractionTint(isSelected: Bool, canSelect: Bool) -> Color {
    if isSelected {
      return .green.opacity(0.05)
    }
    if canSelect, isPressing {
      return Color.accentColor.opacity(0.045)
    }
    return .clear
  }

  private func nodeBorder(isSelected: Bool, canSelect: Bool) -> Color {
    if isSelected {
      return .green.opacity(0.75)
    }
    if canSelect, isPressing {
      return Color.accentColor.opacity(0.35)
    }
    return ProxySurface.border
  }

  private func pressGesture(isEnabled: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isPressing) { _, state, _ in
        state = isEnabled
      }
  }
}

private enum ProxySurface {
  static var group: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  static var node: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var secondary: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  static var border: Color {
    Color(nsColor: .separatorColor).opacity(0.55)
  }
}

private enum ProxyInteractionAnimation {
  static func expansion(reduceMotion: Bool) -> Animation {
    reduceMotion
      ? .easeInOut(duration: 0.12)
      : .spring(response: 0.34, dampingFraction: 0.88)
  }

  static func list(reduceMotion: Bool) -> Animation {
    reduceMotion
      ? .easeInOut(duration: 0.12)
      : .spring(response: 0.38, dampingFraction: 0.90)
  }

  static func chevron(reduceMotion: Bool) -> Animation {
    reduceMotion
      ? .easeInOut(duration: 0.10)
      : .spring(response: 0.24, dampingFraction: 0.78)
  }

  static func press(reduceMotion: Bool) -> Animation {
    reduceMotion
      ? .easeInOut(duration: 0.08)
      : .spring(response: 0.18, dampingFraction: 0.72)
  }

  static func selection(reduceMotion: Bool) -> Animation {
    reduceMotion
      ? .easeInOut(duration: 0.12)
      : .spring(response: 0.26, dampingFraction: 0.82)
  }

  static func expansionTransition(reduceMotion: Bool) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .asymmetric(
      insertion: .opacity.combined(with: .move(edge: .top)),
      removal: .opacity
    )
  }

  static func nodeTransition(reduceMotion: Bool) -> AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
  }
}

private struct ProxyTypeBadge: View {
  let text: String
  var isSelectable = true

  var body: some View {
    Text(displayText)
      .font(.caption2.weight(.medium))
      .foregroundStyle(isSelectable ? .secondary : .tertiary)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.tertiary.opacity(isSelectable ? 0.16 : 0.08), in: Capsule())
  }

  private var displayText: String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "proxy" : trimmed
  }
}

struct ProxyDelayDisplay: Equatable {
  let label: String
  let tone: ProxyDelayTone

  init(delay: Int?) {
    guard let delay else {
      label = "No delay"
      tone = .unavailable
      return
    }

    label = "\(delay) ms"
    tone = ProxyDelayTone(delay: delay)
  }
}

enum ProxyDelayTone: Equatable {
  case unavailable
  case fast
  case good
  case moderate
  case slow

  init(delay: Int) {
    switch delay {
    case ...100:
      self = .fast
    case 101...150:
      self = .good
    case 151...250:
      self = .moderate
    default:
      self = .slow
    }
  }

  var color: Color {
    switch self {
    case .unavailable:
      return .secondary
    case .fast:
      return .green
    case .good:
      return .mint
    case .moderate:
      return .yellow
    case .slow:
      return .red
    }
  }
}

enum ProxyPreviewNoticeKind: Equatable {
  case previewRuntime
  case offlinePreview

  static func resolve(
    developerMode: Bool,
    previewRuntimeActive: Bool,
    isShowingProxyPreview: Bool
  ) -> ProxyPreviewNoticeKind? {
    guard developerMode else { return nil }
    if previewRuntimeActive { return .previewRuntime }
    if isShowingProxyPreview { return .offlinePreview }
    return nil
  }

  var icon: String {
    switch self {
    case .previewRuntime:
      return "wand.and.stars"
    case .offlinePreview:
      return "info.circle"
    }
  }

  var message: String {
    switch self {
    case .previewRuntime:
      return "Preview core is running on loopback for delay testing. Hit Start on Home to redirect traffic."
    case .offlinePreview:
      return "Pick a node and we'll remember it. Tests start a quiet preview core automatically."
    }
  }
}

enum ProxiesPageActionState {
  static func canStart(isRunning: Bool, hasActiveProfile: Bool, isStarting: Bool, readinessIssue: String?) -> Bool {
    !isRunning && hasActiveProfile && !isStarting && readinessIssue == nil
  }

  static func canRefresh(isStarting: Bool) -> Bool {
    !isStarting
  }
}

private struct ProxyPreviewNotice: View {
  let icon: String
  let message: String

  var body: some View {
    Label(message, systemImage: icon)
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ProxySurface.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(ProxySurface.border, lineWidth: 1)
      }
  }
}
