import Darwin
import Foundation
import Yams

private extension KeyedDecodingContainer {
  func decodeDefault<T: Decodable>(
    _ type: T.Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> T
  ) -> T {
    (try? decodeIfPresent(type, forKey: key)) ?? defaultValue()
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

enum ProfileSource: Codable, Equatable, Sendable {
  case localFile(originalPath: String?)
  case subscription(id: UUID)

  private enum CodingKeys: String, CodingKey {
    case kind
    case originalPath
    case subscriptionID
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "localFile":
      self = .localFile(originalPath: try container.decodeIfPresent(String.self, forKey: .originalPath))
    case "subscription":
      self = .subscription(id: try container.decode(UUID.self, forKey: .subscriptionID))
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown profile source")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .localFile(originalPath):
      try container.encode("localFile", forKey: .kind)
      try container.encodeIfPresent(originalPath, forKey: .originalPath)
    case let .subscription(id):
      try container.encode("subscription", forKey: .kind)
      try container.encode(id, forKey: .subscriptionID)
    }
  }
}

extension ProfileSource {
  var displayName: String {
    switch self {
    case .localFile: String(localized: "Local YAML")
    case .subscription: String(localized: "Subscription")
    }
  }
}

enum SubscriptionProviderFetchProxy: String, Codable, CaseIterable, Identifiable, Sendable {
  case defaultOrder
  case direct
  case localClashProxy
  case systemProxy

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .defaultOrder: String(localized: "Default")
    case .direct: String(localized: "Direct")
    case .localClashProxy: String(localized: "Local Clash Proxy")
    case .systemProxy: String(localized: "System Proxy")
    }
  }
}

enum SubscriptionContentKind: String, Codable, Equatable, Sendable {
  case clashConfig
  case proxyProviderContent
  case shareLinkList
  case base64ShareLinkList
}

enum SubscriptionTemplateKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case minimal
  case global
  case rule
  case cnDirect

  static let legacyVersion = 1
  static let currentVersion = 2

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .minimal: String(localized: "Minimal")
    case .global: String(localized: "Global")
    case .rule: String(localized: "Rule")
    case .cnDirect: String(localized: "CN Direct")
    }
  }

  var description: String {
    switch self {
    case .minimal:
      return String(localized: "Only Proxy, Auto, DIRECT, DNS defaults, and MATCH.")
    case .global:
      return String(localized: "Send all traffic through the generated Proxy group with app-managed DNS defaults.")
    case .rule:
      return String(localized: "Use a practical rule-mode template with private network direct rules and app-managed DNS defaults.")
    case .cnDirect:
      return String(localized: "Route common China/private destinations direct before MATCH, with ClashX-style DNS defaults.")
    }
  }

  var presetSummary: String {
    switch self {
    case .minimal:
      return String(localized: "Smallest generated profile for provider subscriptions.")
    case .global:
      return String(localized: "All traffic goes through the generated select group.")
    case .rule:
      return String(localized: "Private and local traffic stays direct before fallback.")
    case .cnDirect:
      return String(localized: "Private and China geodata rules stay direct before fallback.")
    }
  }

  var ruleSummary: String {
    switch self {
    case .minimal:
      return String(localized: "Rules: MATCH to the final policy.")
    case .global:
      return String(localized: "Rules: MATCH to the generated proxy group.")
    case .rule:
      return String(localized: "Rules: local domain plus private IPv4 CIDRs direct, then MATCH.")
    case .cnDirect:
      return String(localized: "Rules: private and CN geodata direct, then MATCH.")
    }
  }

  var dnsSummary: String {
    String(localized: "DNS: v2 templates add fake-ip, system hosts, rule-respecting resolver defaults, and fallback filtering.")
  }

  func versionSummary(version: Int) -> String {
    version >= Self.currentVersion
      ? String(localized: "Template v2: includes app-managed DNS base.")
      : String(localized: "Template v1: legacy generated provider rules without DNS base.")
  }
}

struct SubscriptionRequestHeader: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var value: String

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case value
  }

  init(id: UUID = UUID(), name: String = "", value: String = "") {
    self.id = id
    self.name = name
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
  }

  var normalizedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedValue: String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct SubscriptionProviderOptions: Codable, Equatable, Sendable {
  static let minimumIntervalSeconds = 60
  static let maximumIntervalSeconds = 86_400

  var intervalSeconds: Int
  var filter: String
  var excludeFilter: String
  var excludeType: String
  var overrideYAML: String
  var runtimeMergeYAML: String
  var requestHeaders: [SubscriptionRequestHeader]
  var fetchProxy: SubscriptionProviderFetchProxy
  var primaryGroupName: String
  var autoGroupName: String
  var finalRulePolicy: String
  var ruleOverlay: RuleOverlaySettings
  var generatedTemplate: SubscriptionTemplateKind
  var generatedTemplateVersion: Int

  private enum CodingKeys: String, CodingKey {
    case intervalSeconds
    case filter
    case excludeFilter
    case excludeType
    case overrideYAML
    case runtimeMergeYAML
    case runtimeMergeYAMLEnabled
    case requestHeaders
    case fetchProxy
    case primaryGroupName
    case autoGroupName
    case finalRulePolicy
    case ruleOverlay
    case generatedTemplate
    case generatedTemplateVersion
  }

  init(
    intervalSeconds: Int = 300,
    filter: String = "",
    excludeFilter: String = "",
    excludeType: String = "",
    overrideYAML: String = "",
    runtimeMergeYAML: String = "",
    requestHeaders: [SubscriptionRequestHeader] = [],
    fetchProxy: SubscriptionProviderFetchProxy = .defaultOrder,
    primaryGroupName: String = "Proxy",
    autoGroupName: String = "Auto",
    finalRulePolicy: String = "Proxy",
    ruleOverlay: RuleOverlaySettings = .disabled,
    generatedTemplate: SubscriptionTemplateKind = .minimal,
    generatedTemplateVersion: Int = SubscriptionTemplateKind.currentVersion
  ) {
    self.intervalSeconds = min(max(intervalSeconds, Self.minimumIntervalSeconds), Self.maximumIntervalSeconds)
    self.filter = filter
    self.excludeFilter = excludeFilter
    self.excludeType = excludeType
    self.overrideYAML = overrideYAML
    self.runtimeMergeYAML = runtimeMergeYAML
    self.requestHeaders = requestHeaders
    self.fetchProxy = fetchProxy
    self.primaryGroupName = primaryGroupName
    self.autoGroupName = autoGroupName
    self.finalRulePolicy = finalRulePolicy
    self.ruleOverlay = ruleOverlay
    self.generatedTemplate = generatedTemplate
    self.generatedTemplateVersion = max(1, generatedTemplateVersion)
  }

  static let `default` = SubscriptionProviderOptions()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      intervalSeconds: container.decodeDefault(Int.self, forKey: .intervalSeconds, default: defaults.intervalSeconds),
      filter: container.decodeDefault(String.self, forKey: .filter, default: defaults.filter),
      excludeFilter: container.decodeDefault(String.self, forKey: .excludeFilter, default: defaults.excludeFilter),
      excludeType: container.decodeDefault(String.self, forKey: .excludeType, default: defaults.excludeType),
      overrideYAML: container.decodeDefault(String.self, forKey: .overrideYAML, default: defaults.overrideYAML),
      runtimeMergeYAML: container.decodeDefault(String.self, forKey: .runtimeMergeYAML, default: defaults.runtimeMergeYAML),
      requestHeaders: container.decodeDefault(
        [SubscriptionRequestHeader].self,
        forKey: .requestHeaders,
        default: defaults.requestHeaders
      ),
      fetchProxy: container.decodeDefault(SubscriptionProviderFetchProxy.self, forKey: .fetchProxy, default: defaults.fetchProxy),
      primaryGroupName: container.decodeDefault(String.self, forKey: .primaryGroupName, default: defaults.primaryGroupName),
      autoGroupName: container.decodeDefault(String.self, forKey: .autoGroupName, default: defaults.autoGroupName),
      finalRulePolicy: container.decodeDefault(String.self, forKey: .finalRulePolicy, default: defaults.finalRulePolicy),
      ruleOverlay: container.decodeDefault(RuleOverlaySettings.self, forKey: .ruleOverlay, default: defaults.ruleOverlay),
      generatedTemplate: container.decodeDefault(
        SubscriptionTemplateKind.self,
        forKey: .generatedTemplate,
        default: defaults.generatedTemplate
      ),
      generatedTemplateVersion: container.decodeDefault(
        Int.self,
        forKey: .generatedTemplateVersion,
        default: SubscriptionTemplateKind.legacyVersion
      )
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(intervalSeconds, forKey: .intervalSeconds)
    try container.encode(filter, forKey: .filter)
    try container.encode(excludeFilter, forKey: .excludeFilter)
    try container.encode(excludeType, forKey: .excludeType)
    try container.encode(overrideYAML, forKey: .overrideYAML)
    if hasRuntimeMergeYAML {
      try container.encode(true, forKey: .runtimeMergeYAMLEnabled)
    }
    try container.encode(requestHeaders, forKey: .requestHeaders)
    try container.encode(fetchProxy, forKey: .fetchProxy)
    try container.encode(primaryGroupName, forKey: .primaryGroupName)
    try container.encode(autoGroupName, forKey: .autoGroupName)
    try container.encode(finalRulePolicy, forKey: .finalRulePolicy)
    try container.encode(ruleOverlay, forKey: .ruleOverlay)
    try container.encode(generatedTemplate, forKey: .generatedTemplate)
    try container.encode(generatedTemplateVersion, forKey: .generatedTemplateVersion)
  }

  var normalizedHeaders: [String: String] {
    requestHeaders.reduce(into: [String: String]()) { result, header in
      let name = header.normalizedName
      guard !name.isEmpty else { return }
      result[name] = header.normalizedValue
    }
  }

  var hasRuntimeMergeYAML: Bool {
    !runtimeMergeYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var requiresRuntimeConfigPreflight: Bool {
    hasRuntimeMergeYAML || ruleOverlay.hasRuntimeOverlay
  }
}

struct ProviderOptionsRuntimeDiff: Identifiable, Codable, Equatable, Sendable {
  var category: String
  var title: String
  var before: String
  var after: String
  var isAdvanced: Bool

  var id: String { "\(category):\(title)" }

  init(
    category: String,
    title: String,
    before: String,
    after: String,
    isAdvanced: Bool = false
  ) {
    self.category = category
    self.title = title
    self.before = before
    self.after = after
    self.isAdvanced = isAdvanced
  }
}

struct ProviderOptionsRisk: Identifiable, Codable, Equatable, Sendable {
  enum Severity: String, Codable, Sendable {
    case info
    case warning
    case danger

    var displayName: String {
      switch self {
      case .info:
        return String(localized: "Info")
      case .warning:
        return String(localized: "Warning")
      case .danger:
        return String(localized: "Danger")
      }
    }
  }

  var source: String
  var keyPath: String
  var key: String
  var severity: Severity
  var message: String

  var id: String { "\(source):\(keyPath):\(severity.rawValue)" }
}

struct SubscriptionProviderOptionsGuardrailReport: Codable, Equatable, Sendable {
  var runtimeDiff: [ProviderOptionsRuntimeDiff]
  var risks: [ProviderOptionsRisk]
  var presetTitle: String
  var presetDescription: String
  var presetDetails: [String]
  var rollbackAvailable: Bool

  var hasDangerousRisks: Bool {
    risks.contains { $0.severity == .danger }
  }

  var hasWarnings: Bool {
    risks.contains { $0.severity == .warning || $0.severity == .danger }
  }

  var summary: String {
    if hasDangerousRisks {
      return String(localized: "Review high-risk provider options before saving.")
    }
    if hasWarnings {
      return String(localized: "Review provider option warnings before saving.")
    }
    return String(localized: "Provider options are within the guarded generated template.")
  }

  static func analyze(
    options: SubscriptionProviderOptions,
    baseline: SubscriptionProviderOptions = .default,
    rollbackOptions: SubscriptionProviderOptions? = nil
  ) -> SubscriptionProviderOptionsGuardrailReport {
    SubscriptionProviderOptionsGuardrailReport(
      runtimeDiff: runtimeDiff(options: options, baseline: baseline),
      risks: yamlRisks(options: options),
      presetTitle: options.generatedTemplate.displayName,
      presetDescription: options.generatedTemplate.description,
      presetDetails: [
        options.generatedTemplate.presetSummary,
        options.generatedTemplate.ruleSummary,
        options.generatedTemplate.versionSummary(version: options.generatedTemplateVersion),
        options.generatedTemplate.dnsSummary
      ],
      rollbackAvailable: rollbackOptions.map { $0 != options } ?? false
    )
  }

  private static func runtimeDiff(
    options: SubscriptionProviderOptions,
    baseline: SubscriptionProviderOptions
  ) -> [ProviderOptionsRuntimeDiff] {
    var result: [ProviderOptionsRuntimeDiff] = []
    appendDiff(
      &result,
      category: String(localized: "Template"),
      title: String(localized: "Preset"),
      before: baseline.generatedTemplate.displayName,
      after: options.generatedTemplate.displayName
    )
    appendDiff(
      &result,
      category: String(localized: "Template"),
      title: String(localized: "Version"),
      before: "\(baseline.generatedTemplateVersion)",
      after: "\(options.generatedTemplateVersion)"
    )
    appendDiff(
      &result,
      category: String(localized: "Provider"),
      title: String(localized: "Refresh Interval"),
      before: "\(baseline.intervalSeconds)s",
      after: "\(options.intervalSeconds)s"
    )
    appendDiff(
      &result,
      category: String(localized: "Provider"),
      title: String(localized: "Fetch Proxy"),
      before: baseline.fetchProxy.displayName,
      after: options.fetchProxy.displayName
    )
    appendDiff(
      &result,
      category: String(localized: "Groups"),
      title: String(localized: "Select Group"),
      before: baseline.primaryGroupName,
      after: options.primaryGroupName
    )
    appendDiff(
      &result,
      category: String(localized: "Groups"),
      title: String(localized: "URL-Test Group"),
      before: baseline.autoGroupName,
      after: options.autoGroupName
    )
    appendDiff(
      &result,
      category: String(localized: "Rules"),
      title: String(localized: "Final MATCH Policy"),
      before: baseline.finalRulePolicy,
      after: options.finalRulePolicy
    )
    appendDiff(
      &result,
      category: String(localized: "Rules"),
      title: String(localized: "Rule Overlay"),
      before: baseline.ruleOverlay.summary,
      after: options.ruleOverlay.summary
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Provider Filter"),
      before: normalizedPresenceLabel(baseline.filter),
      after: normalizedPresenceLabel(options.filter),
      isAdvanced: true
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Exclude Filter"),
      before: normalizedPresenceLabel(baseline.excludeFilter),
      after: normalizedPresenceLabel(options.excludeFilter),
      isAdvanced: true
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Exclude Type"),
      before: normalizedPresenceLabel(baseline.excludeType),
      after: normalizedPresenceLabel(options.excludeType),
      isAdvanced: true
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Provider Override YAML"),
      before: normalizedPresenceLabel(baseline.overrideYAML),
      after: normalizedPresenceLabel(options.overrideYAML),
      isAdvanced: true
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Runtime Merge YAML"),
      before: normalizedPresenceLabel(baseline.runtimeMergeYAML),
      after: normalizedPresenceLabel(options.runtimeMergeYAML),
      isAdvanced: true
    )
    appendDiff(
      &result,
      category: String(localized: "Advanced"),
      title: String(localized: "Custom Headers"),
      before: "\(baseline.normalizedHeaders.count)",
      after: "\(options.normalizedHeaders.count)",
      isAdvanced: true
    )
    return result
  }

