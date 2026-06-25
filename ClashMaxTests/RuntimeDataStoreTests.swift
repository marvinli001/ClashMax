import Observation
import XCTest
@testable import ClashMax

@MainActor
final class RuntimeDataStoreTests: XCTestCase {
  /// A Sendable box the one-shot `withObservationTracking` `onChange` can flip.
  /// `onChange` is `@Sendable`, so under Swift 6 it cannot capture a mutable
  /// local `var`; it always fires synchronously on this MainActor during the
  /// mutation, so `@unchecked Sendable` is safe here.
  private final class ChangeFlag: @unchecked Sendable {
    var didChange = false
  }

  /// Arms a one-shot Observation tracker over the properties read in `access`,
  /// runs `mutation`, and reports whether a tracked property was mutated.
  /// `withObservationTracking`'s `onChange` fires once, synchronously, on the
  /// first `willSet` of any property read in `access` — so this proves observer
  /// fan-out at the property granularity without Combine/`objectWillChange`.
  private func observedChange(
    observing access: () -> Void,
    during mutation: () -> Void
  ) -> Bool {
    let flag = ChangeFlag()
    withObservationTracking(access) { flag.didChange = true }
    mutation()
    return flag.didChange
  }

  // MARK: - Per-property observation fan-out

  func testTrafficSampleDoesNotTriggerRulesObserver() {
    let store = RuntimeDataStore()
    store.rules = [RuntimeRule(index: 0, type: "DOMAIN", payload: "seed.example", policy: "DIRECT")]

    let rulesObserverFired = observedChange {
      _ = store.rules
    } during: {
      store.appendTrafficSample(TrafficSample(upload: 100, download: 200))
    }

    XCTAssertFalse(
      rulesObserverFired,
      "appending a traffic sample must not invalidate a rules-only observer"
    )
  }

  func testRulesMutationTriggersRulesObserver() {
    let store = RuntimeDataStore()

    let rulesObserverFired = observedChange {
      _ = store.rules
    } during: {
      store.rules = [RuntimeRule(index: 0, type: "DOMAIN", payload: "example.com", policy: "PROXY")]
    }

    XCTAssertTrue(rulesObserverFired, "mutating rules must invalidate a rules observer")
    XCTAssertEqual(store.rules.count, 1)
  }

  // MARK: - Log buffering

  func testLogBurstDoesNotPublishUntilFlush() async throws {
    let store = RuntimeDataStore()
    let flag = ChangeFlag()
    withObservationTracking { _ = store.logs } onChange: { flag.didChange = true }

    for index in 0..<100 {
      store.appendLog(LogEntry(level: "debug", message: "line \(index)"))
    }

    XCTAssertEqual(store.logs.count, 0)
    XCTAssertFalse(flag.didChange, "buffered appends must not publish logs before flush")

    store.flushPendingLogs()

    XCTAssertEqual(store.logs.count, 100)
    XCTAssertTrue(flag.didChange, "flush must publish the buffered logs")
  }

  func testScheduledLogPublishCoalescesBurst() async throws {
    let store = RuntimeDataStore()
    let flag = ChangeFlag()
    withObservationTracking { _ = store.logs } onChange: { flag.didChange = true }

    for index in 0..<20 {
      store.appendLog(LogEntry(level: "info", message: "line \(index)"))
    }

    XCTAssertEqual(store.logs.count, 0)
    XCTAssertFalse(flag.didChange, "buffered appends must not publish before the scheduled flush")

    try await Task.sleep(nanoseconds: 350_000_000)

    XCTAssertEqual(store.logs.count, 20)
    XCTAssertTrue(flag.didChange, "the scheduled flush must publish the buffered burst")
  }

  // MARK: - Connection history semantics

  func testConnectionHistoryTracksEndedRecords() async throws {
    let store = RuntimeDataStore()
    let first = ConnectionSnapshot(
      id: "one",
      network: "tcp",
      host: "example.com",
      processName: "Safari",
      upload: 10,
      download: 20,
      chain: ["Proxy"],
      rule: "MATCH"
    )

    store.replaceConnections([first])
    store.replaceConnections([])

    XCTAssertTrue(store.connections.isEmpty)
    let record = try XCTUnwrap(store.connectionRecords.first)
    XCTAssertEqual(record.snapshot.processName, "Safari")
    XCTAssertNotNil(record.snapshot.lastSeenAt)
    XCTAssertNotNil(record.snapshot.endedAt)
  }

