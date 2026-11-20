@testable import ClashMax
import SwiftUI
import XCTest

/// The pure policies behind the seven simplified pages: what a row says, when a pane may open, and
/// what a draft is allowed to lose. Layout constants are not asserted here — the rendered pages are
/// checked by eye — only the decisions a view makes from data.
@MainActor
final class PageSimplificationTests: XCTestCase {
  func testHomeRatePartsUseTheSameBinaryUnitsAndPrecisionAsTheCoreReadouts() {
    for (bytes, number, unit) in [(0, "0", "B/s"), (1023, "1023", "B/s"), (1024, "1", "KB/s"),
                                  (1536, "2", "KB/s"), (1_048_576, "1.0", "MB/s"), (1_073_741_824, "1024.0", "MB/s")]
    {
      XCTAssertEqual(HomeRateParts.split(bytes), HomeRateParts(number: number, unit: unit))
      XCTAssertEqual(TrafficSample.format(bytes), "\(number) \(unit)")
    }
    XCTAssertEqual(HomeRateParts.bytes(1_073_741_824), HomeRateParts(number: "1.0", unit: "GB"))
  }

  func testHomePowerStateHonorsStartInFlightAndOutstandingStopOwnership() {
    XCTAssertEqual(HomePowerState(state: .stopped, canStop: false, readinessIssue: nil), .start)
    XCTAssertEqual(HomePowerState(state: .running, canStop: true, readinessIssue: nil), .stop)
    XCTAssertEqual(HomePowerState(state: .starting, canStop: true, readinessIssue: nil), .starting)
    XCTAssertEqual(HomePowerState(state: .crashed(message: "exited"), canStop: false, readinessIssue: nil), .restart)
    XCTAssertEqual(HomePowerState(state: .stopped, canStop: false, readinessIssue: "helper"), .blocked)
    XCTAssertEqual(HomePowerState(state: .crashed(message: "NE"), canStop: true, readinessIssue: "cleanup"), .stop)
  }

  func testHomeTrafficDestinationsRankOpenConnectionsAndResetWithTheStore() async {
    func connection(_ id: String, _ host: String, _ exit: String?, _ upload: Int, _ download: Int, ip: String? = nil) -> ConnectionSnapshot {
      ConnectionSnapshot(id: id, network: "tcp", host: host, destinationIP: ip, upload: upload, download: download,
                         chain: exit.map { [$0, "Group"] } ?? [], rule: "MATCH")
    }
    let snapshots = [connection("1", "A.example", "Tokyo", 2, 8), connection("2", "a.example", "DIRECT", 9, 8),
                     connection("3", "", "Tokyo", 11, 12, ip: "192.0.2.5"), connection("4", "", "REJECT-DROP", 0, 1)]
    let ranked = HomeTrafficDestinations.make(from: snapshots, limit: 2)
    XCTAssertEqual(ranked.domains, [.init(name: "a.example", bytes: 27), .init(name: "192.0.2.5", bytes: 23)])
    XCTAssertEqual(ranked.exits, [.init(name: "Tokyo", bytes: 33), .init(name: "DIRECT", bytes: 17)])
    XCTAssertEqual([ranked.proxy, ranked.direct, ranked.reject], [2, 1, 1])
    XCTAssertEqual(HomeConnectionRoute.classify("reject"), .reject)
    XCTAssertEqual(HomeConnectionRoute.classify("Direct"), .direct)
    XCTAssertEqual(HomeConnectionRoute.classify(nil), .proxy)
    XCTAssertEqual(HomeTrafficDestinations.make(from: []).domains, [])
    XCTAssertEqual(HomeTrafficDestinations.make(from: []).exits, [])
    XCTAssertTrue(HomeTrafficDestinations.make(from: snapshots, limit: 0).domains.isEmpty)
    let store = RuntimeDataStore()
    await store.updateConnections(snapshots)
    XCTAssertEqual(store.trafficDestinations.domains.last?.name, String(localized: "(IP connection)"))
    store.removeConnection(id: "2")
    XCTAssertEqual(store.trafficDestinations.direct, 0)
    store.clearRuntimeCollections()
    XCTAssertEqual(store.trafficDestinations, HomeTrafficDestinations())
  }