  private static func appendDiff(
    _ result: inout [ProviderOptionsRuntimeDiff],
    category: String,
    title: String,
    before: String,
    after: String,
    isAdvanced: Bool = false
  ) {
    guard before != after else { return }
    result.append(
      ProviderOptionsRuntimeDiff(
        category: category,
        title: title,
        before: before.isEmpty ? String(localized: "Empty") : before,
        after: after.isEmpty ? String(localized: "Empty") : after,
        isAdvanced: isAdvanced
      )
    )
  }

  private static func normalizedPresenceLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? String(localized: "Empty")
      : String(localized: "Configured")
  }

  private static func yamlRisks(options: SubscriptionProviderOptions) -> [ProviderOptionsRisk] {
    risks(in: options.overrideYAML, source: String(localized: "Provider Override YAML"))
      + risks(in: options.runtimeMergeYAML, source: String(localized: "Runtime Merge YAML"))
  }

  private static func risks(in yaml: String, source: String) -> [ProviderOptionsRisk] {
    let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    do {
      guard let root = try Yams.load(yaml: trimmed) as? [String: Any] else {
        return [
          ProviderOptionsRisk(
            source: source,
            keyPath: source,
            key: source,
            severity: .warning,
            message: String(localized: "YAML must be a mapping to be applied safely.")
          )
        ]
      }
      var risks: [ProviderOptionsRisk] = []
      scan(root, path: [], source: source, risks: &risks)
      return risks
    } catch {
      return [
        ProviderOptionsRisk(
          source: source,
          keyPath: source,
          key: source,
          severity: .danger,
          message: String(format: String(localized: "YAML parse failed: %@"), String(describing: error))
        )
      ]
    }
  }

  private static func scan(
    _ value: Any,
    path: [String],
    source: String,
    risks: inout [ProviderOptionsRisk]
  ) {
    if let map = value as? [String: Any] {
      for key in map.keys.sorted() {
        let nextPath = path + [key]
        if let risk = risk(for: key, path: nextPath, source: source) {
          risks.append(risk)
        }
        if let nested = map[key] {
          scan(nested, path: nextPath, source: source, risks: &risks)
        }
      }
    } else if let list = value as? [Any] {
      for (index, element) in list.enumerated() {
        scan(element, path: path + ["[\(index)]"], source: source, risks: &risks)
      }
    }
  }

  private static func risk(for key: String, path: [String], source: String) -> ProviderOptionsRisk? {
    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let dangerKeys: Set<String> = [
      "external-controller",
      "external-controller-cors",
      "secret",
      "allow-lan",
      "mixed-port",
      "port",
      "socks-port",
      "http-port",
      "redir-port",
      "tproxy-port",
      "tun",
      "dns",
      "script",
      "listeners"
    ]
    guard dangerKeys.contains(normalizedKey) || normalizedKey.hasSuffix("-port") else { return nil }
    let severity: ProviderOptionsRisk.Severity = ["secret", "external-controller", "listeners", "script"].contains(normalizedKey)
      ? .danger
      : .warning
    let message: String
    switch normalizedKey {
    case "external-controller", "external-controller-cors", "secret":
      message = String(localized: "ClashMax manages controller binding and authentication at runtime.")
    case "allow-lan":
      message = String(localized: "LAN exposure is controlled by ClashMax runtime settings.")
    case "tun":
      message = String(localized: "TUN settings are controlled by ClashMax and the privileged helper.")
    case "dns":
      message = String(localized: "DNS is app-managed in v2 templates and runtime routing modes.")
    case "script", "listeners":
      message = String(localized: "Runtime script/listener hooks can change traffic handling outside the guarded template.")
    default:
      message = String(localized: "Ports are controlled by ClashMax launch settings.")
    }
    return ProviderOptionsRisk(
      source: source,
      keyPath: path.joined(separator: "."),
      key: key,
      severity: severity,
      message: message
    )
  }
}

enum SubscriptionUpdateResult: String, Codable, Equatable, Sendable {
  case never
  case running
  case succeeded
  case failed
  case skipped

  var displayName: String {
    switch self {
    case .never: String(localized: "Never")
    case .running: String(localized: "Running")
    case .succeeded: String(localized: "Succeeded")
    case .failed: String(localized: "Failed")
    case .skipped: String(localized: "Skipped")
    }
  }
}

struct SubscriptionUpdatePolicy: Codable, Equatable, Sendable {
  static let minimumIntervalMinutes = 30
  static let maximumIntervalMinutes = 7 * 24 * 60

  var automaticUpdatesEnabled: Bool
  var intervalOverrideMinutes: Int?
  var prefersRemoteInterval: Bool

  private enum CodingKeys: String, CodingKey {
    case automaticUpdatesEnabled
    case intervalOverrideMinutes
    case prefersRemoteInterval
  }

  init(
    automaticUpdatesEnabled: Bool = true,
    intervalOverrideMinutes: Int? = nil,
    prefersRemoteInterval: Bool = true
  ) {
    self.automaticUpdatesEnabled = automaticUpdatesEnabled
    self.intervalOverrideMinutes = intervalOverrideMinutes.map(Self.normalizedInterval)
    self.prefersRemoteInterval = prefersRemoteInterval
  }

  static let `default` = SubscriptionUpdatePolicy()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      automaticUpdatesEnabled: container.decodeDefault(
        Bool.self,
        forKey: .automaticUpdatesEnabled,
        default: defaults.automaticUpdatesEnabled
      ),
      intervalOverrideMinutes: try container.decodeIfPresent(Int.self, forKey: .intervalOverrideMinutes),
      prefersRemoteInterval: container.decodeDefault(
        Bool.self,
        forKey: .prefersRemoteInterval,
        default: defaults.prefersRemoteInterval
      )
    )
  }

  func effectiveIntervalMinutes(remoteIntervalMinutes: Int?, globalDefaultMinutes: Int) -> Int? {
    guard automaticUpdatesEnabled else { return nil }
    if let intervalOverrideMinutes {
      return Self.normalizedInterval(intervalOverrideMinutes)
    }
    if prefersRemoteInterval, let remoteIntervalMinutes, remoteIntervalMinutes > 0 {
      return Self.normalizedInterval(remoteIntervalMinutes)
    }
    return Self.normalizedInterval(globalDefaultMinutes)
  }

  static func normalizedInterval(_ minutes: Int) -> Int {
    min(max(minutes, minimumIntervalMinutes), maximumIntervalMinutes)
  }
}

struct SubscriptionUpdateStatus: Codable, Equatable, Sendable {
  var result: SubscriptionUpdateResult
  var lastStartedAt: Date?
  var lastFinishedAt: Date?
  var lastSucceededAt: Date?
  var lastError: String?
  var nextUpdateAt: Date?
  var backoffUntil: Date?
  var consecutiveFailures: Int

  private enum CodingKeys: String, CodingKey {
    case result
    case lastStartedAt
    case lastFinishedAt
    case lastSucceededAt
    case lastError
    case nextUpdateAt
    case backoffUntil
    case consecutiveFailures
  }

  init(
    result: SubscriptionUpdateResult = .never,
    lastStartedAt: Date? = nil,
    lastFinishedAt: Date? = nil,
    lastSucceededAt: Date? = nil,
    lastError: String? = nil,
    nextUpdateAt: Date? = nil,
    backoffUntil: Date? = nil,
    consecutiveFailures: Int = 0
  ) {
    self.result = result
    self.lastStartedAt = lastStartedAt
    self.lastFinishedAt = lastFinishedAt
    self.lastSucceededAt = lastSucceededAt
    self.lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.nextUpdateAt = nextUpdateAt
    self.backoffUntil = backoffUntil
    self.consecutiveFailures = max(0, consecutiveFailures)
  }

  static let empty = SubscriptionUpdateStatus()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      result: container.decodeDefault(SubscriptionUpdateResult.self, forKey: .result, default: .never),
      lastStartedAt: try container.decodeIfPresent(Date.self, forKey: .lastStartedAt),
      lastFinishedAt: try container.decodeIfPresent(Date.self, forKey: .lastFinishedAt),
      lastSucceededAt: try container.decodeIfPresent(Date.self, forKey: .lastSucceededAt),
      lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
      nextUpdateAt: try container.decodeIfPresent(Date.self, forKey: .nextUpdateAt),
      backoffUntil: try container.decodeIfPresent(Date.self, forKey: .backoffUntil),
      consecutiveFailures: container.decodeDefault(Int.self, forKey: .consecutiveFailures, default: 0)
    )
  }

  func started(at date: Date) -> SubscriptionUpdateStatus {
    SubscriptionUpdateStatus(
      result: .running,
      lastStartedAt: date,
      lastFinishedAt: lastFinishedAt,
      lastSucceededAt: lastSucceededAt,
      lastError: nil,
      nextUpdateAt: nextUpdateAt,
      backoffUntil: backoffUntil,
      consecutiveFailures: consecutiveFailures
    )
  }

  func succeeded(at date: Date, nextUpdateAt: Date?) -> SubscriptionUpdateStatus {
    SubscriptionUpdateStatus(
      result: .succeeded,
      lastStartedAt: lastStartedAt,
      lastFinishedAt: date,
      lastSucceededAt: date,
      lastError: nil,
      nextUpdateAt: nextUpdateAt,
      backoffUntil: nil,
      consecutiveFailures: 0
    )
  }

  func failed(message: String, at date: Date, backoffUntil: Date?, nextUpdateAt: Date?) -> SubscriptionUpdateStatus {
    SubscriptionUpdateStatus(
      result: .failed,
      lastStartedAt: lastStartedAt,
      lastFinishedAt: date,
      lastSucceededAt: lastSucceededAt,
      lastError: message,
      nextUpdateAt: nextUpdateAt,
      backoffUntil: backoffUntil,
      consecutiveFailures: consecutiveFailures + 1
    )
  }

  func scheduled(nextUpdateAt: Date?) -> SubscriptionUpdateStatus {
    SubscriptionUpdateStatus(
      result: result,
      lastStartedAt: lastStartedAt,
      lastFinishedAt: lastFinishedAt,
      lastSucceededAt: lastSucceededAt,
      lastError: lastError,
      nextUpdateAt: nextUpdateAt,
      backoffUntil: backoffUntil,
      consecutiveFailures: consecutiveFailures
    )
  }
}

struct Profile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var nameIsUserCustomized: Bool
  var source: ProfileSource
  var originalConfigPath: String
  var subscriptionMetadata: SubscriptionMetadata?
  var subscriptionProviderOptions: SubscriptionProviderOptions
  var subscriptionUpdatePolicy: SubscriptionUpdatePolicy
  var subscriptionUpdateStatus: SubscriptionUpdateStatus
  var createdAt: Date
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case nameIsUserCustomized
    case source
    case originalConfigPath
    case subscriptionMetadata
    case subscriptionProviderOptions
    case subscriptionUpdatePolicy
    case subscriptionUpdateStatus
    case createdAt
    case updatedAt
  }

  init(
    id: UUID = UUID(),
    name: String,
    nameIsUserCustomized: Bool = true,
    source: ProfileSource,
    originalConfigPath: String,
    subscriptionMetadata: SubscriptionMetadata? = nil,
    subscriptionProviderOptions: SubscriptionProviderOptions = .default,
    subscriptionUpdatePolicy: SubscriptionUpdatePolicy = .default,
    subscriptionUpdateStatus: SubscriptionUpdateStatus = .empty,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.nameIsUserCustomized = nameIsUserCustomized
    self.source = source
    self.originalConfigPath = originalConfigPath
    self.subscriptionMetadata = subscriptionMetadata
    self.subscriptionProviderOptions = subscriptionProviderOptions
    self.subscriptionUpdatePolicy = subscriptionUpdatePolicy
    self.subscriptionUpdateStatus = subscriptionUpdateStatus
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    source = try container.decode(ProfileSource.self, forKey: .source)
    originalConfigPath = try container.decode(String.self, forKey: .originalConfigPath)
    subscriptionMetadata = try container.decodeIfPresent(SubscriptionMetadata.self, forKey: .subscriptionMetadata)
    subscriptionProviderOptions = container.decodeDefault(
      SubscriptionProviderOptions.self,
      forKey: .subscriptionProviderOptions,
      default: .default
    )
    subscriptionUpdatePolicy = container.decodeDefault(
      SubscriptionUpdatePolicy.self,
      forKey: .subscriptionUpdatePolicy,
      default: .default
    )
    subscriptionUpdateStatus = container.decodeDefault(
      SubscriptionUpdateStatus.self,
      forKey: .subscriptionUpdateStatus,
      default: .empty
    )
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    nameIsUserCustomized = try container.decodeIfPresent(Bool.self, forKey: .nameIsUserCustomized) ?? !source.isSubscription
  }
}

extension Profile {
  var isSubscription: Bool {
    source.isSubscription
  }
}

extension ProfileSource {
  var isSubscription: Bool {
    if case .subscription = self { return true }
    return false
  }
}

