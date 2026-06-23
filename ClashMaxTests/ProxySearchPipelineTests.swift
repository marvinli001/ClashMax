import Combine
import XCTest

@testable import ClashMax

/// Regression coverage for issue #10 (large proxy-list search performance).
///
/// The proxy search work (provider expansion, per-group sort, query filtering) used to run
/// synchronously inside `ProxiesView.body`. These tests pin the behaviour of the extracted
/// pure pipeline plus the `@MainActor` coordinator that debounces and offloads the work so the
/// main thread only publishes finished snapshots.
@MainActor
final class ProxySearchPipelineTests: XCTestCase {

  // MARK: - Fixtures

  /// Builds a catalog with 1600+ resolvable nodes spread across regions, fronted by a provider
  /// reference so the pipeline's provider-expansion path is exercised at scale.
  private enum Fixture {
    static let regions = ["韩国", "美国", "日本", "香港", "新加坡", "台湾", "英国", "德国"]
    static let perRegion = 200

    /// Number of nodes whose name contains "韩国".
    static var koreaNodeCount: Int { perRegion }
    /// Total resolved node count (every region node plus the standalone DIRECT node).
    static var resolvedNodeCount: Int { regions.count * perRegion + 1 }

    static func make() -> (groups: [ProxyGroup], providers: [ProxyProvider]) {
      var proxies: [ProxyNode] = []
      proxies.reserveCapacity(regions.count * perRegion)
      for region in regions {
        for index in 1...perRegion {
          proxies.append(
            ProxyNode(
              name: "\(region) \(String(format: "%03d", index))",
              type: "vless",
              delay: ((index * 7) % 280) + 20,
              isSelectable: true
            )
          )
        }
      }
      let provider = ProxyProvider(
        name: "Subscribe",
        type: "http",
        vehicleType: nil,
        updatedAt: nil,
        proxies: proxies
      )
      // `selected` deliberately points at a non-Korea node: `searchableText` folds the group's
      // selected name into every node, so a Korea selection would make all nodes match "韩国".
      let proxyGroup = ProxyGroup(
        name: "Proxy",
        type: "select",
        selected: "美国 001",
        nodes: [ProxyNode(name: "Provider:Subscribe", type: "provider", delay: nil, isSelectable: false)]
      )
      let directGroup = ProxyGroup(
        name: "Direct",
        type: "select",
        selected: "DIRECT",
        nodes: [ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)]
      )
      return ([proxyGroup, directGroup], [provider])
    }

