import Foundation

/// Where a quick rule sits relative to the active profile's own rule list.
///
/// Issue #15 phase B: the point of a quick rule is to win *now*, while the user is watching a
/// connection take the wrong route — so prepending is the default. Appending is kept for the
/// opposite case, a catch-all that should only apply once the profile's own rules have all missed.
enum QuickRulePlacement: String, CaseIterable, Identifiable, Codable, Sendable {
  case beforeProfileRules
  case afterProfileRules

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .beforeProfileRules:
      return String(localized: "Before profile rules")
    case .afterProfileRules:
      return String(localized: "After profile rules")
    }
  }

  var explanation: String {
    switch self {
    case .beforeProfileRules:
      return String(localized: "Evaluated ahead of the profile's rules, so it overrides them.")
    case .afterProfileRules:
      return String(localized: "Evaluated only after every profile rule has missed.")
    }
  }
}

/// One rule the user is adding straight from Rules or Connections, without first navigating to
/// Routing and building a snippet by hand.
///
/// This is deliberately a thin wrapper over `ManagedRuleOverlayRule` rather than a new rule model:
/// quick rules are stored in an ordinary runtime snippet and stay fully editable in Routing, so
/// there is exactly one rule representation and one storage format in the app.
struct QuickRuleDraft: Equatable, Sendable {
  var rule: ManagedRuleOverlayRule
  var placement: QuickRulePlacement

  init(rule: ManagedRuleOverlayRule, placement: QuickRulePlacement = .beforeProfileRules) {
    self.rule = rule
    self.placement = placement
  }

  /// Prefill for "add a rule before this one" on the Rules page. The type and payload of the rule
  /// being looked at are carried over, because the common case is overriding *that* rule for the
  /// same target; the policy is left to the caller since copying it would produce a no-op rule.
  static func overriding(_ runtimeRule: RuntimeRule, policy: String = "") -> QuickRuleDraft {
    let kind = ManagedRuleOverlayRule.Kind(runtimeRuleType: runtimeRule.type) ?? .domainSuffix
    return QuickRuleDraft(
      rule: ManagedRuleOverlayRule(
        kind: kind,
        value: kind.requiresValue ? runtimeRule.payload : "",
        policy: policy
      ),
      placement: .beforeProfileRules
    )
  }

  /// Prefill for "add a rule for this host" on the Connections page. A suffix rule is the useful
  /// default: connections are usually reported per subdomain, and the user almost always means the
  /// whole site. A literal IP gets a CIDR rule instead, since a suffix rule would never match one.
  static func targeting(host: String, policy: String = "") -> QuickRuleDraft {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: ManagedRuleOverlayRule.Kind
    let value: String
    switch QuickRuleHostClassifier.classify(host) {
    case .ipv4:
      kind = .ipCIDR
      value = "\(host)/32"
    case .ipv6:
      kind = .ipCIDR6
      value = "\(host)/128"
    case .domain:
      kind = .domainSuffix
      value = host
    }
    return QuickRuleDraft(
      rule: ManagedRuleOverlayRule(kind: kind, value: value, policy: policy),
      placement: .beforeProfileRules
    )
  }

  var validationError: String? {
    rule.validationError
  }

  /// The rule line exactly as it will be written into the runtime config.
  var runtimeRule: String {
    rule.runtimeRule
  }

  /// Whether `runtimeRule` is the rule this draft describes.
  ///
  /// Used to tell "your rule is the one that matched" from "something else matched first" after
  /// applying. The type is compared canonically because the same rule is spelled one way in the
  /// config this draft writes and another way when the core reports it back.
  func describes(_ runtimeRule: RuntimeRule) -> Bool {
    guard RuntimeRuleTypeName.canonical(runtimeRule.type) == RuntimeRuleTypeName.canonical(rule.kind.rawValue) else {
      return false
    }
    guard rule.kind.requiresValue else { return matchesPolicy(runtimeRule.policy) }
    return runtimeRule.payload.trimmingCharacters(in: .whitespacesAndNewlines)
      .compare(rule.normalizedValue, options: [.caseInsensitive]) == .orderedSame
      && matchesPolicy(runtimeRule.policy)
  }

  private func matchesPolicy(_ policy: String) -> Bool {
    policy.trimmingCharacters(in: .whitespacesAndNewlines)
      .compare(rule.normalizedPolicy, options: [.caseInsensitive]) == .orderedSame
  }

