import Foundation
import Yams

enum RuntimeSnippetBinding: Codable, Equatable, Sendable {
  case allProfiles
  case profiles([UUID])

  private enum CodingKeys: String, CodingKey {
    case kind
    case profileIDs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "allProfiles"
    switch kind {
    case "profiles":
      self = .profiles(Self.normalizedProfileIDs(try container.decodeIfPresent([UUID].self, forKey: .profileIDs) ?? []))
    default:
      self = .allProfiles
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .allProfiles:
      try container.encode("allProfiles", forKey: .kind)
    case let .profiles(profileIDs):
      try container.encode("profiles", forKey: .kind)
      try container.encode(Self.normalizedProfileIDs(profileIDs), forKey: .profileIDs)
    }
  }

  var displayName: String {
    switch self {
    case .allProfiles:
      return String(localized: "All Profiles")
    case let .profiles(profileIDs):
      let count = Self.normalizedProfileIDs(profileIDs).count
      guard count > 0 else {
        return String(localized: "No profiles selected")
      }
      return String(
        format: String(localized: "%lld bound profiles"),
        Int64(count)
      )
    }
  }

  var profileIDs: [UUID] {
    switch self {
    case .allProfiles:
      return []
    case let .profiles(profileIDs):
      return Self.normalizedProfileIDs(profileIDs)
    }
  }

  var validationError: String? {
    switch self {
    case .allProfiles:
      return nil
    case let .profiles(profileIDs):
      return Self.normalizedProfileIDs(profileIDs).isEmpty
        ? String(localized: "Select at least one profile for this snippet.")
        : nil
    }
  }

  func applies(to profileID: UUID) -> Bool {
    switch self {
    case .allProfiles:
      return true
    case let .profiles(profileIDs):
      return Set(profileIDs).contains(profileID)
    }
  }

  func removingMissingProfiles(validProfileIDs: Set<UUID>) -> RuntimeSnippetBinding {
    switch self {
    case .allProfiles:
      return .allProfiles
    case let .profiles(profileIDs):
      return .profiles(profileIDs.filter { validProfileIDs.contains($0) })
    }
  }

  private static func normalizedProfileIDs(_ profileIDs: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return profileIDs.filter { seen.insert($0).inserted }
  }
}

enum RuntimeSnippetPayloadKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case rules
  case dnsPatch

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .rules:
      return String(localized: "Rules")
    case .dnsPatch:
      return String(localized: "DNS Patch")
    }
  }
}

enum RuntimeSnippetPayload: Codable, Equatable, Sendable {
  case rules(RuleOverlaySettings)
  case dnsPatch(TunDNSSettings)

  private enum CodingKeys: String, CodingKey {
    case kind
    case rules
    case dnsPatch
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decodeIfPresent(RuntimeSnippetPayloadKind.self, forKey: .kind) ?? .rules
    switch kind {
    case .rules:
      self = .rules(try container.decodeIfPresent(RuleOverlaySettings.self, forKey: .rules) ?? .disabled)
    case .dnsPatch:
      self = .dnsPatch(try container.decodeIfPresent(TunDNSSettings.self, forKey: .dnsPatch) ?? .profileDefault)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case let .rules(settings):
      try container.encode(settings, forKey: .rules)
    case let .dnsPatch(settings):
      try container.encode(settings, forKey: .dnsPatch)
    }
  }

  var kind: RuntimeSnippetPayloadKind {
    switch self {
    case .rules:
      return .rules
    case .dnsPatch:
      return .dnsPatch
    }
  }

  var displayName: String {
    switch self {
    case .rules:
      return String(localized: "Rules")
    case .dnsPatch:
      return String(localized: "DNS Patch")
    }
  }

  var summary: String {
    switch self {
    case let .rules(settings):
      return settings.summary
    case let .dnsPatch(settings):
      let count = settings.runtimePatchCount
      if count == 0 {
        return String(localized: "No DNS changes")
      }
      return String(format: String(localized: "%lld DNS changes"), Int64(count))
    }
  }

  var hasRuntimeEffect: Bool {
    switch self {
    case let .rules(settings):
      return settings.hasRuntimeOverlay
    case let .dnsPatch(settings):
      return settings.hasRuntimeOverlay
    }
  }

  var validationError: String? {
    switch self {
    case let .rules(settings):
      return settings.validationError
    case let .dnsPatch(settings):
      return settings.validationError
    }
  }
}

