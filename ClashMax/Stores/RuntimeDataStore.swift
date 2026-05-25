import Foundation

@MainActor
final class RuntimeDataStore: ObservableObject {
  private static let logPublishIntervalNanoseconds: UInt64 = 250_000_000

  @Published var proxyGroups: [ProxyGroup] = []
  @Published var proxyProviders: [ProxyProvider] = []
  @Published var ruleProviders: [RuleProvider] = []
  @Published var rules: [RuntimeRule] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published var connectionRecords: [ConnectionRecord] = []
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
  private var connectionRecordBuffer = BoundedBuffer<ConnectionRecord>(limit: AppConstants.retainedConnectionLimit)
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
    let now = Date()
    let activeIDs = Set(snapshots.map(\.id))
    let previousRecordsByID = Dictionary(uniqueKeysWithValues: connectionRecords.map { ($0.id, $0) })
    var nextRecords = snapshots.map { snapshot -> ConnectionRecord in
      var snapshot = snapshot
      snapshot.lastSeenAt = now
      snapshot.endedAt = nil
      return ConnectionRecord(snapshot: snapshot, isActive: true)
    }
    let endedRecords = connectionRecords.compactMap { record -> ConnectionRecord? in
      guard record.isActive, !activeIDs.contains(record.id) else { return nil }
      var snapshot = record.snapshot
      snapshot.endedAt = now
      return ConnectionRecord(snapshot: snapshot, isActive: false)
    }
    let retainedInactive = previousRecordsByID.values.filter { !$0.isActive && !activeIDs.contains($0.id) }
    nextRecords.append(contentsOf: endedRecords)
    nextRecords.append(contentsOf: retainedInactive)
    nextRecords.sort { lhs, rhs in
      let left = lhs.snapshot.lastSeenAt ?? lhs.snapshot.endedAt ?? lhs.snapshot.startedAt ?? .distantPast
      let right = rhs.snapshot.lastSeenAt ?? rhs.snapshot.endedAt ?? rhs.snapshot.startedAt ?? .distantPast
      return left > right
    }
    connectionRecordBuffer.replace(with: nextRecords)
    connectionRecords = connectionRecordBuffer.elements
    connectionBuffer.replace(with: snapshots)
    connections = snapshots
  }

  func removeConnection(id: ConnectionSnapshot.ID) {
    let remaining = connections.filter { $0.id != id }
    replaceConnections(remaining)
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
    connectionRecordBuffer.replace(with: [])
    connectionRecords = []
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
