import Darwin
import Foundation

private extension KeyedDecodingContainer {
  func decodeDefault<T: Decodable>(
    _ type: T.Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> T
  ) -> T {
    (try? decodeIfPresent(type, forKey: key)) ?? defaultValue()
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

struct Profile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var nameIsUserCustomized: Bool
  var source: ProfileSource
  var originalConfigPath: String
  var subscriptionMetadata: SubscriptionMetadata?
  var createdAt: Date
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case nameIsUserCustomized
    case source
    case originalConfigPath
    case subscriptionMetadata
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
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.nameIsUserCustomized = nameIsUserCustomized
    self.source = source
    self.originalConfigPath = originalConfigPath
    self.subscriptionMetadata = subscriptionMetadata
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
      case .domain, .domainSuffix, .domainKeyword, .geoSite, .match:
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
      return "Rule value cannot be empty."
    }
    if kind.requiresValue, !Self.isValidField(normalizedValue) {
      return "Rule value cannot contain commas or line breaks."
    }
    if normalizedPolicy.isEmpty {
      return "Rule policy cannot be empty."
    }
    if !Self.isValidField(normalizedPolicy) {
      return "Rule policy cannot contain commas or line breaks."
    }
    return nil
  }

  private static func isValidField(_ value: String) -> Bool {
    !value.contains(",") && !value.contains(where: \.isNewline)
  }
}

struct RuleOverlaySettings: Codable, Equatable, Sendable {
  var enabled: Bool
  var prependRules: [ManagedRuleOverlayRule]
  var appendRules: [ManagedRuleOverlayRule]

  private enum CodingKeys: String, CodingKey {
    case enabled
    case prependRules
    case appendRules
  }

  init(
    enabled: Bool = false,
    prependRules: [ManagedRuleOverlayRule] = [],
    appendRules: [ManagedRuleOverlayRule] = []
  ) {
    self.enabled = enabled
    self.prependRules = prependRules
    self.appendRules = appendRules
  }

  static let disabled = RuleOverlaySettings()

  var hasRuntimeOverlay: Bool {
    enabled && (!prependRules.isEmpty || !appendRules.isEmpty)
  }

  var validationError: String? {
    for rule in prependRules + appendRules {
      if let error = rule.validationError {
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

  var summary: String {
    guard enabled else {
      return String(localized: "Disabled")
    }
    let count = prependRules.count + appendRules.count
    if count == 0 {
      return String(localized: "Enabled, no rules")
    }
    return String(format: String(localized: "%lld managed rules"), Int64(count))
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
  var id: String { name }
  var name: String
  var type: String
  var delay: Int?
  var isSelectable: Bool
  var serverHost: String?
  var serverPort: Int?
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

struct ConnectionSnapshot: Identifiable, Codable, Equatable, Sendable {
  var id: String
  var network: String
  var host: String
  var upload: Int
  var download: Int
  var chain: [String]
  var rule: String?
  var startedAt: Date?
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

  init(
    userAgent: String = "clash.meta",
    timeout: TimeInterval = 20,
    localProxyHost: String = "127.0.0.1",
    localProxyPort: Int = 7890,
    allowsInsecureTLS: Bool = false,
    retryOrder: [SubscriptionFetchStrategy] = SubscriptionFetchStrategy.defaultRetryOrder
  ) {
    self.userAgent = userAgent
    self.timeout = timeout
    self.localProxyHost = localProxyHost
    self.localProxyPort = localProxyPort
    self.allowsInsecureTLS = allowsInsecureTLS
    self.retryOrder = retryOrder
  }
}

struct SubscriptionFetchSettings: Codable, Equatable, Sendable {
  static let defaultUserAgent = "clash.meta"
  static let minimumTimeoutSeconds = 5
  static let maximumTimeoutSeconds = 120

  var userAgent: String
  var timeoutSeconds: Int
  var useLocalClashProxy: Bool
  var useSystemProxy: Bool
  var allowsInsecureTLS: Bool
  var automaticUpdatesEnabled: Bool

  private enum CodingKeys: String, CodingKey {
    case userAgent
    case timeoutSeconds
    case useLocalClashProxy
    case useSystemProxy
    case allowsInsecureTLS
    case automaticUpdatesEnabled
  }

  init(
    userAgent: String = defaultUserAgent,
    timeoutSeconds: Int = 20,
    useLocalClashProxy: Bool = true,
    useSystemProxy: Bool = true,
    allowsInsecureTLS: Bool = false,
    automaticUpdatesEnabled: Bool = true
  ) {
    let trimmedUserAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
    self.userAgent = trimmedUserAgent.isEmpty ? Self.defaultUserAgent : trimmedUserAgent
    self.timeoutSeconds = min(max(timeoutSeconds, Self.minimumTimeoutSeconds), Self.maximumTimeoutSeconds)
    self.useLocalClashProxy = useLocalClashProxy
    self.useSystemProxy = useSystemProxy
    self.allowsInsecureTLS = allowsInsecureTLS
    self.automaticUpdatesEnabled = automaticUpdatesEnabled
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
      )
    )
  }

  var timeoutDescription: String {
    "\(timeoutSeconds)s"
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

struct SubscriptionFetchResult: Equatable, Sendable {
  var source: String
  var metadata: SubscriptionMetadata
}

struct ProxyProvider: Identifiable, Codable, Equatable, Sendable {
  var id: String { name }
  var name: String
  var type: String
  var vehicleType: String?
  var updatedAt: Date?
  var proxies: [ProxyNode]
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
