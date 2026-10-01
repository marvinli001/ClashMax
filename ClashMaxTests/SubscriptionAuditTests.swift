@testable import ClashMax
import Foundation
import XCTest
import Yams

/// Roadmap C1 (and the C3 / A1d items it closes): the audit is built from the profile as fetched and
/// the config ClashMax actually generates from it, so these tests run the real normalizer.
final class SubscriptionAuditTests: XCTestCase {
  private static let nodes = """
  proxies:
    - name: JP
      type: ss
      server: jp.example.com
      port: 8388
      cipher: aes-128-gcm
      password: node-secret-1
  proxy-groups:
    - name: Proxy
      type: select
      proxies: [JP, DIRECT]
  rules:
    - MATCH,Proxy
  """

  // MARK: The danger key set

  func testEveryDangerItemNamesItsConsequenceAndNoSecretIsKept() throws {
    let source = """
    external-controller: 0.0.0.0:9090
    secret: author-known-secret
    external-controller-unix: /tmp/mihomo.sock
    \(Self.nodes)
    """

    let report = try audit(source)

    let danger = report.items.filter { $0.severity == .danger }
    XCTAssertEqual(Set(danger.map(\.key)), ["external-controller", "secret", "external-controller-unix"])
    for item in danger {
      XCTAssertFalse(item.consequence?.isEmpty ?? true, "\(item.key) has no consequence")
    }
    XCTAssertEqual(item("external-controller", in: report)?.disposition, .overridden)
    XCTAssertTrue(item("external-controller", in: report)?.consequence?.contains("0.0.0.0:9090") == true)
    XCTAssertEqual(item("secret", in: report)?.disposition, .overridden)
    // The normalizer does not manage the other controller variants, and the report says so.
    XCTAssertEqual(item("external-controller-unix", in: report)?.disposition, .passedThrough)
    XCTAssertTrue(report.needsAttention)

    let encoded = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(encoded.contains("author-known-secret"))
  }

  func testInboundPortsAndLANAccessAreOverriddenWithTheUsersSettings() throws {
    let source = """
    port: 7890
    socks-port: 7891
    redir-port: 7892
    tproxy-port: 7893
    mixed-port: 7899
    allow-lan: true
    \(Self.nodes)
    """

    let report = try audit(source, overrides: { $0.allowLan = false; $0.mixedPort = 17890 })

    for key in ["port", "socks-port", "redir-port", "tproxy-port", "mixed-port"] {
      XCTAssertEqual(item(key, in: report)?.disposition, .overridden, key)
      XCTAssertTrue(item(key, in: report)?.outcome.contains("17890") == true, key)
    }
    XCTAssertEqual(item("allow-lan", in: report)?.disposition, .overridden)
    XCTAssertTrue(item("allow-lan", in: report)?.outcome.contains("false") == true)
  }

  func testTunAndDNSSayWhichSubkeysWereReplacedAndWhichKept() throws {
    let source = """
    tun:
      enable: true
      stack: gvisor
      auto-redirect: true
    dns:
      enable: true
      enhanced-mode: redir-host
      nameserver: [https://dns.example/dns-query]
    \(Self.nodes)
    """

    let report = try audit(source, overrides: { $0.tunEnabled = false; $0.dnsEnabled = false })

    let tun = try XCTUnwrap(item("tun", in: report))
    XCTAssertTrue(tun.outcome.contains("auto-redirect"), tun.outcome)
    XCTAssertTrue(tun.outcome.contains("enable"), tun.outcome)
    XCTAssertTrue(tun.outcome.contains("stack"), "stack is kept while TUN is off: \(tun.outcome)")
    let dns = try XCTUnwrap(item("dns", in: report))
    XCTAssertEqual(dns.disposition, .passedThrough, "nameservers run as authored")
    XCTAssertTrue(dns.outcome.contains("nameserver"), dns.outcome)
  }

  // MARK: Listeners (C3)