  func testRepeatedIdenticalConnectionsDoNotRepublish() {
    let store = RuntimeDataStore()
    let connection = ConnectionSnapshot(
      id: "one",
      network: "tcp",
      host: "example.com",
      processName: "Safari",
      upload: 10,
      download: 20,
      chain: ["Proxy"],
      rule: "MATCH"
    )

    store.replaceConnections([connection])

    let changed = observedChange {
      _ = store.connections
      _ = store.connectionRecords
    } during: {
      store.replaceConnections([connection])
    }

    XCTAssertFalse(changed, "an identical connection tick must not invalidate observers")
    XCTAssertEqual(store.connections, [connection])
    XCTAssertEqual(store.connectionRecords.count, 1)
  }

  func testChangedConnectionFieldsRepublish() {
    let store = RuntimeDataStore()
    let connection = ConnectionSnapshot(
      id: "one",
      network: "tcp",
      host: "example.com",
      processName: "Safari",
      upload: 10,
      download: 20,
      chain: ["Proxy"],
      rule: "MATCH"
    )

    store.replaceConnections([connection])

    var updated = connection
    updated.download = 999
    let changed = observedChange {
      _ = store.connections
      _ = store.connectionRecords
    } during: {
      store.replaceConnections([updated])
    }

    XCTAssertTrue(changed, "a changed connection must invalidate observers")
    XCTAssertEqual(store.connections, [updated])
    XCTAssertEqual(store.connectionRecords.first?.snapshot.download, 999)
  }

  func testUpdateConnectionsPublishesOffMainActor() async {
    let store = RuntimeDataStore()
    let connection = ConnectionSnapshot(
      id: "one",
      network: "tcp",
      host: "example.com",
      processName: "Safari",
      upload: 10,
      download: 20,
      chain: ["Proxy"],
      rule: "MATCH"
    )

    await store.updateConnections([connection])

    XCTAssertEqual(store.connections, [connection])
    XCTAssertEqual(store.connectionRecords.count, 1)
    XCTAssertTrue(store.connectionRecords[0].isActive)

    // A second identical tick through the async path must not republish.
    let flag = ChangeFlag()
    withObservationTracking {
      _ = store.connections
      _ = store.connectionRecords
    } onChange: { flag.didChange = true }

    await store.updateConnections([connection])

    XCTAssertFalse(flag.didChange, "an identical async tick must not invalidate observers")
  }

  func testStaleConnectionUpdateDoesNotOverwriteClear() async {
    let store = RuntimeDataStore()
    let connection = ConnectionSnapshot(
      id: "one",
      network: "tcp",
      host: "a.example.com",
      upload: 1,
      download: 1,
      chain: ["Proxy"],
      rule: "MATCH"
    )
    let other = ConnectionSnapshot(
      id: "two",
      network: "tcp",
      host: "b.example.com",
      upload: 2,
      download: 2,
      chain: ["Proxy"],
      rule: "MATCH"
    )

    store.replaceConnections([connection])

    // Start a background merge that would publish [connection, other], let it
    // capture state and suspend at the off-actor hop, then clear synchronously
    // before it resumes. The generation guard must drop the stale result.
    let update = Task { await store.updateConnections([connection, other]) }
    await Task.yield()
    store.clearRuntimeCollections()
    await update.value

    XCTAssertTrue(store.connections.isEmpty)
    XCTAssertTrue(store.connectionRecords.isEmpty)
  }

  func testActiveConnectionsAreNotCappedWhileHistoryIs() {
    let store = RuntimeDataStore()
    let limit = AppConstants.retainedConnectionLimit
    let overflow = limit + 100

    let snapshots = (0..<overflow).map { index in
      ConnectionSnapshot(
        id: "conn-\(index)",
        network: "tcp",
        host: "host-\(index).example.com",
        upload: index,
        download: index,
        chain: ["Proxy"],
        rule: "MATCH"
      )
    }

    store.replaceConnections(snapshots)

    // Active connections mirror reality: every open connection is published and
    // never capped, so the live count and the connections table show all of
    // them. Only `connectionRecords` (which retains ended connections) is bound.
    XCTAssertEqual(store.connections.count, overflow)
    XCTAssertEqual(store.connectionRecords.count, limit)
  }

