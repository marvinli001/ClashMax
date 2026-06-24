import AppKit
import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var searchCoordinator = ProxySearchCoordinator()
  @State private var searchText = ""
  @State private var expandedGroupIDs: Set<String>?
  @State private var selectedGroupID: ProxyGroup.ID?
  @State private var showsBatchFailureDetails = false

  var body: some View {
    let pageSettings = appModel.proxyPageSettings
    // Raw groups are cheap to read and `ResolvedProxyCatalog` preserves group identity 1:1, so the
    // skeleton / empty-state gates use the raw count instead of resolving on the main thread.
    let rawGroups = appModel.visibleProxyGroups
    // The heavy resolve/sort/filter happens off-main in the coordinator; the body just reads the
    // most recently published snapshot.
    let snapshot = searchCoordinator.snapshot
    let groups = snapshot.filteredGroups
    let searchQuery = snapshot.query
    let dataSignature = ProxySearchInputSignature(groups: rawGroups, providers: runtimeData.proxyProviders)
    let visibleExpandedGroupIDs = ProxyGroupExpansionPolicy.resolvedExpansion(
      current: expandedGroupIDs,
      groups: groups,
      searchQuery: searchQuery.rawValue
    )
    let listAnimationState = ProxyGroupListAnimationState(
      groups: groups,
      expandedGroupIDs: visibleExpandedGroupIDs,
      searchQuery: searchQuery.rawValue,
      sortOrder: pageSettings.sortOrder
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
      testAllButton
      if !appModel.isRunning, appModel.profileStore.activeProfile != nil {
        Button {
          appModel.start()
        } label: {
          Label(
            localizedProxiesText(isStarting ? "Starting" : "Start"),
            systemImage: isStarting ? "clock.arrow.circlepath" : "play.fill"
          )
        }
        .disabled(!canStart)
      }
      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label(localizedProxiesText("Refresh"), systemImage: "arrow.clockwise")
      }
      .disabled(!ProxiesPageActionState.canRefresh(isStarting: isStarting))
    } content: {
      if showsLoadingSkeleton(rawGroupCount: rawGroups.count) {
        ScrollView {
          ClashMaxProxyGroupSkeletonList(groupCount: 3)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      } else if showsEmptyState(rawGroups: rawGroups, snapshot: snapshot) {
        CenteredUnavailableState(
          title: emptyStateTitle(rawGroups: rawGroups, searchQuery: searchQuery),
          systemImage: "point.3.connected.trianglepath.dotted",
          message: emptyStateMessage(rawGroups: rawGroups, searchQuery: searchQuery)
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          proxyWorkspace(
            groups: groups,
            searchQuery: searchQuery,
            visibleExpandedGroupIDs: visibleExpandedGroupIDs,
            listAnimationState: listAnimationState
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .task {
      // First population: build the snapshot off-main so the initial paint of a large config
      // doesn't block the main thread.
      searchCoordinator.submit(makeSearchInput(searchText: searchText), reason: .initial)
    }
    .onAppear {
      selectDefaultGroupIfNeeded(from: groups)
    }
    .onChange(of: searchText) { _, newValue in
      searchCoordinator.submit(makeSearchInput(searchText: newValue), reason: .searchText)
    }
    .onChange(of: pageSettings.sortOrder) { _, _ in
      searchCoordinator.submit(makeSearchInput(searchText: searchText), reason: .sort)
    }
    .onChange(of: dataSignature) { _, _ in
      searchCoordinator.submit(makeSearchInput(searchText: searchText), reason: .data)
    }
    .onChange(of: snapshot.resultIdentity) { _, _ in
      selectDefaultGroupIfNeeded(from: groups)
      withAnimation(ProxyInteractionAnimation.list(reduceMotion: reduceMotion)) {
        expandedGroupIDs = ProxyGroupExpansionPolicy.retainedExpansion(
          current: expandedGroupIDs,
          groups: groups
        )
      }
    }
  }

  private func makeSearchInput(searchText: String) -> ProxySearchPipeline.Input {
    // Shares the dashboard's data source so both pages resolve provider-backed members identically.
    appModel.proxySearchInput(searchText: searchText)
  }

  private func showsLoadingSkeleton(rawGroupCount: Int) -> Bool {
    ProxyPageVisibilityPolicy.showsLoadingSkeleton(
      unfilteredGroupCount: rawGroupCount,
      hasActiveProfile: appModel.profileStore.activeProfile != nil,
      isRuntimeDataLoading: appModel.runtimeDataLoading,
      isStarting: appModel.dashboardRuntimeState.isStarting
    )
  }

  /// Show the empty-state only once the pipeline has actually resolved and produced no matches, so a
  /// large config doesn't flash "No proxy groups" during the first off-main computation.
  private func showsEmptyState(rawGroups: [ProxyGroup], snapshot: ProxySearchSnapshot) -> Bool {
    if rawGroups.isEmpty { return true }
    return snapshot.hasResolved && snapshot.filteredGroups.isEmpty
  }

  private func subtitle(for groups: [ProxyGroup]) -> String {
    if groups.isEmpty {
      return String(localized: "Proxy groups load from the active profile and runtime.")
    }
    let count = groups.count
    if appModel.previewRuntimeActive {
      if count == 1 {
        return String(localized: "1 group · preview core")
      }
      return localizedProxiesCount("%lld groups · preview core", count)
    }
    if appModel.isShowingProxyPreview {
      if count == 1 {
        return String(localized: "1 preview group")
      }
      return localizedProxiesCount("%lld preview groups", count)
    }
    if count == 1 {
      return String(localized: "1 group")
    }
    return localizedProxiesCount("%lld groups", count)
  }

  private func proxyWorkspace(
    groups: [ProxyGroup],
    searchQuery: ProxySearchQuery,
    visibleExpandedGroupIDs: Set<String>,
    listAnimationState: ProxyGroupListAnimationState
  ) -> some View {
    ProxyWorkspaceSurface {
      proxyWorkspaceControls
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if let progress = appModel.proxyDelayBatchProgress {
        Divider()
        ProxyDelayBatchProgressStrip(
          progress: progress,
          showsFailureDetails: $showsBatchFailureDetails
        ) {
          appModel.cancelProxyDelayBatch()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
      }

      if let notice = ProxyPreviewNoticeKind.resolve(
        developerMode: appModel.developerMode,
        previewRuntimeActive: appModel.previewRuntimeActive,
        isShowingProxyPreview: appModel.isShowingProxyPreview
      ) {
        Divider()
        ProxyPreviewNotice(icon: notice.icon, message: notice.message)
      }

      if ProxyPageVisibilityPolicy.showsProviderSummary(
        developerMode: appModel.developerMode,
        providerCount: runtimeData.proxyProviders.count
      ) {
        Divider()
        ProxyProviderList(providers: runtimeData.proxyProviders)
          .padding(10)
      }

      Divider()

      if appModel.proxyPageSettings.viewMode == .allGroups {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
              ProxyGroupCard(
                group: group,
                customDelayTestURL: appModel.customDelayTestURL(forGroupName: group.name),
                showsDeveloperDetails: appModel.developerMode || appModel.proxyPageSettings.showsNodeDetails,
                closesOldConnectionsAfterSwitch: appModel.proxyPageSettings.closesOldConnectionsAfterSwitch,
                isExpanded: visibleExpandedGroupIDs.contains(group.id),
                isSearchActive: !searchQuery.isEmpty
              ) {
                toggleExpansion(for: group, visibleGroups: groups, searchQuery: searchQuery)
              }
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .animation(ProxyInteractionAnimation.list(reduceMotion: reduceMotion), value: listAnimationState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ProxyGroupSplitView(
          groups: groups,
          selectedGroupID: $selectedGroupID,
          nodePresentation: appModel.proxyPageSettings.nodePresentation,
          showsNodeDetails: appModel.proxyPageSettings.showsNodeDetails,
          closesOldConnectionsAfterSwitch: appModel.proxyPageSettings.closesOldConnectionsAfterSwitch,
          customDelayTestURLText: customDelayTestURLBinding(for: selectedGroupID)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }

  private var proxyWorkspaceControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        searchField
        proxyWorkspaceControlStrip
        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 8) {
        searchField
        ViewThatFits(in: .horizontal) {
          proxyWorkspaceControlStrip
          splitProxyWorkspaceControlStrip
        }
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      TextField("Search", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 180, idealWidth: 260, maxWidth: 340)
      if ProxySearchActivityPolicy.showsSearchProgress(
        searchText: searchText,
        isComputing: searchCoordinator.isComputing
      ) {
        ProgressView()
          .controlSize(.small)
          .help("Updating search results…")
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: searchCoordinator.isComputing)
  }

  private var proxyWorkspaceControlStrip: some View {
    HStack(spacing: 10) {
      viewModePicker
      sortPicker
      nodePresentationPicker
      nodeDetailsButton
      closeOldConnectionsToggle
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var splitProxyWorkspaceControlStrip: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        viewModePicker
        sortPicker
        nodePresentationPicker
      }
      HStack(spacing: 10) {
        nodeDetailsButton
        closeOldConnectionsToggle
      }
    }
  }

  private var testAllButton: some View {
    Button {
      appModel.testDelayForAllProxyGroups()
    } label: {
      Label("Test All", systemImage: "waveform.path.ecg")
    }
    .disabled(!appModel.canControlRuntimeProxies || appModel.visibleProxyGroups.isEmpty || appModel.isProxyDelayBatchRunning)
    .help("Test delay for every selectable node")
  }

  private var nodeDetailsButton: some View {
    Button {
      appModel.updateProxyPageSettings { settings in
        settings.showsNodeDetails.toggle()
      }
    } label: {
      Image(
        systemName: appModel.proxyPageSettings.showsNodeDetails
          ? "list.bullet.rectangle.portrait.fill"
          : "list.bullet.rectangle.portrait"
      )
    }
    .buttonStyle(.borderless)
    .help(appModel.proxyPageSettings.showsNodeDetails ? "Hide node details" : "Show node details")
  }

  private var closeOldConnectionsToggle: some View {
    Toggle(isOn: closeOldConnectionsBinding) {
      Label("Close Old", systemImage: "xmark.circle")
    }
    .toggleStyle(.checkbox)
    .fixedSize(horizontal: true, vertical: false)
    .help("After switching nodes, close active connections whose chain contains the previous selected node.")
  }

  private var viewModePicker: some View {
    Picker("View", selection: viewModeBinding) {
      ForEach(ProxyPageViewMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 190)
  }

  private var sortPicker: some View {
    Picker("Sort", selection: sortOrderBinding) {
      ForEach(ProxyNodeSort.allCases) { order in
        Text(order.displayName).tag(order)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
  }

  private var nodePresentationPicker: some View {
    Picker("Layout", selection: nodePresentationBinding) {
      ForEach(ProxyNodePresentation.allCases) { presentation in
        Image(systemName: presentation.systemImage).tag(presentation)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 88)
    .fixedSize(horizontal: true, vertical: false)
    .help("Switch node layout")
  }

  private var viewModeBinding: Binding<ProxyPageViewMode> {
    Binding(
      get: { appModel.proxyPageSettings.viewMode },
      set: { value in
        appModel.updateProxyPageSettings { settings in
          settings.viewMode = value
        }
      }
    )
  }

  private var sortOrderBinding: Binding<ProxyNodeSort> {
    Binding(
      get: { appModel.proxyPageSettings.sortOrder },
      set: { value in
        appModel.updateProxyPageSettings { settings in
          settings.sortOrder = value
        }
      }
    )
  }

  private var nodePresentationBinding: Binding<ProxyNodePresentation> {
    Binding(
      get: { appModel.proxyPageSettings.nodePresentation },
      set: { value in
        appModel.updateProxyPageSettings { settings in
          settings.nodePresentation = value
        }
      }
    )
  }

  private var closeOldConnectionsBinding: Binding<Bool> {
    Binding(
      get: { appModel.proxyPageSettings.closesOldConnectionsAfterSwitch },
      set: { value in
        appModel.updateProxyPageSettings { settings in
          settings.closesOldConnectionsAfterSwitch = value
        }
      }
    )
  }

  private func emptyStateTitle(rawGroups: [ProxyGroup], searchQuery: ProxySearchQuery) -> String {
    if !searchQuery.isEmpty, !rawGroups.isEmpty {
      return String(localized: "No matching proxies")
    }
    return String(localized: "No proxy groups")
  }

  private func emptyStateMessage(rawGroups: [ProxyGroup], searchQuery: ProxySearchQuery) -> String {
    if !searchQuery.isEmpty, !rawGroups.isEmpty {
      return String(localized: "No proxy groups match the current search.")
    }
    return appModel.proxyGroupsUnavailableMessage
  }

  private func selectDefaultGroupIfNeeded(from groups: [ProxyGroup]) {
    let resolved = ProxyGroupSelectionPolicy.resolvedSelection(current: selectedGroupID, groups: groups)
    // Only write when it actually changes, so keeping a still-valid selection doesn't churn @State.
    if resolved != selectedGroupID {
      selectedGroupID = resolved
    }
  }

  private func customDelayTestURLBinding(for groupID: ProxyGroup.ID?) -> Binding<String> {
    Binding(
      get: {
        guard let groupID else { return "" }
        return appModel.proxyPageSettings.customDelayTestURLText(forGroupName: groupID)
      },
      set: { value in
        guard let groupID else { return }
        appModel.updateProxyPageSettings { settings in
          settings.setCustomDelayTestURLText(value, forGroupName: groupID)
        }
      }
    )
  }

  private func toggleExpansion(for group: ProxyGroup, visibleGroups: [ProxyGroup], searchQuery: ProxySearchQuery) {
    guard searchQuery.isEmpty else { return }
    let currentExpansion = ProxyGroupExpansionPolicy.resolvedExpansion(
      current: expandedGroupIDs,
      groups: visibleGroups,
      searchQuery: searchQuery.rawValue
    )
    withAnimation(ProxyInteractionAnimation.expansion(reduceMotion: reduceMotion)) {
      expandedGroupIDs = ProxyGroupExpansionPolicy.toggled(groupID: group.id, in: currentExpansion)
    }
  }
}

private func localizedProxiesText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private func localizedProxiesCount(_ formatKey: String, _ count: Int) -> String {
  String.localizedStringWithFormat(NSLocalizedString(formatKey, comment: ""), Int64(count))
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

  static func showsLoadingSkeleton(
    unfilteredGroupCount: Int,
    hasActiveProfile: Bool,
    isRuntimeDataLoading: Bool,
    isStarting: Bool
  ) -> Bool {
    unfilteredGroupCount == 0 && hasActiveProfile && (isRuntimeDataLoading || isStarting)
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

enum ProxyNodeSorter {
  /// Orders the nodes inside a single proxy group for display.
  ///
  /// `.profile` keeps the incoming order untouched so the configured member order
  /// (preview groups or Mihomo's `all` array) is preserved. The remaining modes
  /// apply the user's explicit manual ordering.
  static func sorted(_ nodes: [ProxyNode], by sortOrder: ProxyNodeSort) -> [ProxyNode] {
    switch sortOrder {
    case .profile:
      return nodes
    case .name:
      return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    case .delay:
      return nodes.sorted {
        let first = $0.resolvedDelayState.measuredDelay ?? Int.max
        let second = $1.resolvedDelayState.measuredDelay ?? Int.max
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
}

/// Resolves the split view's selected group against the *currently displayed* groups (issue #9).
///
/// A search or a runtime reload can drop the previously-selected group from the displayed set (e.g.
/// searching "韩国" filters out a group with no Korea nodes). When that happens the right pane must
/// re-point at a group that is actually present instead of rendering a stale/empty list. Pure and
/// `@State`-free so it can be unit-tested.
enum ProxyGroupSelectionPolicy {
  static func resolvedSelection(current: ProxyGroup.ID?, groups: [ProxyGroup]) -> ProxyGroup.ID? {
    guard !groups.isEmpty else { return nil }
    if let current, groups.contains(where: { $0.id == current }) {
      return current
    }
    return groups.first(where: { $0.selected != nil })?.id ?? groups.first?.id
  }
}

struct ProxyGroupSearchFilter {
  static func filteredGroups(from groups: [ProxyGroup], searchQuery: ProxySearchQuery) -> [ProxyGroup] {
    guard !searchQuery.isEmpty else { return groups }
    return groups.compactMap { group in
      var group = group
      group.nodes = group.nodes.filter { node in
        searchQuery.matches(group: group, node: node)
      }
      return group.nodes.isEmpty ? nil : group
    }
  }
}

struct ProxySearchQuery: Equatable, Sendable {
  let rawValue: String
  private let terms: [String]
  private let isCaseSensitive: Bool
  private let isWholeWord: Bool

  init(rawValue: String) {
    self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var parsedTerms: [String] = []
    var parsedCaseSensitive = false
    var parsedWholeWord = false
    for term in self.rawValue.split(whereSeparator: \.isWhitespace).map(String.init) {
      switch term.lowercased() {
      case "case=true", "case=yes", "case=on", "case-sensitive=true", "cs=true":
        parsedCaseSensitive = true
      case "word=true", "word=yes", "word=on", "whole=true", "whole-word=true":
        parsedWholeWord = true
      default:
        parsedTerms.append(term)
      }
    }
    self.terms = parsedTerms
    self.isCaseSensitive = parsedCaseSensitive
    self.isWholeWord = parsedWholeWord
  }

  var isEmpty: Bool {
    terms.isEmpty
  }

  func matches(group: ProxyGroup, node: ProxyNode) -> Bool {
    terms.allSatisfy { term in
      matches(term: term, group: group, node: node)
    }
  }

  private func matches(term: String, group: ProxyGroup, node: ProxyNode) -> Bool {
    let normalized = term.lowercased()
    if normalized.hasPrefix("type=") {
      return contains(node.type, value(after: "type=", in: term))
    }
    if normalized.hasPrefix("provider=") {
      return contains(node.providerName ?? "", value(after: "provider=", in: term))
    }
    if normalized.hasPrefix("selected=") {
      let wantsSelected = value(after: "selected=", in: term).lowercased() == "true"
      return (group.selected == node.name) == wantsSelected
    }
    if normalized.hasPrefix("delay=") {
      return delayEquals(value(after: "delay=", in: term), state: node.resolvedDelayState)
    }
    if let comparison = delayComparison(from: term) {
      return matchesDelayComparison(comparison, state: node.resolvedDelayState)
    }
    if normalized.hasPrefix("regex=") {
      return matchesRegex(value(after: "regex=", in: term), group: group, node: node)
    }
    if term.hasPrefix("/"), term.hasSuffix("/"), term.count > 2 {
      let pattern = String(term.dropFirst().dropLast())
      return matchesRegex(pattern, group: group, node: node)
    }
    return contains(searchableText(group: group, node: node), term)
  }

  private func contains(_ text: String, _ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    if isWholeWord {
      return matchesWholeWord(query, in: text)
    }
    if isCaseSensitive {
      return text.contains(query)
    }
    return text.localizedCaseInsensitiveContains(query)
  }

  private func searchableText(group: ProxyGroup, node: ProxyNode) -> String {
    // Issue #9: `group.selected` is the *currently-picked* node's name and is identical for every
    // node in the group, so folding it in here made a free-text query match the whole group whenever
    // the picked node matched (e.g. searching "韩国" with a Korea node selected returned all 1600+
    // nodes). Selection is queryable only through the explicit `selected=true/false` token, which
    // compares `group.selected` to each node individually and is handled before we reach this text.
    [
      group.name,
      group.type,
      node.name,
      node.type,
      node.providerName,
      node.endpointSummary
    ]
    .compactMap { $0 }
    .joined(separator: " ")
  }

  private func value(after prefix: String, in term: String) -> String {
    String(term.dropFirst(prefix.count))
  }

  private func delayEquals(_ value: String, state: ProxyDelayState) -> Bool {
    switch value.lowercased() {
    case "unknown":
      return state == .unknown
    case "testing":
      return state == .testing
    case "timeout":
      return state == .timeout
    case "error":
      if case .error = state { return true }
      return false
    default:
      guard let expected = Int(value), let delay = state.measuredDelay else { return false }
      return delay == expected
    }
  }

  private func delayComparison(from term: String) -> (operatorText: String, value: Int)? {
    let operators = ["<=", ">=", "<", ">"]
    for operatorText in operators {
      let prefix = "delay\(operatorText)"
      guard term.lowercased().hasPrefix(prefix),
            let value = Int(String(term.dropFirst(prefix.count)))
      else { continue }
      return (operatorText, value)
    }
    return nil
  }

  private func matchesDelayComparison(_ comparison: (operatorText: String, value: Int), state: ProxyDelayState) -> Bool {
    guard let delay = state.measuredDelay else { return false }
    switch comparison.operatorText {
    case "<": return delay < comparison.value
    case "<=": return delay <= comparison.value
    case ">": return delay > comparison.value
    case ">=": return delay >= comparison.value
    default: return false
    }
  }

  private func matchesRegex(_ pattern: String, group: ProxyGroup, node: ProxyNode) -> Bool {
    let text = searchableText(group: group, node: node)
    let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return false
    }
    return regex.firstMatch(
      in: text,
      range: NSRange(text.startIndex..<text.endIndex, in: text)
    ) != nil
  }

  private func matchesWholeWord(_ query: String, in text: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: query)
    let pattern = #"\b"# + escaped + #"\b"#
    let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return false
    }
    return regex.firstMatch(
      in: text,
      range: NSRange(text.startIndex..<text.endIndex, in: text)
    ) != nil
  }
}

private struct ProxyWorkspaceSurface<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.cardSurface, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(.separator, lineWidth: 1))
  }
}

private struct ProxyGroupSplitView: View {
  @Binding var selectedGroupID: ProxyGroup.ID?
  let groups: [ProxyGroup]
  let nodePresentation: ProxyNodePresentation
  let showsNodeDetails: Bool
  let closesOldConnectionsAfterSwitch: Bool
  @Binding var customDelayTestURLText: String

  init(
    groups: [ProxyGroup],
    selectedGroupID: Binding<ProxyGroup.ID?>,
    nodePresentation: ProxyNodePresentation,
    showsNodeDetails: Bool,
    closesOldConnectionsAfterSwitch: Bool,
    customDelayTestURLText: Binding<String>
  ) {
    self.groups = groups
    self._selectedGroupID = selectedGroupID
    self.nodePresentation = nodePresentation
    self.showsNodeDetails = showsNodeDetails
    self.closesOldConnectionsAfterSwitch = closesOldConnectionsAfterSwitch
    self._customDelayTestURLText = customDelayTestURLText
  }

  var body: some View {
    HStack(spacing: 0) {
      ProxyGroupNavigator(groups: groups, selectedGroupID: $selectedGroupID)
        .frame(minWidth: 180, idealWidth: 208, maxWidth: 240)

      Divider()

      if let selectedGroup {
        ProxyGroupDetailPane(
          group: selectedGroup,
          nodePresentation: nodePresentation,
          showsNodeDetails: showsNodeDetails,
          closesOldConnectionsAfterSwitch: closesOldConnectionsAfterSwitch,
          customDelayTestURLText: $customDelayTestURLText
        )
      } else {
        CenteredUnavailableState(
          title: "No group selected",
          systemImage: "point.3.connected.trianglepath.dotted",
          message: "Select a proxy group to inspect nodes."
        )
      }
    }
  }

  private var selectedGroup: ProxyGroup? {
    if let selectedGroupID,
       let group = groups.first(where: { $0.id == selectedGroupID }) {
      return group
    }
    return groups.first
  }
}

private struct ProxyGroupNavigator: View {
  let groups: [ProxyGroup]
  @Binding var selectedGroupID: ProxyGroup.ID?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(groups) { group in
          Button {
            selectedGroupID = group.id
          } label: {
            ProxyGroupNavigatorRow(group: group, isSelected: isSelected(group))
          }
          .buttonStyle(.plain)
          .help("Show \(group.name)")
          .accessibilityLabel(group.name)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(.cardSurface)
  }

  private func isSelected(_ group: ProxyGroup) -> Bool {
    if let selectedGroupID {
      return group.id == selectedGroupID
    }
    return group.id == groups.first?.id
  }
}

private struct ProxyGroupNavigatorRow: View {
  let group: ProxyGroup
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: group.allowsManualProxySelection ? "point.3.connected.trianglepath.dotted" : "gearshape.2")
        .foregroundStyle(iconStyle)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .foregroundStyle(isSelected ? .white : .primary)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isSelected ? Color.accentColor : .clear)
    }
  }

  private var subtitle: String {
    let selected = group.selected ?? "No selection"
    let best = group.nodes.compactMap { $0.resolvedDelayState.measuredDelay }.min()
    if let best {
      return "\(group.nodes.count) nodes - \(selected) - best \(best) ms"
    }
    return "\(group.nodes.count) nodes - \(selected)"
  }

  private var iconStyle: Color {
    if isSelected {
      return .white
    }
    return group.allowsManualProxySelection ? .cyan : .secondary
  }
}

private struct ProxyGroupDetailPane: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var scrollToSelectedRequest = 0
  let group: ProxyGroup
  let nodePresentation: ProxyNodePresentation
  let showsNodeDetails: Bool
  let closesOldConnectionsAfterSwitch: Bool
  @Binding var customDelayTestURLText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      detailToolbar
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          if nodePresentation == .grid {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 10, alignment: .topLeading)],
              alignment: .leading,
              spacing: 10
            ) {
              nodeCards
            }
            .padding(10)
          } else {
            LazyVStack(alignment: .leading, spacing: 8) {
              nodeCards
            }
            .padding(10)
          }
        }
        .onChange(of: scrollToSelectedRequest) { _, _ in
          if let selectedNodeID {
            withAnimation(.snappy(duration: 0.22)) {
              proxy.scrollTo(selectedNodeID, anchor: .center)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var nodeCards: some View {
    ForEach(group.nodes) { node in
      ProxyNodeCard(
        group: group,
        node: node,
        customDelayTestURL: parsedCustomDelayTestURL,
        showsDetails: showsNodeDetails,
        closesOldConnectionsAfterSwitch: closesOldConnectionsAfterSwitch
      )
      .id(node.id)
    }
  }

  private var detailToolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        groupSummary
        Spacer(minLength: 12)
        customDelayURLControl
        detailActions
      }

      VStack(alignment: .leading, spacing: 8) {
        groupSummary
        HStack(spacing: 10) {
          customDelayURLControl
          detailActions
        }
      }
    }
  }

  private var groupSummary: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(group.name)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        ProxyTypeBadge(text: group.type)
      }
      Text("\(group.nodes.count) nodes")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var customDelayURLControl: some View {
    VStack(alignment: .leading, spacing: 3) {
      TextField("Custom delay URL", text: $customDelayTestURLText)
        .textFieldStyle(.roundedBorder)
        .help("Optional URL for this group's Mihomo delay test")
      if hasInvalidCustomDelayTestURL {
        Text("Invalid custom delay URL. Falling back to default delay URL.")
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(1)
      }
    }
    .frame(minWidth: 180, idealWidth: 250, maxWidth: 320)
  }

  private var detailActions: some View {
    HStack(spacing: 8) {
      Button {
        scrollToSelectedRequest += 1
      } label: {
        Image(systemName: "scope")
      }
      .disabled(selectedNodeID == nil)
      .help("Locate selected node")

      Button {
        appModel.testDelay(in: group, testURL: parsedCustomDelayTestURL)
      } label: {
        Label("Test Group", systemImage: "waveform.path.ecg")
          .labelStyle(.titleAndIcon)
      }
      .disabled(
        !appModel.canControlRuntimeProxies
          || !group.nodes.contains(where: \.isSelectable)
          || appModel.isProxyDelayBatchRunning
      )
      .help("Test delay for this group")

      Button {
        appModel.toggleMenuBarPinnedGroup(group)
      } label: {
        Image(systemName: appModel.menuBarPinnedGroupSettings.contains(group.name) ? "pin.fill" : "pin")
      }
      .help(appModel.menuBarPinnedGroupSettings.contains(group.name) ? "Unpin from menu bar" : "Pin to menu bar")
    }
  }

  private var selectedNodeID: ProxyNode.ID? {
    group.nodes.first(where: { $0.name == group.selected })?.id
  }

  private var parsedCustomDelayTestURL: URL? {
    appModel.customDelayTestURL(forGroupName: group.name)
  }

  private var hasInvalidCustomDelayTestURL: Bool {
    appModel.proxyPageSettings.hasInvalidCustomDelayTestURL(forGroupName: group.name)
  }
}

