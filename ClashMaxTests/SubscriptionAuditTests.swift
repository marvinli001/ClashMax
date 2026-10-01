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
    // The normalizer drops the other controller variants: the unix socket ignores the secret.
    XCTAssertEqual(item("external-controller-unix", in: report)?.disposition, .overridden)
    XCTAssertEqual(item("external-controller-unix", in: report)?.outcome, String(localized: "Removed by ClashMax."))
    // Every danger item here was overridden, so nothing is left for the user to act on.
    XCTAssertFalse(report.needsAttention)

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
    // Measured: the same list made ClashMax's own port answer 407 to local apps until the
    // normalizer exempted loopback; it still gates every port another device reaches.
    let authentication = try XCTUnwrap(item("authentication", in: report))
    XCTAssertEqual(authentication.severity, .info)
    XCTAssertEqual(authentication.disposition, .passedThrough)
    XCTAssertEqual(
      authentication.outcome,
      String(
        format: String(localized: "Passed through. Apps on this Mac are exempt: ClashMax adds %@ to skip-auth-prefixes."),
        "127.0.0.0/8, ::1/128"
      )
    )
    XCTAssertEqual(
      authentication.consequence,
      String(localized: "Other devices that reach your proxy, through Allow LAN or a listener, must sign in with these credentials, which whoever wrote the subscription also knows.")
    )
    let encoded = try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(encoded.contains("lan-pass"))
  }

  func testAuthenticationWithoutTheLoopbackExemptionIsStillReportedAsBreakingTheSystemProxy() throws {
    // The exemption is read from the generated config, not assumed: a runtime that lacks it is
    // reported with the measured 407.
    let source = """
    authentication:
      - "lan-user:lan-pass"
    \(Self.nodes)
    """
    let runtime = """
    authentication:
      - "lan-user:lan-pass"
    skip-auth-prefixes: ["127.0.0.0/8"]
    \(Self.nodes)
    """

    let report = SubscriptionAuditBuilder.build(
      sourceYAML: source,
      runtimeYAML: runtime,
      listenerPolicy: nil,
      trigger: .imported,
      generatedAt: Date()
    )

    let authentication = try XCTUnwrap(item("authentication", in: report))
    XCTAssertEqual(authentication.severity, .warning)
    XCTAssertEqual(authentication.outcome, String(localized: "Passed through."))
    XCTAssertEqual(
      authentication.consequence,
      String(localized: "ClashMax's own port asks for these credentials too, so apps using the system proxy get HTTP 407 and stop connecting.")
    )
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

  // MARK: skip-auth-prefixes

  private static let everyIPv4Address = String(format: String(localized: "any IPv4 address (%@)"), "0.0.0.0/0")

  private static let wideOpenListenerSource = """
  authentication:
    - "lan-user:lan-pass"
  skip-auth-prefixes: ["0.0.0.0/0"]
  listeners:
    - name: lan-mixed
      type: mixed
      listen: 0.0.0.0
      port: 7999
  \(nodes)
  """

  /// Measured on v1.19.31: with `0.0.0.0/0` in the list, a LAN source used the authenticated
  /// listener with no credentials. Neither the listener nor the authentication item may still say
  /// that every other device has to sign in.
  func testAPrefixPastThisMacOpensAnAllowedListenerWithoutAPassword() throws {
    let report = try audit(Self.wideOpenListenerSource, policy: .allowExposed, overrides: { $0.allowLan = false })

    let endpoint = RuntimeListener(name: "lan-mixed", type: "mixed", listen: "0.0.0.0", port: "7999").summary
    let prefixes = try XCTUnwrap(item("skip-auth-prefixes", in: report))
    XCTAssertEqual(prefixes.severity, .danger)
    XCTAssertEqual(prefixes.disposition, .passedThrough, "ClashMax only appends loopback; the profile's entry runs")
    XCTAssertEqual(
      prefixes.attempted,
      String(format: String(localized: "Let connections from %@ skip the authentication list."), "0.0.0.0/0")
    )
    XCTAssertEqual(
      prefixes.consequence,
      String(format: String(localized: "Devices at %@ can use your proxy through %@ without a password."), Self.everyIPv4Address, endpoint)
    )
    XCTAssertEqual(
      item("listeners", in: report)?.consequence,
      String(
        format: String(localized: "Devices at %@ can use your proxy through %@ without a password, because the profile's skip-auth-prefixes exempts them. Other devices need the credentials in its authentication list."),
        Self.everyIPv4Address,
        endpoint
      )
    )
    XCTAssertEqual(
      item("authentication", in: report)?.consequence,
      String(
        format: String(localized: "Devices at %@ skip these credentials because of skip-auth-prefixes. Other devices that reach your proxy, through Allow LAN or a listener, must sign in with them, which whoever wrote the subscription also knows."),
        Self.everyIPv4Address
      )
    )
    XCTAssertTrue(report.needsAttention)
  }

  /// Kept off and Allow LAN off: nothing another device can reach is open yet, so the item says
  /// what allowing either would do — and the confirmation for allowing the listener says it too.
  func testAPrefixPastThisMacIsAWarningWhileNothingTheNetworkCanReachIsOpen() throws {
    let report = try audit(Self.wideOpenListenerSource, policy: nil, overrides: { $0.allowLan = false })

    let prefixes = try XCTUnwrap(item("skip-auth-prefixes", in: report))
    XCTAssertEqual(prefixes.severity, .warning)
    XCTAssertEqual(
      prefixes.consequence,
      String(
        format: String(localized: "If you turn on Allow LAN or allow listeners other devices can reach, devices at %@ can use your proxy without a password."),
        Self.everyIPv4Address
      )
    )
    let endpoint = RuntimeListener(name: "lan-mixed", type: "mixed", listen: "0.0.0.0", port: "7999").summary
    XCTAssertEqual(
      item("listeners", in: report)?.consequence,
      String(
        format: String(localized: "If allowed: %@"),
        String(
          format: String(localized: "Devices at %@ can use your proxy through %@ without a password, because the profile's skip-auth-prefixes exempts them. Other devices need the credentials in its authentication list."),
          Self.everyIPv4Address,
          endpoint
        )
      )
    )
  }

  /// Measured on v1.19.31: under Allow LAN the same exemption opened the mixed port, listeners or not.
  func testAPrefixPastThisMacReachesTheMixedPortUnderAllowLAN() throws {
    let source = """
    authentication:
      - "lan-user:lan-pass"
    skip-auth-prefixes:
      - 192.168.0.0/16
    \(Self.nodes)
    """

    let report = try audit(source, overrides: { $0.allowLan = true; $0.mixedPort = 17890 })

    let prefixes = try XCTUnwrap(item("skip-auth-prefixes", in: report))
    XCTAssertEqual(prefixes.severity, .danger)
    XCTAssertEqual(
      prefixes.consequence,
      String(
        format: String(localized: "Devices at %@ can use your proxy through %@ without a password."),
        "192.168.0.0/16",
        String(format: String(localized: "the mixed port %@ (Allow LAN is on)"), "17890")
      )
    )
    XCTAssertTrue(report.needsAttention)
  }

  func testPrefixesThatNameOnlyThisMacOrHaveNothingToSkipAreInformational() throws {
    let loopback = try audit("authentication: [\"u:p\"]\nskip-auth-prefixes: [\"127.0.0.0/8\"]\n\(Self.nodes)", overrides: { $0.allowLan = true })
    let loopbackItem = try XCTUnwrap(item("skip-auth-prefixes", in: loopback))
    XCTAssertEqual(loopbackItem.severity, .info)
    XCTAssertEqual(loopbackItem.disposition, .passedThrough, "the normalizer appended ::1/128 and kept the entry")
    XCTAssertEqual(
      loopbackItem.outcome,
      String(localized: "Passed through: every entry is an address on this Mac, which ClashMax exempts anyway.")
    )
    XCTAssertFalse(loopback.needsAttention)

    // Measured: the core unmaps IPv4 sources, so a mapped prefix lets nobody in, even under Allow LAN.
    let mapped = try audit("authentication: [\"u:p\"]\nskip-auth-prefixes: [\"::ffff:0:0/96\", \"127.0.0.0/8\"]\n\(Self.nodes)", overrides: { $0.allowLan = true })
    let mappedItem = try XCTUnwrap(item("skip-auth-prefixes", in: mapped))
    XCTAssertEqual(mappedItem.severity, .info)
    XCTAssertEqual(
      mappedItem.outcome,
      String(localized: "Passed through, with no effect on other machines: the core never matches an IPv4-mapped prefix, and this Mac is exempt anyway.")
    )
    XCTAssertFalse(mapped.needsAttention)

    let unauthenticated = try audit("skip-auth-prefixes: [\"0.0.0.0/0\"]\n\(Self.nodes)", overrides: { $0.allowLan = true })
    let unauthenticatedItem = try XCTUnwrap(item("skip-auth-prefixes", in: unauthenticated))
    XCTAssertEqual(unauthenticatedItem.severity, .info)
    XCTAssertEqual(
      unauthenticatedItem.outcome,
      String(localized: "Passed through, with no effect: the profile asks no one for credentials.")
    )

    let emptyList = try audit("authentication: [\"u:p\"]\nskip-auth-prefixes: []\n\(Self.nodes)")
    XCTAssertNil(item("skip-auth-prefixes", in: emptyList), "an empty list exempts nobody")
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