  func testConnectionHistoryRetainsMostRecentRecordsWhenOverLimit() {
    let store = RuntimeDataStore()
    let limit = AppConstants.retainedConnectionLimit
    let total = limit + 50
    let base = Date(timeIntervalSince1970: 1_000_000)

    // Seed > limit ended records with strictly increasing timestamps: index 0 is
    // the oldest, index (total - 1) the most recent. (Driving this through real
    // active→ended replace cycles would stamp every record with the same wall
    // clock `now`, leaving the retention *order* untestable, so we seed the merge
    // input — `replaceConnections` reads `connectionRecords` as previous records —
    // with controlled timestamps instead.)
    store.connectionRecords = (0..<total).map { index in
      let seenAt = base.addingTimeInterval(Double(index))
      let snapshot = ConnectionSnapshot(
        id: "conn-\(index)",
        network: "tcp",
        host: "host-\(index).example.com",
        upload: index,
        download: index,
        chain: ["Proxy"],
        rule: "MATCH",
        lastSeenAt: seenAt,
        endedAt: seenAt
      )
      return ConnectionRecord(snapshot: snapshot, isActive: false)
    }

    // Merge with no active connections so the retained history is capped.
    store.replaceConnections([])

    XCTAssertEqual(store.connectionRecords.count, limit)

    let retainedIDs = Set(store.connectionRecords.map(\.id))
    // The newest `limit` records (conn-50 ... conn-549) must survive; the oldest
    // 50 (conn-0 ... conn-49) must be dropped.
    XCTAssertTrue(retainedIDs.contains("conn-\(total - 1)"), "most-recent record must be retained")
    XCTAssertTrue(retainedIDs.contains("conn-\(total - limit)"), "newest-kept boundary must be retained")
    XCTAssertFalse(retainedIDs.contains("conn-\(total - limit - 1)"), "oldest-dropped boundary must be dropped")
    XCTAssertFalse(retainedIDs.contains("conn-0"), "oldest record must be dropped")
    // History stays published most-recent first.
    XCTAssertEqual(store.connectionRecords.first?.id, "conn-\(total - 1)")
  }

  func testConnectionHistoryRanksInactiveRecordsByEndedAt() {
    let store = RuntimeDataStore()
    let limit = AppConstants.retainedConnectionLimit
    let base = Date(timeIntervalSince1970: 1_000_000)

    func endedRecord(id: String, lastSeenAt: Date, endedAt: Date) -> ConnectionRecord {
      let snapshot = ConnectionSnapshot(
        id: id,
        network: "tcp",
        host: "\(id).example.com",
        upload: 1,
        download: 1,
        chain: ["Proxy"],
        rule: "MATCH",
        lastSeenAt: lastSeenAt,
        endedAt: endedAt
      )
      return ConnectionRecord(snapshot: snapshot, isActive: false)
    }

    // A long-idle connection: idle dedup froze its `lastSeenAt` at the oldest
    // value of all, but it *just* ended, so its `endedAt` is the newest of all.
    let idleJustEnded = endedRecord(
      id: "idle-just-ended",
      lastSeenAt: base,
      endedAt: base.addingTimeInterval(1_000_000)
    )
    // `limit` fillers that ended earlier, each with lastSeenAt == endedAt and
    // both strictly newer than the idle record's stale `lastSeenAt`.
    let fillers = (0..<limit).map { index -> ConnectionRecord in
      let seenAt = base.addingTimeInterval(Double(index + 1))
      return endedRecord(id: "conn-\(index)", lastSeenAt: seenAt, endedAt: seenAt)
    }

    // total = limit + 1, so exactly one record is trimmed. Ranking inactive
    // records by the stale `lastSeenAt` would sort the idle record last and drop
    // it; ranking by `endedAt` keeps it as the newest history.
    store.connectionRecords = fillers + [idleJustEnded]

    store.replaceConnections([])

    XCTAssertEqual(store.connectionRecords.count, limit)
    let retainedIDs = Set(store.connectionRecords.map(\.id))
    XCTAssertTrue(retainedIDs.contains("idle-just-ended"), "freshly-ended idle record must be retained by endedAt")
    XCTAssertEqual(store.connectionRecords.first?.id, "idle-just-ended", "most-recently-ended record must sort first")
    XCTAssertFalse(retainedIDs.contains("conn-0"), "the oldest-ended filler must be the trimmed record")
  }
}
