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

enum NetworkExtensionRuntimeConstants {
  static let providerBundleIdentifier = "io.github.clashmax.ClashMax.NetworkExtension"
  static let appGroupIdentifier = "group.678WA95W4U.io.github.clashmax.ClashMax.network-extension"
  static let diagnosticsFilename = "transparent-proxy-diagnostics.json"
  static let mihomoArm64SigningIdentifier = "io.github.clashmax.ClashMax.Mihomo.arm64"
  static let mihomoAmd64SigningIdentifier = "io.github.clashmax.ClashMax.Mihomo.amd64"
}

enum NetworkExtensionRouteCIDRError: LocalizedError, Equatable {
  case invalidFormat(String)
  case invalidAddress(String)
  case invalidPrefix(String, Int)

  var errorDescription: String? {
    switch self {
    case let .invalidFormat(value):
      return "NE route exclude must be an IP CIDR: \(value)"
    case let .invalidAddress(value):
      return "NE route exclude address is invalid: \(value)"
    case let .invalidPrefix(value, maximum):
      return "NE route exclude prefix is invalid for \(value). Expected 0...\(maximum)."
    }
  }
}

struct NetworkExtensionRouteCIDR: Codable, Equatable, Sendable {
  enum AddressFamily: String, Codable, Equatable, Sendable {
    case ipv4
    case ipv6
  }

  var address: String
  var prefix: Int
  var family: AddressFamily

  init(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard pieces.count == 2,
          !pieces[0].isEmpty,
          !pieces[1].isEmpty,
          let prefix = Int(pieces[1])
    else {
      throw NetworkExtensionRouteCIDRError.invalidFormat(value)
    }

    var ipv4 = in_addr()
    if pieces[0].withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      guard (0...32).contains(prefix) else {
        throw NetworkExtensionRouteCIDRError.invalidPrefix(trimmed, 32)
      }
      address = pieces[0]
      self.prefix = prefix
      family = .ipv4
      return
    }

    var ipv6 = in6_addr()
    if pieces[0].withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
      guard (0...128).contains(prefix) else {
        throw NetworkExtensionRouteCIDRError.invalidPrefix(trimmed, 128)
      }
      address = pieces[0].lowercased()
      self.prefix = prefix
      family = .ipv6
      return
    }

    throw NetworkExtensionRouteCIDRError.invalidAddress(pieces[0])
  }

  var rawValue: String {
    "\(address)/\(prefix)"
  }
}

struct NetworkExtensionRoutingSettings: Codable, Equatable, Sendable {
  static let defaultDNSListenHost = "127.0.0.1"
  static let defaultDNSListenPort = 1053
  static let defaultFakeIPRange = "198.18.0.1/16"
  static let defaultSystemDNSServers = ["114.114.114.114"]
  static let defaultLANRouteExcludeCIDRs = [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "::1/128",
    "fe80::/10",
    "fc00::/7"
  ]

  var excludeLAN: Bool
  var dnsCaptureEnabled: Bool
  var dnsFakeIPEnabled: Bool
  var dnsListenPort: Int
  var systemDNSOverrideEnabled: Bool
  var systemDNSServers: [String]
  var customRouteExcludeCIDRs: [String]

  private enum CodingKeys: String, CodingKey {
    case excludeLAN
    case dnsCaptureEnabled
    case dnsFakeIPEnabled
    case legacyDNSFakeIP = "dnsFakeIP"
    case dnsListenPort
    case systemDNSOverrideEnabled
    case systemDNSServers
    case customRouteExcludeCIDRs
  }

  init(
    excludeLAN: Bool = true,
    dnsCaptureEnabled: Bool = true,
    dnsFakeIPEnabled: Bool = true,
    dnsListenPort: Int = Self.defaultDNSListenPort,
    systemDNSOverrideEnabled: Bool = true,
    systemDNSServers: [String] = Self.defaultSystemDNSServers,
    customRouteExcludeCIDRs: [String] = []
  ) {
    self.excludeLAN = excludeLAN
    self.dnsCaptureEnabled = dnsCaptureEnabled
    self.dnsFakeIPEnabled = dnsFakeIPEnabled
    self.dnsListenPort = dnsListenPort
    self.systemDNSOverrideEnabled = systemDNSOverrideEnabled
    self.systemDNSServers = Self.normalizedDNSServerInputs(systemDNSServers)
    self.customRouteExcludeCIDRs = Self.normalizedRouteExcludeCIDRs(customRouteExcludeCIDRs)
  }