enum RunMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case rule
  case global
  case direct

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .rule: String(localized: "Rule")
    case .global: String(localized: "Global")
    case .direct: String(localized: "Direct")
    }
  }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: String(localized: "System")
    case .light: String(localized: "Light")
    case .dark: String(localized: "Dark")
    }
  }
}

enum ProxyRoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case systemProxy
  case tun
  case neProxy = "networkExtensionExperimental"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .systemProxy: String(localized: "System Proxy")
    case .tun: String(localized: "TUN")
    case .neProxy: String(localized: "NE Proxy")
    }
  }

  var symbolName: String {
    switch self {
    case .systemProxy: "network.badge.shield.half.filled"
    case .tun: "point.topleft.down.curvedto.point.bottomright.up"
    case .neProxy: "network"
    }
  }
}

enum DelayTestMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case mihomoURL
  case nativePing

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mihomoURL: String(localized: "Mihomo URL Delay")
    case .nativePing: String(localized: "Native Ping")
    }
  }

  var description: String {
    switch self {
    case .mihomoURL:
      return String(localized: "Measure through Mihomo's proxy delay API.")
    case .nativePing:
      return String(localized: "Ping the node server host directly from macOS.")
    }
  }
}

struct DelayTestSettings: Codable, Equatable, Sendable {
  static let defaultTimeoutMilliseconds = 5_000

  var mode: DelayTestMode
  var unifiedDelay: Bool
  var timeoutMilliseconds: Int

  private enum CodingKeys: String, CodingKey {
    case mode
    case unifiedDelay
    case timeoutMilliseconds
  }

  init(
    mode: DelayTestMode = .mihomoURL,
    unifiedDelay: Bool = false,
    timeoutMilliseconds: Int = Self.defaultTimeoutMilliseconds
  ) {
    self.mode = mode
    self.unifiedDelay = unifiedDelay
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  static let `default` = DelayTestSettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    mode = container.decodeDefault(DelayTestMode.self, forKey: .mode, default: defaults.mode)
    unifiedDelay = container.decodeDefault(Bool.self, forKey: .unifiedDelay, default: defaults.unifiedDelay)
    timeoutMilliseconds = container.decodeDefault(
      Int.self,
      forKey: .timeoutMilliseconds,
      default: defaults.timeoutMilliseconds
    )
  }

  var normalizedTimeoutMilliseconds: Int {
    min(max(timeoutMilliseconds, 1_000), 30_000)
  }
}

struct ProxyNodeKey: Identifiable, Hashable, Codable, Sendable {
  var profileID: String?
  var groupName: String
  var nodeName: String
  var providerName: String?
  var testURL: String

  init(
    profileID: UUID?,
    groupName: String,
    nodeName: String,
    providerName: String? = nil,
    testURL: URL = AppConstants.defaultDelayTestURL
  ) {
    self.profileID = profileID?.uuidString
    self.groupName = groupName
    self.nodeName = nodeName
    self.providerName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.testURL = testURL.absoluteString
  }

  var id: String {
    [
      profileID,
      groupName,
      providerName,
      nodeName,
      testURL
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    .joined(separator: "::")
  }
}

enum ProxyDelayState: Codable, Equatable, Sendable {
  case unknown
  case testing
  case measured(Int)
  case timeout
  case error(String)

  var measuredDelay: Int? {
    if case let .measured(delay) = self {
      return delay
    }
    return nil
  }
}

struct ExternalControllerCORSSettings: Codable, Equatable, Sendable {
  static let fixedLocalOrigins = [
    "tauri://localhost",
    "http://tauri.localhost",
    "http://localhost:3000"
  ]
  static let defaultPanelOrigins = [
    "https://yacd.metacubex.one",
    "https://metacubex.github.io",
    "https://board.zash.run.place"
  ]

  var enabled: Bool
  var allowPrivateNetwork: Bool
  var allowedOrigins: [String]

  private enum CodingKeys: String, CodingKey {
    case enabled
    case allowPrivateNetwork
    case allowedOrigins
  }

  init(
    enabled: Bool = true,
    allowPrivateNetwork: Bool = true,
    allowedOrigins: [String] = Self.defaultPanelOrigins
  ) {
    self.enabled = enabled
    self.allowPrivateNetwork = allowPrivateNetwork
    self.allowedOrigins = Self.normalizedOrigins(allowedOrigins)
  }

  static let `default` = ExternalControllerCORSSettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      enabled: container.decodeDefault(Bool.self, forKey: .enabled, default: defaults.enabled),
      allowPrivateNetwork: container.decodeDefault(
        Bool.self,
        forKey: .allowPrivateNetwork,
        default: defaults.allowPrivateNetwork
      ),
      allowedOrigins: container.decodeDefault([String].self, forKey: .allowedOrigins, default: defaults.allowedOrigins)
    )
  }

  var effectiveAllowedOrigins: [String] {
    Self.normalizedOrigins(Self.fixedLocalOrigins + allowedOrigins)
  }

  var validationError: String? {
    if let invalid = allowedOrigins.first(where: { !Self.isValidOrigin($0) }) {
      return "Invalid origin: \(invalid)"
    }
    return nil
  }

  static func normalizedOrigins(_ origins: [String]) -> [String] {
    var seen = Set<String>()
    return origins.compactMap { origin in
      let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { return nil }
      seen.insert(key)
      return trimmed
    }
  }

  static func isValidOrigin(_ origin: String) -> Bool {
    let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.contains(where: \.isWhitespace),
          let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased()
    else { return false }

    guard ["http", "https", "tauri"].contains(scheme),
          components.host != nil,
          components.path.isEmpty || components.path == "/",
          components.query == nil,
          components.fragment == nil
    else { return false }

    return true
  }
}

struct ExternalControllerSettings: Codable, Equatable, Sendable {
  static let defaultHost = "127.0.0.1"
  static let defaultPort = 9097
  static let portRange = 1024...65535

  var enabled: Bool
  var host: String
  var port: Int
  var secret: String
  var cors: ExternalControllerCORSSettings

  private enum CodingKeys: String, CodingKey {
    case enabled
    case host
    case port
    case secret
    case cors
  }

  init(
    enabled: Bool = true,
    host: String = Self.defaultHost,
    port: Int = Self.defaultPort,
    secret: String = Self.generateSecret(),
    cors: ExternalControllerCORSSettings = .default
  ) {
    self.enabled = enabled
    self.host = host
    self.port = port
    self.secret = secret
    self.cors = cors
  }

  static let `default` = ExternalControllerSettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      enabled: container.decodeDefault(Bool.self, forKey: .enabled, default: defaults.enabled),
      host: container.decodeDefault(String.self, forKey: .host, default: defaults.host),
      port: container.decodeDefault(Int.self, forKey: .port, default: defaults.port),
      secret: container.decodeDefault(String.self, forKey: .secret, default: defaults.secret),
      cors: container.decodeDefault(ExternalControllerCORSSettings.self, forKey: .cors, default: defaults.cors)
    )
  }

  var address: String {
    "\(normalizedHost):\(normalizedPort)"
  }

  var normalizedHost: String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Self.defaultHost : trimmed
  }

  var normalizedPort: Int {
    Self.portRange.contains(port) ? port : Self.defaultPort
  }

  var normalizedSecret: String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Self.generateSecret() : trimmed
  }

  var runtimeCORS: ExternalControllerCORSSettings {
    var runtime = cors
    runtime.enabled = enabled && cors.enabled
    runtime.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(runtime.allowedOrigins)
    return runtime
  }

  var validationError: String? {
    let host = normalizedHost
    guard Self.isLoopbackHost(host) else {
      return "Controller host must stay on localhost, 127.0.0.1, or ::1."
    }
    guard Self.portRange.contains(port) else {
      return "Controller port must be between \(Self.portRange.lowerBound) and \(Self.portRange.upperBound)."
    }
    guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "API secret cannot be empty."
    }
    return cors.validationError
  }

  static func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["127.0.0.1", "localhost", "::1"].contains(normalized)
  }

  static func generateSecret() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }
}

struct ManagedRuleOverlayRule: Codable, Equatable, Identifiable, Sendable {
  enum Kind: String, CaseIterable, Codable, Identifiable, Sendable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoIP = "GEOIP"
    case geoSite = "GEOSITE"
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"
    case match = "MATCH"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var requiresValue: Bool {
      self != .match
    }

    var allowsNoResolve: Bool {
      switch self {
      case .ipCIDR, .ipCIDR6, .geoIP:
        return true
      case .domain, .domainSuffix, .domainKeyword, .geoSite, .processName, .processPath, .match:
        return false
      }
    }
  }

  var id: UUID
  var kind: Kind
  var value: String
  var policy: String
  var noResolve: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case value
    case policy
    case noResolve
  }

  init(
    id: UUID = UUID(),
    kind: Kind,
    value: String = "",
    policy: String,
    noResolve: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    self.policy = policy.trimmingCharacters(in: .whitespacesAndNewlines)
    self.noResolve = kind.allowsNoResolve && noResolve
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = container.decodeDefault(Kind.self, forKey: .kind, default: .domainSuffix)
    self.init(
      id: container.decodeDefault(UUID.self, forKey: .id, default: UUID()),
      kind: kind,
      value: container.decodeDefault(String.self, forKey: .value, default: ""),
      policy: container.decodeDefault(String.self, forKey: .policy, default: "DIRECT"),
      noResolve: container.decodeDefault(Bool.self, forKey: .noResolve, default: false)
    )
  }

  var runtimeRule: String {
    var components = [kind.rawValue]
    if kind.requiresValue {
      components.append(normalizedValue)
    }
    components.append(normalizedPolicy)
    if kind.allowsNoResolve && noResolve {
      components.append("no-resolve")
    }
    return components.joined(separator: ",")
  }

  var normalizedValue: String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedPolicy: String {
    policy.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var validationError: String? {
    if kind.requiresValue, normalizedValue.isEmpty {
      return String(localized: "Rule value cannot be empty.")
    }
    if kind.requiresValue, !Self.isValidField(normalizedValue) {
      return String(localized: "Rule value cannot contain commas or line breaks.")
    }
    if normalizedPolicy.isEmpty {
      return String(localized: "Rule policy cannot be empty.")
    }
    if !Self.isValidField(normalizedPolicy) {
      return String(localized: "Rule policy cannot contain commas or line breaks.")
    }
    return nil
  }

  private static func isValidField(_ value: String) -> Bool {
    !value.contains(",") && !value.contains(where: \.isNewline)
  }
}

enum RuleDisableMatchMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case contains
  case exact
  case regex

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .contains:
      return String(localized: "Contains")
    case .exact:
      return String(localized: "Exact")
    case .regex:
      return String(localized: "Regex")
    }
  }
}

struct ManagedRuleDisableMatcher: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var mode: RuleDisableMatchMode
  var pattern: String

  private enum CodingKeys: String, CodingKey {
    case id
    case mode
    case pattern
  }

  init(id: UUID = UUID(), mode: RuleDisableMatchMode = .contains, pattern: String = "") {
    self.id = id
    self.mode = mode
    self.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: container.decodeDefault(UUID.self, forKey: .id, default: UUID()),
      mode: container.decodeDefault(RuleDisableMatchMode.self, forKey: .mode, default: .contains),
      pattern: container.decodeDefault(String.self, forKey: .pattern, default: "")
    )
  }

  var normalizedPattern: String {
    pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var validationError: String? {
    let pattern = normalizedPattern
    if pattern.isEmpty {
      return String(localized: "Disabled rule pattern cannot be empty.")
    }
    if pattern.contains(where: \.isNewline) {
      return String(localized: "Disabled rule pattern cannot contain line breaks.")
    }
    if mode == .regex, (try? NSRegularExpression(pattern: pattern)) == nil {
      return String(localized: "Disabled rule regex is invalid.")
    }
    return nil
  }

  func matches(_ rule: String) -> Bool {
    guard validationError == nil else { return false }
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = normalizedPattern
    switch mode {
    case .contains:
      return rule.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    case .exact:
      return rule.compare(pattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    case .regex:
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return false
      }
      let range = NSRange(rule.startIndex..<rule.endIndex, in: rule)
      return regex.firstMatch(in: rule, range: range) != nil
    }
  }
}

struct RuleOverlaySettings: Codable, Equatable, Sendable {
  var enabled: Bool
  var prependRules: [ManagedRuleOverlayRule]
  var appendRules: [ManagedRuleOverlayRule]
  var disabledRuleMatchers: [ManagedRuleDisableMatcher]

  private enum CodingKeys: String, CodingKey {
    case enabled
    case prependRules
    case appendRules
    case disabledRuleMatchers
  }

  init(
    enabled: Bool = false,
    prependRules: [ManagedRuleOverlayRule] = [],
    appendRules: [ManagedRuleOverlayRule] = [],
    disabledRuleMatchers: [ManagedRuleDisableMatcher] = []
  ) {
    self.enabled = enabled
    self.prependRules = prependRules
    self.appendRules = appendRules
    self.disabledRuleMatchers = disabledRuleMatchers
  }

  static let disabled = RuleOverlaySettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: container.decodeDefault(Bool.self, forKey: .enabled, default: false),
      prependRules: container.decodeDefault([ManagedRuleOverlayRule].self, forKey: .prependRules, default: []),
      appendRules: container.decodeDefault([ManagedRuleOverlayRule].self, forKey: .appendRules, default: []),
      disabledRuleMatchers: container.decodeDefault(
        [ManagedRuleDisableMatcher].self,
        forKey: .disabledRuleMatchers,
        default: []
      )
    )
  }

  var hasRuntimeOverlay: Bool {
    enabled && (!prependRules.isEmpty || !appendRules.isEmpty || !disabledRuleMatchers.isEmpty)
  }

  var validationError: String? {
    for rule in prependRules + appendRules {
      if let error = rule.validationError {
        return error
      }
    }
    for matcher in disabledRuleMatchers {
      if let error = matcher.validationError {
        return error
      }
    }
    return nil
  }

  var runtimePrependRules: [String] {
    guard enabled else { return [] }
    return prependRules.compactMap { rule in
      rule.validationError == nil ? rule.runtimeRule : nil
    }
  }

  var runtimeAppendRules: [String] {
    guard enabled else { return [] }
    return appendRules.compactMap { rule in
      rule.validationError == nil ? rule.runtimeRule : nil
    }
  }

  var runtimeDisabledRuleMatchers: [ManagedRuleDisableMatcher] {
    guard enabled else { return [] }
    return disabledRuleMatchers.filter { $0.validationError == nil }
  }

  func disablesRule(_ rule: String) -> Bool {
    runtimeDisabledRuleMatchers.contains { $0.matches(rule) }
  }

  var summary: String {
    guard enabled else {
      return String(localized: "Disabled")
    }
    let count = prependRules.count + appendRules.count
    let disabledCount = disabledRuleMatchers.count
    if count == 0, disabledCount == 0 {
      return String(localized: "Enabled, no rules")
    }
    if disabledCount > 0 {
      return String(
        format: String(localized: "%lld added, %lld disabled"),
        Int64(count),
        Int64(disabledCount)
      )
    }
    return String(format: String(localized: "%lld managed rules"), Int64(count))
  }
}

