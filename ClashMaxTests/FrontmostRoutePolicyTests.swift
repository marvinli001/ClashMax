@testable import ClashMax
import XCTest

/// The menu bar's "Route This Site or App…": which subjects the frontmost app offers, which targets
/// are listed, and which rule line each (subject, target) pair becomes.
final class FrontmostRoutePolicyTests: XCTestCase {
  private static let chrome = FrontmostAppSnapshot(
    name: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true),
    executableURL: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  )

  private static let safari = FrontmostAppSnapshot(
    name: "Safari",
    bundleIdentifier: "com.apple.Safari",
    bundleURL: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true),
    executableURL: URL(fileURLWithPath: "/Applications/Safari.app/Contents/MacOS/Safari")
  )

  private static let slack = FrontmostAppSnapshot(
    name: "Slack",
    bundleIdentifier: "com.tinyspeck.slackmacgap",
    bundleURL: URL(fileURLWithPath: "/Applications/Slack.app", isDirectory: true),
    executableURL: URL(fileURLWithPath: "/Applications/Slack.app/Contents/MacOS/Slack")
  )

  private static let chromeHelper =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
  private static let webKitNetworking =
    "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"

  private func connection(
    _ id: String,
    host: String,
    sniffHost: String? = nil,
    processName: String? = nil,
    processPath: String?,
    startedAt seconds: TimeInterval?
  ) -> ConnectionSnapshot {
    ConnectionSnapshot(
      id: id,
      network: "tcp",
      host: host,
      sniffHost: sniffHost,
      processName: processName,
      processPath: processPath,
      upload: 0,
      download: 0,
      chain: ["DIRECT"],
      rule: "Match",
      startedAt: seconds.map { Date(timeIntervalSince1970: $0) }
    )
  }

  // MARK: - Sites

  func testRecentSitesAreTheFrontmostAppsDomainsNewestFirstAndDistinct() {
    let connections = [
      connection("1", host: "old.example.com", processPath: Self.chromeHelper, startedAt: 100),
      connection("2", host: "github.com", processPath: Self.chromeHelper, startedAt: 300),
      connection("3", host: "slack.com", processPath: "/Applications/Slack.app/Contents/MacOS/Slack", startedAt: 400),
      connection("4", host: "GitHub.com", processPath: Self.chromeHelper, startedAt: 200),
      connection("5", host: "api.github.com", processPath: Self.chromeHelper, startedAt: 250),
    ]

    let sites = FrontmostRoutePolicy.recentSites(for: Self.chrome, connections: connections)

    // Slack's connection is not Chrome's; the helper inside Chrome.app is.
    XCTAssertEqual(sites, ["github.com", "api.github.com", "old.example.com"])
  }

  func testRecentSitesSkipIPOnlyConnectionsAndPreferTheSniffedName() {
    let connections = [
      connection("1", host: "142.250.72.14", processPath: Self.chromeHelper, startedAt: 300),
      connection("2", host: "203.0.113.9", sniffHost: "video.example.com", processPath: Self.chromeHelper, startedAt: 200),
    ]

    XCTAssertEqual(FrontmostRoutePolicy.recentSites(for: Self.chrome, connections: connections), ["video.example.com"])
  }

  func testRecentSitesAreCappedAndUseListOrderWhenTimesAreMissing() {
    let connections = (0..<10).map {
      connection("\($0)", host: "host\($0).example.com", processPath: Self.chromeHelper, startedAt: nil)
    }

    let sites = FrontmostRoutePolicy.recentSites(for: Self.chrome, connections: connections, limit: 3)

    // The core lists connections oldest first, so the last ones are the newest.
    XCTAssertEqual(sites, ["host9.example.com", "host8.example.com", "host7.example.com"])
  }

  func testSafariSitesComeFromWebKitsNetworkingService() {
    let connections = [
      connection("1", host: "apple.com", processPath: Self.webKitNetworking, startedAt: 100),
      connection("2", host: "news.example.com", processName: "com.apple.WebKit.Networking", processPath: nil, startedAt: 200),
    ]

    XCTAssertEqual(
      FrontmostRoutePolicy.recentSites(for: Self.safari, connections: connections),
      ["news.example.com", "apple.com"]
    )
    // Only a WebKit browser borrows WebKit's traffic: Chrome in front must not claim it.
    XCTAssertEqual(FrontmostRoutePolicy.recentSites(for: Self.chrome, connections: connections), [])
  }

  func testABareExecutableOwnsOnlyConnectionsFromItsOwnPath() {
    let tool = FrontmostAppSnapshot(
      name: "tool",
      bundleIdentifier: nil,
      bundleURL: nil,
      executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tool")
    )
    let connections = [
      connection("1", host: "a.example.com", processPath: "/opt/homebrew/bin/tool", startedAt: 1),
      connection("2", host: "b.example.com", processPath: "/opt/homebrew/bin/other", startedAt: 2),
    ]

    XCTAssertEqual(FrontmostRoutePolicy.recentSites(for: tool, connections: connections), ["a.example.com"])
  }

  // MARK: - Subjects

  func testSubjectsOfferTheAppThenItsSites() {
    let connections = [connection("1", host: "github.com", processPath: Self.chromeHelper, startedAt: 1)]

    let subjects = FrontmostRoutePolicy.subjects(for: Self.chrome, connections: connections)

    XCTAssertEqual(subjects, [.app(name: "Google Chrome"), .site(host: "github.com")])
  }

  func testAnAppWithNoLocationOffersOnlyItsSites() {
    let unknown = FrontmostAppSnapshot(name: "Ghost", bundleIdentifier: nil, bundleURL: nil, executableURL: nil)

    XCTAssertEqual(FrontmostRoutePolicy.subjects(for: unknown, connections: []), [])
  }

  func testBrowsersPreselectTheNewestSiteAndOtherAppsPreselectTheApp() {
    let chromeSubjects: [FrontmostRouteSubject] = [.app(name: "Google Chrome"), .site(host: "github.com"), .site(host: "x.com")]
    XCTAssertEqual(FrontmostRoutePolicy.defaultSubject(in: chromeSubjects, app: Self.chrome), .site(host: "github.com"))

    let slackSubjects: [FrontmostRouteSubject] = [.app(name: "Slack"), .site(host: "slack.com")]
    XCTAssertEqual(FrontmostRoutePolicy.defaultSubject(in: slackSubjects, app: Self.slack), .app(name: "Slack"))

    // A browser that has not connected anywhere yet falls back to the app.
    XCTAssertEqual(
      FrontmostRoutePolicy.defaultSubject(in: [.app(name: "Google Chrome")], app: Self.chrome),
      .app(name: "Google Chrome")
    )
  }

  // MARK: - Rules

  func testRoutingTheAppWritesTheSameBundleRuleAsConnections() throws {
    let draft = try XCTUnwrap(FrontmostRoutePolicy.draft(for: .app(name: "Slack"), app: Self.slack, target: .group("Proxy")))

    XCTAssertEqual(draft.rule.kind, .processPathRegex)
    XCTAssertEqual(draft.runtimeRule, #"PROCESS-PATH-REGEX,^/Applications/Slack\.app/,Proxy"#)
    XCTAssertEqual(draft.placement, .beforeProfileRules)
    // The verdict probes with the app's own executable, which the bundle pattern must cover.
    XCTAssertEqual(draft.verificationProcessPath, "/Applications/Slack.app/Contents/MacOS/Slack")

    let fromConnections = try XCTUnwrap(
      AppProcessRule.draft(forProcessPath: "/Applications/Slack.app/Contents/MacOS/Slack")
    )
    XCTAssertEqual(draft.rule.kind, fromConnections.rule.kind)
    XCTAssertEqual(draft.rule.value, fromConnections.rule.value)
  }

  func testRoutingABareExecutableWritesAProcessPathRule() throws {
    let tool = FrontmostAppSnapshot(
      name: "tool",
      bundleIdentifier: nil,
      bundleURL: nil,
      executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tool")
    )

    let draft = try XCTUnwrap(FrontmostRoutePolicy.draft(for: .app(name: "tool"), app: tool, target: .direct))

    XCTAssertEqual(draft.runtimeRule, "PROCESS-PATH,/opt/homebrew/bin/tool,DIRECT")
  }

  func testRoutingASiteWritesTheSameSuffixRuleAsConnections() throws {
    let draft = try XCTUnwrap(
      FrontmostRoutePolicy.draft(for: .site(host: "api.github.com"), app: Self.chrome, target: .node("JP Nano"))
    )

    XCTAssertEqual(draft.runtimeRule, "DOMAIN-SUFFIX,api.github.com,JP Nano")
    XCTAssertEqual(draft.rule, QuickRuleDraft.targeting(host: "api.github.com", policy: "JP Nano").rule.withID(draft.rule.id))
    XCTAssertEqual(draft.verificationInput, RuleMatchSimulationInput(destination: "api.github.com"))
  }

  func testDirectTargetWritesTheBuiltInPolicy() throws {
    let draft = try XCTUnwrap(FrontmostRoutePolicy.draft(for: .site(host: "example.cn"), app: Self.chrome, target: .direct))

    XCTAssertEqual(draft.runtimeRule, "DOMAIN-SUFFIX,example.cn,DIRECT")
  }

  // MARK: - Targets

  func testTargetsListEveryGroupButGlobalAndOnlyRealNodes() {
    let groups = [
      ProxyGroup(name: "GLOBAL", type: "Selector", selected: "Proxy", nodes: [
        ProxyNode(name: "Proxy", type: "Selector", delay: nil, isSelectable: true),
      ]),
      ProxyGroup(name: "Proxy", type: "Selector", selected: "Auto", nodes: [
        ProxyNode(name: "Auto", type: "URLTest", delay: nil, isSelectable: true),
        ProxyNode(name: "JP Nano", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "DIRECT", type: "Direct", delay: nil, isSelectable: true),
        ProxyNode(name: "jp nano", type: "vless", delay: nil, isSelectable: true),
      ]),
      ProxyGroup(name: "Auto", type: "URLTest", selected: "US West", nodes: [
        ProxyNode(name: "US West", type: "ss", delay: nil, isSelectable: false),
      ]),
      ProxyGroup(name: "Reject Ads", type: "Selector", selected: "REJECT", nodes: [
        ProxyNode(name: "REJECT", type: "Reject", delay: nil, isSelectable: true),
      ]),
    ]

    let options = FrontmostRoutePolicy.targetOptions(groups: groups)

    // A url-test group is a valid policy too; GLOBAL is the global-mode selector, not a route.
    XCTAssertEqual(options.groups, ["Proxy", "Auto", "Reject Ads"])
    XCTAssertEqual(options.nodesByGroup, [
      FrontmostRoutePolicy.NodeGroup(group: "Proxy", nodes: ["JP Nano"]),
      FrontmostRoutePolicy.NodeGroup(group: "Auto", nodes: ["US West"]),
    ])
  }

  func testTargetPolicyNames() {
    XCTAssertEqual(FrontmostRouteTarget.group("Proxy").policy, "Proxy")
    XCTAssertEqual(FrontmostRouteTarget.node("JP Nano").policy, "JP Nano")
    XCTAssertEqual(FrontmostRouteTarget.direct.policy, "DIRECT")
  }
}

private extension ManagedRuleOverlayRule {
  func withID(_ id: UUID) -> ManagedRuleOverlayRule {
    var copy = self
    copy.id = id
    return copy
  }
}
