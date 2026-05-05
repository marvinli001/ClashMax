import Foundation

enum ProfileSource: Codable, Equatable {
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

struct Profile: Identifiable, Codable, Equatable {
  var id: UUID
  var name: String
  var source: ProfileSource
  var originalConfigPath: String
  var subscriptionMetadata: SubscriptionMetadata?
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    source: ProfileSource,
    originalConfigPath: String,
    subscriptionMetadata: SubscriptionMetadata? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.source = source
    self.originalConfigPath = originalConfigPath
    self.subscriptionMetadata = subscriptionMetadata
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

extension Profile {
  var isSubscription: Bool {
    if case .subscription = source { return true }
    return false
  }
}

enum RunMode: String, Codable, CaseIterable, Identifiable {
  case rule
  case global
  case direct

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .rule: "Rule"
    case .global: "Global"
    case .direct: "Direct"
    }
  }
}

enum ProxyRoutingMode: String, Codable, CaseIterable, Identifiable {
  case systemProxy
  case tun

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .systemProxy: "System Proxy"
    case .tun: "TUN"
    }
  }

  var symbolName: String {
    switch self {
    case .systemProxy: "network.badge.shield.half.filled"
    case .tun: "point.topleft.down.curvedto.point.bottomright.up"
    }
  }
}

struct RuntimeOverrides: Codable, Equatable {
  var mixedPort: Int
  var externalControllerHost: String
  var externalControllerPort: Int
  var secret: String
  var allowLan: Bool
  var mode: RunMode
  var logLevel: String
  var dnsEnabled: Bool?
  var tunEnabled: Bool

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
      tunEnabled: false
    )
  }

  var endpoint: CoreAPIEndpoint {
    CoreAPIEndpoint(host: externalControllerHost, port: externalControllerPort, secret: secret)
  }
}

struct CoreAPIEndpoint: Codable, Equatable {
  var host: String
  var port: Int
  var secret: String

  var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
  }
}

enum CoreStatus: Equatable {
  case stopped
  case starting
  case running(version: String?)
  case crashed(message: String)
  case restarting

  var displayName: String {
    switch self {
    case .stopped: "Stopped"
    case .starting: "Starting"
    case .running: "Running"
    case .crashed: "Crashed"
    case .restarting: "Restarting"
    }
  }
}

struct ProxyNode: Identifiable, Codable, Equatable {
  var id: String { name }
  var name: String
  var type: String
  var delay: Int?
  var isSelectable: Bool
}

struct ProxyGroup: Identifiable, Codable, Equatable {
  var id: String { name }
  var name: String
  var type: String
  var selected: String?
  var nodes: [ProxyNode]
}

struct ConnectionSnapshot: Identifiable, Codable, Equatable {
  var id: String
  var network: String
  var host: String
  var upload: Int
  var download: Int
  var chain: [String]
  var rule: String?
  var startedAt: Date?
}

struct TrafficSample: Codable, Equatable {
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

struct LogEntry: Identifiable, Codable, Equatable {
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

struct SubscriptionTrafficUsage: Codable, Equatable {
  var upload: Int?
  var download: Int?
  var total: Int?
  var expireAt: Date?
}

struct SubscriptionMetadata: Codable, Equatable {
  var traffic: SubscriptionTrafficUsage?
  var remoteFileName: String?
  var updateIntervalMinutes: Int?
  var webPageURL: URL?
  var lastFetchedAt: Date?

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

struct SubscriptionFetchResult: Equatable {
  var source: String
  var metadata: SubscriptionMetadata
}

struct ProxyProvider: Identifiable, Codable, Equatable {
  var id: String { name }
  var name: String
  var type: String
  var vehicleType: String?
  var updatedAt: Date?
  var proxies: [ProxyNode]
}

enum RuntimeOwner: String, Codable, Equatable {
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
