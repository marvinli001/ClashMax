@testable import ClashMax
import XCTest

/// Pins what moved out of `AppModel` into `OutboundProxyEndpointsCoordinator` (roadmap D1): the
/// `AppModel` members are now computed facades, and a view reading one must still be invalidated
/// when the coordinator changes. Nothing fails to compile when that relay breaks, so it is asserted
/// here, together with the refresh rules that keep a test result across a reload.
@MainActor
final class OutboundProxyEndpointsCoordinatorTests: XCTestCase {
  func testAppModelFacadesInvalidateWhenTheCoordinatorChanges() async throws {
    let (model, _) = try makeModel()
    await model.waitForOutboundProxyEndpointLoad()
    let endpointsCounter = ObservationChangeCounter { _ = model.outboundProxyEndpoints }
    let secretsCounter = ObservationChangeCounter { _ = model.outboundProxyEndpointSecretStates }
    let testsCounter = ObservationChangeCounter { _ = model.outboundProxyEndpointTestStates }
    let endpoint = makeEndpoint(authenticated: true)

    let didAdd = await model.addOutboundProxyEndpoint(endpoint, password: "secret")

    XCTAssertTrue(didAdd, model.lastError ?? "add returned false")
    XCTAssertEqual(endpointsCounter.count, 1)
    XCTAssertEqual(secretsCounter.count, 1)
    XCTAssertGreaterThan(testsCounter.count, 0)
    XCTAssertEqual(model.outboundProxyEndpoints, [endpoint])
    XCTAssertEqual(model.outboundProxyEndpointSecretStates, [endpoint.id: .ready])
    XCTAssertEqual(model.outboundProxyEndpointTestStates, [endpoint.id: .untested])
    XCTAssertEqual(model.outboundProxyEndpointsCoordinator.endpoints, [endpoint])
  }

  func testLoadErrorFacadeInvalidatesAndClearsTheLists() async throws {
    let (model, paths) = try makeModel()
    await model.waitForOutboundProxyEndpointLoad()
    XCTAssertNil(model.outboundProxyEndpointLoadError)
    let errorCounter = ObservationChangeCounter { _ = model.outboundProxyEndpointLoadError }
    try Data("not json".utf8).write(to: paths.outboundProxyEndpointManifestURL)

    await model.refreshOutboundProxyEndpoints()

    XCTAssertEqual(errorCounter.count, 1)
    XCTAssertNotNil(model.outboundProxyEndpointLoadError)
    XCTAssertEqual(model.outboundProxyEndpoints, [])
    XCTAssertEqual(model.outboundProxyEndpointSecretStates, [:])
    XCTAssertEqual(model.outboundProxyEndpointTestStates, [:])
  }

  /// The `== nil` guard in `refresh()` is what lets a connection test result survive a reload of the
  /// list; an endpoint that disappeared from the manifest loses its state.
  func testRefreshKeepsExistingTestResultsAndPrunesRemovedEndpoints() async throws {
    let (coordinator, store) = try makeCoordinator()
    let kept = makeEndpoint()
    let removed = makeEndpoint()
    try await coordinator.add(kept, password: nil)
    try await coordinator.add(removed, password: nil)
    _ = await coordinator.test(kept.id)
    let keptState = try XCTUnwrap(coordinator.testStates[kept.id])
    XCTAssertNotEqual(keptState, .untested)

    try await store.delete(id: removed.id)
    await coordinator.refresh()

    XCTAssertEqual(coordinator.endpoints, [kept])
    XCTAssertEqual(coordinator.testStates, [kept.id: keptState])
  }

  func testEditsAndAddsResetTheTestStateAndDeleteDropsIt() async throws {
    let (coordinator, _) = try makeCoordinator()
    let endpoint = makeEndpoint()
    try await coordinator.add(endpoint, password: nil)
    _ = await coordinator.test(endpoint.id)
    XCTAssertNotEqual(coordinator.testStates[endpoint.id], .untested)

    coordinator.markUntested(endpoint.id)
    XCTAssertEqual(coordinator.testStates[endpoint.id], .untested)

    try await coordinator.delete(id: endpoint.id)
    XCTAssertEqual(coordinator.endpoints, [])
    XCTAssertNil(coordinator.testStates[endpoint.id])
  }

  /// A failed test reports the message for `AppModel` to surface and leaves `.unreachable` behind.
  func testFailedTestReturnsTheMessageAndRecordsUnreachable() async throws {
    let (coordinator, _) = try makeCoordinator()
    let missing = UUID()

    let message = await coordinator.test(missing)

    let unwrapped = try XCTUnwrap(message)
    XCTAssertEqual(coordinator.testStates[missing], .unreachable(unwrapped))
  }

  // MARK: - Helpers

  /// Port 9 on loopback (discard) is closed on a stock Mac, so a connection test fails quickly
  /// without touching the network.
  private func makeEndpoint(authenticated: Bool = false) -> OutboundProxyEndpoint {
    OutboundProxyEndpoint(
      name: "Endpoint \(UUID().uuidString.prefix(4))",
      kind: .http,
      host: "127.0.0.1",
      port: 9,
      authentication: authenticated ? OutboundProxyAuthentication(username: "user") : nil
    )
  }

  private func makeCoordinator() throws -> (OutboundProxyEndpointsCoordinator, OutboundProxyEndpointStore) {
    let directory = try makeDirectory()
    let store = OutboundProxyEndpointStore(
      manifestURL: directory.appendingPathComponent("outbound-proxies.json"),
      secretStore: InMemorySecretStore()
    )
    return (OutboundProxyEndpointsCoordinator(store: store), store)
  }

  private func makeModel() throws -> (AppModel, RuntimePaths) {
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
    let secrets = InMemorySecretStore()
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClashMaxOutboundEndpointsTests-\(UUID().uuidString)"))
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: secrets),
      outboundProxyEndpointStore: OutboundProxyEndpointStore(
        manifestURL: paths.outboundProxyEndpointManifestURL,
        secretStore: secrets
      ),
      defaults: defaults
    )
    return (model, paths)
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxOutboundEndpointsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}
