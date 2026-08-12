import XCTest
@testable import ClashMax

/// Issue #15 phase B: adding a rule from the row that showed the problem, and then being told
/// whether that rule is actually the one deciding the route.
final class QuickRuleTests: XCTestCase {
  // MARK: - Prefill

  func testOverridingCarriesTypeAndPayloadButNotPolicy() {
    let runtimeRule = RuntimeRule(
      index: 12,
      type: "DOMAIN-SUFFIX",
      payload: "github.com",
      policy: "Proxy",
      raw: "DOMAIN-SUFFIX,github.com,Proxy"
    )

    let draft = QuickRuleDraft.overriding(runtimeRule)

    XCTAssertEqual(draft.rule.kind, .domainSuffix)
    XCTAssertEqual(draft.rule.value, "github.com")
    // Copying the policy would produce a rule identical to the one being overridden.
    XCTAssertEqual(draft.rule.policy, "")
    XCTAssertEqual(draft.placement, .beforeProfileRules)
  }

  func testOverridingAcceptsTheCamelCaseTypesARunningCoreReports() {
    let runtimeRule = RuntimeRule(
      index: 3,
      type: "DomainSuffix",
      payload: "example.com",
      policy: "DIRECT",
      raw: "DomainSuffix,example.com,DIRECT"
    )

    // The core spells the type differently from the config, and the prefill must not silently
    // fall back to a type the user did not ask for without at least staying usable.
    let draft = QuickRuleDraft.overriding(runtimeRule)
    XCTAssertEqual(draft.rule.value, "example.com")
  }

  func testOverridingAnUnrepresentableTypeStillProducesAUsableDraft() {
    let runtimeRule = RuntimeRule(
      index: 1,
      type: "SOMETHING-NEW",
      payload: "example.com",
      policy: "DIRECT",
      raw: "SOMETHING-NEW,example.com,DIRECT"
    )

    let draft = QuickRuleDraft.overriding(runtimeRule)

    XCTAssertEqual(draft.rule.kind, .domainSuffix)
    XCTAssertEqual(draft.rule.value, "example.com")
  }

  func testTargetingAHostnameUsesASuffixRule() {
    let draft = QuickRuleDraft.targeting(host: "api.github.com", policy: "Proxy")

    XCTAssertEqual(draft.rule.kind, .domainSuffix)
    XCTAssertEqual(draft.rule.value, "api.github.com")
    XCTAssertEqual(draft.runtimeRule, "DOMAIN-SUFFIX,api.github.com,Proxy")
  }

  func testTargetingALiteralIPUsesACIDRRuleInsteadOfAnUnmatchableSuffix() {
    let ipv4 = QuickRuleDraft.targeting(host: "203.0.113.7", policy: "DIRECT")
    XCTAssertEqual(ipv4.rule.kind, .ipCIDR)
    XCTAssertEqual(ipv4.runtimeRule, "IP-CIDR,203.0.113.7/32,DIRECT")

    let ipv6 = QuickRuleDraft.targeting(host: "2001:db8::1", policy: "DIRECT")
    XCTAssertEqual(ipv6.rule.kind, .ipCIDR6)
    XCTAssertEqual(ipv6.runtimeRule, "IP-CIDR6,2001:db8::1/128,DIRECT")
  }

  func testTargetingTrimsSurroundingWhitespace() {
    let draft = QuickRuleDraft.targeting(host: "  example.com  ", policy: "DIRECT")
    XCTAssertEqual(draft.rule.value, "example.com")
  }

  func testDraftWithoutAPolicyDoesNotValidate() {
    let draft = QuickRuleDraft.targeting(host: "example.com")
    XCTAssertNotNil(draft.validationError)
  }

  /// Switching the type in the sheet leaves the prefilled value behind, and an IP rule holding a
  /// domain is a config Mihomo refuses outright — so it has to be caught before it is applied.
  func testIPRuleWithANonCIDRValueDoesNotValidate() {
    for kind in [ManagedRuleOverlayRule.Kind.ipCIDR, .ipCIDR6] {
      let draft = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: kind, value: "example.com", policy: "DIRECT"))
      XCTAssertNotNil(draft.validationError, "\(kind.rawValue) with a domain value must not validate")

