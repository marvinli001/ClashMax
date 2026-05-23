import Foundation

@MainActor
final class RuntimeDataStore: ObservableObject {
  private static let logPublishIntervalNanoseconds: UInt64 = 250_000_000

  @Published var proxyGroups: [ProxyGroup] = []
  @Published var proxyProviders: [ProxyProvider] = []
  @Published var ruleProviders: [RuleProvider] = []
  @Published var rules: [String] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published private(set) var logs: [LogEntry] = []
  @Published var trafficSample: TrafficSample = .zero
  @Published var trafficHistory: [TrafficSample] = []
  @Published private(set) var providerHealthChecksInFlight: Set<ProxyProvider.ID> = []
  @Published private(set) var proxyProviderUpdatesInFlight: Set<ProxyProvider.ID> = []
  @Published private(set) var ruleProviderUpdatesInFlight: Set<RuleProvider.ID> = []
  @Published private(set) var closingConnectionIDs: Set<ConnectionSnapshot.ID> = []
  @Published var closingAllConnections = false

  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  private var connectionBuffer = BoundedBuffer<ConnectionSnapshot>(limit: AppConstants.retainedConnectionLimit)
  private var logPublishTask: Task<Void, Never>?

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

  func setProxyProvider(_ id: ProxyProvider.ID, updateInFlight isRunning: Bool) {
    var ids = proxyProviderUpdatesInFlight
    if isRunning {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    proxyProviderUpdatesInFlight = ids
  }

  func setRuleProvider(_ id: RuleProvider.ID, updateInFlight isRunning: Bool) {
    var ids = ruleProviderUpdatesInFlight
    if isRunning {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    ruleProviderUpdatesInFlight = ids
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
    scheduleLogPublish()
  }

  func appendLog(_ entry: LogEntry) {
    logBuffer.append(entry)
    scheduleLogPublish()
  }

  func flushPendingLogs() {
    logPublishTask?.cancel()
    logPublishTask = nil

    let nextLogs = logBuffer.elements
    guard logs != nextLogs else { return }
    logs = nextLogs
  }

  func clearRuntimeCollections() {
    flushPendingLogs()
    proxyGroups = []
    proxyProviders = []
    ruleProviders = []
    rules = []
    replaceConnections([])
    closingConnectionIDs = []
    closingAllConnections = false
    providerHealthChecksInFlight = []
    proxyProviderUpdatesInFlight = []
    ruleProviderUpdatesInFlight = []
    trafficSample = .zero
    trafficHistory = []
  }

  private func scheduleLogPublish() {
    guard logPublishTask == nil else { return }

    logPublishTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.logPublishIntervalNanoseconds)
      } catch {
        return
      }
      self?.flushPendingLogs()
    }
  }
}