  func testLogSearchDoesNotMutateCollectionAndCountsOnlyUnseenEntries() {
    let first = LogEntry(level: "info", message: "Synthetic example.com connected")
    let second = LogEntry(level: "warning", message: "合成连接需要检查")
    let retained = [first, second]
    let paused = retained
    let latest = retained + [LogEntry(level: "info", message: "New synthetic message")]
    XCTAssertEqual(LogDisplayPolicy.search(entries: retained, text: "EXAMPLE"), [first])
    XCTAssertEqual(LogDisplayPolicy.search(entries: retained, text: "连接"), [second])
    XCTAssertEqual(LogDisplayPolicy.search(entries: retained, text: "warning"), [second])
    XCTAssertEqual(paused.count, 2)
    XCTAssertEqual(LogDisplayPolicy.unseenCount(entries: latest, after: paused.last?.id), 1)
    XCTAssertEqual(LogDisplayPolicy.unseenCount(entries: [latest.last!], after: first.id), 1)
    XCTAssertEqual(retained, [first, second])
  }

  func testSettingsSearchReturnsOneEditableDestinationWithAStableAnchor() {
    let results = SettingsSearchEntry.matches("Mixed Port")
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.category, .runtime)
    XCTAssertEqual(results.first?.title, "Mixed Port")
    XCTAssertTrue(SettingsSearchEntry.matches("never-a-setting").isEmpty)
  }

  func testProxyGroupColumnLeavesRoomForNodes() {
    XCTAssertFalse(ProxiesLayout.usesGroupColumn(pageWidth: ProxiesLayout.groupListWidth + 439))
    XCTAssertTrue(ProxiesLayout.usesGroupColumn(pageWidth: ProxiesLayout.groupListWidth + 440))
  }

  func testDashboardNavigationOverridesRetainedProxySearchInEitherLifecycleOrder() {
    for restoreFirst in [false, true] {
      var navigation = ProxiesPageNavigationState()
      if restoreFirst { navigation.restoreSearch("group=Other") }
      navigation.apply(ProxiesPageRequest(groupName: "Streaming"))
      navigation.restoreSearch("group=Other")

      XCTAssertEqual(navigation.searchText, "")
      XCTAssertEqual(navigation.pendingFocusGroupName, "Streaming")
    }
  }

  func testViewAllProxyGroupsClearsBothSearchAndAnOlderFocusRequest() {
    var navigation = ProxiesPageNavigationState()
    navigation.apply(ProxiesPageRequest(groupName: "Streaming"))
    navigation.searchText = "JP"
    navigation.apply(ProxiesPageRequest(groupName: nil))
    navigation.restoreSearch("group=Other")

    XCTAssertEqual(navigation.searchText, "")
    XCTAssertNil(navigation.pendingFocusGroupName)
  }

  func testOrdinaryProxyPageVisitRetainsSearchAndDoesNotOverwriteTyping() {
    var navigation = ProxiesPageNavigationState()
    navigation.restoreSearch("JP")
    XCTAssertEqual(navigation.searchText, "JP")
    navigation.searchText = "US"
    navigation.restoreSearch("JP")
    XCTAssertEqual(navigation.searchText, "US")
    XCTAssertNil(navigation.pendingFocusGroupName)
  }

  // MARK: - Profiles

  func testProfileDetailPaneNeedsBothRoomAndARequest() {
    XCTAssertTrue(ProfilesLayout.showsDetailPane(pageWidth: ProfilesLayout.detailPaneBreakpoint, requested: true))
    XCTAssertFalse(ProfilesLayout.showsDetailPane(pageWidth: ProfilesLayout.detailPaneBreakpoint - 1, requested: true))
    XCTAssertFalse(ProfilesLayout.showsDetailPane(pageWidth: 2_000, requested: false))
    XCTAssertFalse(ProfilesLayout.showsDetailPane(pageWidth: .nan, requested: true))
    XCTAssertFalse(ProfilesLayout.showsDetailPane(pageWidth: 0, requested: true))
  }

  func testProfileStatusSummaryNamesTheFailureAndNeverFakesAValue() {
    var profile = Profile(name: "Sub", source: .subscription(id: UUID()), originalConfigPath: "/tmp/sub.yaml")
    profile.subscriptionUpdateStatus = SubscriptionUpdateStatus(result: .failed, lastError: "HTTP 503")

    XCTAssertEqual(
      ProfileStatusSummary.text(for: profile, isUpdating: false),
      String(format: String(localized: "Update failed: %@"), "HTTP 503")
    )
    XCTAssertTrue(ProfileStatusSummary.isFailure(profile))
    // An update in flight wins over the stale failure, so the row never shows a red line while the
    // retry that could clear it is running.
    XCTAssertEqual(ProfileStatusSummary.text(for: profile, isUpdating: true), String(localized: "Updating…"))

    profile.subscriptionUpdateStatus = .empty
    XCTAssertEqual(ProfileStatusSummary.text(for: profile, isUpdating: false), String(localized: "Not updated yet"))
    XCTAssertFalse(ProfileStatusSummary.isFailure(profile))

    let local = Profile(name: "Local", source: .localFile(originalPath: "/tmp/a.yaml"), originalConfigPath: "/tmp/a.yaml")
    XCTAssertFalse(ProfileStatusSummary.isFailure(local))
    XCTAssertNil(ProfileStatusSummary.usageText(for: local))
  }

  func testProfileUsageColumnAppearsOnlyWhenSomeProfileReportsTraffic() {
    let plain = Profile(name: "Plain", source: .subscription(id: UUID()), originalConfigPath: "/tmp/p.yaml")
    XCTAssertFalse(ProfileStatusSummary.showsUsageColumn(for: [plain]))

    var metered = plain
    metered.subscriptionMetadata = SubscriptionMetadata(
      traffic: SubscriptionTrafficUsage(upload: 1_024, download: 2_048, total: 1_073_741_824, expireAt: nil)
    )
    XCTAssertTrue(ProfileStatusSummary.showsUsageColumn(for: [plain, metered]))
    XCTAssertNotNil(ProfileStatusSummary.usageText(for: metered))
  }

  // MARK: - Status

  func testStatusOverviewDistinguishesPreviewFromCapturedTraffic() {
    let captured = StatusOverview(
      isRunning: true,
      previewRuntimeActive: false,
      coreStatus: .running(version: nil),
      isStarting: false,
      routingMode: .systemProxy,
      systemProxyEnabled: true,
      tunEnabled: false,
      networkExtensionEnabled: false,
      readinessIssue: nil
    )
    XCTAssertEqual(captured.tone, .running)
    XCTAssertEqual(
      captured.headline,
      String(format: String(localized: "Traffic is routed through ClashMax via %@"), ProxyRoutingMode.systemProxy.displayName)
    )

    let runningWithoutCapture = StatusOverview(
      isRunning: true,
      previewRuntimeActive: false,
      coreStatus: .running(version: nil),
      isStarting: false,
      routingMode: .systemProxy,
      systemProxyEnabled: false,
      tunEnabled: false,
      networkExtensionEnabled: false,
      readinessIssue: nil
    )
    XCTAssertEqual(runningWithoutCapture.tone, .attention)
    XCTAssertEqual(runningWithoutCapture.headline, String(localized: "Core is running, but no traffic is captured"))

    let preview = StatusOverview(
      isRunning: false,
      previewRuntimeActive: true,
      coreStatus: .stopped,
      isStarting: false,
      routingMode: .tun,
      systemProxyEnabled: false,
      tunEnabled: false,
      networkExtensionEnabled: false,
      readinessIssue: nil
    )
    XCTAssertEqual(preview.tone, .idle)
    XCTAssertEqual(preview.headline, String(localized: "Preview core is running for delay tests"))

    let crashed = StatusOverview(
      isRunning: false,
      previewRuntimeActive: false,
      coreStatus: .crashed(message: "exit 2"),
      isStarting: false,
      routingMode: .tun,
      systemProxyEnabled: false,
      tunEnabled: false,
      networkExtensionEnabled: false,
      readinessIssue: nil
    )
    XCTAssertEqual(crashed.tone, .failure)
    XCTAssertEqual(crashed.detail, "exit 2")

    let blocked = StatusOverview(
      isRunning: false,
      previewRuntimeActive: false,
      coreStatus: .stopped,
      isStarting: false,
      routingMode: .tun,
      systemProxyEnabled: false,
      tunEnabled: false,
      networkExtensionEnabled: false,
      readinessIssue: "Helper requires approval."
    )
    XCTAssertEqual(blocked.headline, String(localized: "Cannot start"))
    XCTAssertEqual(blocked.detail, "Helper requires approval.")
  }

  func testStatusSectionsOpenOnlyWhenRelevantAndReportingSomething() {
    XCTAssertEqual(
      StatusDetailSection.defaultExpanded(routingMode: .systemProxy, helperHasIssue: true, tunHasIssue: true, networkExtensionHasIssue: true),
      [.runtime],
      "Diagnostics for modes that are not selected stay folded even when they report problems"
    )
    XCTAssertEqual(
      StatusDetailSection.defaultExpanded(routingMode: .tun, helperHasIssue: true, tunHasIssue: false, networkExtensionHasIssue: false),
      [.runtime, .helper]
    )
    XCTAssertEqual(
      StatusDetailSection.defaultExpanded(routingMode: .tun, helperHasIssue: false, tunHasIssue: true, networkExtensionHasIssue: false),
      [.runtime, .tun]
    )
    XCTAssertEqual(
      StatusDetailSection.defaultExpanded(routingMode: .neProxy, helperHasIssue: false, tunHasIssue: false, networkExtensionHasIssue: true),
      [.runtime, .networkExtension]
    )
    XCTAssertEqual(
      StatusDetailSection.defaultExpanded(routingMode: .neProxy, helperHasIssue: false, tunHasIssue: false, networkExtensionHasIssue: false),
      [.runtime]
    )
  }

  func testStatusAttentionDropsTheGenericLastErrorWhenASpecificItemAlreadySaysIt() {
    XCTAssertTrue(
      StatusAttentionDeduplication.isRedundant(
        lastError: "Could not repair TUN DNS settings: Operation not permitted",
        specificMessages: ["Operation not permitted"]
      ),
      "The DNS item already carries the failure, with its Repair button"
    )
    XCTAssertTrue(StatusAttentionDeduplication.isRedundant(lastError: "utun is down", specificMessages: ["Default route: utun is down (details)"]))
    XCTAssertFalse(StatusAttentionDeduplication.isRedundant(lastError: "Runtime rejected the selection", specificMessages: ["Operation not permitted"]))
    XCTAssertFalse(StatusAttentionDeduplication.isRedundant(lastError: "Something else", specificMessages: []))
    XCTAssertTrue(StatusAttentionDeduplication.isRedundant(lastError: "   ", specificMessages: []), "An empty error has nothing to show")
  }

  // MARK: - Routing

  func testRoutingDraftIsUnsavedWhileDetachedOrDivergedFromTheLoadedSnippet() {
    let editor = RoutingEditorState()
    XCTAssertFalse(editor.draftHasUnsavedChanges, "Nothing is loaded and nothing is being created")

    editor.beginDetachedDraft(RuntimeSnippet.defaultRuleSnippet)
    XCTAssertTrue(editor.draftHasUnsavedChanges, "A snippet that was never saved is unsaved by definition")
    XCTAssertNil(editor.selectedSnippetID)

    let saved = RuntimeSnippet(name: "Office", payload: .rules(RuleOverlaySettings(enabled: true)))
    editor.load(saved)
    XCTAssertFalse(editor.draftHasUnsavedChanges)
    XCTAssertEqual(editor.selectedSnippetID, saved.id)

    editor.draftSnippet.name = "Office (edited)"
    XCTAssertTrue(editor.draftHasUnsavedChanges)

    editor.load(saved)
    XCTAssertFalse(editor.draftHasUnsavedChanges, "Reloading the saved snippet discards the divergence")

    editor.clearSelection()
    XCTAssertNil(editor.selectedSnippetID)
    XCTAssertFalse(editor.isEditingDetachedDraft)
    XCTAssertFalse(editor.draftHasUnsavedChanges)
  }

  func testRoutingDraftLeavesEnabledToTheListSwitch() {
    // The editor has no Enabled switch; the list's switch writes the store directly. So a draft
    // whose `enabled` differs from its baseline is not "unsaved", and Save writes the stored value.
    let editor = RoutingEditorState()
    let saved = RuntimeSnippet(name: "Office", enabled: true, payload: .rules(RuleOverlaySettings(enabled: true)))
    editor.load(saved)
    editor.draftSnippet.name = "Office (edited)"

    var switchedOff = saved
    switchedOff.enabled = false
    editor.adoptStoredEnabledState(of: switchedOff)
    XCTAssertFalse(editor.draftSnippet.enabled, "The draft follows the list switch")
    XCTAssertEqual(editor.draftSnippet.name, "Office (edited)", "…without losing the unsaved edit")
    XCTAssertTrue(editor.draftHasUnsavedChanges)

    let toSave = editor.snippetForSaving(in: [switchedOff])
    XCTAssertFalse(toSave.enabled)
    XCTAssertEqual(toSave.name, "Office (edited)")

    // A stale `enabled` alone never counts as an edit, and never reaches the store.
    editor.load(saved)
    editor.draftSnippet.enabled = false
    XCTAssertFalse(editor.draftHasUnsavedChanges)
    editor.draftSnippet.enabled = true
    XCTAssertFalse(editor.snippetForSaving(in: [switchedOff]).enabled)

    // Another snippet's state is not adopted, and a new snippet keeps its own value.
    let other = RuntimeSnippet(name: "Other", enabled: false, payload: .rules(RuleOverlaySettings(enabled: true)))
    editor.adoptStoredEnabledState(of: other)
    XCTAssertTrue(editor.draftSnippet.enabled)
    editor.beginDetachedDraft(RuntimeSnippet.defaultRuleSnippet)
    XCTAssertTrue(editor.snippetForSaving(in: [switchedOff, other]).enabled)
  }

  func testRoutingEditorKeepsTheOpenToolAndSimulationAcrossPageVisits() {
    // The state is owned by AppModel precisely so a page switch cannot reset it; the view only
    // reads it. This pins the two hand-offs Connections relies on.
    let editor = RoutingEditorState()
    XCTAssertNil(editor.activeTool)

    editor.openTool(.simulator)
    editor.simulationInput = RuleMatchSimulationInput(destination: "example.com")
    XCTAssertEqual(editor.activeTool, .simulator)
    XCTAssertEqual(editor.simulationInput.destination, "example.com")

    editor.selectedDiagnostic = .dnsResolution
    editor.openTool(.diagnostics)
    XCTAssertEqual(editor.activeTool, .diagnostics)
    XCTAssertEqual(editor.selectedDiagnostic, .dnsResolution)
  }

  func testRoutingSnippetEffectSummaryListsRulesInEvaluationOrder() {
    let settings = RuleOverlaySettings(
      enabled: true,
      prependRules: [ManagedRuleOverlayRule(kind: .domainSuffix, value: "example.com", policy: "DIRECT")],
      appendRules: [ManagedRuleOverlayRule(kind: .match, policy: "Proxy")],
      disabledRuleMatchers: [ManagedRuleDisableMatcher(mode: .contains, pattern: "GEOIP,CN")]
    )

    let lines = RoutingSnippetEffectSummary.lines(for: .rules(settings))

    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[0].hasSuffix("DOMAIN-SUFFIX,example.com,DIRECT"))
    XCTAssertTrue(lines[1].contains("GEOIP,CN"))
    XCTAssertTrue(lines[2].hasSuffix("MATCH,Proxy"))
    XCTAssertEqual(RoutingSnippetEffectSummary.lines(for: .rawYAML(.empty)), [])
  }

  // MARK: - Errors

  func testPagesRepeatTheLastErrorOnlyWhenThereIsMoreToShowThanTheAlert() {
    XCTAssertFalse(
      PageErrorPresentation.showsInlineError(hasDetails: false),
      "The alert already shows the one-line error; a second copy on the page says nothing new"
    )
    XCTAssertTrue(PageErrorPresentation.showsInlineError(hasDetails: true), "Expandable details are more than the alert offers")
  }

  // MARK: - Rules

  func testRulesProviderColumnFoldsAwayOnNarrowPagesAndWithoutProviderRules() {
    XCTAssertTrue(RulesLayout.showsProviderColumn(pageWidth: RulesLayout.providerColumnBreakpoint, hasProviderRules: true))
    XCTAssertFalse(
      RulesLayout.showsProviderColumn(pageWidth: RulesLayout.providerColumnBreakpoint - 1, hasProviderRules: true),
      "Below the breakpoint the payload keeps the room and the source moves to the selected rule's detail line"
    )
    XCTAssertFalse(RulesLayout.showsProviderColumn(pageWidth: 2_000, hasProviderRules: false))
    XCTAssertFalse(RulesLayout.showsProviderColumn(pageWidth: .nan, hasProviderRules: true))
    XCTAssertFalse(RulesLayout.showsProviderColumn(pageWidth: 0, hasProviderRules: true))
  }

  func testRuleTypeSearchMatchesTheConfigSpellingAgainstRuntimeCamelCase() {
    // A running core reports `DomainSuffix` / `IPCIDR`; the help text teaches `type=DOMAIN-SUFFIX`.
    let suffix = RuntimeRule(index: 0, type: "DomainSuffix", payload: "example.com", policy: "DIRECT")
    let domain = RuntimeRule(index: 1, type: "Domain", payload: "example.org", policy: "Proxy")
    let cidr = RuntimeRule(index: 2, type: "IPCIDR", payload: "10.0.0.0/8", policy: "DIRECT")
    let previewCIDR6 = RuntimeRule(index: 3, type: "IP-CIDR6", payload: "fd00::/8", policy: "DIRECT")
    let rules = [suffix, domain, cidr, previewCIDR6]

    func search(_ text: String) -> [Int] {
      let query = RuleSearchQuery(rawValue: text)
      return rules.filter { query.matches($0) }.map(\.index)
    }

    XCTAssertEqual(search("type=DOMAIN-SUFFIX"), [0])
    XCTAssertEqual(search("type=domain_suffix"), [0])
    XCTAssertEqual(search("type=domainsuffix"), [0])
    // A partial type is still a substring match, so `type=domain` keeps catching the whole family.
    XCTAssertEqual(search("type=domain"), [0, 1])
    XCTAssertEqual(search("type=suffix"), [0])
    // The core folds IP-CIDR6 into IPCIDR, so either spelling finds both.
    XCTAssertEqual(search("type=IP-CIDR"), [2, 3])
    XCTAssertEqual(search("type=IP-CIDR6"), [2, 3])
    XCTAssertEqual(search("type=cidr6"), [3])
    XCTAssertEqual(search("type="), [], "An empty value matches nothing, like policy= and provider=")
    // Plain words describe the type too, in either spelling.
    XCTAssertEqual(search("DOMAIN-SUFFIX"), [0])
    XCTAssertEqual(search("type=DOMAIN-SUFFIX policy=DIRECT"), [0])
    XCTAssertEqual(search("type=DOMAIN-SUFFIX policy=Proxy"), [])
  }

  // MARK: - Connections

  func testConnectionMenuPolicyKeysRulesOnTheHostAndOffersDNSOnlyForNames() {
    let named = ConnectionSnapshot(
      id: "named",
      network: "tcp",
      host: "cdn.example.com",
      sourceIP: "127.0.0.1",
      sourcePort: 50_000,
      destinationIP: nil,
      remoteDestinationIP: "203.0.113.7",
      destinationPort: 443,
      inboundPort: 7_890,
      processName: "Safari",
      processPath: "/Applications/Safari.app",
      upload: 1,
      download: 1,
      chain: ["Proxy"],
      rule: "DOMAIN-SUFFIX",
      rulePayload: "example.com",
      startedAt: Date()
    )
    XCTAssertEqual(ConnectionMenuPolicy.ruleHost(for: named), "cdn.example.com")
    XCTAssertEqual(ConnectionMenuPolicy.resolvableDomain(for: named), "cdn.example.com")
    XCTAssertEqual(ConnectionMenuPolicy.selectionTitle(for: [named]), "cdn.example.com")

    let ipOnly = ConnectionSnapshot(
      id: "ip",
      network: "udp",
      host: "",
      sourceIP: "127.0.0.1",
      sourcePort: 50_001,
      destinationIP: "203.0.113.9",
      remoteDestinationIP: "203.0.113.9",
      destinationPort: 443,
      inboundPort: 7_890,
      processName: "Mail",
      processPath: "/System/Applications/Mail.app",
      upload: 1,
      download: 1,
      chain: ["DIRECT"],
      rule: "GEOIP",
      rulePayload: "CN",
      startedAt: Date()
    )
    XCTAssertEqual(ConnectionMenuPolicy.ruleHost(for: ipOnly), "203.0.113.9", "Without a name the rule is keyed on the address")
    XCTAssertNil(ConnectionMenuPolicy.resolvableDomain(for: ipOnly), "There is no name to hand to the resolver")
    XCTAssertEqual(ConnectionMenuPolicy.selectionTitle(for: [ipOnly]), "203.0.113.9")

    XCTAssertEqual(
      ConnectionMenuPolicy.selectionTitle(for: [named, ipOnly]),
      String.localizedStringWithFormat(NSLocalizedString("%lld connections selected", comment: ""), Int64(2))
    )
  }

  // MARK: - Proxies

  func testProxyNodeDelayLabelNeverInventsANumber() {
    let reject = ProxyNode(name: "REJECT", type: "Reject", delay: nil, isSelectable: true)
    XCTAssertEqual(ProxyNodeDelayLabel(node: reject).text, "—")

    let untested = ProxyNode(name: "Tokyo", type: "vless", delay: nil, isSelectable: true)
    XCTAssertEqual(ProxyNodeDelayLabel(node: untested).text, ProxyDelayDisplay(state: .unknown).localizedLabel)

    let measured = ProxyNode(name: "Osaka", type: "vless", delay: 42, isSelectable: true)
    XCTAssertEqual(ProxyNodeDelayLabel(node: measured).text, "42 ms")

    let timedOut = ProxyNode(name: "Seoul", type: "vless", delay: nil, isSelectable: true, delayState: .timeout)
    XCTAssertEqual(ProxyNodeDelayLabel(node: timedOut).text, ProxyDelayDisplay(state: .timeout).localizedLabel)
  }
}

