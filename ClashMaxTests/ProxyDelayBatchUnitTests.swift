@testable import ClashMax
import XCTest

/// Scheduling-unit promotion for the batch delay run (roadmap A6).
///
/// Marvin runs ~1600 nodes, and before this the batch issued one `/proxies/{name}/delay` per node —
/// the origin of the #10/#11/#18 jank series. The core has a whole-group endpoint, so a group large
/// enough to be worth it collapses into a single `/group/{name}/delay` call. Promotion is the part
/// with real preconditions, and getting one wrong either loses results or probes a group the core
/// does not have, so each condition is pinned here.
@MainActor
final class ProxyDelayBatchUnitTests: XCTestCase {
  // MARK: Helpers

  private let testURL = AppConstants.defaultDelayTestURL
  private let otherTestURL = URL(string: "https://cp.cloudflare.com/generate_204")!

  /// One more than the promotion floor, so a test that removes a member still crosses it.
  private let largeGroupSize = 9

  private func item(
    group: String,
    node: String,
    testURL: URL? = nil,
    nativePingHost: String? = nil
  ) -> ProxyDelayBatchItem {
    let url = testURL ?? self.testURL
    let proxyNode = ProxyNode(name: node, type: "ss", delay: nil, isSelectable: true, serverHost: "node.example")
    let key = ProxyNodeKey(profileID: nil, groupName: group, nodeName: node, testURL: url)
    return ProxyDelayBatchItem(
      groupName: group,
      node: proxyNode,
      nodeKey: key,
      taskKey: key,
      testURL: url,
      previousState: .unknown,
      nativePingHost: nativePingHost
    )
  }

  private func items(group: String, count: Int, testURL: URL? = nil) -> [ProxyDelayBatchItem] {
    (0..<count).map { item(group: group, node: "\(group)-\($0)", testURL: testURL) }
  }

  private func groupNames(_ units: [ProxyDelayBatchUnit]) -> [String] {
    units.compactMap { unit in
      guard case let .group(name, _, _) = unit else { return nil }
      return name
    }
  }

  private func nodeNames(_ units: [ProxyDelayBatchUnit]) -> [String] {
    units.compactMap { unit in
      guard case let .node(item) = unit else { return nil }
      return item.node.name
    }
  }

  // MARK: Promotion

  func testLargeGroupCollapsesIntoASingleGroupProbe() {
    let units = AppModel.proxyDelayBatchUnits(
      items: items(group: "Proxy", count: largeGroupSize),
      settings: .default
    )

    XCTAssertEqual(units.count, 1)
    XCTAssertEqual(groupNames(units), ["Proxy"])
    guard case let .group(_, url, members) = units[0] else { return XCTFail("Expected a group unit") }
    XCTAssertEqual(url, testURL)
    XCTAssertEqual(members.count, largeGroupSize)
  }

  /// Below the floor the per-node path already finishes the whole group inside one concurrency
  /// wave, so promoting it would trade incremental per-node results for nothing.
  func testSmallGroupStaysOnThePerNodePath() {
    let units = AppModel.proxyDelayBatchUnits(items: items(group: "Proxy", count: 4), settings: .default)

    XCTAssertEqual(units.count, 4)
    XCTAssertTrue(groupNames(units).isEmpty)
  }

  func testPromotionFloorIsExactAndInclusive() {
    var promotedAt: Int?
    for count in 1...12 {
      let units = AppModel.proxyDelayBatchUnits(items: items(group: "Proxy", count: count), settings: .default)
      if !groupNames(units).isEmpty, promotedAt == nil {
        promotedAt = count
      }
    }

    XCTAssertEqual(promotedAt, 8, "One concurrency wave (6) plus a margin of two")
    XCTAssertTrue(
      groupNames(AppModel.proxyDelayBatchUnits(items: items(group: "Proxy", count: 7), settings: .default)).isEmpty
    )
  }

  // MARK: Preconditions

  /// `.nativePing` measures from this process, so there is no core endpoint to call and the whole
  /// batch has to stay per-node whatever the group sizes are.
  func testNativePingModeNeverPromotes() {
    var settings = DelayTestSettings.default
    settings.mode = .nativePing

    let units = AppModel.proxyDelayBatchUnits(
      items: items(group: "Proxy", count: largeGroupSize),
      settings: settings
    )

    XCTAssertEqual(units.count, largeGroupSize)
    XCTAssertTrue(groupNames(units).isEmpty)
  }

  /// `testDelay(for:)` synthesises an unnamed group for a node in no visible group. The core has no
  /// such group, so probing it would 404 the whole unit.
  func testUnnamedGroupNeverPromotes() {
    let units = AppModel.proxyDelayBatchUnits(items: items(group: "", count: largeGroupSize), settings: .default)

    XCTAssertEqual(units.count, largeGroupSize)
    XCTAssertTrue(groupNames(units).isEmpty)
  }

  /// The endpoint takes a single `url`, so a group whose members disagree cannot be expressed as
  /// one call without silently measuring some members against the wrong target.
  func testMixedTestURLsFallBackToPerNodeForThatGroupOnly() {
    var mixed = items(group: "Proxy", count: largeGroupSize)
    mixed[3] = item(group: "Proxy", node: "Proxy-3", testURL: otherTestURL)
    let all = mixed + items(group: "Streaming", count: largeGroupSize)

    let units = AppModel.proxyDelayBatchUnits(items: all, settings: .default)

    XCTAssertEqual(groupNames(units), ["Streaming"])
    XCTAssertEqual(nodeNames(units).count, largeGroupSize)
  }

