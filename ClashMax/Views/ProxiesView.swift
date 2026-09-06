import AppKit
import SwiftUI

/// Layout policy for the Proxies page, kept pure so it can be unit-tested.
enum ProxiesLayout {
  /// The group navigator is a fixed column: a group name plus its current node fit here, and the
  /// remaining width always belongs to the node list the page exists for.
  static let groupListWidth: CGFloat = 224
}

/// Keeps the browsing selection inside the node list pointed at a node that is still displayed.
/// A search, a sort change or a runtime reload can drop the previously selected node, and the
/// detail bar must then close instead of describing a node that is not in the list.
enum ProxyNodeSelectionPolicy {
  static func resolvedSelection(current: ProxyNode.ID?, nodes: [ProxyNode]) -> ProxyNode.ID? {
    guard let current, nodes.contains(where: { $0.id == current }) else { return nil }
    return current
  }
}

struct ProxiesView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // Owned by AppModel so the resolved snapshot survives tab switches; a fresh
  // per-page instance made every return to this page repaint from empty.
  private let searchCoordinator: ProxySearchCoordinator
  @State private var searchText = ""
  /// Browsing selection for the group navigator. Changing it never changes which node a group uses.
  @State private var selectedGroupID: ProxyGroup.ID?
  /// Browsing selection inside the node list. Using a node is a separate, explicit action.
  @State private var selectedNodeID: ProxyNode.ID?
  @State private var showsBatchFailureDetails = false
  @State private var customDelayURLPopoverPresented = false
  @State private var providersPopoverPresented = false
  @State private var scrollToCurrentNodeRequest = 0

  /// `initialSelectedGroupID` / `initialSelectedNodeID` seed the browsing selection for previews and
  /// fixture renders; the app always starts from the default selection.
  init(
    searchCoordinator: ProxySearchCoordinator,
    initialSelectedGroupID: ProxyGroup.ID? = nil,
    initialSelectedNodeID: ProxyNode.ID? = nil
  ) {
    self.searchCoordinator = searchCoordinator
    _selectedGroupID = State(initialValue: initialSelectedGroupID)
    _selectedNodeID = State(initialValue: initialSelectedNodeID)
  }

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
    let isStarting = appModel.dashboardRuntimeState.isStarting
    let selectedGroup = resolvedSelectedGroup(in: groups)
    let isDelayBatchRunning = appModel.proxyDelayBatchProgress?.isRunning == true

    AdaptivePage(title: "Proxies") {
      // The spinner's fade is scoped to this action bar on purpose. `isComputing` flips twice per
      // pipeline run (once on submit, once on publish) and a delay batch runs the pipeline on
      // every coalesced flush, so as a page-level modifier this put the *entire* Proxies tree into
      // a continuous 150ms interpolation.
      HStack(spacing: 8) {
        searchProgressIndicator
        testGroupButton(selectedGroup, isDelayBatchRunning: isDelayBatchRunning)
        sortMenu
        moreMenu(
          selectedGroup: selectedGroup,
          hasGroups: !rawGroups.isEmpty,
          isStarting: isStarting,
          isDelayBatchRunning: isDelayBatchRunning
        )
      }
      .animation(.easeInOut(duration: 0.15), value: searchCoordinator.isComputing)
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
        proxyWorkspace(
          groups: groups,
          selectedGroup: selectedGroup,
          isDelayBatchRunning: isDelayBatchRunning
        )
      }
    }
    .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search"))
    .task {
      // Returning to the page: the coordinator outlives the view, so restore the
      // search field from the retained snapshot instead of showing a filtered
      // list under an empty field.
      let retainedSearchText = searchCoordinator.snapshot.searchText
      if searchText.isEmpty, !retainedSearchText.isEmpty {
        searchText = retainedSearchText
      }
      // First population: build the snapshot off-main so the initial paint of a large config
      // doesn't block the main thread. On re-entry this recomputes with the same input and
      // the coordinator's equality gate publishes nothing, so the retained snapshot stays up.
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
      reconcileNodeSelection(in: resolvedSelectedGroup(in: groups))
    }
    .onChange(of: selectedGroupID) { _, _ in
      reconcileNodeSelection(in: resolvedSelectedGroup(in: groups))
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

  // MARK: - Workspace

  private func proxyWorkspace(
    groups: [ProxyGroup],
    selectedGroup: ProxyGroup?,
    isDelayBatchRunning: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let progress = appModel.proxyDelayBatchProgress {
        ProxyDelayBatchProgressStrip(
          progress: progress,
          showsFailureDetails: $showsBatchFailureDetails
        ) {
          appModel.cancelProxyDelayBatch()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        Divider()
      }

      if let notice = ProxyPreviewNoticeKind.resolve(
        developerMode: appModel.developerMode,
        previewRuntimeActive: appModel.previewRuntimeActive,
        isShowingProxyPreview: appModel.isShowingProxyPreview
      ) {
        ProxyPreviewNotice(icon: notice.icon, message: notice.message)
        Divider()
      }

      HStack(spacing: 0) {
        ProxyGroupNavigator(groups: groups, selectedGroupID: $selectedGroupID)
          .frame(width: ProxiesLayout.groupListWidth)

        Divider()

        if let selectedGroup {
          ProxyGroupNodePane(
            group: selectedGroup,
            selectedNodeID: $selectedNodeID,
            isDelayBatchRunning: isDelayBatchRunning,
            scrollToCurrentNodeRequest: scrollToCurrentNodeRequest
          )
        } else {
          CenteredUnavailableState(
            title: "No group selected",
            systemImage: "point.3.connected.trianglepath.dotted",
            message: "Select a proxy group to inspect nodes."
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.cardSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1))
  }

  @ViewBuilder
  private var searchProgressIndicator: some View {
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

  // MARK: - Page actions

  /// Testing the group the user is looking at is the everyday action; everything wider or rarer
  /// lives one level down in the More menu.
  private func testGroupButton(_ group: ProxyGroup?, isDelayBatchRunning: Bool) -> some View {
    Button {
      guard let group else { return }
      appModel.testDelay(in: group, testURL: appModel.customDelayTestURL(forGroupName: group.name))
    } label: {
      Label("Test Group", systemImage: "waveform.path.ecg")
    }
    .disabled(!canTestGroup(group, isDelayBatchRunning: isDelayBatchRunning))
    .help(group.map { String(format: String(localized: "Test delay for every node in %@"), $0.name) } ?? String(localized: "Test delay for this group"))
  }

  private func canTestGroup(_ group: ProxyGroup?, isDelayBatchRunning: Bool) -> Bool {
    guard let group else { return false }
    return appModel.canControlRuntimeProxies
      && group.nodes.contains { $0.isSelectable && $0.supportsDelayTesting }
      && !isDelayBatchRunning
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort", selection: sortOrderBinding) {
        ForEach(ProxyNodeSort.allCases) { order in
          Text(order.displayName).tag(order)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
    }
    .help("Sort nodes by profile order, name, delay, or type")
  }

  private func moreMenu(
    selectedGroup: ProxyGroup?,
    hasGroups: Bool,
    isStarting: Bool,
    isDelayBatchRunning: Bool
  ) -> some View {
    let isPinned = selectedGroup.map { appModel.menuBarPinnedGroupSettings.contains($0.name) } ?? false
    return Menu {
      Button {
        appModel.testDelayForAllProxyGroups()
      } label: {
        Label("Test All Groups", systemImage: "waveform.path.ecg.rectangle")
      }
      .disabled(!appModel.canControlRuntimeProxies || !hasGroups || isDelayBatchRunning)

      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(!ProxiesPageActionState.canRefresh(isStarting: isStarting))

      Divider()

      Button {
        scrollToCurrentNodeRequest += 1
      } label: {
        Label("Locate Current Node", systemImage: "scope")
      }
      .disabled(selectedGroup?.selected == nil)

      Button {
        if let selectedGroup {
          appModel.toggleMenuBarPinnedGroup(selectedGroup)
        }
      } label: {
        Label(isPinned ? "Unpin from Menu Bar" : "Pin to Menu Bar", systemImage: isPinned ? "pin.slash" : "pin")
      }
      .disabled(selectedGroup == nil)

      Button {
        customDelayURLPopoverPresented = true
      } label: {
        Label("Custom Delay URL…", systemImage: "link")
      }
      .disabled(selectedGroup == nil)

      if ProxyPageVisibilityPolicy.showsProviderSummary(
        developerMode: appModel.developerMode,
        providerCount: runtimeData.proxyProviders.count
      ) {
        Button {
          providersPopoverPresented = true
        } label: {
          Label("Proxy Providers…", systemImage: "shippingbox")
        }
      }

      Divider()

      // A preference with real consequences, kept exactly where it applies rather than as a
      // permanent checkbox in the header.
      Toggle(isOn: closeOldConnectionsBinding) {
        Label("Close Old Connections After Switching", systemImage: "xmark.circle")
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("More proxy actions")
    .popover(isPresented: $customDelayURLPopoverPresented, arrowEdge: .bottom) {
      if let selectedGroup {
        CustomDelayURLPopover(
          groupName: selectedGroup.name,
          text: customDelayTestURLBinding(for: selectedGroup.id),
          isInvalid: appModel.proxyPageSettings.hasInvalidCustomDelayTestURL(forGroupName: selectedGroup.name)
        )
      }
    }
    .popover(isPresented: $providersPopoverPresented, arrowEdge: .bottom) {
      ProxyProviderList(providers: runtimeData.proxyProviders)
        .padding(12)
        .frame(width: 520)
        .environment(appModel)
        .environment(runtimeData)
    }
  }

  private var sortOrderBinding: Binding<ProxyNodeSort> {
    Binding(
      get: { appModel.proxyPageSettings.sortOrder },
      set: { value in
        guard value != appModel.proxyPageSettings.sortOrder else { return }
        appModel.updateProxyPageSettings { settings in
          settings.sortOrder = value
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

  private func customDelayTestURLBinding(for groupID: ProxyGroup.ID) -> Binding<String> {
    Binding(
      get: {
        appModel.proxyPageSettings.customDelayTestURLText(forGroupName: groupID)
      },
      set: { value in
        appModel.updateProxyPageSettings { settings in
          settings.setCustomDelayTestURLText(value, forGroupName: groupID)
        }
      }
    )
  }

  // MARK: - Empty states

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

  // MARK: - Selection

  private func resolvedSelectedGroup(in groups: [ProxyGroup]) -> ProxyGroup? {
    guard let id = ProxyGroupSelectionPolicy.resolvedSelection(current: selectedGroupID, groups: groups) else {
      return nil
    }
    return groups.first { $0.id == id }
  }

  private func selectDefaultGroupIfNeeded(from groups: [ProxyGroup]) {
    let resolved = ProxyGroupSelectionPolicy.resolvedSelection(current: selectedGroupID, groups: groups)
    // Only write when it actually changes, so keeping a still-valid selection doesn't churn @State.
    if resolved != selectedGroupID {
      selectedGroupID = resolved
    }
  }

  private func reconcileNodeSelection(in group: ProxyGroup?) {
    let resolved = ProxyNodeSelectionPolicy.resolvedSelection(current: selectedNodeID, nodes: group?.nodes ?? [])
    if resolved != selectedNodeID {
      selectedNodeID = resolved
    }
  }
}

/// The group column: one row per group, name and current node only. Everything else about a group
/// is visible the moment it is selected.
private struct ProxyGroupNavigator: View {
  let groups: [ProxyGroup]
  @Binding var selectedGroupID: ProxyGroup.ID?

  var body: some View {
    List(groups, selection: $selectedGroupID) { group in
      ProxyGroupRow(group: group)
        .tag(group.id)
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .accessibilityLabel("Proxy groups")
  }
}

private struct ProxyGroupRow: View {
  let group: ProxyGroup

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: group.allowsManualProxySelection ? "point.3.connected.trianglepath.dotted" : "gearshape.2")
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(group.selected ?? String(localized: "No selection"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, 2)
    .help(group.allowsManualProxySelection ? group.name : String(format: String(localized: "%@ is managed automatically by Mihomo."), group.name))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    let selection = group.selected ?? String(localized: "No selection")
    return "\(group.name), \(selection)"
  }
}

/// The node list for the selected group plus a one-line detail bar for the highlighted node.
///
/// Highlighting a row only browses. Using a node is a deliberate action — double-click, Return, the
/// detail bar's button or the context menu — so a runtime reload or a list refresh can never switch
/// the group's node on its own.
private struct ProxyGroupNodePane: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let group: ProxyGroup
  @Binding var selectedNodeID: ProxyNode.ID?
  /// Passed in rather than read from `appModel`: the getter touches `proxyDelayBatchProgress`, and
  /// Observation tracks the stored property, not the derived flag. Reading it here would subscribe
  /// the whole node list to every coalesced batch flush.
  let isDelayBatchRunning: Bool
  let scrollToCurrentNodeRequest: Int

  var body: some View {
    let canSelect = group.allowsManualProxySelection
      && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let closesOldConnections = appModel.proxyPageSettings.closesOldConnectionsAfterSwitch

    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      Divider()

      ScrollViewReader { proxy in
        List(group.nodes, selection: $selectedNodeID) { node in
          ProxyNodeRow(node: node, isCurrent: group.selected == node.name)
            .tag(node.id)
            .id(node.id)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ProxyNode.ID.self) { ids in
          if let node = ids.first.flatMap(node(for:)) {
            nodeMenu(for: node, canSelect: canSelect, closesOldConnections: closesOldConnections)
          }
        } primaryAction: { ids in
          if let node = ids.first.flatMap(node(for:)) {
            useNode(node, canSelect: canSelect, closesOldConnections: closesOldConnections)
          }
        }
        .onKeyPress(.return) {
          guard let node = selectedNodeID.flatMap(node(for:)) else { return .ignored }
          useNode(node, canSelect: canSelect, closesOldConnections: closesOldConnections)
          return .handled
        }
        .onChange(of: scrollToCurrentNodeRequest) { _, _ in
          guard let currentNodeID else { return }
          selectedNodeID = currentNodeID
          withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            proxy.scrollTo(currentNodeID, anchor: .center)
          }
        }
        .accessibilityLabel(String(format: String(localized: "Nodes in %@"), group.name))
      }

      if let node = selectedNodeID.flatMap(node(for:)) {
        Divider()
        ProxyNodeDetailBar(
          group: group,
          node: node,
          canSelect: canSelect,
          canTest: canTest(node),
          onUse: { useNode(node, canSelect: canSelect, closesOldConnections: closesOldConnections) },
          onTest: { testDelay(for: node) }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(group.name)
        .font(.headline)
        .lineLimit(1)
      Text(headerSubtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if !group.allowsManualProxySelection {
        Label("Automatic", systemImage: "gearshape.2")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(String(format: String(localized: "%@ is managed automatically by Mihomo."), group.name))
      }
    }
  }

  private var headerSubtitle: String {
    let count = String.localizedStringWithFormat(NSLocalizedString("%lld nodes", comment: ""), Int64(group.nodes.count))
    let type = group.type.trimmingCharacters(in: .whitespacesAndNewlines)
    return type.isEmpty ? count : "\(count) · \(type)"
  }

  @ViewBuilder
  private func nodeMenu(for node: ProxyNode, canSelect: Bool, closesOldConnections: Bool) -> some View {
    Button("Use Node") {
      useNode(node, canSelect: canSelect, closesOldConnections: closesOldConnections)
    }
    .disabled(!(canSelect && node.isSelectable))

    Button("Test Delay") {
      testDelay(for: node)
    }
    .disabled(!canTest(node))

    Divider()

    Button("Copy Node Name") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(node.name, forType: .string)
    }
  }

  private func node(for id: ProxyNode.ID) -> ProxyNode? {
    group.nodes.first { $0.id == id }
  }

  private var currentNodeID: ProxyNode.ID? {
    group.nodes.first(where: { $0.name == group.selected })?.id
  }

  private func canTest(_ node: ProxyNode) -> Bool {
    node.isSelectable
      && node.supportsDelayTesting
      && appModel.canControlRuntimeProxies
      && !isDelayBatchRunning
  }

  /// Double-click, Return and "Use Node" all land here. Re-submitting the node the group already
  /// uses is skipped: it would only send the same selection to the core again (and, with the
  /// close-old-connections preference on, needlessly cut the group's live connections).
  private func useNode(_ node: ProxyNode, canSelect: Bool, closesOldConnections: Bool) {
    guard canSelect, node.isSelectable, group.selected != node.name else { return }
    appModel.selectProxy(group: group, node: node, closeOldConnections: closesOldConnections)
  }

  private func testDelay(for node: ProxyNode) {
    appModel.testDelay(in: group, for: node, testURL: appModel.customDelayTestURL(forGroupName: group.name))
  }
}

private struct ProxyNodeRow: View {
  let node: ProxyNode
  let isCurrent: Bool

  var body: some View {
    let delay = ProxyNodeDelayLabel(node: node)
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.accentColor)
        .opacity(isCurrent ? 1 : 0)
        .frame(width: 16)
        .accessibilityHidden(true)

      Text(node.name)
        .fontWeight(isCurrent ? .semibold : .regular)
        .foregroundStyle(node.isSelectable ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 12)

      if node.resolvedDelayState == .testing {
        ProgressView()
          .controlSize(.mini)
      } else {
        Text(delay.text)
          .font(.callout.monospacedDigit())
          .foregroundStyle(delay.color)
          .lineLimit(1)
          .help(delay.help)
      }
    }
    .padding(.vertical, 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(delay: delay))
  }

  private func accessibilityLabel(delay: ProxyNodeDelayLabel) -> String {
    var parts = [node.name]
    if isCurrent {
      parts.append(String(localized: "current node"))
    }
    parts.append(delay.help)
    return parts.joined(separator: ", ")
  }
}

/// Delay as text that never lies: a node that cannot be measured says so instead of showing a number.
struct ProxyNodeDelayLabel {
  let text: String
  let help: String
  let color: Color

  init(node: ProxyNode) {
    guard node.supportsDelayTesting else {
      text = "—"
      help = String(localized: "Built-in outbounds have no connection to measure.")
      color = .secondary
      return
    }
    let display = ProxyDelayDisplay(state: node.resolvedDelayState)
    text = display.localizedLabel
    color = display.tone.color
    switch node.resolvedDelayState {
    case .unknown:
      help = String(localized: "Not tested yet")
    case .testing:
      help = String(localized: "Testing")
    case let .measured(delay):
      help = String(format: String(localized: "Measured %lld ms"), Int64(delay))
    case .timeout:
      help = String(localized: "The delay test timed out.")
    case let .error(message):
      help = message.isEmpty ? String(localized: "No result") : message
    }
  }
}

/// The one place a node's technical facts appear: protocol, provider, endpoint, capabilities and the
/// delay verdict for the highlighted node, with the two actions that apply to it.
private struct ProxyNodeDetailBar: View {
  let group: ProxyGroup
  let node: ProxyNode
  let canSelect: Bool
  let canTest: Bool
  let onUse: () -> Void
  let onTest: () -> Void

  var body: some View {
    let isCurrent = group.selected == node.name
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        facts
        Spacer(minLength: 12)
        actions(isCurrent: isCurrent)
      }

      VStack(alignment: .leading, spacing: 8) {
        facts
        actions(isCurrent: isCurrent)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Node details")
  }

  private var facts: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(node.name)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      Text(detailLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  private func actions(isCurrent: Bool) -> some View {
    HStack(spacing: 8) {
      Button("Test Delay", action: onTest)
        .disabled(!canTest)
        .help(canTest ? String(localized: "Test delay") : ProxyNodeDelayLabel(node: node).help)

      if group.allowsManualProxySelection {
        if isCurrent {
          Label("In Use", systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(Color.accentColor)
        } else {
          Button("Use Node", action: onUse)
            .buttonStyle(.borderedProminent)
            .disabled(!(canSelect && node.isSelectable))
        }
      } else {
        Text("Selected automatically")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
  }

  private var detailLine: String {
    var parts: [String] = []
    let type = node.type.trimmingCharacters(in: .whitespacesAndNewlines)
    parts.append(type.isEmpty ? String(localized: "proxy") : type)
    if let providerName = node.providerName {
      parts.append(providerName)
    }
    if let endpoint = node.endpointSummary {
      parts.append(endpoint)
    }
    parts.append(contentsOf: node.capabilityLabels)
    parts.append(ProxyNodeDelayLabel(node: node).help)
    return parts.joined(separator: " · ")
  }
}

private struct CustomDelayURLPopover: View {
  let groupName: String
  @Binding var text: String
  let isInvalid: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Custom Delay URL")
        .font(.headline)
      Text(String(format: String(localized: "Used by delay tests for %@. Leave empty for the default URL."), groupName))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Custom delay URL", text: $text)
        .textFieldStyle(.roundedBorder)
      if isInvalid {
        Label("Invalid custom delay URL. Falling back to default delay URL.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(width: 360)
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

enum ProxyGroupSearchFilter {
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
    terms = parsedTerms
    isCaseSensitive = parsedCaseSensitive
    isWholeWord = parsedWholeWord
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
      node.endpointSummary,
    ]
    .compactMap(\.self)
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
      return .orange
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
        color: .orange
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
        .foregroundStyle(.orange)
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
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @Environment(\.pageHeight) private var pageHeight
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
      // Issue #27: this summary sits above the group list and used to grow one row per provider,
      // so a subscription with dozens of providers pushed the group list — and the page itself —
      // straight out of the window. The header stays put and only the rows scroll.
      BoundedHeightSection(maxHeight: SecondarySectionHeight.maxHeight(pageHeight: pageHeight)) {
        LazyVStack(alignment: .leading, spacing: 0) {
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
      }
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

struct ProxyDelayDisplay: Equatable {
  /// Locale-independent label, kept for the menu bar and for tests that pin the wire-level wording.
  let label: String
  let tone: ProxyDelayTone

  /// The same verdict in the user's language, for the node list where it is the main column.
  var localizedLabel: String {
    switch label {
    case "Unknown": String(localized: "Unknown")
    case "Testing": String(localized: "Testing")
    case "Timeout": String(localized: "Timeout")
    case "No result": String(localized: "No result")
    default: label
    }
  }

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
      label = "No result"
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
      return .orange
    case .timeout:
      return .orange
    case .error:
      return .orange
    }
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