  func testExposedListenersWithoutAuthenticationAreKeptOffUntilAllowed() throws {
    let source = """
    listeners:
      - name: lan-mixed
        type: mixed
        port: 7999
      - name: local-socks
        type: socks
        listen: 127.0.0.1
        port: 7998
    \(Self.nodes)
    """

    let generation = try generate(source, policy: nil)
    let report = SubscriptionAuditBuilder.build(
      sourceYAML: source,
      runtimeYAML: generation,
      listenerPolicy: nil,
      trigger: .imported,
      generatedAt: Date()
    )

    // The normalizer dropped only the exposed one.
    let runtimeListeners = try ListenerRuntimeFacts.facts(from: XCTUnwrap(Yams.load(yaml: generation) as? [String: Any])).listeners
    XCTAssertEqual(runtimeListeners.map(\.name), ["local-socks"])
    let listeners = try XCTUnwrap(item("listeners", in: report))
    XCTAssertEqual(listeners.severity, .danger)
    XCTAssertEqual(listeners.disposition, .overridden)
    // The test host can resolve translated keys to zh-Hans, so the expectation goes through the catalog.
    let endpoint = RuntimeListener(name: "lan-mixed", type: "mixed", port: "7999").summary
    XCTAssertEqual(
      listeners.consequence,
      String(
        format: String(localized: "If allowed: %@"),
        String(format: String(localized: "Anyone on your network can use your proxy through %@ — no password is required."), endpoint)
      )
    )
    XCTAssertEqual(report.exposedListeners.map(\.name), ["lan-mixed"])
    XCTAssertTrue(report.needsListenerDecision)
    XCTAssertTrue(report.needsAttention)
  }

  func testAllowedExposedListenersWithAuthenticationRunAndSaySo() throws {
    let source = """
    authentication:
      - "lan-user:lan-pass"
    listeners:
      - name: lan-mixed
        type: mixed
        listen: 0.0.0.0
        port: 7999
    \(Self.nodes)
    """

    let generation = try generate(source, policy: .allowExposed)
    let report = SubscriptionAuditBuilder.build(
      sourceYAML: source,
      runtimeYAML: generation,
      listenerPolicy: .allowExposed,
      trigger: .updated,
      generatedAt: Date()
    )

    let listeners = try XCTUnwrap(item("listeners", in: report))
    XCTAssertEqual(listeners.disposition, .passedThrough)
    let endpoint = RuntimeListener(name: "lan-mixed", type: "mixed", listen: "0.0.0.0", port: "7999").summary
    XCTAssertEqual(
      listeners.consequence,
      String(
        format: String(localized: "Other devices on your network can use your proxy through %@ with the credentials in the profile's authentication list."),
        endpoint
      )
    )
    XCTAssertFalse(report.needsListenerDecision)
    // Measured: the same list makes ClashMax's own port answer 407 to local apps.
    let authentication = try XCTUnwrap(item("authentication", in: report))
    XCTAssertTrue(authentication.consequence?.contains("407") == true)
    let encoded = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(encoded.contains("lan-pass"))
  }

  func testLoopbackOnlyListenersAreInformational() throws {
    let source = """
    listeners:
      - {name: local, type: socks, listen: 127.0.0.1, port: 7998}
    \(Self.nodes)
    """

    let report = try audit(source)

    XCTAssertEqual(item("listeners", in: report)?.severity, .info)
    XCTAssertTrue(report.exposedListeners.isEmpty)
    XCTAssertFalse(report.needsAttention)
  }

  // MARK: Sniffer (A1d)

  func testSnifferStatesWhatTheSubscriptionWouldChangeAndWhatWasKept() throws {
    let source = """
    sniffer:
      enable: false
      override-destination: false
      skip-domain: [a.example, b.example]
    \(Self.nodes)
    """

    let report = try audit(source)

    let sniffer = try XCTUnwrap(item("sniffer", in: report))
    XCTAssertEqual(sniffer.severity, .warning)
    XCTAssertTrue(
      sniffer.attempted.contains(String(format: String(localized: "override-destination: %@"), "false")),
      sniffer.attempted
    )
    XCTAssertTrue(sniffer.attempted.contains("skip-domain"), sniffer.attempted)
    XCTAssertEqual(sniffer.disposition, .passedThrough, "a profile's own sniffer runs as authored")
    XCTAssertTrue(sniffer.outcome.contains("enable"), sniffer.outcome)
    XCTAssertNotNil(sniffer.consequence, "sniffing off makes domain rules unreachable for IP connections")
  }

  // MARK: Clean and bounded

  func testACleanSubscriptionHasNothingToReview() throws {
    let report = try audit(Self.nodes)

    XCTAssertTrue(report.isClean)
    XCTAssertFalse(report.isNodeListOnly)
    XCTAssertFalse(report.needsAttention)
  }

  func testANodeListSubscriptionIsReportedAsSuch() {
    let report = SubscriptionAuditBuilder.build(
      sourceYAML: "ss://YWVzLTEyOC1nY206cGFzcw@jp.example.com:8388#JP\nss://YWVzLTEyOC1nY206cGFzcw@us.example.com:8388#US\n",
      runtimeYAML: nil,
      listenerPolicy: nil,
      trigger: .imported,
      generatedAt: Date()
    )

    XCTAssertTrue(report.isNodeListOnly)
    XCTAssertTrue(report.isClean)
  }