extension RuleOverlaySettings {
  func combined(withProfileOverlay profileOverlay: RuleOverlaySettings) -> RuleOverlaySettings {
    let globalActive = enabled
    let profileActive = profileOverlay.enabled
    return RuleOverlaySettings(
      enabled: globalActive || profileActive,
      prependRules: (globalActive ? prependRules : []) + (profileActive ? profileOverlay.prependRules : []),
      appendRules: (profileActive ? profileOverlay.appendRules : []) + (globalActive ? appendRules : []),
      disabledRuleMatchers: (globalActive ? disabledRuleMatchers : [])
        + (profileActive ? profileOverlay.disabledRuleMatchers : [])
    )
  }
}

struct RuntimeOverrides: Codable, Equatable, Sendable {
  var mixedPort: Int
  var externalControllerHost: String
  var externalControllerPort: Int
  var secret: String
  var allowLan: Bool
  var ipv6Enabled: Bool
  var mode: RunMode
  var logLevel: String
  var unifiedDelay: Bool
  var dnsEnabled: Bool?
  var externalControllerCORS: ExternalControllerCORSSettings
  var ruleOverlay: RuleOverlaySettings
  var tunEnabled: Bool
  var tunSettings: TunSettings

  private enum CodingKeys: String, CodingKey {
    case mixedPort
    case externalControllerHost
    case externalControllerPort
    case secret
    case allowLan
    case ipv6Enabled
    case mode
    case logLevel
    case unifiedDelay
    case dnsEnabled
    case externalControllerCORS
    case ruleOverlay
    case tunEnabled
    case tunSettings
  }

  init(
    mixedPort: Int,
    externalControllerHost: String,
    externalControllerPort: Int,
    secret: String,
    allowLan: Bool,
    ipv6Enabled: Bool = false,
    mode: RunMode,
    logLevel: String,
    dnsEnabled: Bool?,
    ruleOverlay: RuleOverlaySettings = .disabled,
    tunEnabled: Bool,
    unifiedDelay: Bool = false,
    externalControllerCORS: ExternalControllerCORSSettings = .default,
    tunSettings: TunSettings = .default
  ) {
    self.mixedPort = mixedPort
    self.externalControllerHost = externalControllerHost
    self.externalControllerPort = externalControllerPort
    self.secret = secret
    self.allowLan = allowLan
    self.ipv6Enabled = ipv6Enabled
    self.mode = mode
    self.logLevel = logLevel
    self.unifiedDelay = unifiedDelay
    self.dnsEnabled = dnsEnabled
    self.externalControllerCORS = externalControllerCORS
    self.ruleOverlay = ruleOverlay
    self.tunEnabled = tunEnabled
    self.tunSettings = tunSettings
  }

  static func defaultForLaunch(secret: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> RuntimeOverrides {
    RuntimeOverrides(
      mixedPort: 7890,
      externalControllerHost: "127.0.0.1",
      externalControllerPort: 9097,
      secret: secret,
      allowLan: false,
      ipv6Enabled: false,
      mode: .rule,
      logLevel: "info",
      dnsEnabled: nil,
      ruleOverlay: .disabled,
      tunEnabled: false,
      unifiedDelay: false,
      externalControllerCORS: .default,
      tunSettings: .default
    )
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.defaultForLaunch()
    mixedPort = container.decodeDefault(Int.self, forKey: .mixedPort, default: defaults.mixedPort)
    externalControllerHost = container.decodeDefault(
      String.self,
      forKey: .externalControllerHost,
      default: defaults.externalControllerHost
    )
    externalControllerPort = container.decodeDefault(
      Int.self,
      forKey: .externalControllerPort,
      default: defaults.externalControllerPort
    )
    secret = container.decodeDefault(String.self, forKey: .secret, default: defaults.secret)
    allowLan = container.decodeDefault(Bool.self, forKey: .allowLan, default: defaults.allowLan)
    ipv6Enabled = container.decodeDefault(Bool.self, forKey: .ipv6Enabled, default: defaults.ipv6Enabled)
    mode = container.decodeDefault(RunMode.self, forKey: .mode, default: defaults.mode)
    logLevel = container.decodeDefault(String.self, forKey: .logLevel, default: defaults.logLevel)
    unifiedDelay = container.decodeDefault(Bool.self, forKey: .unifiedDelay, default: defaults.unifiedDelay)
    dnsEnabled = container.decodeDefault(Bool?.self, forKey: .dnsEnabled, default: defaults.dnsEnabled)
    externalControllerCORS = container.decodeDefault(
      ExternalControllerCORSSettings.self,
      forKey: .externalControllerCORS,
      default: defaults.externalControllerCORS
    )
    ruleOverlay = container.decodeDefault(
      RuleOverlaySettings.self,
      forKey: .ruleOverlay,
      default: defaults.ruleOverlay
    )
    tunEnabled = container.decodeDefault(Bool.self, forKey: .tunEnabled, default: defaults.tunEnabled)
    tunSettings = container.decodeDefault(TunSettings.self, forKey: .tunSettings, default: defaults.tunSettings)
  }

  var endpoint: CoreAPIEndpoint {
    CoreAPIEndpoint(host: externalControllerHost, port: externalControllerPort, secret: secret)
  }
}

struct SystemProxySettings: Codable, Equatable, Sendable {
  static let defaultProxyHost = "127.0.0.1"
  static let defaultGuardIntervalSeconds = 30
  static let minimumGuardIntervalSeconds = 5
  static let maximumGuardIntervalSeconds = 600
  static let defaultBypassDomains = [
    "127.0.0.1",
    "localhost",
    "::1",
    "*.local",
    "*.crashlytics.com",
    "<local>",
    "169.254/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
  ]

  var proxyHost: String
  var customBypassDomains: [String]
  var useDefaultBypass: Bool
  var validateBypass: Bool
  var guardEnabled: Bool
  var guardIntervalSeconds: Int

  private enum CodingKeys: String, CodingKey {
    case proxyHost
    case customBypassDomains
    case useDefaultBypass
    case validateBypass
    case guardEnabled
    case guardIntervalSeconds
  }

  init(
    proxyHost: String,
    customBypassDomains: [String],
    useDefaultBypass: Bool,
    validateBypass: Bool,
    guardEnabled: Bool,
    guardIntervalSeconds: Int
  ) {
    self.proxyHost = proxyHost
    self.customBypassDomains = Self.normalizedBypassDomains(customBypassDomains)
    self.useDefaultBypass = useDefaultBypass
    self.validateBypass = validateBypass
    self.guardEnabled = guardEnabled
    self.guardIntervalSeconds = guardIntervalSeconds
  }

  static let `default` = SystemProxySettings(
    proxyHost: defaultProxyHost,
    customBypassDomains: [],
    useDefaultBypass: true,
    validateBypass: true,
    guardEnabled: false,
    guardIntervalSeconds: defaultGuardIntervalSeconds
  )

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      proxyHost: container.decodeDefault(String.self, forKey: .proxyHost, default: defaults.proxyHost),
      customBypassDomains: container.decodeDefault(
        [String].self,
        forKey: .customBypassDomains,
        default: defaults.customBypassDomains
      ),
      useDefaultBypass: container.decodeDefault(Bool.self, forKey: .useDefaultBypass, default: defaults.useDefaultBypass),
      validateBypass: container.decodeDefault(Bool.self, forKey: .validateBypass, default: defaults.validateBypass),
      guardEnabled: container.decodeDefault(Bool.self, forKey: .guardEnabled, default: defaults.guardEnabled),
      guardIntervalSeconds: container.decodeDefault(
        Int.self,
        forKey: .guardIntervalSeconds,
        default: defaults.guardIntervalSeconds
      )
    )
  }

  var normalizedProxyHost: String {
    let trimmed = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || Self.isUnspecifiedBindHost(trimmed) {
      return Self.defaultProxyHost
    }
    return trimmed
  }

  var normalizedGuardIntervalSeconds: Int {
    min(max(guardIntervalSeconds, Self.minimumGuardIntervalSeconds), Self.maximumGuardIntervalSeconds)
  }

  var effectiveBypassDomains: [String] {
    var domains: [String] = []
    if useDefaultBypass {
      domains.append(contentsOf: Self.defaultBypassDomains)
    }
    domains.append(contentsOf: customBypassDomains)
    return Self.normalizedBypassDomains(domains)
  }

  var validationError: String? {
    guard validateBypass else { return nil }
    if normalizedProxyHost.contains(" ") {
      return "Proxy host cannot contain spaces."
    }
    if let invalid = customBypassDomains.first(where: { !Self.isValidBypassDomain($0) }) {
      return "Invalid bypass entry: \(invalid)"
    }
    return nil
  }

  static func normalizedBypassDomains(_ domains: [String]) -> [String] {
    var seen = Set<String>()
    return domains.compactMap { domain in
      let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { return nil }
      seen.insert(key)
      return trimmed
    }
  }

  static func isValidBypassDomain(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed == "<local>" { return true }
    if trimmed.contains(" ") { return false }
    if trimmed.contains("/") {
      let pieces = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
      guard pieces.count == 2, let prefix = Int(pieces[1]), (0...128).contains(prefix) else { return false }
      return !pieces[0].isEmpty
    }
    return trimmed.range(of: #"^[A-Za-z0-9*_.:-]+$"#, options: .regularExpression) != nil
  }

  static func isUnspecifiedBindHost(_ host: String) -> Bool {
    let normalized = host
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    var ipv4 = in_addr()
    if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      return ipv4.s_addr == 0
    }

    var ipv6 = in6_addr()
    guard normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
      return false
    }

    let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
    if bytes.allSatisfy({ $0 == 0 }) {
      return true
    }

    let ipv4MappedPrefix: [UInt8] = Array(repeating: 0, count: 10) + [0xff, 0xff]
    return bytes.starts(with: ipv4MappedPrefix)
      && bytes[12...15].allSatisfy { $0 == 0 }
  }
}

enum TunStack: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case gvisor
  case mixed

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .gvisor: "GVisor"
    case .mixed: "Mixed"
    }
  }
}

struct TunDNSFallbackFilter: Codable, Equatable, Sendable {
  var geoIP: Bool?
  var geoIPCode: String?
  var geoSite: [String]
  var ipCIDR: [String]
  var domain: [String]

  private enum CodingKeys: String, CodingKey {
    case geoIP
    case geoIPCode
    case geoSite
    case ipCIDR
    case domain
  }

  init(
    geoIP: Bool? = nil,
    geoIPCode: String? = nil,
    geoSite: [String] = [],
    ipCIDR: [String] = [],
    domain: [String] = []
  ) {
    self.geoIP = geoIP
    self.geoIPCode = Self.normalizedOptionalString(geoIPCode)
    self.geoSite = TunDNSSettings.normalizedList(geoSite)
    self.ipCIDR = NetworkExtensionRoutingSettings.normalizedRouteExcludeCIDRs(ipCIDR)
    self.domain = TunDNSSettings.normalizedList(domain)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      geoIP: try? container.decodeIfPresent(Bool.self, forKey: .geoIP),
      geoIPCode: try? container.decodeIfPresent(String.self, forKey: .geoIPCode),
      geoSite: container.decodeDefault([String].self, forKey: .geoSite, default: []),
      ipCIDR: container.decodeDefault([String].self, forKey: .ipCIDR, default: []),
      domain: container.decodeDefault([String].self, forKey: .domain, default: [])
    )
  }

  static let empty = TunDNSFallbackFilter()

  var isEmpty: Bool {
    geoIP == nil
      && geoIPCode == nil
      && geoSite.isEmpty
      && ipCIDR.isEmpty
      && domain.isEmpty
  }

  var validationError: String? {
    if let geoIPCode, !Self.isValidGeoIPCode(geoIPCode) {
      return "Invalid TUN DNS fallback geoip-code: \(geoIPCode)"
    }
    if let invalid = geoSite.first(where: { !TunDNSSettings.isValidPattern($0) }) {
      return "Invalid TUN DNS fallback geosite: \(invalid)"
    }
    if let invalid = ipCIDR.first(where: { !TunSettings.isValidRouteExcludeCIDR($0) }) {
      return "Invalid TUN DNS fallback ipcidr: \(invalid)"
    }
    if let invalid = domain.first(where: { !TunDNSSettings.isValidPattern($0) }) {
      return "Invalid TUN DNS fallback domain: \(invalid)"
    }
    return nil
  }

  private static func normalizedOptionalString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isValidGeoIPCode(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 32, !trimmed.contains(where: \.isWhitespace) else {
      return false
    }
    return trimmed.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
  }
}

struct TunDNSSettings: Codable, Equatable, Sendable {
  var preferH3: Bool?
  var useHosts: Bool?
  var useSystemHosts: Bool?
  var respectRules: Bool?
  var fakeIPFilter: [String]
  var defaultNameserver: [String]
  var nameserver: [String]
  var fallback: [String]
  var proxyServerNameserver: [String]
  var directNameserver: [String]
  var directNameserverFollowPolicy: Bool?
  var nameserverPolicy: [String: String]
  var proxyServerNameserverPolicy: [String: String]
  var hosts: [String: String]
  var fallbackFilter: TunDNSFallbackFilter

  private enum CodingKeys: String, CodingKey {
    case preferH3
    case useHosts
    case useSystemHosts
    case respectRules
    case fakeIPFilter
    case defaultNameserver
    case nameserver
    case fallback
    case proxyServerNameserver
    case directNameserver
    case directNameserverFollowPolicy
    case nameserverPolicy
    case proxyServerNameserverPolicy
    case hosts
    case fallbackFilter
  }

