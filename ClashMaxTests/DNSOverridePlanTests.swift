@testable import ClashMax
import XCTest
import Yams

/// Covers the pure classifier behind the Routing › DNS Override panel (issue #16).
final class DNSOverridePlanTests: XCTestCase {
  // MARK: - Facts

  func testFactsAreAbsentWhenProfileHasNoDNSMapping() {
    XCTAssertEqual(DNSRuntimeFacts.facts(from: nil), .absent)
    XCTAssertEqual(DNSRuntimeFacts.facts(from: "dns"), .absent)
    XCTAssertFalse(DNSRuntimeFacts.absent.isPresent)
  }

  func testFactsFlattenListsMapsAndBooleans() throws {
    let facts = try dnsFacts(
      """
      dns:
        enable: true
        respect-rules: true
        enhanced-mode: fake-ip
        nameserver:
          - https://a.example/dns-query
          - https://b.example/dns-query
        nameserver-policy:
          "+.corp.example": https://corp.example/dns-query
          "geosite:cn": 223.5.5.5
      """
    )

    XCTAssertTrue(facts.isPresent)
    XCTAssertEqual(facts.enable, true)
    XCTAssertTrue(facts.respectRules)
    XCTAssertTrue(facts.isFakeIPMode)
    XCTAssertEqual(
      facts.values[.nameserver],
      "https://a.example/dns-query,https://b.example/dns-query"
    )
    // Map keys are sorted so two equal mappings compare equal regardless of YAML order.
    XCTAssertEqual(
      facts.values[.nameserverPolicy],
      "+.corp.example=https://corp.example/dns-query,geosite:cn=223.5.5.5"
    )
  }

  func testEmptyValuesAreNotRecordedAsOverrides() throws {
    let facts = try dnsFacts(
      """
      dns:
        enable: false
        nameserver: []
        hosts: {}
      """
    )

    XCTAssertEqual(facts.enable, false)
    XCTAssertNil(facts.values[.nameserver])
    XCTAssertNil(facts.values[.hosts])
    XCTAssertFalse(facts.hasProxyServerNameserver)
  }

  // MARK: - Overridden fields

  func testPlanReportsOnlyKeysThatDifferFromTheProfile() throws {
    let plan = try plan(
      baselineYAML: """
      dns:
        enable: true
        nameserver:
          - https://keep.example/dns-query
      """,
      finalYAML: """
      dns:
        enable: true
        nameserver:
          - https://keep.example/dns-query
        respect-rules: true
        proxy-server-nameserver:
          - https://doh.pub/dns-query
      """
    )

    XCTAssertEqual(plan.overriddenFields, [.respectRules, .proxyServerNameserver])
    XCTAssertEqual(plan.overriddenFieldNames, ["respect-rules", "proxy-server-nameserver"])
    XCTAssertTrue(plan.hasOverride)
    XCTAssertEqual(plan.enablement, .profile)
  }

  func testPlanIsInactiveWhenTheProfileDecidesDNSAlone() throws {
    let yaml = """
    dns:
      enable: true
      nameserver:
        - https://keep.example/dns-query
    """
    let plan = try plan(baselineYAML: yaml, finalYAML: yaml)

    XCTAssertFalse(plan.hasOverride)
    XCTAssertFalse(plan.isInert)
    XCTAssertTrue(plan.issues.isEmpty)
    XCTAssertEqual(plan.summary, String(localized: "No app-managed DNS override."))
  }

  // MARK: - Enablement

  func testEnablementNamesTheLayerThatTurnedDNSOn() throws {
    let baseline = "proxies: []"
    let final = """
    dns:
      enable: true
      nameserver:
        - https://a.example/dns-query
    """

    XCTAssertEqual(
      try plan(baselineYAML: baseline, finalYAML: final, sources: DNSOverrideSources(globalDNSEnabled: true))
        .enablement,
      .globalToggle
    )
    XCTAssertEqual(
      try plan(
        baselineYAML: baseline,
        finalYAML: final,
        sources: DNSOverrideSources(tunEnabled: true, tunContributesDNS: true)
      ).enablement,
      .tun
    )
    XCTAssertEqual(
      try plan(
        baselineYAML: baseline,
        finalYAML: final,
        sources: DNSOverrideSources(networkExtensionContributesDNS: true)
      ).enablement,
      .networkExtension
    )
    // Nothing else claimed it, so the generator enabled DNS for the snippet patch itself.
    XCTAssertEqual(
      try plan(
        baselineYAML: baseline,
        finalYAML: final,
        sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
      ).enablement,
      .overrideAutoEnabled
    )
  }

