import Foundation

@MainActor
final class RuntimeDataStore: ObservableObject {
  @Published var proxyGroups: [ProxyGroup] = []
  @Published var proxyProviders: [ProxyProvider] = []
  @Published var rules: [String] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published var logs: [LogEntry] = []
  @Published var trafficSample: TrafficSample = .zero
  @Published var trafficHistory: [TrafficSample] = []
  @Published private(set) var providerHealthChecksInFlight: Set<ProxyProvider.ID> = []
  @Published private(set) var closingConnectionIDs: Set<ConnectionSnapshot.ID> = []
  @Published var closingAllConnections = false

  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  private var connectionBuffer = BoundedBuffer<ConnectionSnapshot>(limit: AppConstants.retainedConnectionLimit)

  var userVisibleLogs: [LogEntry] {
    LogVisibility.visibleEntries(in: logs, developerMode: false)
  }

  func visibleLogs(developerMode: Bool) -> [LogEntry] {
    LogVisibility.visibleEntries(in: logs, developerMode: developerMode)
  }

  func setProvider(_ id: ProxyProvider.ID, healthCheckInFlight isRunning: Bool) {
    var ids = providerHealthChecksInFlight
    if isRunning {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    providerHealthChecksInFlight = ids
  }

  func setConnection(_ id: ConnectionSnapshot.ID, closing isClosing: Bool) {
    var ids = closingConnectionIDs
    if isClosing {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    closingConnectionIDs = ids
  }

  func replaceConnections(_ snapshots: [ConnectionSnapshot]) {
    connectionBuffer.replace(with: snapshots)
    connections = connectionBuffer.elements
  }

  func removeConnection(id: ConnectionSnapshot.ID) {
    let remaining = connections.filter { $0.id != id }
    connectionBuffer.replace(with: remaining)
    connections = remaining
  }

  func appendTrafficSample(_ sample: TrafficSample) {
    trafficSample = sample
    trafficHistory.append(sample)
    if trafficHistory.count > 72 {
      trafficHistory.removeFirst(trafficHistory.count - 72)
    }
  }

  func appendLog(level: String, message: String) {
    logBuffer.append(LogEntry(level: level, message: message))
    logs = logBuffer.elements
  }

  func appendLog(_ entry: LogEntry) {
    logBuffer.append(entry)
    logs = logBuffer.elements
  }

  func clearRuntimeCollections() {
    proxyGroups = []
    proxyProviders = []
    rules = []
    replaceConnections([])
    closingConnectionIDs = []
    closingAllConnections = false
    providerHealthChecksInFlight = []
    trafficSample = .zero
    trafficHistory = []
  }
}
