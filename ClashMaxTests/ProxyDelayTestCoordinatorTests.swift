@testable import ClashMax
import XCTest

/// Pins what moved out of `AppModel` into `ProxyDelayTestCoordinator` (roadmap D1): the facades must
/// still invalidate views, results must still land in the collections the views read, and the
/// issue #11 coalescing and dedup guards must still hold. Nothing fails to compile when one of those
/// breaks, so it is asserted here. The batches run in native-ping mode so every probe goes through a
/// scripted ping tester and the controller client is never called.
@MainActor
final class ProxyDelayTestCoordinatorTests: XCTestCase {
  func testAppModelFacadesInvalidateWhenTheCoordinatorPublishes() async throws {
    let model = try makeModel()
    let group = makeGroup(name: "Proxy", nodeCount: 3)
    model.proxyGroups = [group]
    let progressCounter = ObservationChangeCounter { _ = model.proxyDelayBatchProgress }
    let runningCounter = ObservationChangeCounter { _ = model.isProxyDelayBatchRunning }
    let groupsCounter = ObservationChangeCounter { _ = model.proxyGroups }

    model.proxyDelayTests.startBatch(
      items: makeItems(for: group),
      apiClient: unusedAPIClient,
      settings: nativePing
    )

    // The `.testing` phase is one coalesced write, made before the batch task starts.
    XCTAssertEqual(groupsCounter.count, 1)
    XCTAssertTrue(model.proxyGroups.flatMap(\.nodes).allSatisfy { $0.delayState == .testing })
    XCTAssertTrue(model.isProxyDelayBatchRunning)
    XCTAssertGreaterThanOrEqual(progressCounter.count, 1)
    XCTAssertGreaterThanOrEqual(runningCounter.count, 1)

    await waitUntil { model.proxyDelayBatchProgress?.isRunning == false }
    XCTAssertEqual(model.proxyDelayBatchProgress?.succeeded, 3)
    XCTAssertFalse(model.isProxyDelayBatchRunning)
    XCTAssertGreaterThanOrEqual(progressCounter.count, 2)
  }