  func testGeneratedProviderTemplateIsCreditedInsteadOfTheOverride() throws {
    // A URI-list subscription has no `dns:` of its own, so the whole generated block reads as an
    // override. Without this attribution the panel blames a DNS setting the user never touched.
    let plan = try plan(
      baselineYAML: "https://example.invalid/sub",
      finalYAML: """
      dns:
        enable: true
        respect-rules: true
        enhanced-mode: fake-ip
        proxy-server-nameserver:
          - 223.5.5.5
      """,
      sources: DNSOverrideSources(providerTemplateContributesDNS: true)
    )

    XCTAssertEqual(plan.enablement, .providerTemplate)
    XCTAssertTrue(plan.isEnabled)
    XCTAssertFalse(plan.isInert)
    XCTAssertEqual(plan.contributors, [String(localized: "Subscription template")])
    XCTAssertTrue(plan.blockingIssues.isEmpty)
  }

  func testProviderTemplateOutranksAppLayersButNotTheProfile() throws {
    let sources = DNSOverrideSources(
      globalDNSEnabled: true,
      tunEnabled: true,
      tunContributesDNS: true,
      providerTemplateContributesDNS: true,
      dnsPatchSnippetNames: ["Corp DNS"]
    )

    XCTAssertEqual(
      try plan(baselineYAML: "proxies: []", finalYAML: "dns:\n  enable: true\n", sources: sources).enablement,
      .providerTemplate
    )
    // A full-YAML subscription that already enables DNS still wins: the template never ran for it.
    XCTAssertEqual(
      try plan(baselineYAML: "dns:\n  enable: true\n", finalYAML: "dns:\n  enable: true\n  ipv6: true\n", sources: sources)
        .enablement,
      .profile
    )
  }

