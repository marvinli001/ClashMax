@testable import ClashMax
import XCTest

/// Pins what moved out of `AppModel` into `RuntimeDiagnosticsStore` (roadmap D1): the `AppModel`
/// members are now computed facades, and a view reading one must still be invalidated when the
/// store changes. Nothing fails to compile when that relay breaks, so it is asserted here.
@MainActor
final class RuntimeDiagnosticsStoreTests: XCTestCase {
  func testAppModelFacadesInvalidateWhenTheStoreChanges() throws {
    let model = try makeModel()
    let flushCounter = ObservationChangeCounter { _ = model.lastFakeIPFlushAt }
    let networkCounter = ObservationChangeCounter { _ = model.lastNetworkEnvironmentChangeAt }
    let launchCounter = ObservationChangeCounter { _ = model.lastCoreLaunchAt }
    let queryCounter = ObservationChangeCounter { _ = model.dnsResolutionQuery }

    model.runtimeDiagnostics.recordFakeIPFlush()
    model.runtimeDiagnostics.recordNetworkEnvironmentChange()
    model.runtimeDiagnostics.recordCoreLaunch()
    model.runtimeDiagnostics.dnsResolutionQuery = "example.com"

    XCTAssertEqual(flushCounter.count, 1)
    XCTAssertEqual(networkCounter.count, 1)
    XCTAssertEqual(launchCounter.count, 1)
    XCTAssertEqual(queryCounter.count, 1)
    XCTAssertNotNil(model.lastFakeIPFlushAt)
    XCTAssertNotNil(model.lastNetworkEnvironmentChangeAt)
    XCTAssertNotNil(model.lastCoreLaunchAt)
    XCTAssertEqual(model.dnsResolutionQuery, "example.com")
  }

  /// The Routing panel binds `$appModel.dnsResolutionQuery` / `...QueryType`; the setters have to
  /// land in the store, or the resolve button would query a name the field no longer shows.
  func testAppModelDNSQuerySettersWriteThroughToTheStore() throws {
    let model = try makeModel()

    model.dnsResolutionQuery = "example.org"
    model.dnsResolutionQueryType = .aaaa

    XCTAssertEqual(model.runtimeDiagnostics.dnsResolutionQuery, "example.org")
    XCTAssertEqual(model.runtimeDiagnostics.dnsResolutionQueryType, .aaaa)
  }

  /// The change stamp is the structural dedup guard: re-reading an unchanged `sniffer` block must
  /// not stamp it, or every hot reload would mark the whole connection list as predating it.
  func testSnifferChangeIsStampedOnlyWhenTheAppliedBlockActuallyChanges() async throws {
    let store = RuntimeDiagnosticsStore()
    let directory = try makeDirectory()
    let sniffingOn = try writeConfig("sniffer:\n  enable: true\n", named: "on.yaml", in: directory)
    let sniffingOff = try writeConfig("sniffer:\n  enable: false\n", named: "off.yaml", in: directory)

    store.refreshAppliedConfigFacts(from: sniffingOn)
    await waitUntil { store.activeSnifferSettings != nil }
    XCTAssertEqual(store.activeSnifferSettings?.isSniffingEnabled, true)
    XCTAssertNil(store.activeSnifferSettingsChangedAt, "the first read of a runtime is not a change")

    store.refreshAppliedConfigFacts(from: sniffingOn)
    await settle()
    XCTAssertNil(store.activeSnifferSettingsChangedAt, "an identical re-read is not a change")

    store.refreshAppliedConfigFacts(from: sniffingOff)
    await waitUntil { store.activeSnifferSettings?.isSniffingEnabled == false }
    XCTAssertNotNil(store.activeSnifferSettingsChangedAt)
  }

  func testClearingRuntimeFactsKeepsTheNetworkChangeStamp() async throws {
    let store = RuntimeDiagnosticsStore()
    let directory = try makeDirectory()
    let config = try writeConfig("sniffer:\n  enable: true\n", named: "config.yaml", in: directory)
    store.refreshAppliedConfigFacts(from: config)
    await waitUntil { store.activeSnifferSettings != nil }
    store.recordCoreLaunch()
    store.recordFakeIPFlush()
    store.recordNetworkEnvironmentChange()

    store.clearRuntimeFacts()

    XCTAssertNil(store.activeSnifferSettings)
    XCTAssertNil(store.activeSnifferSettingsChangedAt)
    XCTAssertNil(store.activeDNSFacts)
    XCTAssertNil(store.activeListenerFacts)
    XCTAssertNil(store.activeFindProcessMode)
    XCTAssertNil(store.activeTunCongestionController)
    XCTAssertNil(store.lastCoreLaunchAt)
    XCTAssertNil(store.lastFakeIPFlushAt)
    XCTAssertEqual(store.dnsResolutionOutcome, .idle)
    XCTAssertFalse(store.isResolvingDNS)
    XCTAssertNotNil(store.lastNetworkEnvironmentChangeAt, "a network change is about the Mac, not the core")
  }

  func testResolvingWithoutARunningControllerDoesNothing() {
    let store = RuntimeDiagnosticsStore()
    store.dnsResolutionQuery = "example.com"

    store.resolveDNSQuery(using: nil)

    XCTAssertEqual(store.dnsResolutionOutcome, .idle)
    XCTAssertFalse(store.isResolvingDNS)
  }

  // MARK: - Helpers

  private func makeModel() throws -> AppModel {
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
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClashMaxRuntimeDiagnosticsTests-\(UUID().uuidString)"))
    return AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxRuntimeDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func writeConfig(_ text: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func waitUntil(_ isSatisfied: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSatisfied(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// Gives the background config reads a chance to land when the assertion is that nothing changes.
  private func settle(_ duration: TimeInterval = 0.2) async {
    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
  }
}