  /// Issue #11: the first result is flushed at once (the zero sentinel), and later results coalesce
  /// up to the count or time threshold. Every other probe is held back here, so the only way the
  /// first node can show its delay is the immediate first flush.
  func testFirstBatchResultIsPublishedWithoutWaitingForAThreshold() async throws {
    let ping = GatedPingTester(instantHost: hostName(for: 0))
    let fixture = makeCoordinator(pingTester: ping)
    let group = makeGroup(name: "Proxy", nodeCount: 12)
    fixture.runtimeData.proxyGroups = [group]
    fixture.coordinator.startBatch(
      items: makeItems(for: group),
      apiClient: unusedAPIClient,
      settings: nativePing
    )

    await waitUntil { fixture.runtimeData.proxyGroups.first?.nodes.first?.delayState == .measured(10) }
    let nodes = try XCTUnwrap(fixture.runtimeData.proxyGroups.first?.nodes)
    XCTAssertEqual(nodes.first?.delayState, .measured(10))
    XCTAssertTrue(nodes.dropFirst().allSatisfy { $0.delayState == .testing })
    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.isRunning, true)
    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.succeeded, 1)

    await ping.open()
    await waitUntil { fixture.coordinator.proxyDelayBatchProgress?.isRunning == false }
    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.succeeded, 12)
  }

  func testLargeBatchPublishesTheCollectionsFarBelowOncePerNode() async throws {
    let ping = GatedPingTester(instantHost: nil, startsOpen: true)
    let fixture = makeCoordinator(pingTester: ping)
    let nodeCount = 96
    let group = makeGroup(name: "Proxy", nodeCount: nodeCount)
    fixture.runtimeData.proxyGroups = [group]
    let groupsCounter = ObservationChangeCounter { _ = fixture.runtimeData.proxyGroups }
    let progressCounter = ObservationChangeCounter { _ = fixture.coordinator.proxyDelayBatchProgress }

    fixture.coordinator.startBatch(
      items: makeItems(for: group),
      apiClient: unusedAPIClient,
      settings: nativePing
    )
    await waitUntil { fixture.coordinator.proxyDelayBatchProgress?.isRunning == false }

    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.succeeded, nodeCount)
    let pingCount = await ping.callCount
    XCTAssertEqual(pingCount, nodeCount)
    XCTAssertTrue(fixture.runtimeData.proxyGroups.flatMap(\.nodes).allSatisfy { $0.delayState == .measured(20) })
    // A per-node regression would publish ~192 times (one `.testing` and one result per node).
    XCTAssertLessThan(groupsCounter.count, 30, "proxyGroups published \(groupsCounter.count) times")
    XCTAssertLessThan(progressCounter.count, 30, "progress published \(progressCounter.count) times")
  }

  /// Results for nodes no visible collection shows must not republish any of them, yet still land in
  /// the cache that a later reload restores from. This asserts the outcome, not the per-collection
  /// `didChange` guard itself: since Swift 6.2 `@Observable` also skips a write of an equal
  /// `Equatable` value, so removing that guard is invisible to Observation (checked by mutation).
  func testResultsForNodesNoCollectionShowsDoNotRepublishTheCollections() async throws {
    let fixture = makeCoordinator()
    fixture.runtimeData.proxyGroups = [makeGroup(name: "Visible", nodeCount: 2)]
    let groupsCounter = ObservationChangeCounter { _ = fixture.runtimeData.proxyGroups }
    let providersCounter = ObservationChangeCounter { _ = fixture.runtimeData.proxyProviders }
    let previewCounter = ObservationChangeCounter { _ = fixture.proxyPreview.profilePreviewGroups }
    let hidden = makeGroup(name: "Hidden", nodeCount: 3)

    fixture.coordinator.startBatch(
      items: makeItems(for: hidden),
      apiClient: unusedAPIClient,
      settings: nativePing
    )
    await waitUntil { fixture.coordinator.proxyDelayBatchProgress?.isRunning == false }

    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.succeeded, 3)
    XCTAssertEqual(groupsCounter.count, 0)
    XCTAssertEqual(providersCounter.count, 0)
    XCTAssertEqual(previewCounter.count, 0)
    let cached = fixture.coordinator.delayStateMap(from: [hidden]) { group, node in
      ProxyNodeKey(profileID: nil, groupName: group.name, nodeName: node.name)
    }
    XCTAssertEqual(cached.count, 3)
    XCTAssertTrue(cached.values.allSatisfy { $0 == .measured(20) })
  }

  func testCancelAllDropsARunningBatchButKeepsAFinishedOnesProgress() async throws {
    let held = GatedPingTester(instantHost: nil)
    let fixture = makeCoordinator(pingTester: held)
    let group = makeGroup(name: "Proxy", nodeCount: 3)
    fixture.runtimeData.proxyGroups = [group]
    fixture.coordinator.startBatch(items: makeItems(for: group), apiClient: unusedAPIClient, settings: nativePing)
    XCTAssertTrue(fixture.coordinator.isBatchTaskActive)

    fixture.coordinator.cancelAll()

    XCTAssertNil(fixture.coordinator.proxyDelayBatchProgress)
    XCTAssertFalse(fixture.coordinator.isBatchTaskActive)
    // Opened, the same tester answers the second batch at once.
    await held.open()

    fixture.coordinator.startBatch(items: makeItems(for: group), apiClient: unusedAPIClient, settings: nativePing)
    await waitUntil { fixture.coordinator.proxyDelayBatchProgress?.isRunning == false }
    await waitUntil { !fixture.coordinator.isBatchTaskActive }

    fixture.coordinator.cancelAll()

    XCTAssertEqual(fixture.coordinator.proxyDelayBatchProgress?.succeeded, 3)
  }

  // MARK: - Helpers

  private struct Fixture {
    let coordinator: ProxyDelayTestCoordinator
    let runtimeData: RuntimeDataStore
    let proxyPreview: ProxyPreviewStore
  }

  private let nativePing = DelayTestSettings(mode: .nativePing)

  /// Never called: native-ping batches measure through the ping tester alone.
  private let unusedAPIClient = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9")!, secret: "")

  private func makeCoordinator(pingTester: any PingTesting = GatedPingTester(instantHost: nil, startsOpen: true)) -> Fixture {
    let runtimeData = RuntimeDataStore()
    let proxyPreview = ProxyPreviewStore(defaults: makeDefaults())
    let coordinator = ProxyDelayTestCoordinator(
      runtimeData: runtimeData,
      proxyPreview: proxyPreview,
      pingTester: pingTester,
      delayStateCacheTTL: 600
    )
    return Fixture(coordinator: coordinator, runtimeData: runtimeData, proxyPreview: proxyPreview)
  }

  private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxProxyDelayTestCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    for directory in [paths.profiles, paths.runtime, paths.subscriptions, paths.logs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      pingTester: GatedPingTester(instantHost: nil, startsOpen: true),
      defaults: makeDefaults()
    )
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "ClashMaxProxyDelayTestCoordinatorTests-\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
    return UserDefaults(suiteName: suiteName)!
  }

  private func hostName(for index: Int) -> String {
    "node-\(index).example"
  }

  private func makeGroup(name: String, nodeCount: Int) -> ProxyGroup {
    let nodes = (0..<nodeCount).map { index in
      ProxyNode(name: "\(name) \(index)", type: "vless", delay: nil, isSelectable: true)
    }
    return ProxyGroup(name: name, type: "select", selected: nodes.first?.name, nodes: nodes)
  }

  private func makeItems(for group: ProxyGroup) -> [ProxyDelayBatchItem] {
    group.nodes.enumerated().map { index, node in
      ProxyDelayBatchItem(
        groupName: group.name,
        node: node,
        nodeKey: ProxyNodeKey(profileID: nil, groupName: group.name, nodeName: node.name),
        taskKey: ProxyNodeKey(profileID: nil, groupName: group.name, nodeName: node.name),
        testURL: AppConstants.defaultDelayTestURL,
        previousState: node.resolvedDelayState,
        nativePingHost: hostName(for: index)
      )
    }
  }

  private func waitUntil(_ isSatisfied: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSatisfied(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}

/// Answers `instantHost` at once with 10 ms and every other host with 20 ms once `open()` is called,
/// so a test can hold all but one probe of a batch in flight.
private actor GatedPingTester: PingTesting {
  private let instantHost: String?
  private var isOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var callCount = 0

  init(instantHost: String?, startsOpen: Bool = false) {
    self.instantHost = instantHost
    isOpen = startsOpen
  }

  func ping(host: String, timeoutMilliseconds _: Int) async throws -> Int {
    callCount += 1
    if host == instantHost {
      return 10
    }
    if !isOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    return 20
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}
