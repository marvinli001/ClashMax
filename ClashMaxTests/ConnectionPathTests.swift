@testable import ClashMax
import Foundation
import Testing

struct ConnectionPathTests {
  @Test @MainActor func retainedPathUsesCaptureTimesAndCurrentSimulation() throws {
    let now = Date()
    let store = RuntimeDataStore()
    store.dnsLogIndex.record(.init(date: now, level: "debug", message: "[DNS] site.test --> [127.0.0.1] A from https://user:pass@dns.test/private?token=value"))
    let connection = ConnectionSnapshot(id: "1", network: "tcp", host: "site.test", remoteDestinationIP: "127.0.0.1", upload: 0, download: 0, chain: ["A", "Inner", "Outer"], rule: "Domain", rulePayload: "site.test", startedAt: now)
    store.replaceConnections([connection])
    store.replaceConnections([])
    let closed = try #require(store.connectionRecords.first?.snapshot)
    #expect(closed.endedAt != nil)
    let later = now.addingTimeInterval(900)
    let rules = [RuntimeRule(index: 1, type: "MATCH", payload: "", policy: "DIRECT")]
    let facts = ConnectionPath.facts(closed, rules: rules, now: later)
    #expect(facts.map(\.id) == ConnectionPathFact.Step.allCases)
    #expect(facts.map(\.source) == [.core, .log, .core, .simulation, .core, .core, .probe])
    #expect(facts[1].value.contains("https://dns.test"))
    #expect(!facts[1].value.contains("private"))
    #expect(facts[1].date == now)
    #expect(facts[3].mismatch && facts[3].date == later)
    #expect(facts[4].value == "Outer → Inner")
    #expect(facts[5].value == "A")
    #expect(facts[6].date == nil)
  }

  @Test func cacheHitAndMissingFields() throws {
    let now = Date()
    var connection = ConnectionSnapshot(id: "bare", network: "tcp", host: "", destinationIP: "192.0.2.1", upload: 0, download: 0, chain: [], rule: nil, startedAt: now)
    let facts = ConnectionPath.facts(connection, rules: [])
    #expect(facts[1].date == nil && !facts[1].value.contains("192.0.2.1"))
    #expect(!facts[3].mismatch)
    var index = ConnectionDNSLogIndex()
    connection.reportedHost = "site.test"
    index.record(.init(date: now, level: "debug", message: "[DNS] cache hit site.test --> [192.0.2.1] A, expire at 2026-11-20 22:10:25"))
    let hit = try #require(index.observation(for: connection, now: now))
    #expect(hit.cacheHit && hit.upstream == nil)
    #expect(index.observation(for: connection, now: now.addingTimeInterval(16)) == nil)
    connection.startedAt = now.addingTimeInterval(-60)
    #expect(index.observation(for: connection, now: now) == nil)
  }
}