  /// An input that should hit this rule once it is live, used to verify after applying that the
  /// rule really is the one that wins. `nil` means the rule's match cannot be reproduced locally
  /// (provider, geodata, and sub-rule matching all happen inside Mihomo), so claiming a verdict
  /// would be guessing.
  var verificationInput: RuleMatchSimulationInput? {
    let value = rule.normalizedValue
    switch rule.kind {
    case .domain, .domainSuffix, .domainKeyword:
      guard !value.isEmpty else { return nil }
      return RuleMatchSimulationInput(destination: value)
    case .ipCIDR, .ipCIDR6:
      guard let address = QuickRuleHostClassifier.address(fromCIDR: value) else { return nil }
      return RuleMatchSimulationInput(destination: address)
    case .srcIPCIDR:
      guard let address = QuickRuleHostClassifier.address(fromCIDR: value) else { return nil }
      return RuleMatchSimulationInput(sourceIP: address)
    case .dstPort:
      guard let port = QuickRuleHostClassifier.firstPort(in: value) else { return nil }
      return RuleMatchSimulationInput(destinationPort: port)
    case .srcPort:
      guard let port = QuickRuleHostClassifier.firstPort(in: value) else { return nil }
      return RuleMatchSimulationInput(sourcePort: port)
    case .inPort:
      guard let port = QuickRuleHostClassifier.firstPort(in: value) else { return nil }
      return RuleMatchSimulationInput(inboundPort: port)
    case .processName, .processPath:
      guard !value.isEmpty else { return nil }
      return RuleMatchSimulationInput(process: value)
    case .geoIP, .geoSite, .ruleSet, .subRule, .srcGeoIP, .srcIPASN, .srcIPSuffix, .match:
      // Matched by Mihomo itself, or (MATCH) matches everything and so proves nothing.
      return nil
    }
  }
}

/// Shared parsing for the bits of a host or rule value the quick-rule flow needs. Kept separate so
/// both the prefill and the verification input use exactly the same notion of "is this an IP".
enum QuickRuleHostClassifier {
  enum HostKind: Equatable, Sendable {
    case ipv4
    case ipv6
    case domain
  }

  static func classify(_ host: String) -> HostKind {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if isIPv4(host) { return .ipv4 }
    if isIPv6(host) { return .ipv6 }
    return .domain
  }

  static func isIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let octet = Int(part) else {
        return false
      }
      return (0...255).contains(octet)
    }
  }

  static func isIPv6(_ value: String) -> Bool {
    guard value.contains(":") else { return false }
    var buffer = [UInt8](repeating: 0, count: 16)
    return value.withCString { pointer in
      inet_pton(AF_INET6, pointer, &buffer) == 1
    }
  }

  /// The bare address out of `1.2.3.0/24`, so a CIDR rule can be probed with an address inside it.
  /// Only the network address is used — it is always a member of its own range.
  static func address(fromCIDR value: String) -> String? {
    let address = value
      .split(separator: "/", omittingEmptySubsequences: false)
      .first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    guard !address.isEmpty, isIPv4(address) || isIPv6(address) else { return nil }
    return address
  }

  /// The low end of `8080` or `8000-8100`, which is inside the range either way.
  static func firstPort(in value: String) -> String? {
    let first = value
      .split(separator: "-", omittingEmptySubsequences: false)
      .first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    guard let port = Int(first), (1...65_535).contains(port) else { return nil }
    return String(port)
  }
}

extension ManagedRuleOverlayRule.Kind {
  /// The editable kind matching a rule type reported by the runtime, so "add a rule before this
  /// one" can start from the same type. Runtime types the editor cannot represent return `nil`.
  init?(runtimeRuleType: String) {
    let normalized = runtimeRuleType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let kind = ManagedRuleOverlayRule.Kind(rawValue: normalized) else { return nil }
    self = kind
  }
}

/// The single snippet every quick rule is written into.
///
/// Quick rules deliberately reuse the ordinary snippet library rather than introducing a second
/// store: they show up in Routing next to hand-written snippets, can be edited, reordered, disabled
/// and deleted there, and they commit through the same preflight/reload/rollback path as everything
/// else. The only thing special about them is that the UI knows which snippet to append to.
enum QuickRuleLibrary {
  /// Fixed so repeated quick rules collect in one place instead of spawning a snippet each time.
  static let snippetID = UUID(uuidString: "7B1E5C2A-9F43-4D8E-A6C1-3E0B5A7D9F21")!

  static var snippetName: String {
    String(localized: "Quick Rules")
  }

  /// The snippet a quick rule should be folded into, ready to receive it.
  ///
  /// The returned snippet is always enabled and always bound to the active profile. That is not a
  /// convenience: a rule added into a disabled or unbound snippet would be stored and produce
  /// nothing, which is precisely the silent no-op issue #15 is about. The user asked for this rule
  /// to take effect now, so the container it lands in has to be live.
  static func targetSnippet(in snippets: [RuntimeSnippet], activeProfileID: UUID?) -> RuntimeSnippet {
    guard let existing = snippets.first(where: { $0.id == snippetID }),
          case .rules = existing.payload
    else {
      // A snippet squatting on the id with a DNS payload (only reachable through a restored backup)
      // is left completely alone rather than converted, so no user data is ever overwritten.
      return activated(
        RuntimeSnippet(
          id: snippets.contains(where: { $0.id == snippetID }) ? UUID() : snippetID,
          name: snippetName,
          payload: .rules(RuleOverlaySettings(enabled: true))
        ),
        activeProfileID: activeProfileID
      )
    }
    return activated(existing, activeProfileID: activeProfileID)
  }