  init(
    preferH3: Bool? = nil,
    useHosts: Bool? = nil,
    useSystemHosts: Bool? = nil,
    respectRules: Bool? = nil,
    fakeIPFilter: [String] = [],
    defaultNameserver: [String] = [],
    nameserver: [String] = [],
    fallback: [String] = [],
    proxyServerNameserver: [String] = [],
    directNameserver: [String] = [],
    directNameserverFollowPolicy: Bool? = nil,
    nameserverPolicy: [String: String] = [:],
    proxyServerNameserverPolicy: [String: String] = [:],
    hosts: [String: String] = [:],
    fallbackFilter: TunDNSFallbackFilter = .empty
  ) {
    self.preferH3 = preferH3
    self.useHosts = useHosts
    self.useSystemHosts = useSystemHosts
    self.respectRules = respectRules
    self.fakeIPFilter = Self.normalizedList(fakeIPFilter)
    self.defaultNameserver = Self.normalizedList(defaultNameserver)
    self.nameserver = Self.normalizedList(nameserver)
    self.fallback = Self.normalizedList(fallback)
    self.proxyServerNameserver = Self.normalizedList(proxyServerNameserver)
    self.directNameserver = Self.normalizedList(directNameserver)
    self.directNameserverFollowPolicy = directNameserverFollowPolicy
    self.nameserverPolicy = Self.normalizedMap(nameserverPolicy)
    self.proxyServerNameserverPolicy = Self.normalizedMap(proxyServerNameserverPolicy)
    self.hosts = Self.normalizedMap(hosts)
    self.fallbackFilter = fallbackFilter
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      preferH3: try? container.decodeIfPresent(Bool.self, forKey: .preferH3),
      useHosts: try? container.decodeIfPresent(Bool.self, forKey: .useHosts),
      useSystemHosts: try? container.decodeIfPresent(Bool.self, forKey: .useSystemHosts),
      respectRules: try? container.decodeIfPresent(Bool.self, forKey: .respectRules),
      fakeIPFilter: container.decodeDefault([String].self, forKey: .fakeIPFilter, default: []),
      defaultNameserver: container.decodeDefault([String].self, forKey: .defaultNameserver, default: []),
      nameserver: container.decodeDefault([String].self, forKey: .nameserver, default: []),
      fallback: container.decodeDefault([String].self, forKey: .fallback, default: []),
      proxyServerNameserver: container.decodeDefault([String].self, forKey: .proxyServerNameserver, default: []),
      directNameserver: container.decodeDefault([String].self, forKey: .directNameserver, default: []),
      directNameserverFollowPolicy: try? container.decodeIfPresent(Bool.self, forKey: .directNameserverFollowPolicy),
      nameserverPolicy: container.decodeDefault([String: String].self, forKey: .nameserverPolicy, default: [:]),
      proxyServerNameserverPolicy: container.decodeDefault(
        [String: String].self,
        forKey: .proxyServerNameserverPolicy,
        default: [:]
      ),
      hosts: container.decodeDefault([String: String].self, forKey: .hosts, default: [:]),
      fallbackFilter: container.decodeDefault(TunDNSFallbackFilter.self, forKey: .fallbackFilter, default: .empty)
    )
  }

  static let legacyEmpty = TunDNSSettings()
  static let chinaNetworkDefault = TunDNSSettings(
    fakeIPFilter: [
      "*.lan",
      "*.local",
      "localhost.ptlogin2.qq.com",
      "captive.apple.com",
      "time.apple.com",
      "time-ios.apple.com",
      "time-macos.apple.com",
      "connectivitycheck.gstatic.com",
      "detectportal.firefox.com",
      "msftconnecttest.com",
      "msftncsi.com",
      "router.asus.com",
      "routerlogin.net",
      "tplogin.cn",
      "miwifi.com",
      "tendawifi.com"
    ],
    nameserver: [
      "https://dns.alidns.com/dns-query",
      "https://doh.pub/dns-query"
    ],
    fallback: [
      "tls://8.8.4.4",
      "tls://1.1.1.1"
    ]
  )
  static let `default` = chinaNetworkDefault
  static let profileDefault = TunDNSSettings()
  static let globalSecureDefault = TunDNSSettings(
    fakeIPFilter: chinaNetworkDefault.fakeIPFilter,
    defaultNameserver: ["1.1.1.1", "8.8.8.8"],
    nameserver: [
      "https://cloudflare-dns.com/dns-query",
      "https://dns.google/dns-query"
    ],
    fallback: [
      "tls://1.1.1.1",
      "tls://8.8.8.8"
    ]
  )
  static let presets = [
    TunDNSPreset(
      id: "china-default",
      title: String(localized: "China Optimized"),
      description: String(localized: "AliDNS and DNSPod with common LAN and captive-portal fake-ip exclusions."),
      settings: .chinaNetworkDefault
    ),
    TunDNSPreset(
      id: "profile",
      title: String(localized: "Profile DNS"),
      description: String(localized: "Do not add app-managed DNS resolvers; keep the profile DNS map."),
      settings: .profileDefault
    ),
    TunDNSPreset(
      id: "global-secure",
      title: String(localized: "Global Secure"),
      description: String(localized: "Cloudflare and Google DoH/TLS resolvers with the standard fake-ip exclusions."),
      settings: .globalSecureDefault
    )
  ]

  var hasRuntimeOverlay: Bool {
    preferH3 != nil
      || useHosts != nil
      || useSystemHosts != nil
      || respectRules != nil
      || !fakeIPFilter.isEmpty
      || !defaultNameserver.isEmpty
      || !nameserver.isEmpty
      || !fallback.isEmpty
      || !proxyServerNameserver.isEmpty
      || !directNameserver.isEmpty
      || directNameserverFollowPolicy != nil
      || !nameserverPolicy.isEmpty
      || !proxyServerNameserverPolicy.isEmpty
      || !hosts.isEmpty
      || !fallbackFilter.isEmpty
  }

  var validationError: String? {
    if let invalid = fakeIPFilter.first(where: { !Self.isValidPattern($0) }) {
      return "Invalid TUN fake-ip filter: \(invalid)"
    }
    if let invalid = defaultNameserver.first(where: { !Self.isValidDefaultNameserverResolver($0) }) {
      return "Invalid TUN DNS default-nameserver: \(invalid)"
    }
    for (title, values) in [
      ("nameserver", nameserver),
      ("fallback", fallback),
      ("proxy-server-nameserver", proxyServerNameserver),
      ("direct-nameserver", directNameserver)
    ] {
      if let invalid = values.first(where: { !Self.isValidResolver($0) }) {
        return "Invalid TUN DNS \(title): \(invalid)"
      }
    }
    if let invalid = nameserverPolicy.first(where: { !Self.isValidPattern($0.key) || !Self.isValidResolver($0.value) }) {
      return "Invalid TUN nameserver policy: \(invalid.key)=\(invalid.value)"
    }
    if let invalid = proxyServerNameserverPolicy.first(where: { !Self.isValidPattern($0.key) || !Self.isValidResolver($0.value) }) {
      return "Invalid TUN proxy-server-nameserver policy: \(invalid.key)=\(invalid.value)"
    }
    if let invalid = hosts.first(where: { !Self.isValidPattern($0.key) || !Self.isValidHostValue($0.value) }) {
      return "Invalid TUN host entry: \(invalid.key)=\(invalid.value)"
    }
    if let fallbackFilterValidationError = fallbackFilter.validationError {
      return fallbackFilterValidationError
    }
    return nil
  }

  static func normalizedList(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { return nil }
      seen.insert(key)
      return trimmed
    }
  }

  static func normalizedMap(_ values: [String: String]) -> [String: String] {
    values.reduce(into: [:]) { result, entry in
      let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { return }
      result[key] = value
    }
  }

  static func isValidDefaultNameserverResolver(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains(where: \.isWhitespace) else {
      return false
    }
    if NetworkExtensionRoutingSettings.isValidDNSServer(trimmed) {
      return true
    }

    let normalized = trimmed.lowercased()
    guard let schemeSeparator = normalized.range(of: "://") else {
      return false
    }
    let scheme = String(normalized[..<schemeSeparator.lowerBound])
    guard ["udp", "tcp", "tls", "https", "quic"].contains(scheme),
          hasValidResolverAuthorityPort(trimmed),
          let components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == scheme,
          isValidResolverIPAddressHost(components.host)
    else {
      return false
    }

    switch scheme {
    case "udp", "tcp", "tls", "quic":
      return components.path.isEmpty && components.query == nil
    case "https":
      return !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    default:
      return false
    }
  }

  static func isValidResolver(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains(where: \.isWhitespace) else {
      return false
    }
    let normalized = trimmed.lowercased()
    if normalized == "system" || normalized == "system://" {
      return true
    }
    if NetworkExtensionRoutingSettings.isValidDNSServer(trimmed) {
      return true
    }
    if normalized.hasPrefix("rcode://") {
      return isValidRCodeResolver(trimmed)
    }

    guard let schemeSeparator = normalized.range(of: "://") else {
      return false
    }
    let scheme = String(normalized[..<schemeSeparator.lowerBound])
    guard ["udp", "tcp", "tls", "https", "quic", "dhcp"].contains(scheme),
          hasValidResolverAuthorityPort(trimmed),
          let components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == scheme
    else {
      return false
    }

    switch scheme {
    case "udp", "tcp", "tls", "quic":
      return isValidResolverHost(components.host)
        && components.path.isEmpty
        && components.query == nil
    case "https":
      return isValidResolverHost(components.host)
        && !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case "dhcp":
      return isValidResolverToken(components.host)
        && components.path.isEmpty
        && components.query == nil
    default:
      return false
    }
  }

  static func isValidPattern(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 253, !trimmed.contains(where: \.isWhitespace) else {
      return false
    }
    return true
  }

  static func isValidHostValue(_ value: String) -> Bool {
    isValidResolver(value)
  }

  private static func isValidResolverIPAddressHost(_ value: String?) -> Bool {
    guard let value else { return false }
    return NetworkExtensionRoutingSettings.isValidDNSServer(value.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func isValidResolverHost(_ value: String?) -> Bool {
    guard let value else { return false }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
    if NetworkExtensionRoutingSettings.isValidDNSServer(trimmed) {
      return true
    }
    if isInvalidIPv4Literal(trimmed) {
      return false
    }
    if trimmed.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#, options: .regularExpression) != nil {
      return true
    }
    return false
  }

  private static func isInvalidIPv4Literal(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy(\.isNumber)
    }
  }

  private static func isValidResolverToken(_ value: String?) -> Bool {
    guard let value else { return false }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed.count <= 64
      && trimmed.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
  }

  private static func isValidRCodeResolver(_ value: String) -> Bool {
    let code = value.dropFirst("rcode://".count).lowercased()
    return [
      "success",
      "format_error",
      "server_failure",
      "name_error",
      "not_implemented",
      "refused"
    ].contains(String(code))
  }

  private static func hasValidResolverAuthorityPort(_ value: String) -> Bool {
    guard let separator = value.range(of: "://") else { return false }
    let remainder = value[separator.upperBound...]
    let authorityEnd = remainder.firstIndex { character in
      character == "/" || character == "?" || character == "#"
    } ?? remainder.endIndex
    let authority = remainder[..<authorityEnd]
    guard !authority.isEmpty, !authority.contains("@") else { return false }

    if authority.first == "[" {
      guard let closingBracket = authority.firstIndex(of: "]") else { return false }
      let afterHost = authority[authority.index(after: closingBracket)...]
      guard afterHost.isEmpty || afterHost.first == ":" else { return false }
      if afterHost.isEmpty { return true }
      return isValidResolverPort(String(afterHost.dropFirst()))
    }

    let colonCount = authority.reduce(into: 0) { count, character in
      if character == ":" { count += 1 }
    }
    guard colonCount <= 1 else { return false }
    if colonCount == 1 {
      guard let colon = authority.lastIndex(of: ":") else { return false }
      return isValidResolverPort(String(authority[authority.index(after: colon)...]))
    }
    return true
  }

  private static func isValidResolverPort(_ value: String) -> Bool {
    guard let port = Int(value), (1...65_535).contains(port) else {
      return false
    }
    return true
  }
}

struct TunDNSPreset: Equatable, Identifiable, Sendable {
  var id: String
  var title: String
  var description: String
  var settings: TunDNSSettings
}

struct TunSettings: Codable, Equatable, Sendable {
  static let defaultDevice = "utun1024"
  static let defaultDNSHijack = ["any:53"]
  static let defaultMTU = 1500
  static let defaultFakeIPRange = NetworkExtensionRoutingSettings.defaultFakeIPRange
  static let defaultSystemDNSServers = NetworkExtensionRoutingSettings.defaultSystemDNSServers

  var stack: TunStack
  var device: String
  var autoRoute: Bool
  var strictRoute: Bool
  var autoDetectInterface: Bool
  var dnsHijack: [String]
  var mtu: Int
  var routeExcludeAddresses: [String]
  var dnsFakeIPEnabled: Bool
  var fakeIPRange: String
  var systemDNSOverrideEnabled: Bool
  var systemDNSServers: [String]
  var dns: TunDNSSettings

  private enum CodingKeys: String, CodingKey {
    case stack
    case device
    case autoRoute
    case strictRoute
    case autoDetectInterface
    case dnsHijack
    case mtu
    case routeExcludeAddresses
    case dnsFakeIPEnabled
    case fakeIPRange
    case systemDNSOverrideEnabled
    case systemDNSServers
    case dns
  }

  init(
    stack: TunStack,
    device: String,
    autoRoute: Bool,
    strictRoute: Bool,
    autoDetectInterface: Bool,
    dnsHijack: [String],
    mtu: Int,
    routeExcludeAddresses: [String],
    dnsFakeIPEnabled: Bool = true,
    fakeIPRange: String = Self.defaultFakeIPRange,
    systemDNSOverrideEnabled: Bool = true,
    systemDNSServers: [String] = Self.defaultSystemDNSServers,
    dns: TunDNSSettings = .default
  ) {
    self.stack = stack
    self.device = device
    self.autoRoute = autoRoute
    self.strictRoute = strictRoute
    self.autoDetectInterface = autoDetectInterface
    self.dnsHijack = dnsHijack
    self.mtu = mtu
    self.routeExcludeAddresses = NetworkExtensionRoutingSettings.normalizedRouteExcludeCIDRs(routeExcludeAddresses)
    self.dnsFakeIPEnabled = dnsFakeIPEnabled
    self.fakeIPRange = fakeIPRange.trimmingCharacters(in: .whitespacesAndNewlines)
    self.systemDNSOverrideEnabled = systemDNSOverrideEnabled
    self.systemDNSServers = NetworkExtensionRoutingSettings.normalizedDNSServerInputs(systemDNSServers)
    self.dns = dns
  }

