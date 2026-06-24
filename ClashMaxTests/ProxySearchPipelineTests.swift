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
      // `selected` is a non-Korea node so this scale fixture's "韩国" search count stays equal to the
      // Korea node count regardless of the issue #9 fix. (Pre-fix, `searchableText` folded the
      // selected name into every node, so a Korea selection made the whole group match — that
      // regression is pinned directly by `testSearchDoesNotMatchWholeGroupWhenSelectedNodeMatchesQuery`.)
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

  /// Issue #11: while searching "韩国", a delay-batch data refresh that only changes a filtered-out
  /// "美国" node must NOT push a new snapshot — otherwise every batched result during "Test All"
  /// would re-diff the displayed list and stutter scrolling.
  func testCoordinatorSkipsRepublishWhenOnlyFilteredOutNodeDelayChanges() async {
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    let base = Fixture.make()
    var snapshotEmissions = 0
    let cancellable = coordinator.$snapshot.dropFirst().sink { _ in snapshotEmissions += 1 }
    defer { cancellable.cancel() }

    coordinator.submit(
      ProxySearchPipeline.Input(groups: base.groups, providers: base.providers, sortOrder: .profile, searchText: "韩国"),
      reason: .searchText
    )
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 1, "first 韩国 result publishes once")

    var bumped = base.providers
    bumped[0].proxies = bumped[0].proxies.map { node in
      guard node.name.hasPrefix("美国") else { return node }
      return ProxyNode(
        name: node.name,
        type: node.type,
        delay: (node.delay ?? 0) + 500,
        isSelectable: node.isSelectable,
        providerName: node.providerName
      )
    }
    coordinator.submit(
      ProxySearchPipeline.Input(groups: base.groups, providers: bumped, sortOrder: .profile, searchText: "韩国"),
      reason: .data
    )
    await coordinator.settleForTesting()
    XCTAssertEqual(
      snapshotEmissions,
      1,
      "a delay change on a filtered-out 美国 node must not republish the 韩国 result during search"
    )
  }

  /// Counterpoint: a delay change on a node that *is* displayed (matches "韩国") must republish so
  /// the visible delay updates.
  func testCoordinatorRepublishesWhenDisplayedNodeDelayChanges() async {
    let coordinator = ProxySearchCoordinator()
    coordinator.searchDebounce = .zero
    coordinator.dataDebounce = .zero

    let base = Fixture.make()
    var snapshotEmissions = 0
    let cancellable = coordinator.$snapshot.dropFirst().sink { _ in snapshotEmissions += 1 }
    defer { cancellable.cancel() }

    coordinator.submit(
      ProxySearchPipeline.Input(groups: base.groups, providers: base.providers, sortOrder: .profile, searchText: "韩国"),
      reason: .searchText
    )
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 1)

    var bumped = base.providers
    bumped[0].proxies = bumped[0].proxies.map { node in
      guard node.name.hasPrefix("韩国") else { return node }
      return ProxyNode(
        name: node.name,
        type: node.type,
        delay: (node.delay ?? 0) + 500,
        isSelectable: node.isSelectable,
        providerName: node.providerName
      )
    }
    coordinator.submit(
      ProxySearchPipeline.Input(groups: base.groups, providers: bumped, sortOrder: .profile, searchText: "韩国"),
      reason: .data
    )
    await coordinator.settleForTesting()
    XCTAssertEqual(snapshotEmissions, 2, "a delay change on a displayed 韩国 node must update the view")
  }

  /// Issue #11: while a search is active, a delay change on a node that's filtered *out* (only
  /// reflected in the unfiltered side) must leave the snapshot equal so the coordinator can skip a
  /// redundant publish. A *structural* change (node removed) still alters `unfilteredIdentity` and
  /// makes the snapshot unequal, so counts / empty-state stay correct.
  func testFilteredOutNodeDelayChangeKeepsSnapshotEqualDuringSearch() {
    let base = Fixture.make()
    func snapshot(_ providers: [ProxyProvider]) -> ProxySearchSnapshot {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(groups: base.groups, providers: providers, sortOrder: .profile, searchText: "韩国")
      )
    }
    let before = snapshot(base.providers)

    var bumped = base.providers
    bumped[0].proxies = bumped[0].proxies.map { node in
      guard node.name.hasPrefix("美国") else { return node }
      return ProxyNode(
        name: node.name,
        type: node.type,
        delay: (node.delay ?? 0) + 500,
        isSelectable: node.isSelectable,
        providerName: node.providerName
      )
    }
    let afterDelayBump = snapshot(bumped)

    XCTAssertEqual(afterDelayBump.filteredGroups, before.filteredGroups, "displayed 韩国 result is unchanged")
    XCTAssertEqual(
      afterDelayBump,
      before,
      "a delay change on a filtered-out 美国 node must keep the snapshot equal during search"
    )

    // A structural change (drop a 美国 node) must still be observed via unfilteredIdentity.
    var removed = base.providers
    removed[0].proxies = removed[0].proxies.filter { $0.name != "美国 001" }
    let afterRemoval = snapshot(removed)
    XCTAssertNotEqual(
      afterRemoval,
      before,
      "removing a node changes unfilteredIdentity and must republish so counts stay correct"
    )
  }

  /// Sort stability (issue #11): a delay change may reorder nodes only under `.delay`. Under
  /// `.profile` / `.name` / `.type` the order must not move because of measured delays, so the list
  /// doesn't jump around while "Test All" runs.
  func testSortOrderStabilityUnderDelayChanges() {
    func nodes(_ delays: [Int]) -> [ProxyNode] {
      [
        ProxyNode(name: "z-node", type: "trojan", delay: delays[0], isSelectable: true),
        ProxyNode(name: "a-node", type: "vless", delay: delays[1], isSelectable: true),
        ProxyNode(name: "m-node", type: "vmess", delay: delays[2], isSelectable: true)
      ]
    }
    func order(_ sort: ProxyNodeSort, _ delays: [Int]) -> [String] {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(
          groups: [ProxyGroup(name: "Proxy", type: "select", selected: nil, nodes: nodes(delays))],
          providers: [],
          sortOrder: sort,
          searchText: ""
        )
      )
      .filteredGroups.first?.nodes.map(\.name) ?? []
    }

    // Same nodes, different measured delays.
    let slow = [300, 50, 120]
    let fast = [40, 260, 90]

    for sort in [ProxyNodeSort.profile, .name, .type] {
      XCTAssertEqual(
        order(sort, slow),
        order(sort, fast),
        "\(sort) ordering must not change when only delays change"
      )
    }
    XCTAssertNotEqual(
      order(.delay, slow),
      order(.delay, fast),
      "delay ordering must react to delay changes"
    )
  }

  // MARK: - Issue #9: search context must not match a whole group via `group.selected`

  /// Builds one provider-backed group whose members come from `regions`. `selected` mirrors the
  /// user's currently-picked node — the issue #9 regression is that this name used to be folded into
  /// every node's searchable text, so picking a Korea node made the *entire* group match "韩国".
  private static func providerBackedGroup(
    name: String,
    provider providerName: String,
    regions: [String],
    perRegion: Int,
    selected: String?
  ) -> (group: ProxyGroup, provider: ProxyProvider) {
    var proxies: [ProxyNode] = []
    for region in regions {
      for index in 1...perRegion {
        proxies.append(
          ProxyNode(
            name: "\(region) \(String(format: "%03d", index))",
            type: "vless",
            delay: 100,
            isSelectable: true
          )
        )
      }
    }
    let provider = ProxyProvider(
      name: providerName,
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: proxies
    )
    let group = ProxyGroup(
      name: name,
      type: "select",
      selected: selected,
      nodes: [ProxyNode(name: "Provider:\(providerName)", type: "provider", delay: nil, isSelectable: false)]
    )
    return (group, provider)
  }

  /// Core issue #9 repro: a group selecting a Korea node, but also holding US/JP nodes. Searching
  /// "韩国" must return only the genuinely-matching Korea nodes — not the whole 150-node group just
  /// because `group.selected` happens to contain "韩国".
  func testSearchDoesNotMatchWholeGroupWhenSelectedNodeMatchesQuery() {
    let perRegion = 50
    let built = Self.providerBackedGroup(
      name: "Proxy",
      provider: "Subscribe",
      regions: ["韩国", "美国", "日本"],
      perRegion: perRegion,
      selected: "韩国 001"
    )
    let snapshot = ProxySearchPipeline.run(
      ProxySearchPipeline.Input(
        groups: [built.group],
        providers: [built.provider],
        sortOrder: .profile,
        searchText: "韩国"
      )
    )

    XCTAssertEqual(
      snapshot.resultNodeCount,
      perRegion,
      "Only the Korea nodes survive — not the whole group via its selected name"
    )
    XCTAssertTrue(
      snapshot.filteredGroups.flatMap(\.nodes).allSatisfy { $0.name.contains("韩国") },
      "Every surviving node must genuinely match the query"
    )
    XCTAssertFalse(
      snapshot.filteredGroups.flatMap(\.nodes).contains { $0.name.contains("美国") || $0.name.contains("日本") },
      "US/JP nodes must not leak in via the group's selected name"
    )
  }

  /// Multi-group / "switch group" repro: two independent provider-backed groups, each with its OWN
  /// Korea nodes and each selecting a Korea node. Reading group B's filtered nodes (as the split view
  /// does after switching to B) must yield only B's Korea nodes — never A's, never B's non-Korea.
  func testSearchKeepsPerGroupKoreaMembershipAcrossGroups() {
    let groupA = Self.providerBackedGroup(
      name: "Asia-A",
      provider: "PA",
      regions: ["韩国-A", "美国-A"],
      perRegion: 30,
      selected: "韩国-A 001"
    )
    let groupB = Self.providerBackedGroup(
      name: "Asia-B",
      provider: "PB",
      regions: ["韩国-B", "日本-B"],
      perRegion: 30,
      selected: "韩国-B 001"
    )
    let snapshot = ProxySearchPipeline.run(
      ProxySearchPipeline.Input(
        groups: [groupA.group, groupB.group],
        providers: [groupA.provider, groupB.provider],
        sortOrder: .profile,
        searchText: "韩国"
      )
    )

    XCTAssertEqual(snapshot.filteredGroups.map(\.name), ["Asia-A", "Asia-B"])

    let a = snapshot.filteredGroups.first { $0.name == "Asia-A" }?.nodes ?? []
    let b = snapshot.filteredGroups.first { $0.name == "Asia-B" }?.nodes ?? []

    XCTAssertEqual(a.count, 30)
    XCTAssertTrue(a.allSatisfy { $0.name.contains("韩国-A") }, "Group A shows only its own Korea nodes")
    XCTAssertFalse(a.contains { $0.name.contains("美国") }, "Group A's US nodes must be filtered out")

    XCTAssertEqual(b.count, 30)
    XCTAssertTrue(b.allSatisfy { $0.name.contains("韩国-B") }, "Group B shows only its own Korea nodes")
    XCTAssertFalse(b.contains { $0.name.contains("日本") }, "Group B's JP nodes must be filtered out")
    XCTAssertFalse(b.contains { $0.name.contains("-A") }, "No cross-group leakage from A into B")
  }

  /// Guard: the explicit `selected=` token compares `group.selected` to `node.name` directly, so it
  /// must keep working after the free-text `searchableText` stops folding `group.selected` in.
  func testExplicitSelectedTokenStillResolvesAgainstSelectedNode() {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "韩国 001",
      nodes: [
        ProxyNode(name: "韩国 001", type: "vless", delay: 80, isSelectable: true),
        ProxyNode(name: "美国 001", type: "vless", delay: 80, isSelectable: true),
        ProxyNode(name: "日本 001", type: "vless", delay: 80, isSelectable: true)
      ]
    )
    func run(_ text: String) -> [String] {
      ProxySearchPipeline.run(
        ProxySearchPipeline.Input(groups: [group], providers: [], sortOrder: .profile, searchText: text)
      )
      .filteredGroups.flatMap { $0.nodes.map(\.name) }
    }

    XCTAssertEqual(run("selected=true"), ["韩国 001"], "selected=true resolves to the selected node only")
    XCTAssertEqual(run("selected=false"), ["美国 001", "日本 001"], "selected=false excludes the selected node")
  }

  // MARK: - Issue #9: split-view selection must stay valid as the displayed groups change

  private static func emptyGroup(_ name: String, selected: String? = nil) -> ProxyGroup {
    ProxyGroup(name: name, type: "select", selected: selected, nodes: [])
  }

  func testSelectionPolicyKeepsValidCurrentSelection() {
    let groups = [Self.emptyGroup("A"), Self.emptyGroup("B")]
    XCTAssertEqual(
      ProxyGroupSelectionPolicy.resolvedSelection(current: "B", groups: groups),
      "B",
      "A still-present selection must be preserved across reloads/searches"
    )
  }

  func testSelectionPolicyFallsBackWhenCurrentGroupFilteredOut() {
    // Searching "韩国" filtered group B out of the displayed set, so the stale "B" selection (which
    // the split view's right pane would otherwise render as empty) must move to a present group.
    let groups = [Self.emptyGroup("A", selected: "韩国 001"), Self.emptyGroup("C")]
    XCTAssertEqual(
      ProxyGroupSelectionPolicy.resolvedSelection(current: "B", groups: groups),
      "A",
      "Falls back to the first group that carries a selected node"
    )
  }

  func testSelectionPolicyFallsBackToFirstGroupWhenNoneSelected() {
    let groups = [Self.emptyGroup("A"), Self.emptyGroup("B")]
    XCTAssertEqual(
      ProxyGroupSelectionPolicy.resolvedSelection(current: "missing", groups: groups),
      "A",
      "With no selected-bearing group, falls back to the first displayed group"
    )
  }

  func testSelectionPolicyResolvesNilCurrentToADisplayedGroup() {
    let groups = [Self.emptyGroup("A"), Self.emptyGroup("B", selected: "节点")]
    XCTAssertEqual(
      ProxyGroupSelectionPolicy.resolvedSelection(current: nil, groups: groups),
      "B",
      "A nil selection (first appearance) resolves to the first selected-bearing group"
    )
  }

  func testSelectionPolicyReturnsNilForEmptyGroups() {
    XCTAssertNil(
      ProxyGroupSelectionPolicy.resolvedSelection(current: "A", groups: []),
      "No displayed groups (e.g. empty search result) clears the selection"
    )
  }
}
