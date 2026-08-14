@testable import ClashMax
import XCTest

/// The local rule simulator has to understand rule types in both spellings the app sees them in:
/// `DOMAIN-SUFFIX` as written in a config, and `DomainSuffix` as a running Mihomo core reports it
/// back over `/rules`. Switching on only the config spelling meant every hyphenated type fell
/// through to a substring fallback whenever the core was running — which is exactly when Routing,
/// "Why This Rule" and the quick-rule verdict are used.
final class RuleMatchSimulatorRuleTypeTests: XCTestCase {
  private let simulator = RuleMatchSimulator()

  private func rule(_ type: String, _ payload: String, _ policy: String = "Proxy", index: Int = 1) -> RuntimeRule {
    RuntimeRule(index: index, type: type, payload: payload, policy: policy, raw: "\(type),\(payload),\(policy)")
  }

  private func matchedPolicy(
    _ rules: [RuntimeRule],
    _ input: RuleMatchSimulationInput
  ) -> String? {
    let trace = simulator.simulate(
      input: input,
      candidates: RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: rules)
    )
    guard case let .matched(rule) = trace.outcome else { return nil }
    return rule.policy
  }

  func testBothSpellingsOfEveryDomainTypeMatch() {
    for type in ["DOMAIN", "Domain"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "example.com")], RuleMatchSimulationInput(destination: "example.com")),
        "Proxy",
        "\(type) should match an exact domain"
      )
    }

    for type in ["DOMAIN-SUFFIX", "DomainSuffix"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "example.com")], RuleMatchSimulationInput(destination: "api.example.com")),
        "Proxy",
        "\(type) should match a subdomain"
      )
      XCTAssertNil(
        matchedPolicy([rule(type, "example.com")], RuleMatchSimulationInput(destination: "notexample.com")),
        "\(type) must not match a domain that merely ends with the same characters"
      )
    }

    for type in ["DOMAIN-KEYWORD", "DomainKeyword"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "exam")], RuleMatchSimulationInput(destination: "api.example.com")),
        "Proxy",
        "\(type) should match a keyword"
      )
    }
  }

  func testBothSpellingsOfCIDRTypesMatch() {
    for type in ["IP-CIDR", "IPCIDR"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "10.0.0.0/8")], RuleMatchSimulationInput(destination: "10.1.2.3")),
        "Proxy",
        "\(type) should match an address inside the range"
      )
      XCTAssertNil(
        matchedPolicy([rule(type, "10.0.0.0/8")], RuleMatchSimulationInput(destination: "192.168.0.1")),
        "\(type) must not match an address outside the range"
      )
    }

    // A running core reports an IP-CIDR6 rule as plain `IPCIDR`, so the family cannot be pinned by
    // the type name — the payload carries it.
    for type in ["IP-CIDR6", "IPCIDR"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "2001:db8::/32")], RuleMatchSimulationInput(destination: "2001:db8::1")),
        "Proxy",
        "\(type) should match an IPv6 address inside the range"
      )
    }

    for type in ["SRC-IP-CIDR", "SrcIPCIDR"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "192.168.1.0/24")], RuleMatchSimulationInput(sourceIP: "192.168.1.20")),
        "Proxy",
        "\(type) should match a source address inside the range"
      )
    }
  }

  func testBothSpellingsOfPortTypesMatch() {
    for type in ["DST-PORT", "DstPort"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "8000-8100")], RuleMatchSimulationInput(destinationPort: "8080")),
        "Proxy",
        "\(type) should match a port inside the range"
      )
    }

    for type in ["SRC-PORT", "SrcPort"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "5000")], RuleMatchSimulationInput(sourcePort: "5000")),
        "Proxy",
        "\(type) should match an exact source port"
      )
    }

    for type in ["IN-PORT", "InPort"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "7890")], RuleMatchSimulationInput(inboundPort: "7890")),
        "Proxy",
        "\(type) should match an inbound port"
      )
    }
  }

  func testBothSpellingsOfProcessTypesMatch() {
    for type in ["PROCESS-NAME", "ProcessName"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "curl")], RuleMatchSimulationInput(process: "/usr/bin/curl")),
        "Proxy",
        "\(type) should match the process name out of a path"
      )
    }

    for type in ["PROCESS-PATH", "ProcessPath"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "/usr/bin/curl")], RuleMatchSimulationInput(process: "/usr/bin/curl")),
        "Proxy",
        "\(type) should match a full process path"
      )
    }
  }

  func testMatchRuleMatchesEverythingInBothSpellings() {
    for type in ["MATCH", "Match"] {
      XCTAssertEqual(
        matchedPolicy([rule(type, "")], RuleMatchSimulationInput(destination: "anything.example")),
        "Proxy",
        "\(type) is the catch-all"
      )
    }
  }

  /// Before the type names were normalized these fell through to a substring-contains fallback,
  /// which produced confident matches that Mihomo would not agree with.
  func testTypesDecidedInsideMihomoAreReportedRatherThanGuessed() {
    for type in [
      "GEOIP", "GeoIP", "GEOSITE", "GeoSite", "RULE-SET", "RuleSet", "SUB-RULE",
      "SRC-GEOIP", "SrcGeoIP", "SRC-IP-ASN", "SRC-IP-SUFFIX", "SrcIPSuffix",
      "IP-SUFFIX", "IPSuffix", "NETWORK", "Network",
    ] {
      let trace = simulator.simulate(
        input: RuleMatchSimulationInput(destination: "example.com"),
        candidates: RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: [rule(type, "example.com")])
      )
      guard case .mihomoOnly = trace.outcome else {
        return XCTFail("\(type) should be reported as Mihomo-decided, got \(trace.outcome)")
      }
    }
  }

  func testARuleThatDoesNotMatchDoesNotShadowTheNextOne() {
    // The regression this guards: an IP rule reported as `IPCIDR` used to fall through to the
    // substring fallback and swallow domain traffic that a later rule should have taken.
    let rules = [
      rule("IPCIDR", "10.0.0.0/8", "Wrong", index: 1),
      rule("DomainSuffix", "example.com", "Right", index: 2),
    ]

    XCTAssertEqual(
      matchedPolicy(rules, RuleMatchSimulationInput(destination: "api.example.com")),
      "Right"
    )
  }

  func testNormalizationIsCaseAndSeparatorInsensitive() {
    XCTAssertEqual(RuntimeRuleTypeName.normalized("domain-suffix"), "DOMAINSUFFIX")
    XCTAssertEqual(RuntimeRuleTypeName.normalized("DomainSuffix"), "DOMAINSUFFIX")
    XCTAssertEqual(RuntimeRuleTypeName.normalized(" SRC_IP_CIDR "), "SRCIPCIDR")
    // Mihomo collapses IP-CIDR6 into IPCIDR when reporting, so the two must compare as one type.
    XCTAssertEqual(RuntimeRuleTypeName.canonical("IP-CIDR6"), RuntimeRuleTypeName.canonical("IP-CIDR"))
  }
}