  static let `default` = TunSettings(
    stack: .mixed,
    device: defaultDevice,
    autoRoute: true,
    strictRoute: false,
    autoDetectInterface: true,
    dnsHijack: defaultDNSHijack,
    mtu: defaultMTU,
    routeExcludeAddresses: [],
    dnsFakeIPEnabled: true,
    fakeIPRange: defaultFakeIPRange,
    systemDNSOverrideEnabled: true,
    systemDNSServers: defaultSystemDNSServers,
    dns: .default
  )

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      stack: container.decodeDefault(TunStack.self, forKey: .stack, default: defaults.stack),
      device: container.decodeDefault(String.self, forKey: .device, default: defaults.device),
      autoRoute: container.decodeDefault(Bool.self, forKey: .autoRoute, default: defaults.autoRoute),
      strictRoute: container.decodeDefault(Bool.self, forKey: .strictRoute, default: defaults.strictRoute),
      autoDetectInterface: container.decodeDefault(
        Bool.self,
        forKey: .autoDetectInterface,
        default: defaults.autoDetectInterface
      ),
      dnsHijack: container.decodeDefault([String].self, forKey: .dnsHijack, default: defaults.dnsHijack),
      mtu: container.decodeDefault(Int.self, forKey: .mtu, default: defaults.mtu),
      routeExcludeAddresses: container.decodeDefault(
        [String].self,
        forKey: .routeExcludeAddresses,
        default: defaults.routeExcludeAddresses
      ),
      dnsFakeIPEnabled: container.decodeDefault(
        Bool.self,
        forKey: .dnsFakeIPEnabled,
        default: defaults.dnsFakeIPEnabled
      ),
      fakeIPRange: container.decodeDefault(String.self, forKey: .fakeIPRange, default: defaults.fakeIPRange),
      systemDNSOverrideEnabled: container.decodeDefault(
        Bool.self,
        forKey: .systemDNSOverrideEnabled,
        default: defaults.systemDNSOverrideEnabled
      ),
      systemDNSServers: container.decodeDefault(
        [String].self,
        forKey: .systemDNSServers,
        default: defaults.systemDNSServers
      ),
      dns: container.decodeDefault(
        TunDNSSettings.self,
        forKey: .dns,
        default: defaults.dns
      )
    )
  }

  var normalizedDevice: String {
    let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? Self.defaultDevice : trimmed
  }

  var normalizedDNSHijack: [String] {
    normalizedList(dnsHijack, fallback: Self.defaultDNSHijack)
  }

  var normalizedRouteExcludeAddresses: [String] {
    Self.normalizedRouteExcludeCIDRs(routeExcludeAddresses)
  }

  var normalizedMTU: Int {
    min(max(mtu, 576), 9_000)
  }

  var normalizedFakeIPRange: String {
    Self.isValidRouteExcludeCIDR(fakeIPRange)
      ? fakeIPRange.trimmingCharacters(in: .whitespacesAndNewlines)
      : Self.defaultFakeIPRange
  }

  var effectiveSystemDNSServers: [String] {
    let normalized = NetworkExtensionRoutingSettings.normalizedDNSServers(systemDNSServers)
    return normalized.isEmpty ? Self.defaultSystemDNSServers : normalized
  }

  var validationError: String? {
    if dnsFakeIPEnabled, !Self.isValidRouteExcludeCIDR(fakeIPRange) {
      return "Invalid TUN fake-ip range: \(fakeIPRange)"
    }
    if systemDNSOverrideEnabled, let invalid = systemDNSServers.first(where: { !NetworkExtensionRoutingSettings.isValidDNSServer($0) }) {
      return "Invalid TUN system DNS server: \(invalid)"
    }
    if let dnsValidationError = dns.validationError {
      return dnsValidationError
    }
    if let invalid = routeExcludeAddresses.first(where: { !Self.isValidRouteExcludeCIDR($0) }) {
      return "Invalid TUN route exclude CIDR: \(invalid)"
    }
    return nil
  }

  static func isValidRouteExcludeCIDR(_ value: String) -> Bool {
    (try? NetworkExtensionRouteCIDR(value)) != nil
  }

  static func normalizedRouteExcludeCIDRs(_ values: [String]) -> [String] {
    NetworkExtensionRoutingSettings.normalizedRouteExcludeCIDRs(values).filter(Self.isValidRouteExcludeCIDR)
  }

  private func normalizedList(_ values: [String], fallback: [String]) -> [String] {
    let normalized = SystemProxySettings.normalizedBypassDomains(values)
    return normalized.isEmpty ? fallback : normalized
  }
}

enum TunHelperPreparationState: Equatable, Sendable {
  case idle
  case checking
  case registered(String)
  case ready
  case requiresApproval(String)
  case notBootstrapped(String)
  case failed(String)

  var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  var allowsStartAttempt: Bool {
    switch self {
    case .registered, .ready:
      return true
    case .idle, .checking, .requiresApproval, .notBootstrapped, .failed:
      return false
    }
  }

  var isFailure: Bool {
    switch self {
    case .notBootstrapped, .failed:
      return true
    default:
      return false
    }
  }

  var shouldPollForApproval: Bool {
    switch self {
    case .requiresApproval:
      return true
    default:
      return false
    }
  }

  var message: String {
    switch self {
    case .idle:
      return String(localized: "TUN helper needs preparation before Start is available.")
    case .checking:
      return String(localized: "Preparing the TUN helper with macOS.")
    case let .registered(message):
      return message
    case .ready:
      return String(localized: "TUN helper is ready.")
    case let .requiresApproval(message),
         let .notBootstrapped(message),
         let .failed(message):
      return message
    }
  }
}

struct LaunchSettings: Equatable {
  var launchAtLogin: Bool
  var silentStart: Bool
  var statusMessage: String

  static let `default` = LaunchSettings(
    launchAtLogin: false,
    silentStart: false,
    statusMessage: String(localized: "Launch at login is not registered.")
  )
}

struct CoreAPIEndpoint: Codable, Equatable, Sendable {
  var host: String
  var port: Int
  var secret: String

  var baseURL: URL {
    get throws {
      let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
      let authorityHost = Self.authorityHost(for: normalizedHost)
      let urlString = "http://\(authorityHost):\(port)"
      guard !normalizedHost.isEmpty,
            (1...65_535).contains(port),
            let url = URL(string: urlString),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "http",
            let componentHost = components.host,
            !componentHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw MihomoAPIClient.ClientError.invalidURL(urlString)
      }
      return url
    }
  }

  private static func authorityHost(for host: String) -> String {
    guard host.contains(":"),
          !host.hasPrefix("["),
          !host.hasSuffix("]")
    else {
      return host
    }
    return "[\(host)]"
  }
}

enum CoreStatus: Equatable, Sendable {
  case stopped
  case starting
  case running(version: String?)
  case crashed(message: String)
  case restarting

  var displayName: String {
    switch self {
    case .stopped: String(localized: "Stopped")
    case .starting: String(localized: "Starting")
    case .running: String(localized: "Running")
    case .crashed: String(localized: "Crashed")
    case .restarting: String(localized: "Restarting")
    }
  }
}

struct ProxyNode: Identifiable, Codable, Equatable, Sendable {
  var id: String {
    [
      providerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      name
    ]
    .compactMap { $0 }
    .joined(separator: "::")
  }
  var name: String
  var type: String
  var delay: Int?
  var isSelectable: Bool
  var serverHost: String?
  var serverPort: Int?
  var providerName: String?
  var udpSupported: Bool?
  var tfoSupported: Bool?
  var xudpSupported: Bool?
  var delayState: ProxyDelayState

  private enum CodingKeys: String, CodingKey {
    case name
    case type
    case delay
    case isSelectable
    case serverHost
    case serverPort
    case providerName
    case udpSupported
    case tfoSupported
    case xudpSupported
    case delayState
  }

  init(
    name: String,
    type: String,
    delay: Int?,
    isSelectable: Bool,
    serverHost: String? = nil,
    serverPort: Int? = nil,
    providerName: String? = nil,
    udpSupported: Bool? = nil,
    tfoSupported: Bool? = nil,
    xudpSupported: Bool? = nil,
    delayState: ProxyDelayState? = nil
  ) {
    self.name = name
    self.type = type
    self.delay = delay
    self.isSelectable = isSelectable
    self.serverHost = serverHost
    self.serverPort = serverPort
    self.providerName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.udpSupported = udpSupported
    self.tfoSupported = tfoSupported
    self.xudpSupported = xudpSupported
    self.delayState = delayState ?? delay.map(ProxyDelayState.measured) ?? .unknown
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let delay = try container.decodeIfPresent(Int.self, forKey: .delay)
    self.init(
      name: try container.decode(String.self, forKey: .name),
      type: try container.decode(String.self, forKey: .type),
      delay: delay,
      isSelectable: try container.decode(Bool.self, forKey: .isSelectable),
      serverHost: try container.decodeIfPresent(String.self, forKey: .serverHost),
      serverPort: try container.decodeIfPresent(Int.self, forKey: .serverPort),
      providerName: try container.decodeIfPresent(String.self, forKey: .providerName),
      udpSupported: try container.decodeIfPresent(Bool.self, forKey: .udpSupported),
      tfoSupported: try container.decodeIfPresent(Bool.self, forKey: .tfoSupported),
      xudpSupported: try container.decodeIfPresent(Bool.self, forKey: .xudpSupported),
      delayState: try container.decodeIfPresent(ProxyDelayState.self, forKey: .delayState)
    )
  }

  var resolvedDelayState: ProxyDelayState {
    if case .unknown = delayState, let delay {
      return .measured(delay)
    }
    return delayState
  }

  var endpointSummary: String? {
    guard let host = serverHost?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
      return nil
    }
    if let serverPort {
      return "\(host):\(serverPort)"
    }
    return host
  }

  var capabilityLabels: [String] {
    var labels: [String] = []
    if udpSupported == true {
      labels.append("UDP")
    }
    if tfoSupported == true {
      labels.append("TFO")
    }
    if xudpSupported == true {
      labels.append("XUDP")
    }
    return labels
  }
}

struct ProxyGroup: Identifiable, Codable, Equatable, Sendable {
  var id: String { name }
  var name: String
  var type: String
  var selected: String?
  var nodes: [ProxyNode]

  var allowsManualProxySelection: Bool {
    let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalizedType == "select" || normalizedType == "selector"
  }
}

struct MenuBarPinnedGroupSettings: Codable, Equatable, Sendable {
  static let maximumPinnedGroups = 3

  var groupNames: [String]

  init(groupNames: [String] = []) {
    self.groupNames = Self.normalized(groupNames)
  }

  static let `default` = MenuBarPinnedGroupSettings()

  mutating func toggle(_ groupName: String) {
    let normalizedName = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else { return }
    if groupNames.contains(where: { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }) {
      groupNames.removeAll { $0.caseInsensitiveCompare(normalizedName) == .orderedSame }
    } else {
      groupNames = Self.normalized(groupNames + [normalizedName])
    }
  }

  func contains(_ groupName: String) -> Bool {
    groupNames.contains { $0.caseInsensitiveCompare(groupName) == .orderedSame }
  }

  static func normalized(_ groupNames: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for groupName in groupNames {
      let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      guard seen.insert(key).inserted else { continue }
      result.append(trimmed)
      if result.count == maximumPinnedGroups { break }
    }
    return result
  }
}

struct ConnectionSnapshot: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var network: String
  var host: String
  var sourceIP: String?
  var sourcePort: Int?
  var destinationIP: String?
  var destinationPort: Int?
  var processName: String?
  var processPath: String?
  var upload: Int
  var download: Int
  var chain: [String]
  var rule: String?
  var rulePayload: String?
  var startedAt: Date?
  var lastSeenAt: Date?
  var endedAt: Date?

  init(
    id: String,
    network: String,
    host: String,
    sourceIP: String? = nil,
    sourcePort: Int? = nil,
    destinationIP: String? = nil,
    destinationPort: Int? = nil,
    processName: String? = nil,
    processPath: String? = nil,
    upload: Int,
    download: Int,
    chain: [String],
    rule: String?,
    rulePayload: String? = nil,
    startedAt: Date? = nil,
    lastSeenAt: Date? = nil,
    endedAt: Date? = nil
  ) {
    self.id = id
    self.network = network
    self.host = host
    self.sourceIP = sourceIP?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.sourcePort = sourcePort
    self.destinationIP = destinationIP?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.destinationPort = destinationPort
    self.processName = processName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.processPath = processPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.upload = upload
    self.download = download
    self.chain = chain
    self.rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.rulePayload = rulePayload?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.startedAt = startedAt
    self.lastSeenAt = lastSeenAt
    self.endedAt = endedAt
  }

  var appDisplayName: String {
    processName ?? processPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "-"
  }

  var sourceAddress: String {
    Self.endpointLabel(host: sourceIP, port: sourcePort)
  }

  var destinationAddress: String {
    let destinationHost = destinationIP ?? host
    return Self.endpointLabel(host: destinationHost, port: destinationPort)
  }

  var ruleSummary: String {
    [rule, rulePayload].compactMap { $0 }.joined(separator: " ")
  }

  private static func endpointLabel(host: String?, port: Int?) -> String {
    guard let host, !host.isEmpty else { return "-" }
    guard let port else { return host }
    return "\(host):\(port)"
  }
}

struct ConnectionRecord: Identifiable, Codable, Equatable, Sendable {
  var id: String { snapshot.id }
  var snapshot: ConnectionSnapshot
  var isActive: Bool
}

struct RuntimeRule: Identifiable, Codable, Equatable, Sendable {
  var index: Int
  var type: String
  var payload: String
  var policy: String
  var providerName: String?
  var raw: String

  var id: String {
    "\(index):\(type):\(payload):\(policy)"
  }

  init(
    index: Int,
    type: String,
    payload: String,
    policy: String,
    providerName: String? = nil,
    raw: String? = nil
  ) {
    self.index = index
    self.type = type
    self.payload = payload
    self.policy = policy
    self.providerName = providerName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.raw = raw ?? [type, payload, policy].filter { !$0.isEmpty }.joined(separator: ",")
  }
}