struct RuntimeSnippet: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var enabled: Bool
  var binding: RuntimeSnippetBinding
  var payload: RuntimeSnippetPayload

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case enabled
    case binding
    case payload
  }

  init(
    id: UUID = UUID(),
    name: String,
    enabled: Bool = true,
    binding: RuntimeSnippetBinding = .allProfiles,
    payload: RuntimeSnippetPayload
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
    self.binding = binding
    self.payload = payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
      enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      binding: try container.decodeIfPresent(RuntimeSnippetBinding.self, forKey: .binding) ?? .allProfiles,
      payload: try container.decodeIfPresent(RuntimeSnippetPayload.self, forKey: .payload)
        ?? .rules(.disabled)
    )
  }

  static var defaultRuleSnippet: RuntimeSnippet {
    RuntimeSnippet(
      name: String(localized: "New Rule Snippet"),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "example.com", policy: "DIRECT")
          ]
        )
      )
    )
  }

  static var defaultDNSPatchSnippet: RuntimeSnippet {
    RuntimeSnippet(
      name: String(localized: "New DNS Patch"),
      payload: .dnsPatch(
        TunDNSSettings(
          respectRules: true,
          fakeIPFilter: ["*.local"]
        )
      )
    )
  }

  var normalizedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var validationError: String? {
    if normalizedName.isEmpty {
      return String(localized: "Snippet name cannot be empty.")
    }
    if enabled, let bindingError = binding.validationError {
      return bindingError
    }
    if let payloadError = payload.validationError {
      return payloadError
    }
    return nil
  }

  var hasRuntimeEffect: Bool {
    enabled && payload.hasRuntimeEffect
  }

  func applies(to profileID: UUID) -> Bool {
    binding.applies(to: profileID)
  }

  func removingMissingProfileBindings(validProfileIDs: Set<UUID>) -> RuntimeSnippet {
    var snippet = self
    let nextBinding = binding.removingMissingProfiles(validProfileIDs: validProfileIDs)
    snippet.binding = nextBinding
    if case let .profiles(profileIDs) = nextBinding, profileIDs.isEmpty {
      snippet.enabled = false
    }
    return snippet
  }
}

struct RuntimeSnippetApplication: Equatable, Sendable {
  var dnsPatches: [TunDNSSettings]
  var ruleOverlay: RuleOverlaySettings

  static let empty = RuntimeSnippetApplication(dnsPatches: [], ruleOverlay: .disabled)

  init(dnsPatches: [TunDNSSettings], ruleOverlay: RuleOverlaySettings) {
    self.dnsPatches = dnsPatches
    self.ruleOverlay = ruleOverlay
  }

  init(snippets: [RuntimeSnippet]) {
    var dnsPatches: [TunDNSSettings] = []
    var ruleOverlays: [RuleOverlaySettings] = []
    for snippet in snippets where snippet.enabled {
      switch snippet.payload {
      case let .rules(settings) where settings.hasRuntimeOverlay:
        ruleOverlays.append(settings)
      case let .dnsPatch(settings) where settings.hasRuntimeOverlay:
        dnsPatches.append(settings)
      case .rules, .dnsPatch:
        continue
      }
    }
    self.dnsPatches = dnsPatches
    self.ruleOverlay = RuleOverlaySettings.combinedRuntimeSnippetOverlays(ruleOverlays)
  }
}

extension RuleOverlaySettings {
  static func combinedRuntimeSnippetOverlays(_ overlays: [RuleOverlaySettings]) -> RuleOverlaySettings {
    var result = RuleOverlaySettings.disabled
    for overlay in overlays where overlay.enabled {
      result.enabled = true
      result.prependRules.append(contentsOf: overlay.prependRules)
      result.appendRules.append(contentsOf: overlay.appendRules)
      result.disabledRuleMatchers.append(contentsOf: overlay.disabledRuleMatchers)
    }
    return result
  }

  func combined(withRuntimeSnippetOverlay snippetOverlay: RuleOverlaySettings) -> RuleOverlaySettings {
    guard snippetOverlay.enabled else { return self }
    return RuleOverlaySettings(
      enabled: enabled || snippetOverlay.enabled,
      prependRules: prependRules + snippetOverlay.prependRules,
      appendRules: appendRules + snippetOverlay.appendRules,
      disabledRuleMatchers: disabledRuleMatchers + snippetOverlay.disabledRuleMatchers
    )
  }
}

enum RuntimeSnippetYAMLPatchParser {
  enum ParserError: Error, CustomStringConvertible {
    case yaml(String)
    case rootIsNotMapping
    case unsupportedTopLevelKey(String)
    case unsupportedDNSKey(String)
    case invalidDNSPatch(String)