      // A bare address is not a range either; Mihomo requires the prefix.
      let bare = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: kind, value: "10.0.0.1", policy: "DIRECT"))
      XCTAssertNotNil(bare.validationError, "\(kind.rawValue) needs a prefix length")
    }

    let valid = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT"))
    XCTAssertNil(valid.validationError)
  }

  func testTargetingALiteralIPProducesAValidDraft() {
    // The prefill has to satisfy the same validation, or the sheet would open pre-broken.
    XCTAssertNil(QuickRuleDraft.targeting(host: "203.0.113.7", policy: "DIRECT").validationError)
    XCTAssertNil(QuickRuleDraft.targeting(host: "2001:db8::1", policy: "DIRECT").validationError)
  }

  // MARK: - "Is this rule the one that matched?"

  func testDescribesMatchesTheSameRuleReportedByARunningCore() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")

    // A running core reports the type camelCased and without hyphens.
    let reported = RuntimeRule(
      index: 1,
      type: "DomainSuffix",
      payload: "example.com",
      policy: "Proxy",
      raw: "DomainSuffix,example.com,Proxy"
    )

    XCTAssertTrue(draft.describes(reported))
  }

  func testDescribesRejectsARuleWithADifferentPolicy() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    let other = RuntimeRule(
      index: 1,
      type: "DomainSuffix",
      payload: "example.com",
      policy: "DIRECT",
      raw: "DomainSuffix,example.com,DIRECT"
    )

    XCTAssertFalse(draft.describes(other))
  }

  func testDescribesRejectsADifferentPayload() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    let other = RuntimeRule(
      index: 1,
      type: "DomainSuffix",
      payload: "example.org",
      policy: "Proxy",
      raw: "DomainSuffix,example.org,Proxy"
    )

    XCTAssertFalse(draft.describes(other))
  }

  func testDescribesIgnoresPayloadForMatchRules() {
    let draft = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .match, policy: "DIRECT"))
    let reported = RuntimeRule(index: 9, type: "Match", payload: "", policy: "DIRECT", raw: "MATCH,DIRECT")

    XCTAssertTrue(draft.describes(reported))
  }

  // MARK: - Verification probes

  func testVerificationInputProbesTheRuleItself() {
    let suffix = QuickRuleDraft.targeting(host: "example.com", policy: "DIRECT")
    XCTAssertEqual(suffix.verificationInput?.destination, "example.com")

    let cidr = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT"))
    XCTAssertEqual(cidr.verificationInput?.destination, "10.0.0.0")

    let srcCIDR = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .srcIPCIDR, value: "192.168.1.0/24", policy: "DIRECT"))
    XCTAssertEqual(srcCIDR.verificationInput?.sourceIP, "192.168.1.0")

    let port = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .dstPort, value: "8000-8100", policy: "DIRECT"))
    XCTAssertEqual(port.verificationInput?.destinationPort, "8000")

    let process = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .processName, value: "curl", policy: "DIRECT"))
    XCTAssertEqual(process.verificationInput?.process, "curl")
  }

  func testVerificationInputIsUnavailableForRulesMihomoDecidesItself() {
    for kind in [ManagedRuleOverlayRule.Kind.geoIP, .geoSite, .ruleSet, .subRule, .srcGeoIP, .srcIPASN, .srcIPSuffix, .match] {
      let draft = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: kind, value: "CN", policy: "DIRECT"))
      XCTAssertNil(
        draft.verificationInput,
        "\(kind.rawValue) cannot be simulated locally, so no verdict should be claimed"
      )
    }
  }

  func testVerificationInputIsUnavailableWhenTheValueCannotBeProbed() {
    let malformedCIDR = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .ipCIDR, value: "not-an-ip/24", policy: "DIRECT"))
    XCTAssertNil(malformedCIDR.verificationInput)

    let malformedPort = QuickRuleDraft(rule: ManagedRuleOverlayRule(kind: .dstPort, value: "http", policy: "DIRECT"))
    XCTAssertNil(malformedPort.verificationInput)
  }

  /// The point of B3: a rule can be live and still lose, and the user has to be told which.
  func testAppliedRuleThatLosesToAnEarlierRuleIsDetectable() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    let rules = [
      RuntimeRule(index: 1, type: "DomainKeyword", payload: "example", policy: "DIRECT", raw: "DOMAIN-KEYWORD,example,DIRECT"),
      RuntimeRule(index: 2, type: "DomainSuffix", payload: "example.com", policy: "Proxy", raw: "DOMAIN-SUFFIX,example.com,Proxy")
    ]

    let input = try? XCTUnwrap(draft.verificationInput)
    let trace = RuleMatchSimulator().simulate(
      input: input ?? RuleMatchSimulationInput(),
      candidates: RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: rules)
    )

    guard case let .matched(winner) = trace.outcome else {
      return XCTFail("expected a match, got \(trace.outcome)")
    }
    XCTAssertEqual(winner.index, 1)
    XCTAssertFalse(draft.describes(winner), "the keyword rule wins, so the quick rule is shadowed")
  }

  func testAppliedRuleThatWinsIsDetectable() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    let rules = [
      RuntimeRule(index: 1, type: "DomainSuffix", payload: "example.com", policy: "Proxy", raw: "DOMAIN-SUFFIX,example.com,Proxy"),
      RuntimeRule(index: 2, type: "DomainKeyword", payload: "example", policy: "DIRECT", raw: "DOMAIN-KEYWORD,example,DIRECT")
    ]

    let trace = RuleMatchSimulator().simulate(
      input: RuleMatchSimulationInput(destination: "example.com"),
      candidates: RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: rules)
    )

    guard case let .matched(winner) = trace.outcome else {
      return XCTFail("expected a match, got \(trace.outcome)")
    }
    XCTAssertTrue(draft.describes(winner))
  }

  // MARK: - Storage

  func testQuickRulesLandInASingleFixedSnippet() {
    let first = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil)
    XCTAssertEqual(first.id, QuickRuleLibrary.snippetID)

    let withRule = QuickRuleLibrary.adding(QuickRuleDraft.targeting(host: "a.com", policy: "DIRECT"), to: first)
    let second = QuickRuleLibrary.targetSnippet(in: [withRule], activeProfileID: nil)

    XCTAssertEqual(second.id, QuickRuleLibrary.snippetID, "a second quick rule must reuse the same snippet")
    guard case let .rules(settings) = second.payload else {
      return XCTFail("quick rules snippet must carry a rule payload")
    }
    XCTAssertEqual(settings.prependRules.count, 1)
  }

  func testTargetSnippetIsAlwaysLiveForTheActiveProfile() {
    let profileID = UUID()
    let dormant = RuntimeSnippet(
      id: QuickRuleLibrary.snippetID,
      name: "Quick Rules",
      enabled: false,
      binding: .profiles([UUID()]),
      payload: .rules(RuleOverlaySettings(enabled: true))
    )

    let target = QuickRuleLibrary.targetSnippet(in: [dormant], activeProfileID: profileID)

    // A rule added into a disabled or unbound snippet is stored and does nothing, which is exactly
    // the silent no-op issue #15 is about.
    XCTAssertTrue(target.enabled)
    XCTAssertTrue(target.binding.applies(to: profileID))
  }

  func testTargetSnippetLeavesAForeignPayloadOnTheSameIDAlone() {
    let squatter = RuntimeSnippet(
      id: QuickRuleLibrary.snippetID,
      name: "Restored DNS patch",
      payload: .dnsPatch(TunDNSSettings())
    )

    let target = QuickRuleLibrary.targetSnippet(in: [squatter], activeProfileID: nil)

    XCTAssertNotEqual(target.id, QuickRuleLibrary.snippetID, "user data must never be overwritten")
    guard case .rules = target.payload else {
      return XCTFail("the replacement snippet must be a rule snippet")
    }
  }

  func testNewestPrependedRuleWins() {
    var snippet = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil)
    snippet = QuickRuleLibrary.adding(QuickRuleDraft.targeting(host: "first.com", policy: "DIRECT"), to: snippet)
    snippet = QuickRuleLibrary.adding(QuickRuleDraft.targeting(host: "second.com", policy: "DIRECT"), to: snippet)

    guard case let .rules(settings) = snippet.payload else {
      return XCTFail("expected a rule payload")
    }
    XCTAssertEqual(settings.prependRules.map(\.value), ["second.com", "first.com"])
  }

  func testReAddingARuleAtANewPlacementMovesItInsteadOfDuplicatingIt() {
    var snippet = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil)
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "DIRECT")
    snippet = QuickRuleLibrary.adding(draft, to: snippet)

    var moved = draft
    moved.placement = .afterProfileRules
    snippet = QuickRuleLibrary.adding(moved, to: snippet)

    guard case let .rules(settings) = snippet.payload else {
      return XCTFail("expected a rule payload")
    }
    // A stale copy left in the prepends would still win, so the move would look like it did nothing.
    XCTAssertTrue(settings.prependRules.isEmpty)
    XCTAssertEqual(settings.appendRules.map(\.runtimeRule), ["DOMAIN-SUFFIX,example.com,DIRECT"])
  }

  /// Re-adding the same rule must not reload the core to produce the identical config, and the
  /// check cannot be an identity comparison: every draft carries a fresh rule id.
  func testReAddingAnUnchangedRuleIsRecognisedAsANoOp() {
    let profileID = UUID()
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    let snippet = QuickRuleLibrary.adding(
      draft,
      to: QuickRuleLibrary.targetSnippet(in: [], activeProfileID: profileID)
    )

    // A different draft object for the same rule, exactly as a second visit to the sheet produces.
    let sameRuleAgain = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    XCTAssertNotEqual(sameRuleAgain.rule.id, draft.rule.id)

    XCTAssertTrue(QuickRuleLibrary.isAlreadyActive(sameRuleAgain, in: snippet, activeProfileID: profileID))
  }

  func testChangingTheRuleIsNotANoOp() {
    let profileID = UUID()
    let snippet = QuickRuleLibrary.adding(
      QuickRuleDraft.targeting(host: "example.com", policy: "Proxy"),
      to: QuickRuleLibrary.targetSnippet(in: [], activeProfileID: profileID)
    )

    let differentPolicy = QuickRuleDraft.targeting(host: "example.com", policy: "DIRECT")
    XCTAssertFalse(QuickRuleLibrary.isAlreadyActive(differentPolicy, in: snippet, activeProfileID: profileID))

    var differentPlacement = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    differentPlacement.placement = .afterProfileRules
    XCTAssertFalse(QuickRuleLibrary.isAlreadyActive(differentPlacement, in: snippet, activeProfileID: profileID))
  }

  func testRuleThatIsPresentButOutrankedIsNotANoOp() {
    let profileID = UUID()
    var snippet = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: profileID)
    let first = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    snippet = QuickRuleLibrary.adding(first, to: snippet)
    snippet = QuickRuleLibrary.adding(QuickRuleDraft.targeting(host: "other.com", policy: "DIRECT"), to: snippet)

    // Adding it again moves it back to the front, which is a real change.
    XCTAssertFalse(QuickRuleLibrary.isAlreadyActive(first, in: snippet, activeProfileID: profileID))
  }

  func testARuleInADormantSnippetIsNeverTreatedAsActive() {
    let profileID = UUID()
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    var snippet = QuickRuleLibrary.adding(
      draft,
      to: QuickRuleLibrary.targetSnippet(in: [], activeProfileID: profileID)
    )

    snippet.enabled = false
    XCTAssertFalse(QuickRuleLibrary.isAlreadyActive(draft, in: snippet, activeProfileID: profileID))

    snippet.enabled = true
    snippet.binding = .profiles([UUID()])
    XCTAssertFalse(
      QuickRuleLibrary.isAlreadyActive(draft, in: snippet, activeProfileID: profileID),
      "a rule bound to another profile does nothing for the active one"
    )
  }

  func testNoQuickRulesSnippetMeansNothingIsActive() {
    let draft = QuickRuleDraft.targeting(host: "example.com", policy: "Proxy")
    XCTAssertFalse(QuickRuleLibrary.isAlreadyActive(draft, in: nil, activeProfileID: UUID()))
  }

  func testAddingARuleEnablesTheOverlay() {
    let snippet = RuntimeSnippet(
      id: QuickRuleLibrary.snippetID,
      name: "Quick Rules",
      payload: .rules(RuleOverlaySettings(enabled: false))
    )

    let updated = QuickRuleLibrary.adding(QuickRuleDraft.targeting(host: "a.com", policy: "DIRECT"), to: snippet)

    guard case let .rules(settings) = updated.payload else {
      return XCTFail("expected a rule payload")
    }
    XCTAssertTrue(settings.enabled)
  }

  // MARK: - Disabling a profile's own rule

  func testDisablingAndEnablingARuleRoundTrips() {
    let raw = "DOMAIN-SUFFIX,ads.example.com,REJECT"
    var snippet = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil)

    snippet = QuickRuleLibrary.disabling(raw, in: snippet)
    guard case let .rules(disabled) = snippet.payload else {
      return XCTFail("expected a rule payload")
    }
    XCTAssertEqual(disabled.disabledRuleMatchers.count, 1)
    XCTAssertEqual(disabled.disabledRuleMatchers.first?.mode, .exact)
    XCTAssertTrue(disabled.disabledRuleMatchers.first?.isExactDisable(of: raw) == true)

    snippet = QuickRuleLibrary.enabling(raw, in: snippet)
    guard case let .rules(enabled) = snippet.payload else {
      return XCTFail("expected a rule payload")
    }
    XCTAssertTrue(enabled.disabledRuleMatchers.isEmpty)
  }

  func testDisablingTheSameRuleTwiceDoesNotAccumulateMatchers() {
    let raw = "DOMAIN-SUFFIX,ads.example.com,REJECT"
    var snippet = QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil)
    snippet = QuickRuleLibrary.disabling(raw, in: snippet)
    snippet = QuickRuleLibrary.disabling(raw, in: snippet)

    guard case let .rules(settings) = snippet.payload else {
      return XCTFail("expected a rule payload")
    }
    XCTAssertEqual(settings.disabledRuleMatchers.count, 1)
  }

  func testExactDisableMatcherIgnoresAContainsMatcherOnTheSameText() {
    let raw = "DOMAIN-SUFFIX,ads.example.com,REJECT"
    let contains = ManagedRuleDisableMatcher(mode: .contains, pattern: raw)
    XCTAssertFalse(contains.isExactDisable(of: raw), "a hand-written contains matcher is not the quick-rule toggle")
  }

  func testDisabledRuleActuallyDropsOutOfTheComposedRuleList() {
    let raw = "DOMAIN-SUFFIX,ads.example.com,REJECT"
    let snippet = QuickRuleLibrary.disabling(raw, in: QuickRuleLibrary.targetSnippet(in: [], activeProfileID: nil))
    let runtimeRules = [
      RuntimeRule(index: 1, type: "DomainSuffix", payload: "ads.example.com", policy: "REJECT", raw: raw),
      RuntimeRule(index: 2, type: "Match", payload: "", policy: "DIRECT", raw: "MATCH,DIRECT")
    ]

    let candidates = RuntimeRuleCandidateBuilder.candidates(
      globalOverlay: .disabled,
      profileOverlay: .disabled,
      snippetOverlay: RuntimeSnippetApplication(snippets: [snippet]).ruleOverlay,
      runtimeRules: runtimeRules
    )

    XCTAssertFalse(
      candidates.contains { $0.rule.raw == raw },
      "the disable toggle must remove the rule, not just record an intent"
    )
  }
}
