@testable import ClashMax
import SwiftUI
import XCTest

/// The pure policies behind the seven simplified pages: what a row says, when a pane may open, and
/// what a draft is allowed to lose. Layout constants are not asserted here — the rendered pages are
/// checked by eye — only the decisions a view makes from data.
@MainActor
final class PageSimplificationTests: XCTestCase {
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

  func testPagesRepeatTheLastErrorOnlyWhenTheStripCannotShowItOrThereIsMoreToShow() {
    XCTAssertFalse(
      PageErrorPresentation.showsInlineError(readinessIssue: nil, hasDetails: false),
      "The status strip already shows the one-line error; a second copy on the page says nothing new"
    )
    XCTAssertTrue(
      PageErrorPresentation.showsInlineError(readinessIssue: "No active profile selected.", hasDetails: false),
      "The strip prefers the readiness issue, so the page is the only place left for the error"
    )
    XCTAssertTrue(PageErrorPresentation.showsInlineError(readinessIssue: nil, hasDetails: true), "Expandable details are more than the strip offers")
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
