import Combine
import XCTest
@testable import ClashMax

@MainActor
final class DashboardRuntimeStateTests: XCTestCase {
  func testNoActiveProfileBlocksDashboard() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore())
    )

    guard case let .blocked(reason) = model.dashboardRuntimeState else {
      XCTFail("Expected dashboard to be blocked without an active profile.")
      return
    }

    XCTAssertTrue(reason.contains("No active profile"))
  }

  func testAddingSubscriptionShowsLoadingUntilRequestFinishes() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let model = AppModel(paths: paths, profileStore: store)
    let recorder = URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseDelay: 0.2
    )
    let session = URLSession(configuration: recorder.configuration)

    let addTask = Task {
      await model.addSubscription(
        name: "Remote",
        urlString: "https://example.com/sub",
        session: session
      )
    }

    for _ in 0..<20 where !model.isAddingSubscription {
      await Task.yield()
    }

    XCTAssertTrue(model.isAddingSubscription)
    XCTAssertTrue(store.profiles.isEmpty)

    let didAdd = await addTask.value
    XCTAssertTrue(didAdd)
    XCTAssertFalse(model.isAddingSubscription)
    XCTAssertEqual(store.profiles.count, 1)
  }

  func testDeletingActiveProfilePublishesStatusMessage() throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    model.deleteProfile(profile)

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertNil(store.activeProfileID)
    XCTAssertEqual(model.profileOperationMessage, "Deleted profile profile.")
  }

  func testProxyGroupsUnavailableMessageExplainsRuntimeLoadingBeforeStart() throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    XCTAssertEqual(
      model.proxyGroupsUnavailableMessage,
      "Start the active profile to load proxy groups from Mihomo. Subscription protocols are parsed by the core at launch."
    )
  }

  func testStartInFlightTakesPriorityOverStoppedTunPath() {
    XCTAssertEqual(
      DashboardRuntimeState.resolve(
        startInFlight: true,
        tunnelCoreRunning: false,
        coreStatus: .stopped,
        readinessIssue: nil
      ),
      .starting
    )
  }

  func testStartDefersPublishedStateChangesUntilNextActorTurn() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try store.importLocalConfig(from: configURL)
    try "mixed-port: 7890\nrules: []\n"
      .write(to: URL(fileURLWithPath: profile.originalConfigPath), atomically: true, encoding: .utf8)
    let model = AppModel(paths: paths, profileStore: store)

    model.start()

    XCTAssertFalse(model.startInFlight)
    XCTAssertNil(model.lastError)

    for _ in 0..<20 where model.lastError == nil {
      await Task.yield()
    }

    XCTAssertFalse(model.startInFlight)
    XCTAssertEqual(model.lastError, "Profile must include at least one proxy or proxy provider.")
  }

  func testSettingCurrentModeDoesNotPublishChanges() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore())
    )
    var changeCount = 0
    let cancellable = model.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    model.setMode(model.overrides.mode)

    XCTAssertEqual(changeCount, 0)
  }

  func testRequestingModeDefersPublishedChangesUntilNextActorTurn() async throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore())
    )
    var changeCount = 0
    let cancellable = model.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    model.requestMode(.global)

    XCTAssertEqual(model.overrides.mode, .rule)
    XCTAssertEqual(changeCount, 0)

    for _ in 0..<20 where model.overrides.mode != .global {
      await Task.yield()
    }

    XCTAssertEqual(model.overrides.mode, .global)
    XCTAssertGreaterThan(changeCount, 0)
  }

  func testRunningCoversUserModeAndTunnelCore() {
    XCTAssertEqual(
      DashboardRuntimeState.resolve(
        startInFlight: false,
        tunnelCoreRunning: false,
        coreStatus: .running(version: "v-test"),
        readinessIssue: nil
      ),
      .running
    )
    XCTAssertEqual(
      DashboardRuntimeState.resolve(
        startInFlight: false,
        tunnelCoreRunning: true,
        coreStatus: .stopped,
        readinessIssue: nil
      ),
      .running
    )
  }

  func testCrashedStatePrecedesBlockedState() {
    XCTAssertEqual(
      DashboardRuntimeState.resolve(
        startInFlight: false,
        tunnelCoreRunning: false,
        coreStatus: .crashed(message: "boom"),
        readinessIssue: "No active profile selected."
      ),
      .crashed(message: "boom")
    )
  }

  func testLaunchVisualShrinksForShortWindows() {
    XCTAssertLessThanOrEqual(
      DashboardLayoutMetrics.launchVisualSideLength(
        availableWidth: 840,
        availableHeight: 520
      ),
      140
    )
  }

  func testLaunchVisualUsesMoreSpaceInLargeWindows() {
    let length = DashboardLayoutMetrics.launchVisualSideLength(
      availableWidth: 1180,
      availableHeight: 760
    )

    XCTAssertGreaterThanOrEqual(length, 180)
    XCTAssertLessThanOrEqual(length, 220)
  }

  func testPowerButtonRiveAssetIsBundled() {
    XCTAssertNotNil(
      Bundle.main.url(
        forResource: DashboardPowerButtonAsset.fileName,
        withExtension: DashboardPowerButtonAsset.fileExtension,
        subdirectory: DashboardPowerButtonAsset.bundleSubdirectory
      )
    )
  }

  func testHomeBackgroundUsesSingleSystemFillAcrossStates() {
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .blocked(reason: "No profile")), "system-window")
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .running), "system-window")
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .crashed(message: "boom")), "system-window")
  }

  func testPowerButtonSurfaceAdaptsToColorScheme() {
    XCTAssertNotEqual(
      DashboardPowerButtonSurfaceStyle.surfaceID(for: .light),
      DashboardPowerButtonSurfaceStyle.surfaceID(for: .dark)
    )
  }

  private static func makeRuntimePaths() throws -> RuntimePaths {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxDashboardTests-\(UUID().uuidString)", isDirectory: true)
    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    for directory in [paths.appSupport, paths.profiles, paths.runtime, paths.subscriptions, paths.logs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return paths
  }
}