  func testEveryMemberSurvivesPromotionAndFallbackAlike() {
    let all = items(group: "Proxy", count: largeGroupSize) + items(group: "Fallback", count: 3)

    let units = AppModel.proxyDelayBatchUnits(items: all, settings: .default)
    let covered = units.flatMap { unit -> [String] in
      switch unit {
      case let .node(item): return [item.node.name]
      case let .group(_, _, members): return members.map(\.node.name)
      }
    }

    XCTAssertEqual(Set(covered), Set(all.map(\.node.name)))
    XCTAssertEqual(covered.count, all.count, "No node may be probed twice")
  }

  // MARK: Ordering

  /// The batch still runs top-to-bottom over the page, so the first unit belongs to the first group
  /// the user can see rather than to whichever group happened to hash first.
  func testUnitOrderFollowsFirstSeenGroupOrder() {
    let all = items(group: "Zulu", count: largeGroupSize)
      + items(group: "Alpha", count: 2)
      + items(group: "Mike", count: largeGroupSize)

    let units = AppModel.proxyDelayBatchUnits(items: all, settings: .default)

    XCTAssertEqual(groupNames(units), ["Zulu", "Mike"])
    XCTAssertEqual(nodeNames(units), ["Alpha-0", "Alpha-1"])
    guard case .group("Zulu", _, _) = units[0] else { return XCTFail("Expected Zulu first") }
  }

  /// Members of one group arriving in two runs of the flat list are still one group, and the group
  /// keeps the position of its first member.
  func testInterleavedMembersOfOneGroupAreCollectedIntoASingleUnit() {
    var all: [ProxyDelayBatchItem] = []
    for index in 0..<largeGroupSize {
      all.append(item(group: "Proxy", node: "Proxy-\(index)"))
      all.append(item(group: "Direct", node: "Direct-\(index)"))
    }

    let units = AppModel.proxyDelayBatchUnits(items: all, settings: .default)

    XCTAssertEqual(groupNames(units), ["Proxy", "Direct"])
    XCTAssertEqual(units.count, 2)
  }

  // MARK: Concurrency cost

  /// A group unit is not one request's worth of load. Mihomo's group `URLTest` starts one goroutine
  /// per member with no internal wave limit — the A6 measurement resolved all 1200 members of a
  /// synthetic group inside a single 5 s window — so a group in flight is already probing every
  /// member at once. Charging it one slot let six such groups run together, which on the
  /// maintainer's own profile is thousands of simultaneous probes: a bigger storm than the per-node
  /// path A6 replaced.
  func testAGroupUnitOccupiesTheWholeConcurrencyBudget() {
    let unit = ProxyDelayBatchUnit.group(
      name: "Proxy",
      testURL: testURL,
      items: items(group: "Proxy", count: largeGroupSize)
    )

    // 6 is `AppModel.proxyDelayBatchConcurrencyLimit`, spelled out here the way the promotion
    // floor already is, because the constant is private to the model.
    XCTAssertEqual(unit.concurrencyCost(budget: 6), 6)
    XCTAssertEqual(unit.concurrencyCost(budget: 24), 24)
  }

  func testANodeUnitCostsOneSlotWhateverTheBudgetIs() {
    let unit = ProxyDelayBatchUnit.node(item(group: "Proxy", node: "Proxy-0"))

    XCTAssertEqual(unit.concurrencyCost(budget: 6), 1)
    XCTAssertEqual(unit.concurrencyCost(budget: 1), 1)
  }

  /// The scheduler subtracts the cost it charged, so a zero cost would leak budget and a cost it
  /// can never afford would deadlock. Both are ruled out at the source.
  func testEveryUnitCostsAtLeastOneSlotEvenWithAnEmptyBudget() {
    let group = ProxyDelayBatchUnit.group(
      name: "Proxy",
      testURL: testURL,
      items: items(group: "Proxy", count: largeGroupSize)
    )

    XCTAssertEqual(group.concurrencyCost(budget: 0), 1)
    XCTAssertEqual(group.concurrencyCost(budget: -3), 1)
    XCTAssertEqual(ProxyDelayBatchUnit.node(item(group: "Proxy", node: "Proxy-0")).concurrencyCost(budget: 0), 1)
  }

  // MARK: Probe attempts

  /// Unified Delay used to mean two different things either side of the promotion floor: the
  /// per-node path sampled twice from this process, the single-call group path once. What the core
  /// does is settled by `unified-delay` in the runtime config, so ClashMax only has to repeat the
  /// probe where the core is not involved at all.
  func testClientSideProbeAttemptsOnlyDoubleWhereTheCoreIsNotInvolved() {
    var settings = DelayTestSettings.default
    settings.mode = .mihomoURL
    settings.unifiedDelay = true
    XCTAssertEqual(settings.clientSideProbeAttempts, 1)

    settings.unifiedDelay = false
    XCTAssertEqual(settings.clientSideProbeAttempts, 1)

    settings.mode = .nativePing
    settings.unifiedDelay = true
    XCTAssertEqual(settings.clientSideProbeAttempts, 2)

    settings.unifiedDelay = false
    XCTAssertEqual(settings.clientSideProbeAttempts, 1)
  }

  func testEmptyBatchProducesNoUnits() {
    XCTAssertTrue(AppModel.proxyDelayBatchUnits(items: [], settings: .default).isEmpty)
  }
}