    static func input(searchText: String, sortOrder: ProxyNodeSort = .profile) -> ProxySearchPipeline.Input {
      let catalog = make()
      return ProxySearchPipeline.Input(
        groups: catalog.groups,
        providers: catalog.providers,
        sortOrder: sortOrder,
        searchText: searchText
      )
    }
  }

  // MARK: - Pure pipeline

  func testPipelineExpandsProvidersIntoLargeCatalog() {
    let snapshot = ProxySearchPipeline.run(Fixture.input(searchText: ""))

    XCTAssertEqual(snapshot.sourceNodeCount, Fixture.resolvedNodeCount)
    XCTAssertGreaterThan(snapshot.sourceNodeCount, 1600)
    // Empty query keeps everything; filtered == unfiltered.
    XCTAssertEqual(snapshot.filteredGroups, snapshot.unfilteredGroups)
    XCTAssertEqual(snapshot.resultNodeCount, Fixture.resolvedNodeCount)
    XCTAssertFalse(snapshot.isSearchActive)
  }

  func testPipelineFiltersKoreaNodesOnly() {
    let snapshot = ProxySearchPipeline.run(Fixture.input(searchText: "韩国"))

    XCTAssertTrue(snapshot.isSearchActive)
    // Only the Proxy group survives; the Direct group has no Korea match.
    XCTAssertEqual(snapshot.filteredGroups.map(\.name), ["Proxy"])
    XCTAssertEqual(snapshot.resultNodeCount, Fixture.koreaNodeCount)
    XCTAssertTrue(
      snapshot.filteredGroups.allSatisfy { group in
        group.nodes.allSatisfy { $0.name.contains("韩国") }
      },
      "Every surviving node must match the query"
    )
    // Unfiltered side still reflects the full catalog for empty-state / count decisions.
    XCTAssertEqual(snapshot.unfilteredGroups.map(\.name), ["Proxy", "Direct"])
  }

  func testPipelinePreservesExistingQuerySyntax() {
    // case / word / regex / type / provider / delay comparisons must keep working post-extraction.
    let groups = [
      ProxyGroup(
        name: "Proxy",
        type: "select",
        selected: nil,
        nodes: [
          ProxyNode(name: "JP Tokyo", type: "vless", delay: 83, isSelectable: true, providerName: "Remote"),
          ProxyNode(name: "US Relay", type: "trojan", delay: 260, isSelectable: true, providerName: "Backup")
        ]
      )
    ]
    func run(_ text: String) -> [String] {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(groups: groups, providers: [], sortOrder: .profile, searchText: text)
      )
      .filteredGroups.flatMap { $0.nodes.map(\.name) }
    }

    XCTAssertEqual(run("provider=Remote delay<100"), ["JP Tokyo"])
    XCTAssertEqual(run("type=trojan"), ["US Relay"])
    XCTAssertEqual(run("case=true JP"), ["JP Tokyo"])
    XCTAssertEqual(run("/Relay/"), ["US Relay"])
  }

  func testPipelineAppliesSortOrderWithinGroups() {
    let groups = [
      ProxyGroup(
        name: "Proxy",
        type: "select",
        selected: nil,
        nodes: [
          ProxyNode(name: "z-node", type: "vless", delay: 200, isSelectable: true),
          ProxyNode(name: "a-node", type: "vless", delay: 50, isSelectable: true),
          ProxyNode(name: "m-node", type: "vless", delay: 120, isSelectable: true)
        ]
      )
    ]
    func order(_ sort: ProxyNodeSort) -> [String] {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(groups: groups, providers: [], sortOrder: sort, searchText: "")
      )
      .filteredGroups.first?.nodes.map(\.name) ?? []
    }

    XCTAssertEqual(order(.profile), ["z-node", "a-node", "m-node"], "profile keeps configured order")
    XCTAssertEqual(order(.name), ["a-node", "m-node", "z-node"])
    XCTAssertEqual(order(.delay), ["a-node", "m-node", "z-node"], "delay sorts ascending")
  }

  func testPipelineRecordsDurationMetric() {
    let snapshot = ProxySearchPipeline.run(Fixture.input(searchText: "韩国"))
    XCTAssertGreaterThanOrEqual(snapshot.durationMs, 0)
    XCTAssertTrue(snapshot.durationMs.isFinite)
  }

  // MARK: - Generation gate (stale-result drop)

  func testGenerationGateRejectsStaleTokens() {
    var gate = ProxySearchGenerationGate()
    let first = gate.begin()
    let second = gate.begin()

    XCTAssertFalse(gate.commit(first), "An older generation must not overwrite a newer query")
    XCTAssertEqual(gate.staleDropped, 1)
    XCTAssertTrue(gate.commit(second))
    XCTAssertEqual(gate.published, second)
    // Re-committing the same token (duplicate publish) is also rejected.
    XCTAssertFalse(gate.commit(second))
    XCTAssertEqual(gate.staleDropped, 2)
  }

  func testGenerationGateAcceptsOnlyTheLatestAmongRapidRequests() {
    var gate = ProxySearchGenerationGate()
    let tokens = (0..<5).map { _ in gate.begin() }
    // Earlier tokens are stale once later ones exist.
    for token in tokens.dropLast() {
      XCTAssertFalse(gate.commit(token))
    }
    XCTAssertTrue(gate.commit(tokens.last!))
    XCTAssertEqual(gate.staleDropped, 4)
  }

  // MARK: - Search progress vs. skeleton policy

  func testSearchProgressShowsOnlyWhileComputingNonEmptyQuery() {
    XCTAssertTrue(ProxySearchActivityPolicy.showsSearchProgress(searchText: "韩国", isComputing: true))
    XCTAssertFalse(ProxySearchActivityPolicy.showsSearchProgress(searchText: "韩国", isComputing: false))
    XCTAssertFalse(ProxySearchActivityPolicy.showsSearchProgress(searchText: "", isComputing: true))
    XCTAssertFalse(ProxySearchActivityPolicy.showsSearchProgress(searchText: "   ", isComputing: true))
  }

  func testSearchingNeverTriggersLoadingSkeleton() {
    // Skeleton depends only on there being no groups yet while loading/starting — searching with a
    // populated catalog must never flip it on.
    XCTAssertFalse(
      ProxyPageVisibilityPolicy.showsLoadingSkeleton(
        unfilteredGroupCount: 4,
        hasActiveProfile: true,
        isRuntimeDataLoading: true,
        isStarting: false
      )
    )
  }

  // MARK: - Coordinator (debounce + offload + stale drop)

  func testCoordinatorPublishesOnlyTheLatestQuery() async {
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    coordinator.submit(Fixture.input(searchText: "韩"), reason: .searchText)
    coordinator.submit(Fixture.input(searchText: "韩国"), reason: .searchText)
    await coordinator.settleForTesting()

    XCTAssertEqual(coordinator.snapshot.searchText, "韩国")
    XCTAssertFalse(coordinator.isComputing)
    XCTAssertEqual(coordinator.snapshot.resultNodeCount, Fixture.koreaNodeCount)
    XCTAssertTrue(
      coordinator.snapshot.filteredGroups.allSatisfy { group in
        group.nodes.allSatisfy { $0.name.contains("韩国") }
      }
    )
  }

  func testCoordinatorEmptySearchRestoresFullResults() async {
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    coordinator.submit(Fixture.input(searchText: "韩国"), reason: .searchText)
    await coordinator.settleForTesting()
    let filteredCount = coordinator.snapshot.resultNodeCount

    coordinator.submit(Fixture.input(searchText: ""), reason: .searchText)
    await coordinator.settleForTesting()

    XCTAssertEqual(coordinator.snapshot.filteredGroups, coordinator.snapshot.unfilteredGroups)
    XCTAssertEqual(coordinator.snapshot.resultNodeCount, Fixture.resolvedNodeCount)
    XCTAssertGreaterThan(coordinator.snapshot.resultNodeCount, filteredCount)
  }

  func testCoordinatorDropsStaleResultWhenNewerQueryArrives() async {
    // A slow generation that finishes after a newer query must not overwrite the newer snapshot.
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    coordinator.submit(Fixture.input(searchText: "美国"), reason: .searchText)
    coordinator.submit(Fixture.input(searchText: "日本"), reason: .searchText)
    coordinator.submit(Fixture.input(searchText: "韩国"), reason: .searchText)
    await coordinator.settleForTesting()

    XCTAssertEqual(coordinator.snapshot.searchText, "韩国")
    XCTAssertGreaterThanOrEqual(coordinator.staleResultsDropped, 0)
    XCTAssertFalse(coordinator.isComputing)
  }

  /// Proves the equality guard in `publish`: a recompute resolving to identical display content does
  /// not re-assign `snapshot`, so the `$snapshot` publisher emits no redundant value. (This is the
  /// *only* thing the guard does — it does not, and cannot, suppress re-renders driven by `appModel`
  /// or the `isComputing` toggle.)
  func testCoordinatorDoesNotRepublishIdenticalSnapshot() async {
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    var snapshotEmissions = 0
    let cancellable = coordinator.$snapshot.dropFirst().sink { _ in snapshotEmissions += 1 }
    defer { cancellable.cancel() }

    coordinator.submit(Fixture.input(searchText: "韩国"), reason: .searchText)
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 1, "first result publishes once")

    // Identical query + identical (value-equal) data → identical snapshot → must be skipped.
    coordinator.submit(Fixture.input(searchText: "韩国"), reason: .data)
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 1, "identical snapshot must not emit a redundant objectWillChange")

    // A genuinely different result must publish.
    coordinator.submit(Fixture.input(searchText: "美国"), reason: .searchText)
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 2, "a changed result publishes")
  }

  /// Counterpoint that pins the corrected understanding: while a search is active, changing a node
  /// that's filtered *out* still alters `unfilteredGroups`, so the snapshot is NOT identical and the
  /// guard does NOT skip it (only `filteredGroups` is unchanged).
  func testFilteredOutNodeChangeStillUpdatesSnapshotDuringSearch() {
    let base = Fixture.make()
    func snapshot(_ providers: [ProxyProvider]) -> ProxySearchSnapshot {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(groups: base.groups, providers: providers, sortOrder: .profile, searchText: "韩国")
      )
    }
    let before = snapshot(base.providers)

    var providers = base.providers
    providers[0].proxies = providers[0].proxies.map { node in
      guard node.name.hasPrefix("美国") else { return node }
      return ProxyNode(
        name: node.name,
        type: node.type,
        delay: (node.delay ?? 0) + 500,
        isSelectable: node.isSelectable,
        providerName: node.providerName
      )
    }
    let after = snapshot(providers)

    XCTAssertEqual(after.filteredGroups, before.filteredGroups, "displayed 韩国 result is unchanged")
    XCTAssertNotEqual(after, before, "unfilteredGroups still tracks the changed 美国 node, so the guard would not skip")
  }
}