private struct ProxyDelayBatchProgressStrip: View {
  let progress: ProxyDelayBatchProgress
  @Binding var showsFailureDetails: Bool
  let onCancel: () -> Void
  @State private var diagnosticsCopiedAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          leadingStatus
          ProgressView(value: progress.progressFraction)
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 260)
          metrics
          Spacer(minLength: 8)
          cancelButton
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            leadingStatus
            Spacer(minLength: 8)
            cancelButton
          }
          ProgressView(value: progress.progressFraction)
          metrics
        }
      }

      if progress.hasFailures {
        failureToggle
        if showsFailureDetails {
          failureDetails
        }
      }
    }
  }

  private var leadingStatus: some View {
    Label(statusTitle, systemImage: statusIcon)
      .font(.caption.weight(.semibold))
      .foregroundStyle(statusColor)
      .lineLimit(1)
  }

  private var statusTitle: String {
    switch progress.status {
    case .running:
      return String(localized: "Batch delay testing")
    case .completed:
      return String(localized: "Batch delay complete")
    case .partiallyCompleted:
      return String(localized: "Batch delay partially completed")
    case .failed:
      return String(localized: "Batch delay failed")
    case .cancelled:
      return String(localized: "Batch delay cancelled")
    }
  }

  private var statusIcon: String {
    switch progress.status {
    case .running:
      return "waveform.path.ecg"
    case .completed:
      return "checkmark.circle"
    case .partiallyCompleted:
      return "exclamationmark.triangle"
    case .failed:
      return "xmark.octagon"
    case .cancelled:
      return "xmark.circle"
    }
  }

  private var statusColor: Color {
    switch progress.status {
    case .running, .completed:
      return .secondary
    case .partiallyCompleted, .cancelled:
      return .orange
    case .failed:
      return .red
    }
  }

  private var metrics: some View {
    HStack(spacing: 8) {
      ProxyDelayBatchMetric(
        text: String.localizedStringWithFormat(
          NSLocalizedString("%lld/%lld tested", comment: ""),
          Int64(progress.testedCount),
          Int64(progress.total)
        ),
        systemImage: "speedometer",
        color: .secondary
      )
      ProxyDelayBatchMetric(
        text: "\(progress.succeeded)",
        systemImage: "checkmark.circle.fill",
        color: .green
      )
      ProxyDelayBatchMetric(
        text: "\(progress.timedOut)",
        systemImage: ProxyDelayFailureKind.timeout.systemImage,
        color: .orange
      )
      ProxyDelayBatchMetric(
        text: "\(progress.failed)",
        systemImage: ProxyDelayFailureKind.other.systemImage,
        color: .red
      )
      if progress.cancelled > 0 {
        ProxyDelayBatchMetric(
          text: "\(progress.cancelled)",
          systemImage: ProxyDelayFailureKind.cancelled.systemImage,
          color: .orange
        )
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private var cancelButton: some View {
    if progress.isRunning {
      Button {
        onCancel()
      } label: {
        Label("Cancel", systemImage: "xmark.circle")
      }
      .controlSize(.small)
      .help("Cancel batch delay testing")
    }
  }

  private var failureToggle: some View {
    Button {
      showsFailureDetails.toggle()
    } label: {
      Label(
        showsFailureDetails ? "Hide Failures" : "Show Failures",
        systemImage: showsFailureDetails ? "chevron.down" : "chevron.right"
      )
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private var failureDetails: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(failureGroups) { group in
        failureCategoryRow(kind: group.kind, count: group.failures.count, failures: group.failures)
      }
      copyDiagnosticsButton
    }
    .padding(.leading, 2)
  }

  private var failureGroups: [ProxyDelayFailureGroup] {
    ProxyDelayFailureKind.allCases.compactMap { kind in
      let failures = progress.failures.filter { $0.kind == kind }
      guard !failures.isEmpty else { return nil }
      return ProxyDelayFailureGroup(kind: kind, failures: failures)
    }
  }

  private var copyDiagnosticsButton: some View {
    Button(action: copyDiagnostics) {
      Label(
        diagnosticsCopiedAt == nil ? "Copy Diagnostics" : "Diagnostics Copied",
        systemImage: diagnosticsCopiedAt == nil ? "doc.on.doc" : "checkmark"
      )
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.top, 2)
  }

  private func copyDiagnostics() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(progress.diagnosticText, forType: .string)
    let stamp = Date()
    diagnosticsCopiedAt = stamp
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      if diagnosticsCopiedAt == stamp {
        diagnosticsCopiedAt = nil
      }
    }
  }

  private func failureCategoryRow(
    kind: ProxyDelayFailureKind,
    count: Int,
    failures: [ProxyDelayBatchFailure]
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("\(kind.displayName) \(count)", systemImage: kind.systemImage)
        .font(.caption)
        .foregroundStyle(kind == .timeout || kind == .cancelled ? .orange : .red)
      ForEach(failures.prefix(3)) { failure in
        Text("\(failure.displayName): \(failure.message)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

private struct ProxyDelayFailureGroup: Identifiable {
  var kind: ProxyDelayFailureKind
  var failures: [ProxyDelayBatchFailure]

  var id: ProxyDelayFailureKind { kind }
}

private struct ProxyDelayBatchMetric: View {
  let text: String
  let systemImage: String
  let color: Color

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption.monospacedDigit())
      .foregroundStyle(color)
      .lineLimit(1)
  }
}

private struct ProxyProviderList: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  let providers: [ProxyProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label("Proxy Providers", systemImage: "shippingbox")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          appModel.updateAllProxyProviders()
        } label: {
          Label("Update All", systemImage: "arrow.clockwise")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .disabled(!appModel.canControlRuntimeProxies || providers.isEmpty || allUpdatesInFlight)
      }
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
            if let usage = provider.subscriptionInfo?.usageSummary {
              Text(usage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 12)
          if let expireAt = provider.subscriptionInfo?.expireAt {
            Text(expireAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let updatedAt = provider.updatedAt {
            Text(updatedAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button {
            appModel.updateProxyProvider(provider)
          } label: {
            if runtimeData.proxyProviderUpdatesInFlight.contains(provider.id) {
              Image(systemName: "clock.arrow.circlepath")
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || runtimeData.proxyProviderUpdatesInFlight.contains(provider.id))
          .help("Update provider")
          .accessibilityLabel("Update provider \(provider.name)")

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
    .background(.insetSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.separator, lineWidth: 1)
    }
  }

  private var allUpdatesInFlight: Bool {
    !providers.isEmpty && providers.allSatisfy { runtimeData.proxyProviderUpdatesInFlight.contains($0.id) }
  }

  private func providerSubtitle(_ provider: ProxyProvider) -> String {
    let vehicle = provider.vehicleType.map { " \($0)" } ?? ""
    return "\(provider.type)\(vehicle) - \(provider.proxies.count) nodes"
  }
}

private struct ProxyGroupCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let group: ProxyGroup
  let customDelayTestURL: URL?
  let showsDeveloperDetails: Bool
  let closesOldConnectionsAfterSwitch: Bool
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
    .background(.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.separator, lineWidth: 1)
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
          ProxyNodeCard(
            group: group,
            node: node,
            customDelayTestURL: customDelayTestURL,
            showsDetails: showsDeveloperDetails,
            closesOldConnectionsAfterSwitch: closesOldConnectionsAfterSwitch
          )
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
        let delayDisplay = ProxyDelayDisplay(state: selectedNode.resolvedDelayState)
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
  let customDelayTestURL: URL?
  let showsDetails: Bool
  let closesOldConnectionsAfterSwitch: Bool

  var body: some View {
    let canSelect = group.allowsManualProxySelection
      && node.isSelectable
      && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let canTest = node.isSelectable && appModel.canControlRuntimeProxies && !appModel.isProxyDelayBatchRunning
    let delayDisplay = ProxyDelayDisplay(state: node.resolvedDelayState)
    let isSelected = group.selected == node.name

    ZStack(alignment: .topTrailing) {
      Button {
        guard canSelect else { return }
        withAnimation(ProxyInteractionAnimation.selection(reduceMotion: reduceMotion)) {
          appModel.selectProxy(
            group: group,
            node: node,
            closeOldConnections: closesOldConnectionsAfterSwitch
          )
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

          ProxyNodeMetadataRow(node: node, delayDisplay: delayDisplay)

          if showsDetails, let endpoint = node.endpointSummary {
            Label(endpoint, systemImage: "network")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)
      .allowsHitTesting(canSelect)
      .help(selectionHelp(canSelect: canSelect))

      Button {
        appModel.testDelay(
          in: group,
          for: node,
          testURL: customDelayTestURL ?? appModel.customDelayTestURL(forGroupName: group.name)
        )
      } label: {
        DelayActionIcon(state: node.resolvedDelayState)
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
        .fill(.insetSurface)
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

  private func nodeBorder(isSelected: Bool, canSelect: Bool) -> AnyShapeStyle {
    if isSelected {
      return AnyShapeStyle(.green.opacity(0.75))
    }
    if canSelect, isPressing {
      return AnyShapeStyle(Color.accentColor.opacity(0.35))
    }
    return AnyShapeStyle(.separator)
  }

  private func pressGesture(isEnabled: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($isPressing) { _, state, _ in
        state = isEnabled
      }
  }
}

private struct ProxyNodeMetadataRow: View {
  let node: ProxyNode
  let delayDisplay: ProxyDelayDisplay

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        allBadges
        Spacer(minLength: 8)
        DelayChip(display: delayDisplay)
      }

      VStack(alignment: .leading, spacing: 6) {
        allBadges
        DelayChip(display: delayDisplay)
      }

      HStack(spacing: 8) {
        coreBadges
        Spacer(minLength: 8)
        DelayChip(display: delayDisplay)
      }

      DelayChip(display: delayDisplay)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var allBadges: some View {
    HStack(spacing: 8) {
      coreBadges
      ForEach(node.capabilityLabels, id: \.self) { label in
        ProxyTypeBadge(text: label, isSelectable: node.isSelectable)
      }
    }
  }

  private var coreBadges: some View {
    HStack(spacing: 8) {
      ProxyTypeBadge(text: node.type, isSelectable: node.isSelectable)
      if let providerName = node.providerName {
        ProxyTypeBadge(text: providerName, isSelectable: node.isSelectable)
      }
    }
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
    self.init(state: delay.map(ProxyDelayState.measured) ?? .unknown)
  }

  init(state: ProxyDelayState) {
    switch state {
    case .unknown:
      label = "Unknown"
      tone = .unavailable
    case .testing:
      label = "Testing"
      tone = .testing
    case let .measured(delay):
      label = "\(delay) ms"
      tone = ProxyDelayTone(delay: delay)
    case .timeout:
      label = "Timeout"
      tone = .timeout
    case .error:
      label = "Error"
      tone = .error
    }
  }
}

enum ProxyDelayTone: Equatable {
  case unavailable
  case testing
  case fast
  case good
  case moderate
  case slow
  case timeout
  case error

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
    case .testing:
      return .cyan
    case .fast:
      return .green
    case .good:
      return .mint
    case .moderate:
      return .yellow
    case .slow:
      return .red
    case .timeout:
      return .orange
    case .error:
      return .red
    }
  }
}

private struct DelayChip: View {
  let display: ProxyDelayDisplay

  var body: some View {
    Text(display.label)
      .font(.caption.monospacedDigit())
      .foregroundStyle(display.tone.color)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(display.tone.color.opacity(0.10), in: Capsule())
      .layoutPriority(10)
      .fixedSize(horizontal: true, vertical: false)
  }
}

private struct DelayActionIcon: View {
  let state: ProxyDelayState

  var body: some View {
    Group {
      if state == .testing {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.system(size: 13, weight: .medium))
      }
    }
    .frame(width: 20, height: 20)
  }
}

enum ProxyPreviewNoticeKind: Equatable {
  case previewRuntime
  case offlinePreview

  static func resolve(
    developerMode _: Bool,
    previewRuntimeActive: Bool,
    isShowingProxyPreview: Bool
  ) -> ProxyPreviewNoticeKind? {
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
      return String(localized: "Preview core is running on loopback for delay testing. Hit Start on Home to redirect traffic.")
    case .offlinePreview:
      return String(localized: "Pick a node and we'll remember it. Tests start a quiet preview core automatically.")
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
  }
}
