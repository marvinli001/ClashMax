@testable import ClashMax
import XCTest

/// Pins what moved out of `AppModel` into `GeoDatabaseStore` (roadmap D1): the `AppModel` members
/// are now computed facades, and a view reading one must still be invalidated when the store
/// changes. Nothing fails to compile when that relay breaks, so it is asserted here.
@MainActor
final class GeoDatabaseStoreTests: XCTestCase {
  func testAppModelFacadesInvalidateWhenTheStoreChanges() async throws {
    let controller = GeoUpdateController()
    let model = try makeModel(apiClient: controller)
    let inventoryCounter = ObservationChangeCounter { _ = model.geoDatabaseInventory }
    let inFlightCounter = ObservationChangeCounter { _ = model.geoDatabaseUpdateInFlight }
    let updatedAtCounter = ObservationChangeCounter { _ = model.lastGeoDatabaseUpdateAt }
    let failureCounter = ObservationChangeCounter { _ = model.lastGeoDatabaseUpdateFailure }
    let messageCounter = ObservationChangeCounter { _ = model.geoDatabaseUpdateStatusMessage }

    model.updateGeoDatabases()
    XCTAssertTrue(model.geoDatabaseUpdateInFlight)
    await waitUntil { !model.geoDatabaseUpdateInFlight }

    XCTAssertEqual(inFlightCounter.count, 2, "on, then off")
    XCTAssertEqual(inventoryCounter.count, 1)
    XCTAssertEqual(updatedAtCounter.count, 1)
    // Observation skips an equal write of an `Equatable` value, so clearing an already-empty
    // failure or message is not a change; only the description that lands is.
    XCTAssertEqual(failureCounter.count, 0)
    XCTAssertEqual(messageCounter.count, 1)
    XCTAssertNotNil(model.geoDatabaseInventory)
    XCTAssertNotNil(model.lastGeoDatabaseUpdateAt)
    XCTAssertNil(model.lastGeoDatabaseUpdateFailure)
    XCTAssertNotNil(model.geoDatabaseUpdateStatusMessage)
    XCTAssertTrue(
      model.geoDatabaseDiagnostics.facts.contains { $0.key == .lastRefresh },
      "the diagnostics builder reads the update stamp through the facade"
    )
  }

  func testAppModelInventoryRefreshLandsInTheStore() async throws {
    let model = try makeModel()
    let counter = ObservationChangeCounter { _ = model.geoDatabaseInventory }

    model.refreshGeoDatabaseInventory()
    await waitUntil { model.geoDatabaseInventory != nil }

    XCTAssertEqual(counter.count, 1)
    XCTAssertEqual(model.geoDatabases.geoDatabaseInventory, model.geoDatabaseInventory)
    XCTAssertEqual(model.geoDatabaseInventory?.files.count, GeoDatabaseKind.allCases.count)
  }

  /// A failed update still reaches the alert through `AppModel.lastError`, which the store can only
  /// set through the closure it is handed.
  func testAppModelUpdateFailureReachesLastError() async throws {
    let controller = GeoUpdateController(failureMessage: "boom")
    let model = try makeModel(apiClient: controller)

    model.updateGeoDatabases()
    await waitUntil { !model.geoDatabaseUpdateInFlight }

    let message = UserFacingError.message(for: AppError.helperResponse("boom"))
    XCTAssertEqual(model.lastGeoDatabaseUpdateFailure, message)
    XCTAssertNil(model.geoDatabaseUpdateStatusMessage)
    XCTAssertNil(model.lastGeoDatabaseUpdateAt)
    XCTAssertEqual(model.lastError, "Could not update the geo databases: \(message)")
  }

  /// The in-flight guard is the structural dedup: a second tap while one update is running must not
  /// start a second download against the same directory.
  func testASecondUpdateWhileOneIsInFlightIsDropped() async throws {
    let store = GeoDatabaseStore()
    let controller = GeoUpdateController()
    let directory = try makeDirectory()

    update(store, at: directory, controller: controller)
    update(store, at: directory, controller: controller)
    await waitUntil { !store.geoDatabaseUpdateInFlight }
    let firstRunRequests = await controller.requestCount
    XCTAssertEqual(firstRunRequests, 1)

    update(store, at: directory, controller: controller)
    await waitUntil { !store.geoDatabaseUpdateInFlight }
    let requests = await controller.requestCount
    XCTAssertEqual(requests, 2, "the guard releases once the first update finishes")
  }

  func testUpdatingWithoutARunningControllerDoesNothing() throws {
    let store = GeoDatabaseStore()
    var logs: [String] = []

    try store.updateGeoDatabases(
      at: makeDirectory(),
      settings: GeoDatabaseSettings(),
      requirements: .unknown,
      apiClient: { nil },
      appendAppLog: { _, message in logs.append(message) },
      reportError: { _ in XCTFail("nothing ran, so nothing failed") }
    )

    XCTAssertFalse(store.geoDatabaseUpdateInFlight)
    XCTAssertNil(store.geoDatabaseUpdateStatusMessage)
    XCTAssertTrue(logs.isEmpty)
  }