/// The route read-outs added with the 2026-11 visual pass: Connections' exit-node column and Home's
/// "group → node · exit" line. Mihomo reports `chains` outbound-first, which is what made the old
/// "Policy" column show a node.
@MainActor
final class RouteReadoutTests: XCTestCase {
  private func connection(chain: [String]) -> ConnectionSnapshot {
    ConnectionSnapshot(id: "c", network: "tcp", host: "example.com", upload: 0, download: 0, chain: chain, rule: "Match")
  }

  func testConnectionChainReadsNodeFirst() {
    let routed = connection(chain: ["JP 01", "Auto", "Proxy"])
    XCTAssertEqual(routed.exitNode, "JP 01")
    XCTAssertEqual(routed.policyGroups, ["Proxy", "Auto"])
    XCTAssertEqual(routed.routeSummary, "Proxy → Auto → JP 01")
  }

  func testConnectionChainWithoutGroups() {
    let direct = connection(chain: ["DIRECT"])
    XCTAssertEqual(direct.exitNode, "DIRECT")
    XCTAssertEqual(direct.policyGroups, [])
    XCTAssertEqual(direct.routeSummary, "DIRECT")

    let empty = connection(chain: [])
    XCTAssertNil(empty.exitNode)
    XCTAssertEqual(empty.routeSummary, "")
  }