  func testTUNThatContributesNoDNSDoesNotClaimEnablement() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: "dns:\n  enable: true\n  respect-rules: false\n",
      sources: DNSOverrideSources(tunEnabled: true, tunContributesDNS: false, dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.enablement, .overrideAutoEnabled)
    XCTAssertEqual(plan.contributors, ["Corp DNS"])
  }

  func testProfileEnablementWinsOverAppLayers() throws {
    let plan = try plan(
      baselineYAML: "dns:\n  enable: true\n",
      finalYAML: "dns:\n  enable: true\n  use-hosts: true\n",
      sources: DNSOverrideSources(globalDNSEnabled: true, tunEnabled: true, tunContributesDNS: true)
    )

    XCTAssertEqual(plan.enablement, .profile)
    XCTAssertEqual(plan.overriddenFields, [.useHosts])
  }

  // MARK: - Inert overrides

  func testOverrideIsInertWhenTheUserTurnedDNSOff() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: """
      dns:
        enable: false
        nameserver:
          - https://a.example/dns-query
      """,
      sources: DNSOverrideSources(globalDNSEnabled: false, dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.enablement, .disabledByUser)
    XCTAssertFalse(plan.isEnabled)
    XCTAssertTrue(plan.isInert)
    XCTAssertEqual(plan.issues.map(\.code), [.overrideInert])
    XCTAssertTrue(plan.blockingIssues.isEmpty)
    XCTAssertEqual(plan.overriddenFields, [.enable, .nameserver])
    XCTAssertEqual(
      plan.summary,
      String(
        format: String(localized: "%@, but DNS is off so Mihomo ignores them."),
        String(format: String(localized: "%lld DNS keys overridden"), Int64(2))
      )
    )
  }

  func testOverrideIsInertWhenNothingEnablesDNS() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: "dns:\n  nameserver:\n    - https://a.example/dns-query\n",
      sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.enablement, .none)
    XCTAssertTrue(plan.isInert)
    XCTAssertEqual(plan.issues.map(\.code), [.overrideInert])
  }

  // MARK: - Issues

  func testRespectRulesWithoutProxyServerNameserverIsBlocking() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: "dns:\n  enable: true\n  respect-rules: true\n",
      sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
    )

    let blocking = plan.blockingIssues
    XCTAssertEqual(blocking.map(\.code), [.respectRulesWithoutProxyServerNameserver])
    XCTAssertEqual(blocking.first?.message, DNSOverridePlanBuilder.respectRulesRequirement)
  }

  func testRespectRulesWithoutProxyServerNameserverIsBlockingEvenWhenDNSIsOff() throws {
    // Mihomo validates this before it looks at `dns.enable`, so "inert" is not "harmless".
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: "dns:\n  enable: false\n  respect-rules: true\n",
      sources: DNSOverrideSources(globalDNSEnabled: false, dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.blockingIssues.map(\.code), [.respectRulesWithoutProxyServerNameserver])
  }

  func testRespectRulesWithResolverExplainsTheRuleRelationship() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: """
      dns:
        enable: true
        respect-rules: true
        proxy-server-nameserver:
          - https://doh.pub/dns-query
      """,
      sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertTrue(plan.blockingIssues.isEmpty)
    XCTAssertEqual(plan.issues.map(\.code), [.respectRulesFollowsRules])
  }

  func testFakeIPFilterWithoutFakeIPModeIsAdvisory() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: """
      dns:
        enable: true
        fake-ip-filter:
          - "*.local"
      """,
      sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.issues.map(\.code), [.fakeIPFilterWithoutFakeIPMode])
    XCTAssertTrue(plan.blockingIssues.isEmpty)
  }

  func testFakeIPFilterInFakeIPModeRaisesNoIssue() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: """
      dns:
        enable: true
        enhanced-mode: fake-ip
        fake-ip-filter:
          - "*.local"
      """,
      sources: DNSOverrideSources(tunEnabled: true, tunContributesDNS: true)
    )

    XCTAssertTrue(plan.issues.isEmpty)
    XCTAssertEqual(plan.contributors, [String(localized: "TUN DNS")])
  }

  // MARK: - Reporting

  func testPlainTextLinesStayStableForTheCopyableReport() throws {
    let plan = try plan(
      baselineYAML: "proxies: []",
      finalYAML: "dns:\n  enable: true\n  respect-rules: true\n",
      sources: DNSOverrideSources(dnsPatchSnippetNames: ["Corp DNS"])
    )

    XCTAssertEqual(plan.plainTextLines[0], "DNS Override: Active")
    XCTAssertEqual(plan.plainTextLines[1], "DNS Enabled: yes (overrideAutoEnabled)")
    XCTAssertEqual(plan.plainTextLines[2], "Overridden Keys: enable, respect-rules")
    XCTAssertEqual(plan.plainTextLines[3], "Contributors: Corp DNS")
    XCTAssertTrue(plan.plainTextLines[4].hasPrefix("Blocking [respectRulesWithoutProxyServerNameserver]: "))
  }

  func testInactivePlanReportsNothing() {
    XCTAssertEqual(
      DNSOverridePlan.inactive.plainTextLines,
      ["DNS Override: None", "DNS Enabled: no (none)"]
    )
  }

  // MARK: - Helpers

  private func dnsFacts(_ yaml: String) throws -> DNSRuntimeFacts {
    let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
    return DNSRuntimeFacts.facts(from: root["dns"])
  }

  private func plan(
    baselineYAML: String,
    finalYAML: String,
    sources: DNSOverrideSources = DNSOverrideSources()
  ) throws -> DNSOverridePlan {
    try DNSOverridePlanBuilder.plan(
      baseline: dnsFactsAllowingAbsent(baselineYAML),
      final: dnsFactsAllowingAbsent(finalYAML),
      sources: sources
    )
  }

  private func dnsFactsAllowingAbsent(_ yaml: String) throws -> DNSRuntimeFacts {
    guard let root = try Yams.load(yaml: yaml) as? [String: Any] else { return .absent }
    return DNSRuntimeFacts.facts(from: root["dns"])
  }
}
