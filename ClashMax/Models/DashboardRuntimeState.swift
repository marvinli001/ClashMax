import Foundation

enum HomeConnectionRoute {
  case proxy, direct, reject

  static func classify(_ exitNode: String?) -> Self {
    let name = exitNode?.uppercased()
    if name == "DIRECT" { return .direct }
    if name?.hasPrefix("REJECT") == true { return .reject }
    return .proxy
  }
}

struct HomeTrafficDestinations: Equatable, Sendable {
  struct Row: Identifiable, Equatable, Sendable {
    let name: String
    let bytes: Int
    var id: String { name }
  }

  var domains: [Row] = []
  var exits: [Row] = []
  var proxy = 0
  var direct = 0
  var reject = 0
  var count: Int { proxy + direct + reject }

  static func make(from connections: [ConnectionSnapshot], limit: Int = 5) -> Self {
    var result = Self()
    var hosts: [String: Int] = [:]
    var nodes: [String: Int] = [:]
    for connection in connections {
      let host = connection.host
      let domain = host.isEmpty ? String(localized: "(IP connection)") : host.lowercased()
      let exit = connection.exitNode
      let node = exit ?? String(localized: "Unknown")
      let bytes = sum(max(0, connection.upload), max(0, connection.download))
      hosts[domain] = sum(hosts[domain, default: 0], bytes)
      nodes[node] = sum(nodes[node, default: 0], bytes)
      switch HomeConnectionRoute.classify(exit) {
      case .proxy: result.proxy += 1
      case .direct: result.direct += 1
      case .reject: result.reject += 1
      }
    }
    func ranked(_ totals: [String: Int]) -> [Row] {
      var rows = totals.map { Row(name: $0.key, bytes: $0.value) }
      rows.sort { lhs, rhs in
        if lhs.bytes == rhs.bytes { return lhs.name < rhs.name }
        return lhs.bytes > rhs.bytes
      }
      return Array(rows.prefix(max(0, limit)))
    }
    result.domains = ranked(hosts)
    result.exits = ranked(nodes)
    return result
  }

  private static func sum(_ lhs: Int, _ rhs: Int) -> Int {
    let (total, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : total
  }
}

enum DashboardRuntimeState: Equatable {
  case blocked(reason: String)
  case stopped
  case starting
  case running
  case crashed(message: String)

  static func resolve(
    startInFlight: Bool,
    tunnelCoreRunning: Bool,
    coreStatus: CoreStatus,
    readinessIssue: String?
  ) -> DashboardRuntimeState {
    if startInFlight {
      return .starting
    }

    switch coreStatus {
    case .starting, .restarting:
      return .starting
    default:
      break
    }

    if tunnelCoreRunning {
      return .running
    }

    switch coreStatus {
    case .running:
      return .running
    case let .crashed(message):
      return .crashed(message: message)
    default:
      break
    }

    if let readinessIssue {
      return .blocked(reason: readinessIssue)
    }

    return .stopped
  }

  var isStarting: Bool {
    if case .starting = self { return true }
    return false
  }

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  var isVisualActive: Bool {
    isStarting || isRunning
  }

  var usesOperationalLayout: Bool {
    isStarting || isRunning
  }

  var displayTitle: String {
    switch self {
    case .blocked:
      return "Ready Needs Setup"
    case .stopped:
      return "Ready"
    case .starting:
      return "Starting"
    case .running:
      return "Running"
    case .crashed:
      return "Crashed"
    }
  }

  var launchTitle: String {
    switch self {
    case .blocked:
      return "ClashMax Needs Setup"
    case .crashed:
      return "Core Needs Attention"
    default:
      return "Ready"
    }
  }

  var detailMessage: String? {
    switch self {
    case let .blocked(reason):
      return reason
    case let .crashed(message):
      return message
    default:
      return nil
    }
  }
}