    var description: String {
      switch self {
      case let .yaml(message):
        return "YAML patch parse error: \(message)"
      case .rootIsNotMapping:
        return "YAML patch must be a mapping."
      case let .unsupportedTopLevelKey(key):
        return "YAML patch key is not allowed in snippets: \(key)"
      case let .unsupportedDNSKey(key):
        return "DNS patch key is not allowed in snippets: \(key)"
      case let .invalidDNSPatch(message):
        return message
      }
    }
  }

  static func dnsPatch(from yaml: String) throws -> TunDNSSettings {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: yaml)
    } catch {
      throw ParserError.yaml(String(describing: error))
    }
    guard let root = loaded as? [String: Any] else {
      throw ParserError.rootIsNotMapping
    }
    for key in root.keys where key != "dns" {
      throw ParserError.unsupportedTopLevelKey(key)
    }
    guard let dns = root["dns"] as? [String: Any] else {
      throw ParserError.invalidDNSPatch("YAML patch must contain a dns mapping.")
    }
    let settings = try dnsSettings(from: dns)
    if let validationError = settings.validationError {
      throw ParserError.invalidDNSPatch(validationError)
    }
    return settings
  }

  private static func dnsSettings(from dns: [String: Any]) throws -> TunDNSSettings {
    let allowedKeys: Set<String> = [
      "prefer-h3",
      "use-hosts",
      "use-system-hosts",
      "respect-rules",
      "fake-ip-filter",
      "default-nameserver",
      "nameserver",
      "fallback",
      "proxy-server-nameserver",
      "direct-nameserver",
      "direct-nameserver-follow-policy",
      "nameserver-policy",
      "proxy-server-nameserver-policy",
      "hosts",
      "fallback-filter"
    ]
    for key in dns.keys where !allowedKeys.contains(key) {
      throw ParserError.unsupportedDNSKey(key)
    }
    return TunDNSSettings(
      preferH3: dns["prefer-h3"] as? Bool,
      useHosts: dns["use-hosts"] as? Bool,
      useSystemHosts: dns["use-system-hosts"] as? Bool,
      respectRules: dns["respect-rules"] as? Bool,
      fakeIPFilter: stringList(dns["fake-ip-filter"]),
      defaultNameserver: stringList(dns["default-nameserver"]),
      nameserver: stringList(dns["nameserver"]),
      fallback: stringList(dns["fallback"]),
      proxyServerNameserver: stringList(dns["proxy-server-nameserver"]),
      directNameserver: stringList(dns["direct-nameserver"]),
      directNameserverFollowPolicy: dns["direct-nameserver-follow-policy"] as? Bool,
      nameserverPolicy: stringMap(dns["nameserver-policy"]),
      proxyServerNameserverPolicy: stringMap(dns["proxy-server-nameserver-policy"]),
      hosts: stringMap(dns["hosts"]),
      fallbackFilter: try fallbackFilter(dns["fallback-filter"])
    )
  }

  private static func stringList(_ value: Any?) -> [String] {
    switch value {
    case let value as String:
      return [value]
    case let values as [String]:
      return values
    case let values as [Any]:
      return values.compactMap { $0 as? String }
    default:
      return []
    }
  }

  private static func stringMap(_ value: Any?) -> [String: String] {
    if let map = value as? [String: String] {
      return map
    }
    guard let map = value as? [String: Any] else { return [:] }
    return map.compactMapValues { $0 as? String }
  }

  private static func fallbackFilter(_ value: Any?) throws -> TunDNSFallbackFilter {
    guard let map = value as? [String: Any] else { return .empty }
    let allowedKeys: Set<String> = ["geoip", "geoip-code", "geosite", "ipcidr", "domain"]
    for key in map.keys where !allowedKeys.contains(key) {
      throw ParserError.unsupportedDNSKey("fallback-filter.\(key)")
    }
    return TunDNSFallbackFilter(
      geoIP: map["geoip"] as? Bool,
      geoIPCode: map["geoip-code"] as? String,
      geoSite: stringList(map["geosite"]),
      ipCIDR: stringList(map["ipcidr"]),
      domain: stringList(map["domain"])
    )
  }
}

private extension TunDNSSettings {
  var runtimePatchCount: Int {
    var count = 0
    count += preferH3 == nil ? 0 : 1
    count += useHosts == nil ? 0 : 1
    count += useSystemHosts == nil ? 0 : 1
    count += respectRules == nil ? 0 : 1
    count += fakeIPFilter.count
    count += defaultNameserver.count
    count += nameserver.count
    count += fallback.count
    count += proxyServerNameserver.count
    count += directNameserver.count
    count += directNameserverFollowPolicy == nil ? 0 : 1
    count += nameserverPolicy.count
    count += proxyServerNameserverPolicy.count
    count += hosts.count
    count += fallbackFilter.isEmpty ? 0 : 1
    return count
  }
}