  static let `default` = NetworkExtensionRoutingSettings()

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    let decodedFakeIP = try container.decodeIfPresent(Bool.self, forKey: .dnsFakeIPEnabled)
      ?? container.decodeIfPresent(Bool.self, forKey: .legacyDNSFakeIP)
      ?? defaults.dnsFakeIPEnabled
    self.init(
      excludeLAN: container.decodeDefault(Bool.self, forKey: .excludeLAN, default: defaults.excludeLAN),
      dnsCaptureEnabled: container.decodeDefault(
        Bool.self,
        forKey: .dnsCaptureEnabled,
        default: defaults.dnsCaptureEnabled
      ),
      dnsFakeIPEnabled: decodedFakeIP,
      dnsListenPort: container.decodeDefault(Int.self, forKey: .dnsListenPort, default: defaults.dnsListenPort),
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
      customRouteExcludeCIDRs: container.decodeDefault(
        [String].self,
        forKey: .customRouteExcludeCIDRs,
        default: defaults.customRouteExcludeCIDRs
      )
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(excludeLAN, forKey: .excludeLAN)
    try container.encode(dnsCaptureEnabled, forKey: .dnsCaptureEnabled)
    try container.encode(dnsFakeIPEnabled, forKey: .dnsFakeIPEnabled)
    try container.encode(dnsListenPort, forKey: .dnsListenPort)
    try container.encode(systemDNSOverrideEnabled, forKey: .systemDNSOverrideEnabled)
    try container.encode(systemDNSServers, forKey: .systemDNSServers)
    try container.encode(customRouteExcludeCIDRs, forKey: .customRouteExcludeCIDRs)
  }

  var effectiveRouteExcludeCIDRs: [String] {
    var values: [String] = []
    if excludeLAN {
      values.append(contentsOf: Self.defaultLANRouteExcludeCIDRs)
    }
    values.append(contentsOf: customRouteExcludeCIDRs)
    return Self.normalizedRouteExcludeCIDRs(values)
  }

  var normalizedDNSListenPort: Int {
    Self.isValidPort(dnsListenPort) ? dnsListenPort : Self.defaultDNSListenPort
  }

  var normalizedDNSListenAddress: String {
    "\(Self.defaultDNSListenHost):\(normalizedDNSListenPort)"
  }

  var effectiveSystemDNSServers: [String] {
    let normalized = Self.normalizedDNSServers(systemDNSServers)
    return normalized.isEmpty ? Self.defaultSystemDNSServers : normalized
  }

  var validationError: String? {
    if !Self.isValidPort(dnsListenPort) {
      return "Invalid NE DNS listen port: \(dnsListenPort)"
    }
    if systemDNSOverrideEnabled, let invalid = systemDNSServers.first(where: { !Self.isValidDNSServer($0) }) {
      return "Invalid NE system DNS server: \(invalid)"
    }
    if let invalid = customRouteExcludeCIDRs.first(where: { !Self.isValidCIDR($0) }) {
      return "Invalid NE route exclude CIDR: \(invalid)"
    }
    return nil
  }

  static func isValidCIDR(_ value: String) -> Bool {
    (try? NetworkExtensionRouteCIDR(value)) != nil
  }

  static func isValidPort(_ value: Int) -> Bool {
    (1...65_535).contains(value)
  }