enum RuleMatchSimulationOutcome: Equatable, Sendable {
  case matched(RuntimeRule)
  case mihomoOnly(String)
  case noMatch

  var title: String {
    switch self {
    case let .matched(rule):
      return String(format: String(localized: "Matched rule #%lld"), Int64(rule.index))
    case .mihomoOnly:
      return String(localized: "Reported by Mihomo")
    case .noMatch:
      return String(localized: "No local match")
    }
  }

  var detail: String {
    switch self {
    case let .matched(rule):
      return rule.raw
    case let .mihomoOnly(reason):
      return reason
    case .noMatch:
      return String(localized: "No supported local rule matched. Runtime provider and geodata rules may still match inside Mihomo.")
    }
  }
}

struct RuleMatchSimulator: Sendable {
  func simulate(target: String, rules: [RuntimeRule]) -> RuleMatchSimulationOutcome {
    let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTarget.isEmpty else { return .noMatch }

    for rule in rules.sorted(by: { $0.index < $1.index }) {
      switch match(rule: rule, target: normalizedTarget) {
      case true:
        return .matched(rule)
      case false:
        continue
      case nil:
        return .mihomoOnly(String(localized: "This rule type depends on provider, geodata, or runtime-only Mihomo matching."))
      }
    }
    return .noMatch
  }

  private func match(rule: RuntimeRule, target: String) -> Bool? {
    let type = rule.type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let payload = rule.payload.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    switch type {
    case "DOMAIN":
      return target.caseInsensitiveCompare(payload) == .orderedSame
    case "DOMAIN-SUFFIX":
      let lowerTarget = target.lowercased()
      let lowerPayload = payload.lowercased()
      return lowerTarget == lowerPayload || lowerTarget.hasSuffix(".\(lowerPayload)")
    case "DOMAIN-KEYWORD":
      return target.localizedCaseInsensitiveContains(payload)
    case "IP-CIDR":
      return matchCIDR(payload: payload, target: target, family: .ipv4)
    case "IP-CIDR6":
      return matchCIDR(payload: payload, target: target, family: .ipv6)
    case "PROCESS-NAME":
      let processNameURL = URL(fileURLWithPath: target)
      let processName = processNameURL.lastPathComponent
      let processNameWithoutExtension = processNameURL.deletingPathExtension().lastPathComponent
      return target.caseInsensitiveCompare(payload) == .orderedSame
        || processName.caseInsensitiveCompare(payload) == .orderedSame
        || processNameWithoutExtension.caseInsensitiveCompare(payload) == .orderedSame
    case "PROCESS-PATH":
      return target.caseInsensitiveCompare(payload) == .orderedSame
    case "MATCH":
      return true
    case "GEOSITE", "GEOIP", "RULE-SET":
      return nil
    default:
      return target.localizedCaseInsensitiveContains(payload)
    }
  }

  private func matchCIDR(
    payload: String,
    target: String,
    family: NetworkExtensionRouteCIDR.AddressFamily
  ) -> Bool {
    guard let cidr = try? NetworkExtensionRouteCIDR(payload),
          cidr.family == family
    else {
      return false
    }

    switch family {
    case .ipv4:
      guard let targetValue = ipv4Value(target),
            let cidrValue = ipv4Value(cidr.address)
      else {
        return false
      }
      let mask: UInt32 = cidr.prefix == 0 ? 0 : UInt32.max << UInt32(32 - cidr.prefix)
      return targetValue & mask == cidrValue & mask
    case .ipv6:
      guard let targetBytes = ipv6Bytes(target),
            let cidrBytes = ipv6Bytes(cidr.address)
      else {
        return false
      }
      return ipv6(targetBytes, matches: cidrBytes, prefix: cidr.prefix)
    }
  }

  private func ipv4Value(_ value: String) -> UInt32? {
    var address = in_addr()
    let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let result = normalized.withCString { inet_pton(AF_INET, $0, &address) }
    guard result == 1 else { return nil }
    return UInt32(bigEndian: address.s_addr)
  }

  private func ipv6Bytes(_ value: String) -> [UInt8]? {
    var address = in6_addr()
    let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let result = normalized.withCString { inet_pton(AF_INET6, $0, &address) }
    guard result == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
  }

  private func ipv6(_ lhs: [UInt8], matches rhs: [UInt8], prefix: Int) -> Bool {
    guard lhs.count == 16, rhs.count == 16 else { return false }
    var remainingBits = prefix
    for index in 0..<16 {
      if remainingBits >= 8 {
        guard lhs[index] == rhs[index] else { return false }
        remainingBits -= 8
      } else if remainingBits > 0 {
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return lhs[index] & mask == rhs[index] & mask
      } else {
        return true
      }
    }
    return true
  }
}

struct RuleExplanation: Equatable, Sendable {
  var connectionID: ConnectionSnapshot.ID
  var target: String
  var reportedRule: String?
  var reportedRulePayload: String?
  var chosenPolicy: String?
  var localOutcome: RuleMatchSimulationOutcome
  var ruleCount: Int

  var reportedRuleSummary: String {
    [reportedRule, reportedRulePayload].compactMap { $0 }.joined(separator: " ")
  }

  var chosenPolicySummary: String {
    if let chosenPolicy, !chosenPolicy.isEmpty {
      return chosenPolicy
    }
    return String(localized: "Unknown")
  }

  var localSummary: String {
    "\(localOutcome.title): \(localOutcome.detail)"
  }
}

struct RoutingSimulationRequest: Identifiable, Equatable, Sendable {
  var id: UUID
  var connectionID: ConnectionSnapshot.ID
  var target: String
  var explanation: RuleExplanation

  init(
    id: UUID = UUID(),
    connectionID: ConnectionSnapshot.ID,
    target: String,
    explanation: RuleExplanation
  ) {
    self.id = id
    self.connectionID = connectionID
    self.target = target
    self.explanation = explanation
  }
}

struct RuleExplanationBuilder: Sendable {
  private let simulator = RuleMatchSimulator()

  func explanation(for connection: ConnectionSnapshot, rules: [RuntimeRule]) -> RuleExplanation {
    let candidates = simulationTargets(for: connection)
    let fallbackTarget = candidates.first ?? connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
    let evaluated = candidates.map { target in
      (target: target, outcome: simulator.simulate(target: target, rules: rules))
    }
    let selected = selectedEvaluation(from: evaluated)
      ?? (target: fallbackTarget, outcome: simulator.simulate(target: fallbackTarget, rules: rules))
    let matchedPolicy: String?
    switch selected.outcome {
    case let .matched(rule):
      matchedPolicy = rule.policy
    case .mihomoOnly, .noMatch:
      matchedPolicy = connection.chain.first
    }
    return RuleExplanation(
      connectionID: connection.id,
      target: selected.target,
      reportedRule: connection.rule,
      reportedRulePayload: connection.rulePayload,
      chosenPolicy: matchedPolicy,
      localOutcome: selected.outcome,
      ruleCount: rules.count
    )
  }

  private func selectedEvaluation(
    from evaluations: [(target: String, outcome: RuleMatchSimulationOutcome)]
  ) -> (target: String, outcome: RuleMatchSimulationOutcome)? {
    if let specificMatch = evaluations.first(where: { evaluation in
      if case let .matched(rule) = evaluation.outcome {
        return rule.type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "MATCH"
      }
      return false
    }) {
      return specificMatch
    }
    if let mihomoOnly = evaluations.first(where: { evaluation in
      if case .mihomoOnly = evaluation.outcome {
        return true
      }
      return false
    }) {
      return mihomoOnly
    }
    if let matchFallback = evaluations.first(where: { evaluation in
      if case .matched = evaluation.outcome {
        return true
      }
      return false
    }) {
      return matchFallback
    }
    return evaluations.first
  }

  private func simulationTargets(for connection: ConnectionSnapshot) -> [String] {
    let ruleType = connection.rule?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    let processTargets = [connection.processPath, connection.processName].compactMap(Self.normalized)
    let ipTargets = [connection.destinationIP, connection.host].compactMap(Self.normalized)
    let hostTargets = [connection.host, connection.destinationIP].compactMap(Self.normalized)
    let ordered: [String]
    if ruleType.hasPrefix("PROCESS") {
      ordered = processTargets + hostTargets
    } else if ruleType.hasPrefix("IP-CIDR") || ruleType == "GEOIP" {
      ordered = ipTargets + processTargets
    } else {
      ordered = hostTargets + processTargets
    }
    return Self.unique(ordered)
  }

  private static func normalized(_ value: String?) -> String? {
    value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      let key = value.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(value)
    }
    return result
  }
}

struct ExternalDashboardProfile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var url: URL
  var readOnly: Bool
  var secretAccount: String?

  init(
    id: UUID = UUID(),
    name: String,
    url: URL = URL(string: "https://yacd.metacubex.one")!,
    readOnly: Bool = true,
    secretAccount: String? = nil
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? String(localized: "Dashboard")
    self.url = url
    self.readOnly = readOnly
    self.secretAccount = secretAccount?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}

struct NetworkPolicyRule: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var ssid: String
  var proxyRoutingMode: ProxyRoutingMode
  var enableSystemProxy: Bool
  var autoStartRuntime: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case ssid
    case proxyRoutingMode
    case enableSystemProxy
    case autoStartRuntime
  }

  init(
    id: UUID = UUID(),
    name: String = "",
    ssid: String = "",
    proxyRoutingMode: ProxyRoutingMode = .systemProxy,
    enableSystemProxy: Bool = true,
    autoStartRuntime: Bool = false
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.ssid = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    self.proxyRoutingMode = proxyRoutingMode
    self.enableSystemProxy = enableSystemProxy
    self.autoStartRuntime = autoStartRuntime
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: container.decodeDefault(UUID.self, forKey: .id, default: UUID()),
      name: container.decodeDefault(String.self, forKey: .name, default: ""),
      ssid: container.decodeDefault(String.self, forKey: .ssid, default: ""),
      proxyRoutingMode: container.decodeDefault(ProxyRoutingMode.self, forKey: .proxyRoutingMode, default: .systemProxy),
      enableSystemProxy: container.decodeDefault(Bool.self, forKey: .enableSystemProxy, default: true),
      autoStartRuntime: container.decodeDefault(Bool.self, forKey: .autoStartRuntime, default: false)
    )
  }

  var validationError: String? {
    if name.isEmpty {
      return String(localized: "Network policy name cannot be empty.")
    }
    if ssid.isEmpty {
      return String(localized: "Network SSID cannot be empty.")
    }
    return nil
  }

  var description: String {
    let systemProxyText = proxyRoutingMode == .systemProxy && enableSystemProxy
      ? String(localized: "System Proxy on")
      : String(localized: "System Proxy unchanged")
    let startText = autoStartRuntime
      ? String(localized: "auto-start")
      : String(localized: "do not start")
    return String(
      format: String(localized: "SSID %@, %@, %@, %@"),
      ssid,
      proxyRoutingMode.displayName,
      systemProxyText,
      startText
    )
  }

  func matches(ssid candidate: String) -> Bool {
    ssid.caseInsensitiveCompare(candidate.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
  }
}

struct NetworkPolicySettings: Codable, Equatable, Sendable {
  var rules: [NetworkPolicyRule]
  var autoApplyEnabled: Bool

  private enum CodingKeys: String, CodingKey {
    case rules
    case autoApplyEnabled
  }

  init(rules: [NetworkPolicyRule] = [], autoApplyEnabled: Bool = true) {
    self.rules = rules
    self.autoApplyEnabled = autoApplyEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      rules: container.decodeDefault([NetworkPolicyRule].self, forKey: .rules, default: []),
      autoApplyEnabled: container.decodeDefault(Bool.self, forKey: .autoApplyEnabled, default: true)
    )
  }

  static let `default` = NetworkPolicySettings()

  var summary: String {
    if rules.isEmpty {
      return String(localized: "No saved network policies")
    }
    return String(format: String(localized: "%lld saved rules"), Int64(rules.count))
  }

  func matchingRule(ssid: String) -> NetworkPolicyRule? {
    rules.first { $0.matches(ssid: ssid) }
  }
}

struct ClashXMigrationReport: Codable, Equatable, Sendable {
  var configDirectory: String
  var subscriptionURLs: [String]
  var duplicateSubscriptionURLs: [String]
  var bypassDomains: [String]
  var ports: [String: Int]
  var allowLan: Bool?
  var mode: String?
  var logLevel: String?
  var systemProxyEnabled: Bool?
  var conflicts: [String]
  var unsupportedSettings: [String]
  var unknownKeys: [String]
  var inspectedFiles: [String]
  var warnings: [String]

  private enum CodingKeys: String, CodingKey {
    case configDirectory
    case subscriptionURLs
    case duplicateSubscriptionURLs
    case bypassDomains
    case ports
    case allowLan
    case mode
    case logLevel
    case systemProxyEnabled
    case conflicts
    case unsupportedSettings
    case unknownKeys
    case inspectedFiles
    case warnings
  }

