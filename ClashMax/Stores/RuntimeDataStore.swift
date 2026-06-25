import Foundation
import Observation

@MainActor
@Observable
final class RuntimeDataStore {
  private static let logPublishIntervalNanoseconds: UInt64 = 250_000_000

  var proxyGroups: [ProxyGroup] = []
  var proxyProviders: [ProxyProvider] = []
  var ruleProviders: [RuleProvider] = []
  var rules: [RuntimeRule] = []
  var connections: [ConnectionSnapshot] = []
  var connectionRecords: [ConnectionRecord] = []
  private(set) var logs: [LogEntry] = []
  var trafficSample: TrafficSample = .zero
  var trafficHistory: [TrafficSample] = []
  private(set) var providerHealthChecksInFlight: Set<ProxyProvider.ID> = []
  private(set) var proxyProviderUpdatesInFlight: Set<ProxyProvider.ID> = []
  private(set) var ruleProviderUpdatesInFlight: Set<RuleProvider.ID> = []
  private(set) var closingConnectionIDs: Set<ConnectionSnapshot.ID> = []
  var closingAllConnections = false

  // Internal implementation state, deliberately excluded from Observation
  // tracking. These mutate on hot paths (per-log buffer appends, the debounce
  // task handle, the connection-merge generation counter) but never represent
  // observable UI state, so tracking them would only create useless invalidation.
  @ObservationIgnored
  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  @ObservationIgnored
  private var connectionRecordBuffer = BoundedBuffer<ConnectionRecord>(limit: AppConstants.retainedConnectionLimit)
  @ObservationIgnored
  private var logPublishTask: Task<Void, Never>?
  // Bumped on every connection-state mutation. A background merge captures this
  // before hopping off the MainActor and bails on resume if it changed, so a
  // stale tick can't overwrite a newer synchronous update or a clear.
  @ObservationIgnored
  private var connectionStateGeneration: UInt64 = 0

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
    let result = Self.mergeConnections(
      previousRecords: connectionRecords,
      previousSnapshots: connections,
      snapshots: snapshots,
      limit: AppConstants.retainedConnectionLimit,
      now: Date()
    )
    applyConnectionMerge(result)
  }

  /// Off-MainActor variant for the once-per-second connection stream tick.
  /// Snapshots the current state on the MainActor, runs the heavy merge/sort on
  /// a background executor, then re-enters the MainActor to publish. The
  /// generation guard drops the result if a synchronous mutation (another
  /// `replaceConnections`, `clearRuntimeCollections`, …) landed while we were
  /// computing, so a stale tick can never resurrect cleared/older connections.
  func updateConnections(_ snapshots: [ConnectionSnapshot]) async {
    let generation = connectionStateGeneration
    let previousRecords = connectionRecords
    let previousSnapshots = connections
    let limit = AppConstants.retainedConnectionLimit
    let now = Date()
    let result = await Task.detached(priority: .utility) {
      Self.mergeConnections(
        previousRecords: previousRecords,
        previousSnapshots: previousSnapshots,
        snapshots: snapshots,
        limit: limit,
        now: now
      )
    }.value
    guard generation == connectionStateGeneration else { return }
    applyConnectionMerge(result)
  }

  private func applyConnectionMerge(_ result: ConnectionMergeResult) {
    connectionStateGeneration &+= 1
    if result.recordsChanged {
      connectionRecordBuffer.replace(with: result.records)
      connectionRecords = connectionRecordBuffer.elements
    }
    if result.snapshotsChanged {
      // Active connections are published unbounded on purpose: a connection
      // leaves the set the moment it closes, so the count mirrors reality and
      // feeds the live "Connections" stat. Only `connectionRecords` (which
      // retains ended connections) needs the retention cap.
      connections = result.snapshots
    }
  }

  private struct ConnectionMergeResult: Sendable {
    var records: [ConnectionRecord]
    var snapshots: [ConnectionSnapshot]
    var recordsChanged: Bool
    var snapshotsChanged: Bool
  }

  /// Pure merge of active snapshots with retained history. Runs off the
  /// MainActor, so it must not touch instance state. To keep an idle tick from
  /// republishing, it reuses an unchanged active connection's previous
  /// `lastSeenAt` instead of stamping `now`: when every business field matches,
  /// the produced record is identical to the prior one and `recordsChanged`
  /// stays false.
  private nonisolated static func mergeConnections(
    previousRecords: [ConnectionRecord],
    previousSnapshots: [ConnectionSnapshot],
    snapshots: [ConnectionSnapshot],
    limit: Int,
    now: Date
  ) -> ConnectionMergeResult {
    let activeIDs = Set(snapshots.map(\.id))
    let previousRecordsByID = Dictionary(
      previousRecords.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var nextRecords: [ConnectionRecord] = []
    nextRecords.reserveCapacity(snapshots.count + previousRecords.count)
    for snapshot in snapshots {
      var candidate = snapshot
      candidate.endedAt = nil
      candidate.lastSeenAt = now
      // Reuse the prior timestamp when nothing but `lastSeenAt` would differ,
      // so a steady connection produces a byte-identical record each tick.
      if let previous = previousRecordsByID[snapshot.id], previous.isActive {
        var unchanged = previous.snapshot
        unchanged.lastSeenAt = candidate.lastSeenAt
        if unchanged == candidate {
          candidate.lastSeenAt = previous.snapshot.lastSeenAt
        }
      }
      nextRecords.append(ConnectionRecord(snapshot: candidate, isActive: true))
    }

    let endedRecords = previousRecords.compactMap { record -> ConnectionRecord? in
      guard record.isActive, !activeIDs.contains(record.id) else { return nil }
      var snapshot = record.snapshot
      snapshot.endedAt = now
      return ConnectionRecord(snapshot: snapshot, isActive: false)
    }
    let retainedInactive = previousRecords.filter { !$0.isActive && !activeIDs.contains($0.id) }
    nextRecords.append(contentsOf: endedRecords)
    nextRecords.append(contentsOf: retainedInactive)
    // Rank by recency. An active connection ranks by `lastSeenAt` (idle dedup
    // may reuse an older value, but it is still live). A closed connection ranks
    // by `endedAt` first: idle dedup can leave its `lastSeenAt` frozen at an old
    // value, so a long-idle connection that *just* ended must still count as the
    // most recent history rather than being sorted/trimmed by that stale stamp.
    func recency(of record: ConnectionRecord) -> Date {
      let snapshot = record.snapshot
      if record.isActive {
        return snapshot.lastSeenAt ?? snapshot.endedAt ?? snapshot.startedAt ?? .distantPast
      }
      return snapshot.endedAt ?? snapshot.lastSeenAt ?? snapshot.startedAt ?? .distantPast
    }
    nextRecords.sort { recency(of: $0) > recency(of: $1) }
    // Records are sorted most-recent first, so the newest `limit` are the
    // *prefix*. Keep those and drop the oldest overflow — `suffix` here would
    // retain the oldest and silently discard the newest history. The result
    // stays most-recent first and within the cap, so `BoundedBuffer.replace`'s
    // own `suffix(limit)` becomes a no-op instead of a second oldest-biased trim.
    let boundedRecords = Array(nextRecords.prefix(limit))

    return ConnectionMergeResult(
      records: boundedRecords,
      snapshots: snapshots,
      recordsChanged: boundedRecords != previousRecords,
      snapshotsChanged: snapshots != previousSnapshots
    )
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