  static func isValidDNSServer(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    var ipv4 = in_addr()
    if trimmed.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      return true
    }
    var ipv6 = in6_addr()
    return trimmed.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
  }

  static func normalizedDNSServers(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard isValidDNSServer(trimmed) else { return nil }
      let normalized = trimmed.lowercased()
      guard !seen.contains(normalized) else { return nil }
      seen.insert(normalized)
      return trimmed
    }
  }

  static func normalizedDNSServerInputs(_ values: [String]) -> [String] {
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

  static func normalizedCIDRs(_ values: [String]) -> [String] {
    normalizedRouteExcludeCIDRs(values).filter(Self.isValidCIDR)
  }

  static func normalizedRouteExcludeCIDRs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let normalized = (try? NetworkExtensionRouteCIDR(trimmed))?.rawValue ?? trimmed
      let key = normalized.lowercased()
      guard !seen.contains(key) else { return nil }
      seen.insert(key)
      return normalized
    }
  }
}

struct NetworkExtensionDNSCapturePolicy: Equatable, Sendable {
  var enabled: Bool
  var listenHost: String
  var listenPort: Int

  static let disabled = NetworkExtensionDNSCapturePolicy(
    enabled: false,
    listenHost: NetworkExtensionRoutingSettings.defaultDNSListenHost,
    listenPort: NetworkExtensionRoutingSettings.defaultDNSListenPort
  )

  static func clashMax(settings: NetworkExtensionRoutingSettings) -> NetworkExtensionDNSCapturePolicy {
    NetworkExtensionDNSCapturePolicy(
      enabled: settings.dnsCaptureEnabled,
      listenHost: NetworkExtensionRoutingSettings.defaultDNSListenHost,
      listenPort: settings.normalizedDNSListenPort
    )
  }

  var listenEndpoint: Socks5Endpoint {
    Socks5Endpoint(host: .ipv4(listenHost), port: listenPort)
  }

  func isDNSEndpoint(_ endpoint: Socks5Endpoint) -> Bool {
    enabled && endpoint.port == 53
  }

  func isCaptureEndpoint(_ endpoint: Socks5Endpoint) -> Bool {
    guard enabled, endpoint.port == listenPort else { return false }
    switch endpoint.host {
    case let .ipv4(address):
      return address == listenHost
    case let .domain(domain):
      return domain == listenHost || domain == "localhost"
    case .ipv6:
      return false
    }
  }

  func targetEndpoint(for endpoint: Socks5Endpoint) -> Socks5Endpoint {
    isDNSEndpoint(endpoint) ? listenEndpoint : endpoint
  }
}

enum NetworkExtensionFlowProtocol: String, Codable, Equatable, Sendable {
  case tcp
  case udp
  case unknown

  var displayName: String {
    switch self {
    case .tcp: "TCP"
    case .udp: "UDP"
    case .unknown: "Flow"
    }
  }
}

struct NetworkExtensionDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var date: Date
  var message: String
  var sourceAppSigningIdentifier: String?
  var flowProtocol: NetworkExtensionFlowProtocol?
  var remoteEndpoint: String?

  init(
    id: String = UUID().uuidString,
    date: Date = Date(),
    message: String,
    sourceAppSigningIdentifier: String? = nil,
    flowProtocol: NetworkExtensionFlowProtocol? = nil,
    remoteEndpoint: String? = nil
  ) {
    self.id = id
    self.date = date
    self.message = message
    self.sourceAppSigningIdentifier = sourceAppSigningIdentifier
    self.flowProtocol = flowProtocol
    self.remoteEndpoint = remoteEndpoint
  }
}

struct NetworkExtensionDiagnosticsSnapshot: Codable, Equatable, Sendable {
  var activeBridgeCount: Int
  var activeTCPBridgeCount: Int
  var activeUDPBridgeCount: Int
  var bypassCount: Int
  var udpBypassCount: Int
  var errorCount: Int
  var socksHandshakeFailureCount: Int
  var udpBridgeFailureCount: Int
  var udpDatagramCount: Int
  var dnsDatagramCount: Int
  var dnsCaptureCount: Int
  var dnsRetargetFailureCount: Int
  var routeExcludeCIDRCount: Int
  var dnsCaptureEnabled: Bool
  var dnsFakeIPEnabled: Bool
  var systemDNSOverrideApplied: Bool
  var systemDNSOverrideStatus: String
  var lastDNSEndpoint: String?
  var lastDNSSourceAppSigningIdentifier: String?
  var recentBypasses: [NetworkExtensionDiagnosticEvent]
  var recentErrors: [NetworkExtensionDiagnosticEvent]
  var updatedAt: Date