  func testStoredTextIsRedactedAndBounded() throws {
    let longHost = String(repeating: "a", count: 400) + ".example"
    let source = """
    external-controller: \(longHost):9090
    external-ui-url: https://ui.example.com/download/zip?token=UI-TOKEN-123
    \(Self.nodes)
    """

    let report = try audit(source)

    let controller = try XCTUnwrap(item("external-controller", in: report))
    XCTAssertLessThanOrEqual(controller.attempted.count, SubscriptionAuditReport.textLimit)
    XCTAssertLessThanOrEqual(controller.consequence?.count ?? 0, SubscriptionAuditReport.textLimit)
    let encoded = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(encoded.contains("UI-TOKEN-123"))
    XCTAssertTrue(item("external-ui-url", in: report)?.attempted.contains("ui.example.com") == true)
  }

  func testAcknowledgingClearsAttentionAndLegacyDiagnosticsStillDecode() throws {
    var report = try audit("secret: s3cr3t-value\n\(Self.nodes)")
    report.items.append(SubscriptionAuditReport.Item(
      key: "external-controller-tls",
      severity: .danger,
      disposition: .passedThrough,
      attempted: "x",
      outcome: "y",
      consequence: "z"
    ))
    XCTAssertTrue(report.needsAttention)
    report.acknowledged = true
    XCTAssertFalse(report.needsAttention)

    var diagnostics = SubscriptionDiagnostics()
    diagnostics.latestAudit = report
    let decoded = try JSONDecoder().decode(SubscriptionDiagnostics.self, from: JSONEncoder().encode(diagnostics))
    XCTAssertEqual(decoded.latestAudit, report)
    let legacy = try JSONDecoder().decode(SubscriptionDiagnostics.self, from: Data(#"{"updateHistory":[]}"#.utf8))
    XCTAssertNil(legacy.latestAudit)
  }

  // MARK: The normalizer gate (C3)

  func testOnlyASubscriptionsUnapprovedListenersAreGated() {
    var subscription = Profile(
      id: UUID(),
      name: "Sub",
      source: .subscription(id: UUID()),
      originalConfigPath: "/tmp/sub.yaml"
    )
    var options = RuntimeConfigOptions()
    options.apply(profile: subscription)
    XCTAssertTrue(options.blocksInheritedExposedListeners)

    subscription.subscriptionProviderOptions.exposedListenerPolicy = .allowExposed
    options.apply(profile: subscription)
    XCTAssertFalse(options.blocksInheritedExposedListeners)

    let local = Profile(id: UUID(), name: "Mine", source: .localFile(originalPath: nil), originalConfigPath: "/tmp/mine.yaml")
    options.apply(profile: local)
    XCTAssertFalse(options.blocksInheritedExposedListeners, "a local file is the user's own config")
  }

  func testAUsersOwnRawYAMLListenerIsNeverGated() throws {
    var options = RuntimeConfigOptions()
    options.blocksInheritedExposedListeners = true
    var patch = RawYAMLPatchSettings()
    patch.yaml = "listeners:\n  - {name: mine, type: mixed, port: 7997}\n"
    options.runtimeSnippets = [RuntimeSnippet(name: "Mine", payload: .rawYAML(patch))]

    let yaml = try ConfigNormalizer().runtimeConfig(
      from: "listeners:\n  - {name: theirs, type: mixed, port: 7999}\n\(Self.nodes)",
      overrides: .defaultForLaunch(secret: "s"),
      options: options
    )

    let names = try ListenerRuntimeFacts.facts(from: XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])).listeners.map(\.name)
    XCTAssertEqual(names, ["mine"])
  }

  // MARK: Helpers

  private func audit(
    _ source: String,
    policy: InheritedListenerPolicy? = nil,
    overrides adjust: (inout RuntimeOverrides) -> Void = { _ in }
  ) throws -> SubscriptionAuditReport {
    try SubscriptionAuditBuilder.build(
      sourceYAML: source,
      runtimeYAML: generate(source, policy: policy, overrides: adjust),
      listenerPolicy: policy,
      trigger: .imported,
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func generate(
    _ source: String,
    policy: InheritedListenerPolicy?,
    overrides adjust: (inout RuntimeOverrides) -> Void = { _ in }
  ) throws -> String {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "app-secret")
    adjust(&overrides)
    var options = RuntimeConfigOptions()
    options.subscriptionProviderOptions.exposedListenerPolicy = policy
    options.blocksInheritedExposedListeners = policy != .allowExposed
    return try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides, options: options)
  }

  private func item(_ key: String, in report: SubscriptionAuditReport) -> SubscriptionAuditReport.Item? {
    report.items.first { $0.key == key }
  }
}