  private static func activated(_ snippet: RuntimeSnippet, activeProfileID: UUID?) -> RuntimeSnippet {
    var snippet = snippet
    snippet.enabled = true
    if let activeProfileID, !snippet.binding.applies(to: activeProfileID) {
      snippet.binding = .profiles(snippet.binding.profileIDs + [activeProfileID])
    }
    return snippet
  }

  /// Fold a drafted rule into the snippet.
  ///
  /// An identical rule line is removed from both lists first, so re-adding a rule at a different
  /// placement moves it instead of leaving a stale copy behind that would still win. New prepends
  /// go to the front: the most recent troubleshooting rule should beat the earlier ones.
  static func adding(_ draft: QuickRuleDraft, to snippet: RuntimeSnippet) -> RuntimeSnippet {
    var settings = ruleSettings(of: snippet)
    settings.enabled = true
    let runtimeRule = draft.runtimeRule
    settings.prependRules.removeAll { $0.runtimeRule == runtimeRule }
    settings.appendRules.removeAll { $0.runtimeRule == runtimeRule }
    switch draft.placement {
    case .beforeProfileRules:
      settings.prependRules.insert(draft.rule, at: 0)
    case .afterProfileRules:
      settings.appendRules.append(draft.rule)
    }
    var updated = snippet
    updated.payload = .rules(settings)
    return updated
  }

  /// Fold an exact-match disable matcher for `rawRule` into the snippet, so a rule shipped by the
  /// profile can be switched off without editing the profile itself.
  static func disabling(_ rawRule: String, in snippet: RuntimeSnippet) -> RuntimeSnippet {
    var settings = ruleSettings(of: snippet)
    settings.enabled = true
    let pattern = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !settings.disabledRuleMatchers.contains(where: { $0.isExactDisable(of: pattern) }) else {
      return snippet
    }
    settings.disabledRuleMatchers.append(ManagedRuleDisableMatcher(mode: .exact, pattern: pattern))
    var updated = snippet
    updated.payload = .rules(settings)
    return updated
  }

  /// Drop the exact-match disable matchers for `rawRule`, re-enabling a rule the user turned off.
  static func enabling(_ rawRule: String, in snippet: RuntimeSnippet) -> RuntimeSnippet {
    var settings = ruleSettings(of: snippet)
    let pattern = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
    let remaining = settings.disabledRuleMatchers.filter { !$0.isExactDisable(of: pattern) }
    guard remaining.count != settings.disabledRuleMatchers.count else { return snippet }
    settings.disabledRuleMatchers = remaining
    var updated = snippet
    updated.payload = .rules(settings)
    return updated
  }

  /// Whether adding `draft` would change nothing that reaches the core.
  ///
  /// Compared by rule line rather than by value: every draft carries a fresh rule id, so an
  /// identity comparison would read a re-add of the same rule as a change and reload the core to
  /// produce the identical config. A rule that is present but not first still counts as a change,
  /// because adding it again moves it ahead of the quick rules that were beating it.
  static func isAlreadyActive(
    _ draft: QuickRuleDraft,
    in snippet: RuntimeSnippet?,
    activeProfileID: UUID?
  ) -> Bool {
    guard let snippet, snippet.enabled, case let .rules(current) = snippet.payload else { return false }
    if let activeProfileID, !snippet.binding.applies(to: activeProfileID) { return false }
    guard case let .rules(proposed) = adding(draft, to: snippet).payload else { return false }
    return current.enabled == proposed.enabled
      && current.prependRules.map(\.runtimeRule) == proposed.prependRules.map(\.runtimeRule)
      && current.appendRules.map(\.runtimeRule) == proposed.appendRules.map(\.runtimeRule)
  }

  private static func ruleSettings(of snippet: RuntimeSnippet) -> RuleOverlaySettings {
    guard case let .rules(settings) = snippet.payload else {
      return RuleOverlaySettings(enabled: true)
    }
    return settings
  }
}

extension ManagedRuleDisableMatcher {
  /// Whether this matcher is the exact-match disable the quick-rule flow writes for `rawRule`.
  /// Compared case-insensitively to line up with `matches(_:)`, which ignores case.
  func isExactDisable(of rawRule: String) -> Bool {
    mode == .exact
      && normalizedPattern.compare(
        rawRule.trimmingCharacters(in: .whitespacesAndNewlines),
        options: [.caseInsensitive, .diacriticInsensitive]
      ) == .orderedSame
  }
}