  static let empty = NetworkExtensionDiagnosticsSnapshot(
    activeBridgeCount: 0,
    activeTCPBridgeCount: 0,
    activeUDPBridgeCount: 0,
    bypassCount: 0,
    udpBypassCount: 0,
    errorCount: 0,
    socksHandshakeFailureCount: 0,
    udpBridgeFailureCount: 0,
    udpDatagramCount: 0,
    dnsDatagramCount: 0,
    dnsCaptureCount: 0,
    dnsRetargetFailureCount: 0,
    routeExcludeCIDRCount: 0,
    dnsCaptureEnabled: false,
    dnsFakeIPEnabled: false,
    systemDNSOverrideApplied: false,
    systemDNSOverrideStatus: "inactive",
    lastDNSEndpoint: nil,
    lastDNSSourceAppSigningIdentifier: nil,
    recentBypasses: [],
    recentErrors: [],
    updatedAt: Date.distantPast
  )

  private enum CodingKeys: String, CodingKey {
    case activeBridgeCount
    case activeTCPBridgeCount
    case activeUDPBridgeCount
    case bypassCount
    case udpBypassCount
    case errorCount
    case socksHandshakeFailureCount
    case udpBridgeFailureCount
    case udpDatagramCount
    case dnsDatagramCount
    case dnsCaptureCount
    case dnsRetargetFailureCount
    case routeExcludeCIDRCount
    case dnsCaptureEnabled
    case dnsFakeIPEnabled
    case systemDNSOverrideApplied
    case systemDNSOverrideStatus
    case lastDNSEndpoint
    case lastDNSSourceAppSigningIdentifier
    case recentBypasses
    case recentErrors
    case updatedAt
  }

