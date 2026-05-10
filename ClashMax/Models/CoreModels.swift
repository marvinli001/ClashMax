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
    case .localFile: "Local YAML"
    case .subscription: "Subscription"
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

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .systemProxy: String(localized: "System Proxy")
    case .tun: String(localized: "TUN")
    }
  }

  var symbolName: String {
    switch self {
    case .systemProxy: "network.badge.shield.half.filled"
    case .tun: "point.topleft.down.curvedto.point.bottomright.up"
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

struct RuntimeOverrides: Codable, Equatable, Sendable {
  var mixedPort: Int
  var externalControllerHost: String
  var externalControllerPort: Int
  var secret: String
  var allowLan: Bool
  var mode: RunMode
  var logLevel: String
  var unifiedDelay: Bool
  var dnsEnabled: Bool?
  var externalControllerCORS: ExternalControllerCORSSettings
  var tunEnabled: Bool
  var tunSettings: TunSettings

  private enum CodingKeys: String, CodingKey {
    case mixedPort
    case externalControllerHost
    case externalControllerPort
    case secret
    case allowLan
    case mode
    case logLevel
    case unifiedDelay
    case dnsEnabled
    case externalControllerCORS
    case tunEnabled
    case tunSettings
  }

  init(
    mixedPort: Int,
    externalControllerHost: String,
    externalControllerPort: Int,
    secret: String,
    allowLan: Bool,
    mode: RunMode,
    logLevel: String,
    dnsEnabled: Bool?,
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
    self.mode = mode
    self.logLevel = logLevel
    self.unifiedDelay = unifiedDelay
    self.dnsEnabled = dnsEnabled
    self.externalControllerCORS = externalControllerCORS
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
      mode: .rule,
      logLevel: "info",
      dnsEnabled: nil,
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
    mode = container.decodeDefault(RunMode.self, forKey: .mode, default: defaults.mode)
    logLevel = container.decodeDefault(String.self, forKey: .logLevel, default: defaults.logLevel)
    unifiedDelay = container.decodeDefault(Bool.self, forKey: .unifiedDelay, default: defaults.unifiedDelay)
    dnsEnabled = container.decodeDefault(Bool?.self, forKey: .dnsEnabled, default: defaults.dnsEnabled)
    externalControllerCORS = container.decodeDefault(
      ExternalControllerCORSSettings.self,
      forKey: .externalControllerCORS,
      default: defaults.externalControllerCORS
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

struct TunSettings: Codable, Equatable, Sendable {
  static let defaultDevice = "utun1024"
  static let defaultDNSHijack = ["any:53"]
  static let defaultMTU = 1500

  var stack: TunStack
  var device: String
  var autoRoute: Bool
  var strictRoute: Bool
  var autoDetectInterface: Bool
  var dnsHijack: [String]
  var mtu: Int
  var routeExcludeAddresses: [String]

  private enum CodingKeys: String, CodingKey {
    case stack
    case device
    case autoRoute
    case strictRoute
    case autoDetectInterface
    case dnsHijack
    case mtu
    case routeExcludeAddresses
  }

  init(
    stack: TunStack,
    device: String,
    autoRoute: Bool,
    strictRoute: Bool,
    autoDetectInterface: Bool,
    dnsHijack: [String],
    mtu: Int,
    routeExcludeAddresses: [String]
  ) {
    self.stack = stack
    self.device = device
    self.autoRoute = autoRoute
    self.strictRoute = strictRoute
    self.autoDetectInterface = autoDetectInterface
    self.dnsHijack = dnsHijack
    self.mtu = mtu
    self.routeExcludeAddresses = routeExcludeAddresses
  }

  static let `default` = TunSettings(
    stack: .mixed,
    device: defaultDevice,
    autoRoute: true,
    strictRoute: false,
    autoDetectInterface: true,
    dnsHijack: defaultDNSHijack,
    mtu: defaultMTU,
    routeExcludeAddresses: []
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
    normalizedList(routeExcludeAddresses, fallback: [])
  }

  var normalizedMTU: Int {
    min(max(mtu, 576), 9_000)
  }

  private func normalizedList(_ values: [String], fallback: [String]) -> [String] {
    let normalized = SystemProxySettings.normalizedBypassDomains(values)
    return normalized.isEmpty ? fallback : normalized
  }
}

enum TunHelperPreparationState: Equatable, Sendable {
  case idle
  case checking
  case ready
  case requiresApproval(String)
  case notBootstrapped(String)
  case failed(String)

  var isReady: Bool {
    if case .ready = self { return true }
    return false
  }

  var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }

  var shouldPollForApproval: Bool {
    switch self {
    case .requiresApproval, .notBootstrapped:
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
  var updateIntervalMinutes: Int?
  var webPageURL: URL?
  var lastFetchedAt: Date?

  init(
    traffic: SubscriptionTrafficUsage? = nil,
    remoteFileName: String? = nil,
    updateIntervalMinutes: Int? = nil,
    webPageURL: URL? = nil,
    lastFetchedAt: Date? = nil
  ) {
    self.traffic = traffic
    self.remoteFileName = remoteFileName
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
  var retryOrder: [SubscriptionFetchStrategy]

  init(
    userAgent: String = "clash.meta",
    timeout: TimeInterval = 20,
    localProxyHost: String = "127.0.0.1",
    localProxyPort: Int = 7890,
    retryOrder: [SubscriptionFetchStrategy] = SubscriptionFetchStrategy.defaultRetryOrder
  ) {
    self.userAgent = userAgent
    self.timeout = timeout
    self.localProxyHost = localProxyHost
    self.localProxyPort = localProxyPort
    self.retryOrder = retryOrder
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
  case preview
}

enum SystemProxyMode: String, Codable, Equatable {
  case global
}

enum SystemProxyGuardState: String, Codable, Equatable {
  case idle
  case active
}