  /// The outcome is judged from the disk, not from the 204: a refresh that wrote nothing while a
  /// referenced database is still absent is the silent no-op, and a rewritten file is an update.
  func testOutcomeIsDescribedFromWhatChangedOnDisk() async throws {
    let directory = try makeDirectory()
    let requirements = GeoRuleRequirements(isKnown: true, geoSite: true)

    let noOpStore = GeoDatabaseStore()
    var noOpLogs: [(String, String)] = []
    noOpStore.updateGeoDatabases(
      at: directory,
      settings: GeoDatabaseSettings(),
      requirements: requirements,
      apiClient: { GeoUpdateController() },
      appendAppLog: { noOpLogs.append(($0, $1)) },
      reportError: { _ in XCTFail("the core reported no error") }
    )
    await waitUntil { !noOpStore.geoDatabaseUpdateInFlight }
    XCTAssertEqual(noOpLogs.map(\.0), ["warn"])
    XCTAssertEqual(noOpLogs.first?.1, "Geo database update downloaded nothing; GeoSite.dat still absent.")

    let writingStore = GeoDatabaseStore()
    var writingLogs: [(String, String)] = []
    writingStore.updateGeoDatabases(
      at: directory,
      settings: GeoDatabaseSettings(),
      requirements: requirements,
      apiClient: { GeoUpdateController(writing: directory.appendingPathComponent("GeoSite.dat")) },
      appendAppLog: { writingLogs.append(($0, $1)) },
      reportError: { _ in XCTFail("the core reported no error") }
    )
    await waitUntil { !writingStore.geoDatabaseUpdateInFlight }
    XCTAssertEqual(writingLogs.map(\.0), ["info"])
    XCTAssertEqual(writingLogs.first?.1, "Geo database update rewrote GeoSite.dat.")
    XCTAssertEqual(writingStore.geoDatabaseInventory?.state(for: .geoSite)?.exists, true)
  }

  // MARK: - Helpers

  private func update(_ store: GeoDatabaseStore, at directory: URL, controller: GeoUpdateController) {
    store.updateGeoDatabases(
      at: directory,
      settings: GeoDatabaseSettings(),
      requirements: .unknown,
      apiClient: { controller },
      appendAppLog: { _, _ in },
      reportError: { _ in }
    )
  }

  private func makeModel(apiClient: (any MihomoAPIControlling)? = nil) throws -> AppModel {
    let root = try makeDirectory()
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
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClashMaxGeoDatabaseStoreTests-\(UUID().uuidString)"))
    return AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      apiClient: apiClient,
      defaults: defaults
    )
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxGeoDatabaseStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func waitUntil(_ isSatisfied: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSatisfied(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}

/// Answers only `POST /configs/geo`; optionally writes a file first, the way a real download
/// rewrites the database in the core's working directory.
private actor GeoUpdateController: MihomoAPIControlling {
  private struct Unsupported: Error {}

  private let failureMessage: String?
  private let writtenFile: URL?
  private(set) var requestCount = 0

  init(failureMessage: String? = nil, writing writtenFile: URL? = nil) {
    self.failureMessage = failureMessage
    self.writtenFile = writtenFile
  }

  func updateGeoDatabases(timeout _: TimeInterval) async throws {
    requestCount += 1
    if let failureMessage {
      throw AppError.helperResponse(failureMessage)
    }
    if let writtenFile {
      try Data("geo".utf8).write(to: writtenFile)
    }
  }

  func updateMode(_: RunMode) async throws { throw Unsupported() }
  func updateIPv6(_: Bool) async throws { throw Unsupported() }
  func proxyGroups() async throws -> [ProxyGroup] { throw Unsupported() }
  func structuredProxyProviders() async throws -> [ProxyProvider] { throw Unsupported() }
  func ruleProviders() async throws -> [RuleProvider] { throw Unsupported() }
  func rules() async throws -> [RuntimeRule] { throw Unsupported() }
  func connections() async throws -> ConnectionsReport { throw Unsupported() }
  func selectProxy(group _: String, proxy _: String) async throws { throw Unsupported() }
  func testDelay(proxy _: String, testURL _: URL, timeout _: Int) async throws -> Int { throw Unsupported() }
  func testGroupDelay(group _: String, testURL _: URL, timeout _: Int) async throws -> [String: Int] { throw Unsupported() }
  func flushFakeIPCache() async throws { throw Unsupported() }
  func dnsQuery(name _: String, type _: String) async throws -> DNSQueryResult { throw Unsupported() }
  func healthCheckProvider(named _: String) async throws { throw Unsupported() }
  func updateProxyProvider(named _: String) async throws { throw Unsupported() }
  func updateRuleProvider(named _: String) async throws { throw Unsupported() }
  func closeConnection(id _: String) async throws { throw Unsupported() }
  func closeAllConnections() async throws { throw Unsupported() }
  func setTunEnabled(_: Bool) async throws { throw Unsupported() }
  func tunDNSMode() async throws -> String? { throw Unsupported() }
  func reloadConfig(path _: String, force _: Bool) async throws { throw Unsupported() }
  func restart(configPath _: String?) async throws { throw Unsupported() }
  nonisolated func trafficStream() -> AsyncThrowingStream<TrafficSample, Error> { AsyncThrowingStream { $0.finish() } }
  nonisolated func memoryStream() -> AsyncThrowingStream<CoreMemorySample, Error> { AsyncThrowingStream { $0.finish() } }
  nonisolated func logStream(level _: String) -> AsyncThrowingStream<LogEntry, Error> { AsyncThrowingStream { $0.finish() } }
  nonisolated func connectionStream(interval _: Int) -> AsyncThrowingStream<ConnectionsReport, Error> { AsyncThrowingStream { $0.finish() } }
}