  init(
    activeBridgeCount: Int,
    activeTCPBridgeCount: Int = 0,
    activeUDPBridgeCount: Int = 0,
    bypassCount: Int,
    udpBypassCount: Int = 0,
    errorCount: Int,
    socksHandshakeFailureCount: Int = 0,
    udpBridgeFailureCount: Int = 0,
    udpDatagramCount: Int = 0,
    dnsDatagramCount: Int = 0,
    dnsCaptureCount: Int = 0,
    dnsRetargetFailureCount: Int = 0,
    routeExcludeCIDRCount: Int = 0,
    dnsCaptureEnabled: Bool = false,
    dnsFakeIPEnabled: Bool = false,
    systemDNSOverrideApplied: Bool = false,
    systemDNSOverrideStatus: String = "inactive",
    lastDNSEndpoint: String? = nil,
    lastDNSSourceAppSigningIdentifier: String? = nil,
    recentBypasses: [NetworkExtensionDiagnosticEvent],
    recentErrors: [NetworkExtensionDiagnosticEvent],
    updatedAt: Date
  ) {
    self.activeBridgeCount = activeBridgeCount
    self.activeTCPBridgeCount = activeTCPBridgeCount
    self.activeUDPBridgeCount = activeUDPBridgeCount
    self.bypassCount = bypassCount
    self.udpBypassCount = udpBypassCount
    self.errorCount = errorCount
    self.socksHandshakeFailureCount = socksHandshakeFailureCount
    self.udpBridgeFailureCount = udpBridgeFailureCount
    self.udpDatagramCount = udpDatagramCount
    self.dnsDatagramCount = dnsDatagramCount
    self.dnsCaptureCount = dnsCaptureCount
    self.dnsRetargetFailureCount = dnsRetargetFailureCount
    self.routeExcludeCIDRCount = routeExcludeCIDRCount
    self.dnsCaptureEnabled = dnsCaptureEnabled
    self.dnsFakeIPEnabled = dnsFakeIPEnabled
    self.systemDNSOverrideApplied = systemDNSOverrideApplied
    self.systemDNSOverrideStatus = systemDNSOverrideStatus
    self.lastDNSEndpoint = lastDNSEndpoint
    self.lastDNSSourceAppSigningIdentifier = lastDNSSourceAppSigningIdentifier
    self.recentBypasses = recentBypasses
    self.recentErrors = recentErrors
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.empty
    self.init(
      activeBridgeCount: container.decodeDefault(Int.self, forKey: .activeBridgeCount, default: defaults.activeBridgeCount),
      activeTCPBridgeCount: container.decodeDefault(Int.self, forKey: .activeTCPBridgeCount, default: defaults.activeTCPBridgeCount),
      activeUDPBridgeCount: container.decodeDefault(Int.self, forKey: .activeUDPBridgeCount, default: defaults.activeUDPBridgeCount),
      bypassCount: container.decodeDefault(Int.self, forKey: .bypassCount, default: defaults.bypassCount),
      udpBypassCount: container.decodeDefault(Int.self, forKey: .udpBypassCount, default: defaults.udpBypassCount),
      errorCount: container.decodeDefault(Int.self, forKey: .errorCount, default: defaults.errorCount),
      socksHandshakeFailureCount: container.decodeDefault(
        Int.self,
        forKey: .socksHandshakeFailureCount,
        default: defaults.socksHandshakeFailureCount
      ),
      udpBridgeFailureCount: container.decodeDefault(
        Int.self,
        forKey: .udpBridgeFailureCount,
        default: defaults.udpBridgeFailureCount
      ),
      udpDatagramCount: container.decodeDefault(Int.self, forKey: .udpDatagramCount, default: defaults.udpDatagramCount),
      dnsDatagramCount: container.decodeDefault(Int.self, forKey: .dnsDatagramCount, default: defaults.dnsDatagramCount),
      dnsCaptureCount: container.decodeDefault(Int.self, forKey: .dnsCaptureCount, default: defaults.dnsCaptureCount),
      dnsRetargetFailureCount: container.decodeDefault(
        Int.self,
        forKey: .dnsRetargetFailureCount,
        default: defaults.dnsRetargetFailureCount
      ),
      routeExcludeCIDRCount: container.decodeDefault(
        Int.self,
        forKey: .routeExcludeCIDRCount,
        default: defaults.routeExcludeCIDRCount
      ),
      dnsCaptureEnabled: container.decodeDefault(
        Bool.self,
        forKey: .dnsCaptureEnabled,
        default: defaults.dnsCaptureEnabled
      ),
      dnsFakeIPEnabled: container.decodeDefault(Bool.self, forKey: .dnsFakeIPEnabled, default: defaults.dnsFakeIPEnabled),
      systemDNSOverrideApplied: container.decodeDefault(
        Bool.self,
        forKey: .systemDNSOverrideApplied,
        default: defaults.systemDNSOverrideApplied
      ),
      systemDNSOverrideStatus: container.decodeDefault(
        String.self,
        forKey: .systemDNSOverrideStatus,
        default: defaults.systemDNSOverrideStatus
      ),
      lastDNSEndpoint: container.decodeDefault(
        String?.self,
        forKey: .lastDNSEndpoint,
        default: defaults.lastDNSEndpoint
      ),
      lastDNSSourceAppSigningIdentifier: container.decodeDefault(
        String?.self,
        forKey: .lastDNSSourceAppSigningIdentifier,
        default: defaults.lastDNSSourceAppSigningIdentifier
      ),
      recentBypasses: container.decodeDefault(
        [NetworkExtensionDiagnosticEvent].self,
        forKey: .recentBypasses,
        default: defaults.recentBypasses
      ),
      recentErrors: container.decodeDefault(
        [NetworkExtensionDiagnosticEvent].self,
        forKey: .recentErrors,
        default: defaults.recentErrors
      ),
      updatedAt: container.decodeDefault(Date.self, forKey: .updatedAt, default: defaults.updatedAt)
    )
  }
}
