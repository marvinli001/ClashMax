import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel
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

          if !appModel.proxyProviders.isEmpty {
            ProxyProviderList(providers: appModel.proxyProviders)
          }

          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(groups) { group in
                ProxyGroupCard(
                  group: group,
                  isExpanded: visibleExpandedGroupIDs.contains(group.id),
                  isSearchActive: !searchQuery.isEmpty
                ) {
                  toggleExpansion(for: group, visibleGroups: groups)
                }
              }
            }
            .padding(.vertical, 2)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
    .onChange(of: appModel.visibleProxyGroups.map(\.id)) { _, _ in
      expandedGroupIDs = ProxyGroupExpansionPolicy.retainedExpansion(
        current: expandedGroupIDs,
        groups: appModel.visibleProxyGroups
      )
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
    expandedGroupIDs = ProxyGroupExpansionPolicy.toggled(groupID: group.id, in: currentExpansion)
  }
}

private enum ProxyNodeSort: String, CaseIterable, Identifiable {
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
            if appModel.providerHealthChecksInFlight.contains(provider.id) {
              Image(systemName: "clock.arrow.circlepath")
            } else {
              Image(systemName: "waveform.path.ecg")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || appModel.providerHealthChecksInFlight.contains(provider.id))
          .help("Run provider health check")
          .accessibilityLabel("Run health check for \(provider.name)")
        }
        .padding(.vertical, 4)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func providerSubtitle(_ provider: ProxyProvider) -> String {
    let vehicle = provider.vehicleType.map { " \($0)" } ?? ""
    return "\(provider.type)\(vehicle) - \(provider.proxies.count) nodes"
  }
}

private struct ProxyGroupCard: View {
  let group: ProxyGroup
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
      .help(isSearchActive ? "Search results expand matching groups automatically." : "Toggle \(group.name)")
      .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(group.name)")

      if isExpanded {
        Divider()
          .padding(.horizontal, 12)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 10, alignment: .topLeading)],
          alignment: .leading,
          spacing: 10
        ) {
          ForEach(group.nodes) { node in
            ProxyNodeCard(group: group, node: node)
          }
        }
        .padding(12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.primary.opacity(0.08))
    }
  }

  private var groupHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 12)

      Image(systemName: "point.3.connected.trianglepath.dotted")
        .foregroundStyle(.cyan)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(group.name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          ProxyTypeBadge(text: group.type)
        }

        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            nodeCountLabel
            selectedLabel
          }

          VStack(alignment: .leading, spacing: 3) {
            nodeCountLabel
            selectedLabel
          }
        }
      }

      Spacer(minLength: 12)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
}

private struct ProxyNodeCard: View {
  @EnvironmentObject private var appModel: AppModel
  let group: ProxyGroup
  let node: ProxyNode

  var body: some View {
    let canSelect = node.isSelectable && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let canTest = node.isSelectable && appModel.canControlRuntimeProxies
    let delayDisplay = ProxyDelayDisplay(delay: node.delay)
    let isSelected = group.selected == node.name

    ZStack(alignment: .topTrailing) {
      Button {
        appModel.selectProxy(group: group, node: node)
      } label: {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(isSelected ? .green : .secondary)
              .frame(width: 16)

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
            Label(delayDisplay.label, systemImage: "speedometer")
              .font(.caption.monospacedDigit())
              .foregroundStyle(delayDisplay.tone.color)
              .lineLimit(1)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .disabled(!canSelect)
      .help(canSelect ? "Select \(node.name)" : appModel.proxyRuntimeActionMessage)

      Button {
        appModel.testDelay(for: node)
      } label: {
        Image(systemName: "speedometer")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .disabled(!canTest)
      .help(canTest ? "Test delay" : "Preview core needs a moment to come up before delay testing.")
      .accessibilityLabel("Test delay for \(node.name)")
      .padding(6)
    }
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(isSelected ? .green.opacity(0.75) : .primary.opacity(0.08), lineWidth: isSelected ? 1.2 : 1)
    }
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
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