  func testHeaderRouteNamesGroupNodeAndExit() {
    let node = ProxyNode(name: "JP 01", type: "vless", delay: 80, isSelectable: true)
    let group = ProxyGroup(name: "Proxy", type: "Selector", selected: "JP 01", nodes: [node])
    let info = PublicIPInfo(ipAddress: "203.0.113.4", countryCode: "JP", countryName: "Japan", city: "Tokyo", sourceName: "test", fetchedAt: .now)

    let route = DashboardHeaderRoute(group: group, node: node, hasMissingSelection: false, exit: .loaded(info))
    XCTAssertEqual(route.groupName, "Proxy")
    XCTAssertEqual(route.nodeName, "JP 01")
    XCTAssertEqual(route.exit, .located("Tokyo, Japan"))
  }

  func testHeaderRouteDropsAMissingSelectionAndUnknownExit() {
    let group = ProxyGroup(name: "Proxy", type: "Selector", selected: "Gone", nodes: [])
    let route = DashboardHeaderRoute(group: group, node: nil, hasMissingSelection: true, exit: .idle)
    XCTAssertNil(route.nodeName)
    XCTAssertEqual(route.exit, .unknown)

    let failed = PublicIPInfoState.failed(message: "x", previous: nil, failedAt: .now)
    XCTAssertEqual(DashboardHeaderRoute.exit(from: failed), .unknown)
    XCTAssertEqual(DashboardHeaderRoute.exit(from: .loading(previous: nil, startedAt: .now)), .checking)
  }

  func testHeaderExitLocationFallsBackToCountryOrCode() {
    XCTAssertEqual(DashboardHeaderRoute.location(of: PublicIPInfo(ipAddress: "1", countryCode: "JP", sourceName: "t", fetchedAt: .now)), "JP")
    XCTAssertEqual(
      DashboardHeaderRoute.location(of: PublicIPInfo(ipAddress: "1", countryName: "Singapore", city: "Singapore", sourceName: "t", fetchedAt: .now)),
      "Singapore"
    )
    XCTAssertNil(DashboardHeaderRoute.location(of: PublicIPInfo(ipAddress: "1", sourceName: "t", fetchedAt: .now)))
  }
}
