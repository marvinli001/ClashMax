import Combine
import XCTest
@testable import ClashMax

@MainActor
final class RuntimeDataStoreTests: XCTestCase {
  func testLogBurstDoesNotPublishUntilFlush() async throws {
    let store = RuntimeDataStore()
    var changeCount = 0
    let cancellable = store.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    for index in 0..<100 {
      store.appendLog(LogEntry(level: "debug", message: "line \(index)"))
    }

    XCTAssertEqual(store.logs.count, 0)
    XCTAssertEqual(changeCount, 0)

    store.flushPendingLogs()

    XCTAssertEqual(store.logs.count, 100)
    XCTAssertEqual(changeCount, 1)
  }

  func testScheduledLogPublishCoalescesBurst() async throws {
    let store = RuntimeDataStore()
    var changeCount = 0
    let cancellable = store.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    for index in 0..<20 {
      store.appendLog(LogEntry(level: "info", message: "line \(index)"))
    }

    XCTAssertEqual(store.logs.count, 0)

    try await Task.sleep(nanoseconds: 350_000_000)

    XCTAssertEqual(store.logs.count, 20)
    XCTAssertEqual(changeCount, 1)
  }

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
}