  init(
    configDirectory: String,
    subscriptionURLs: [String] = [],
    duplicateSubscriptionURLs: [String] = [],
    bypassDomains: [String] = [],
    ports: [String: Int] = [:],
    allowLan: Bool? = nil,
    mode: String? = nil,
    logLevel: String? = nil,
    systemProxyEnabled: Bool? = nil,
    conflicts: [String] = [],
    unsupportedSettings: [String] = [],
    unknownKeys: [String] = [],
    inspectedFiles: [String] = [],
    warnings: [String] = []
  ) {
    self.configDirectory = configDirectory
    self.subscriptionURLs = subscriptionURLs
    self.duplicateSubscriptionURLs = duplicateSubscriptionURLs
    self.bypassDomains = bypassDomains
    self.ports = ports
    self.allowLan = allowLan
    self.mode = mode
    self.logLevel = logLevel
    self.systemProxyEnabled = systemProxyEnabled
    self.conflicts = conflicts
    self.unsupportedSettings = unsupportedSettings
    self.unknownKeys = unknownKeys
    self.inspectedFiles = inspectedFiles
    self.warnings = warnings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      configDirectory: container.decodeDefault(String.self, forKey: .configDirectory, default: ""),
      subscriptionURLs: container.decodeDefault([String].self, forKey: .subscriptionURLs, default: []),
      duplicateSubscriptionURLs: container.decodeDefault([String].self, forKey: .duplicateSubscriptionURLs, default: []),
      bypassDomains: container.decodeDefault([String].self, forKey: .bypassDomains, default: []),
      ports: container.decodeDefault([String: Int].self, forKey: .ports, default: [:]),
      allowLan: try container.decodeIfPresent(Bool.self, forKey: .allowLan),
      mode: try container.decodeIfPresent(String.self, forKey: .mode),
      logLevel: try container.decodeIfPresent(String.self, forKey: .logLevel),
      systemProxyEnabled: try container.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled),
      conflicts: container.decodeDefault([String].self, forKey: .conflicts, default: []),
      unsupportedSettings: container.decodeDefault([String].self, forKey: .unsupportedSettings, default: []),
      unknownKeys: container.decodeDefault([String].self, forKey: .unknownKeys, default: []),
      inspectedFiles: container.decodeDefault([String].self, forKey: .inspectedFiles, default: []),
      warnings: container.decodeDefault([String].self, forKey: .warnings, default: [])
    )
  }

  var summary: String {
    let subscriptionSummary = String.localizedStringWithFormat(
      NSLocalizedString("%lld subscriptions", comment: ""),
      Int64(subscriptionURLs.count)
    )
    let bypassSummary = String.localizedStringWithFormat(
      NSLocalizedString("%lld bypass entries", comment: ""),
      Int64(bypassDomains.count)
    )
    return "\(subscriptionSummary), \(bypassSummary)"
  }
}

struct TrafficSample: Codable, Equatable, Sendable {
  var upload: Int
  var download: Int

  static let zero = TrafficSample(upload: 0, download: 0)

  var shortLabel: String {
    "\(Self.format(download))/\(Self.format(upload))"
  }

  static func format(_ bytesPerSecond: Int) -> String {
    let value = Double(bytesPerSecond)
    if value >= 1024 * 1024 {
      return String(format: "%.1f MB/s", value / 1024 / 1024)
    }
    if value >= 1024 {
      return String(format: "%.0f KB/s", value / 1024)
    }
    return "\(bytesPerSecond) B/s"
  }

  static func formatBytes(_ bytes: Int) -> String {
    let value = Double(bytes)
    if value >= 1024 * 1024 * 1024 {
      return String(format: "%.1f GB", value / 1024 / 1024 / 1024)
    }
    if value >= 1024 * 1024 {
      return String(format: "%.1f MB", value / 1024 / 1024)
    }
    if value >= 1024 {
      return String(format: "%.0f KB", value / 1024)
    }
    return "\(bytes) B"
  }
}

struct LogEntry: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var date: Date
  var level: String
  var message: String

  init(id: UUID = UUID(), date: Date = Date(), level: String, message: String) {
    self.id = id
    self.date = date
    self.level = level
    self.message = message
  }
}

enum LogVisibility {
  static func visibleEntries(in entries: [LogEntry], developerMode: Bool) -> [LogEntry] {
    guard !developerMode else { return entries }
    return entries.filter { !isDeveloperOnly($0) }
  }

  static func isDeveloperOnly(_ entry: LogEntry) -> Bool {
    let level = entry.level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if level == "debug" || level == "trace" {
      return true
    }

    let message = entry.message.lowercased()
    return isDelayDiagnostic(message)
  }

  private static func isDelayDiagnostic(_ message: String) -> Bool {
    if message.contains("url-test") || message.contains("generate_204") {
      return true
    }

    guard let delayHost = AppConstants.defaultDelayTestURL.host?.lowercased() else {
      return false
    }
    return message.contains(delayHost) && (message.contains("delay") || message.contains("latency"))
  }
}

struct SubscriptionTrafficUsage: Codable, Equatable, Sendable {
  var upload: Int?
  var download: Int?
  var total: Int?
  var expireAt: Date?
}

struct SubscriptionMetadata: Codable, Equatable, Sendable {
  var traffic: SubscriptionTrafficUsage?
  var remoteFileName: String?
  var displayNameHint: String?
  var updateIntervalMinutes: Int?
  var webPageURL: URL?
  var lastFetchedAt: Date?

  init(
    traffic: SubscriptionTrafficUsage? = nil,
    remoteFileName: String? = nil,
    displayNameHint: String? = nil,
    updateIntervalMinutes: Int? = nil,
    webPageURL: URL? = nil,
    lastFetchedAt: Date? = nil
  ) {
    self.traffic = traffic
    self.remoteFileName = remoteFileName
    self.displayNameHint = displayNameHint
    self.updateIntervalMinutes = updateIntervalMinutes
    self.webPageURL = webPageURL
    self.lastFetchedAt = lastFetchedAt
  }

  var trafficSummary: String? {
    guard let traffic else { return nil }
    let used = (traffic.upload ?? 0) + (traffic.download ?? 0)
    if let total = traffic.total, total > 0 {
      return "\(TrafficSample.formatBytes(used)) used of \(TrafficSample.formatBytes(total))"
    }
    guard used > 0 else { return nil }
    return "\(TrafficSample.formatBytes(used)) used"
  }
}

enum SubscriptionFetchStrategy: String, Codable, CaseIterable, Equatable, Sendable {
  case direct
  case localClashProxy
  case systemProxy

  static let defaultRetryOrder: [SubscriptionFetchStrategy] = [.direct, .localClashProxy, .systemProxy]
}

struct SubscriptionFetchOptions: Equatable, Sendable {
  var userAgent: String
  var timeout: TimeInterval
  var localProxyHost: String
  var localProxyPort: Int
  var allowsInsecureTLS: Bool
  var retryOrder: [SubscriptionFetchStrategy]
  var customHeaders: [String: String]

  init(
    userAgent: String = "clash.meta",
    timeout: TimeInterval = 20,
    localProxyHost: String = "127.0.0.1",
    localProxyPort: Int = 7890,
    allowsInsecureTLS: Bool = false,
    retryOrder: [SubscriptionFetchStrategy] = SubscriptionFetchStrategy.defaultRetryOrder,
    customHeaders: [String: String] = [:]
  ) {
    self.userAgent = userAgent
    self.timeout = timeout
    self.localProxyHost = localProxyHost
    self.localProxyPort = localProxyPort
    self.allowsInsecureTLS = allowsInsecureTLS
    self.retryOrder = retryOrder
    self.customHeaders = customHeaders
  }
}

struct SubscriptionFetchSettings: Codable, Equatable, Sendable {
  static let defaultUserAgent = "clash.meta"
  static let minimumTimeoutSeconds = 5
  static let maximumTimeoutSeconds = 120
  static let standardUpdateIntervalMinutes = 48 * 60
  static let standardBackgroundCheckIntervalMinutes = 2 * 60
  static let standardRetryCapMinutes = 6 * 60

  var userAgent: String
  var timeoutSeconds: Int
  var useLocalClashProxy: Bool
  var useSystemProxy: Bool
  var allowsInsecureTLS: Bool
  var automaticUpdatesEnabled: Bool
  var defaultUpdateIntervalMinutes: Int
  var backgroundCheckIntervalMinutes: Int
  var retryCapMinutes: Int
  var notifyOnUpdateFailure: Bool

  private enum CodingKeys: String, CodingKey {
    case userAgent
    case timeoutSeconds
    case useLocalClashProxy
    case useSystemProxy
    case allowsInsecureTLS
    case automaticUpdatesEnabled
    case defaultUpdateIntervalMinutes
    case backgroundCheckIntervalMinutes
    case retryCapMinutes
    case notifyOnUpdateFailure
  }

  init(
    userAgent: String = defaultUserAgent,
    timeoutSeconds: Int = 20,
    useLocalClashProxy: Bool = true,
    useSystemProxy: Bool = true,
    allowsInsecureTLS: Bool = false,
    automaticUpdatesEnabled: Bool = true,
    defaultUpdateIntervalMinutes: Int = Self.standardUpdateIntervalMinutes,
    backgroundCheckIntervalMinutes: Int = Self.standardBackgroundCheckIntervalMinutes,
    retryCapMinutes: Int = Self.standardRetryCapMinutes,
    notifyOnUpdateFailure: Bool = false
  ) {
    let trimmedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
    self.userAgent = trimmedUserAgent.isEmpty ? Self.defaultUserAgent : trimmedUserAgent
    self.timeoutSeconds = min(max(timeoutSeconds, Self.minimumTimeoutSeconds), Self.maximumTimeoutSeconds)
    self.useLocalClashProxy = useLocalClashProxy
    self.useSystemProxy = useSystemProxy
    self.allowsInsecureTLS = allowsInsecureTLS
    self.automaticUpdatesEnabled = automaticUpdatesEnabled
    self.defaultUpdateIntervalMinutes = SubscriptionUpdatePolicy.normalizedInterval(defaultUpdateIntervalMinutes)
    self.backgroundCheckIntervalMinutes = SubscriptionUpdatePolicy.normalizedInterval(backgroundCheckIntervalMinutes)
    self.retryCapMinutes = SubscriptionUpdatePolicy.normalizedInterval(retryCapMinutes)
    self.notifyOnUpdateFailure = notifyOnUpdateFailure
  }

  static let `default` = SubscriptionFetchSettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    self.init(
      userAgent: container.decodeDefault(String.self, forKey: .userAgent, default: defaults.userAgent),
      timeoutSeconds: container.decodeDefault(Int.self, forKey: .timeoutSeconds, default: defaults.timeoutSeconds),
      useLocalClashProxy: container.decodeDefault(
        Bool.self,
        forKey: .useLocalClashProxy,
        default: defaults.useLocalClashProxy
      ),
      useSystemProxy: container.decodeDefault(Bool.self, forKey: .useSystemProxy, default: defaults.useSystemProxy),
      allowsInsecureTLS: container.decodeDefault(
        Bool.self,
        forKey: .allowsInsecureTLS,
        default: defaults.allowsInsecureTLS
      ),
      automaticUpdatesEnabled: container.decodeDefault(
        Bool.self,
        forKey: .automaticUpdatesEnabled,
        default: defaults.automaticUpdatesEnabled
      ),
      defaultUpdateIntervalMinutes: container.decodeDefault(
        Int.self,
        forKey: .defaultUpdateIntervalMinutes,
        default: defaults.defaultUpdateIntervalMinutes
      ),
      backgroundCheckIntervalMinutes: container.decodeDefault(
        Int.self,
        forKey: .backgroundCheckIntervalMinutes,
        default: defaults.backgroundCheckIntervalMinutes
      ),
      retryCapMinutes: container.decodeDefault(Int.self, forKey: .retryCapMinutes, default: defaults.retryCapMinutes),
      notifyOnUpdateFailure: container.decodeDefault(
        Bool.self,
        forKey: .notifyOnUpdateFailure,
        default: defaults.notifyOnUpdateFailure
      )
    )
  }

  var timeoutDescription: String {
    "\(timeoutSeconds)s"
  }

  var defaultUpdateIntervalDescription: String {
    Self.intervalDescription(defaultUpdateIntervalMinutes)
  }

  var backgroundCheckIntervalDescription: String {
    Self.intervalDescription(backgroundCheckIntervalMinutes)
  }

  static func intervalDescription(_ minutes: Int) -> String {
    if minutes % 1_440 == 0 {
      return "\(minutes / 1_440)d"
    }
    if minutes % 60 == 0 {
      return "\(minutes / 60)h"
    }
    return "\(minutes)m"
  }

  func fetchOptions(currentMixedPort: Int) -> SubscriptionFetchOptions {
    var retryOrder: [SubscriptionFetchStrategy] = [.direct]
    if useLocalClashProxy {
      retryOrder.append(.localClashProxy)
    }
    if useSystemProxy {
      retryOrder.append(.systemProxy)
    }
    let trimmedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTimeoutSeconds = min(
      max(timeoutSeconds, Self.minimumTimeoutSeconds),
      Self.maximumTimeoutSeconds
    )
    return SubscriptionFetchOptions(
      userAgent: trimmedUserAgent.isEmpty ? Self.defaultUserAgent : trimmedUserAgent,
      timeout: TimeInterval(normalizedTimeoutSeconds),
      localProxyHost: "127.0.0.1",
      localProxyPort: currentMixedPort,
      allowsInsecureTLS: allowsInsecureTLS,
      retryOrder: retryOrder
    )
  }
}

extension SubscriptionProviderOptions {
  func fetchOptions(from base: SubscriptionFetchOptions) -> SubscriptionFetchOptions {
    var options = base
    switch fetchProxy {
    case .defaultOrder:
      break
    case .direct:
      options.retryOrder = [.direct]
    case .localClashProxy:
      options.retryOrder = [.localClashProxy]
    case .systemProxy:
      options.retryOrder = [.systemProxy]
    }
    options.customHeaders = normalizedHeaders
    return options
  }
}

struct SubscriptionFetchResult: Equatable, Sendable {
  var source: String
  var metadata: SubscriptionMetadata
}

struct ProviderSubscriptionInfo: Codable, Equatable, Sendable {
  var upload: Int?
  var download: Int?
  var total: Int?
  var expireAt: Date?

  var usageSummary: String? {
    var parts: [String] = []
    if let upload {
      parts.append("\(String(localized: "Upload")) \(TrafficSample.formatBytes(upload))")
    }
    if let download {
      parts.append("\(String(localized: "Download")) \(TrafficSample.formatBytes(download))")
    }
    if let total {
      parts.append("\(String(localized: "Total")) \(TrafficSample.formatBytes(total))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " / ")
  }
}

struct ProxyProvider: Identifiable, Codable, Equatable, Sendable {
  var id: String { name }
  var name: String
  var type: String
  var vehicleType: String?
  var updatedAt: Date?
  var subscriptionInfo: ProviderSubscriptionInfo? = nil
  var proxies: [ProxyNode]
}

struct RuleProvider: Identifiable, Codable, Equatable, Sendable {
  var id: String { name }
  var name: String
  var type: String
  var vehicleType: String?
  var behavior: String?
  var format: String?
  var updatedAt: Date?
  var ruleCount: Int?
}

enum RuntimeOwner: String, Codable, Equatable, Sendable {
  case stopped
  case user
  case tunnel
  case networkExtension
  case preview
}

enum SystemProxyMode: String, Codable, Equatable {
  case global
}

enum SystemProxyGuardState: String, Codable, Equatable {
  case idle
  case active
}
