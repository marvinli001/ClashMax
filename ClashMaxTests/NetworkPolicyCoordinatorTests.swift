@testable import ClashMax
import XCTest

/// Pins what moved out of `AppModel` into `NetworkPolicyCoordinator` (roadmap D1): the `AppModel`
/// members are now computed facades, and a view reading one must still be invalidated when the
/// coordinator changes. Nothing fails to compile when that relay breaks, so it is asserted here,
/// along with the debounce and the guards that moved with the apply/restore tasks.
@MainActor
final class NetworkPolicyCoordinatorTests: XCTestCase {
  func testAppModelFacadesInvalidateWhenTheCoordinatorChanges() async throws {
    let rule = NetworkPolicyRule(name: "Office", ssid: "CorpNet", proxyRoutingMode: .systemProxy, enableSystemProxy: false)
    let model = try makeModel(provider: CountingNetworkProvider(ssid: "corpnet"))
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: false)
    let networkCounter = ObservationChangeCounter { _ = model.currentNetwork }
    let ssidCounter = ObservationChangeCounter { _ = model.currentNetworkSSID }
    let statusCounter = ObservationChangeCounter { _ = model.networkPolicyStatusMessage }
    let appliedCounter = ObservationChangeCounter { _ = model.lastAppliedNetworkPolicyID }

    model.networkPolicy.refreshCurrentNetworkPolicyState()

    XCTAssertEqual(networkCounter.count, 1)
    XCTAssertEqual(ssidCounter.count, 1)
    XCTAssertEqual(statusCounter.count, 1)
    XCTAssertEqual(appliedCounter.count, 0)
    XCTAssertEqual(model.currentNetworkSSID, "corpnet")

    let outcome = await model.networkPolicy.applyMatchingNetworkPolicyForCurrentNetworkAndWait()

    XCTAssertEqual(outcome, .applied("Applied Office for corpnet."))
    XCTAssertEqual(appliedCounter.count, 1)
    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertEqual(model.networkPolicyStatusMessage, "Applied Office for corpnet.")
  }

  /// A burst of path/SSID notifications must collapse into one match-and-apply, or a single Wi-Fi
  /// hop would flip the routing mode several times.
  func testEnvironmentChangesAreDebouncedIntoOneApply() async throws {
    let provider = CountingNetworkProvider(ssid: "corpnet")
    let fixture = try makeCoordinator(provider: provider, rules: [officeRule()])

    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "ssid")
    XCTAssertEqual(provider.reads, 0, "nothing is matched before the debounce elapses")

    await waitUntil { fixture.recorder.routingModes.count == 1 }
    await settle(0.8)

    XCTAssertEqual(provider.reads, 1)
    XCTAssertEqual(fixture.recorder.routingModes.map(\.mode), [.tun])
    XCTAssertEqual(fixture.recorder.routingModes.first?.preserveRestoreSnapshot, true, "an automatic apply keeps the restore snapshot")
  }

  func testStoppingMonitoringCancelsAPendingDebouncedApply() async throws {
    let provider = CountingNetworkProvider(ssid: "corpnet")
    let fixture = try makeCoordinator(provider: provider, rules: [officeRule()])

    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    fixture.coordinator.stopNetworkEnvironmentMonitoring()
    await settle(0.9)

    XCTAssertEqual(provider.reads, 0)
    XCTAssertTrue(fixture.recorder.routingModes.isEmpty)
  }

  /// The fake-ip staleness stamp is recorded on every environment event, before the auto-apply
  /// gate that returns early when auto-apply is off (roadmap A3).
  func testMonitorEventStampsTheNetworkChangeEvenWhenAutoApplyIsOff() async throws {
    let monitor = CountingEnvironmentMonitor()
    let fixture = try makeCoordinator(
      provider: CountingNetworkProvider(ssid: "corpnet"),
      monitor: monitor,
      rules: [officeRule()],
      autoApplyEnabled: false
    )

    fixture.coordinator.startNetworkEnvironmentMonitoring()
    fixture.coordinator.startNetworkEnvironmentMonitoring()
    XCTAssertEqual(monitor.starts, 1, "monitoring is started once however often it is asked for")

    monitor.emit(NetworkEnvironmentEvent(reason: "path", ssid: "corpnet", pathStatus: "satisfied", isExpensive: false, isConstrained: false))
    await waitUntil { fixture.recorder.networkChanges == 1 }

    XCTAssertEqual(fixture.recorder.networkChanges, 1)
    XCTAssertEqual(fixture.coordinator.currentNetwork.ssid, "corpnet")
    XCTAssertEqual(fixture.coordinator.networkPolicyStatusMessage, "Automatic network policy application is off.")
    fixture.coordinator.stopNetworkEnvironmentMonitoring()
  }

  /// Only the first automatic apply captures what to restore: a second matched network must not
  /// overwrite the state from before any policy ran, or leaving it would restore the policy's own
  /// routing instead of the user's.
  func testRestoreSnapshotIsCapturedOnlyByTheFirstAutomaticApply() async throws {
    let provider = CountingNetworkProvider(ssid: "corpnet")
    let office = officeRule()
    let lab = NetworkPolicyRule(name: "Lab", ssid: "LabNet", proxyRoutingMode: .neProxy, enableSystemProxy: false)
    let fixture = try makeCoordinator(provider: provider, rules: [office, lab])
    fixture.recorder.proxyRoutingMode = .systemProxy

    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    await waitUntil { fixture.coordinator.lastAppliedNetworkPolicyID == office.id }
    provider.ssid = "labnet"
    fixture.coordinator.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    await waitUntil { fixture.coordinator.lastAppliedNetworkPolicyID == lab.id }

    let snapshot = try XCTUnwrap(fixture.coordinator.networkPolicyRestoreSnapshot)
    XCTAssertEqual(snapshot.policyID, office.id)
    XCTAssertEqual(snapshot.ssid, "corpnet")
    XCTAssertEqual(snapshot.proxyRoutingMode, .systemProxy)

    fixture.coordinator.applyNetworkPolicy(lab)
    XCTAssertNil(fixture.coordinator.networkPolicyRestoreSnapshot, "a manual apply is a user change and drops the snapshot")
  }

  /// A newer apply supersedes one still in flight; the token guard keeps the older task from
  /// clearing the newer one's handle, and the older one reports `.cancelled` rather than applied.
  func testSupersededApplyReportsCancelled() async throws {
    let provider = CountingNetworkProvider(ssid: "corpnet")
    let rule = NetworkPolicyRule(name: "Office", ssid: "CorpNet", proxyRoutingMode: .tun, enableSystemProxy: false, autoStartRuntime: true)
    let fixture = try makeCoordinator(provider: provider, rules: [rule])
    fixture.recorder.firstStartDelay = 0.3

    let first = Task { await fixture.coordinator.applyMatchingNetworkPolicyForCurrentNetworkAndWait() }
    await waitUntil { fixture.recorder.starts == 1 }
    let second = await fixture.coordinator.applyMatchingNetworkPolicyForCurrentNetworkAndWait()
    let firstOutcome = await first.value

    XCTAssertEqual(firstOutcome, .cancelled)
    XCTAssertEqual(second, .applied("Applied Office for corpnet."))
    XCTAssertEqual(fixture.coordinator.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertEqual(fixture.recorder.starts, 2)
  }

  // MARK: - Helpers

  private func officeRule() -> NetworkPolicyRule {
    NetworkPolicyRule(name: "Office", ssid: "CorpNet", proxyRoutingMode: .tun, enableSystemProxy: false)
  }

  private struct Fixture {
    let coordinator: NetworkPolicyCoordinator
    let recorder: RuntimeHookRecorder
  }

  private func makeCoordinator(
    provider: CountingNetworkProvider,
    monitor: CountingEnvironmentMonitor? = nil,
    rules: [NetworkPolicyRule],
    autoApplyEnabled: Bool = true
  ) throws -> Fixture {
    let settings = try PersistedSettingsStore(defaults: makeDefaults())
    settings.networkPolicySettings = NetworkPolicySettings(rules: rules, autoApplyEnabled: autoApplyEnabled)
    let coordinator = NetworkPolicyCoordinator(
      settings: settings,
      currentNetworkProvider: provider,
      networkEnvironmentMonitor: monitor ?? CountingEnvironmentMonitor(),
      wiFiLocationAuthorization: nil
    )
    let recorder = RuntimeHookRecorder()
    coordinator.configureRuntimeHooks(
      isRunning: { false },
      startInFlight: { false },
      canStopRuntime: { false },
      proxyRoutingMode: { recorder.proxyRoutingMode },
      systemProxyEnabled: { false },
      setProxyRoutingMode: { mode, preserve in
        recorder.routingModes.append((mode, preserve))
        recorder.proxyRoutingMode = mode
      },
      startRuntimeAndWait: {
        recorder.starts += 1
        if recorder.starts == 1, recorder.firstStartDelay > 0 {
          try? await Task.sleep(nanoseconds: UInt64(recorder.firstStartDelay * 1_000_000_000))
        }
      },
      applySystemProxyEnabledState: { _ in },
      stopRuntime: { NetworkPolicyRuntimeStopResult(succeeded: true) },
      setLastError: { _ in },
      publishNotice: { _ in },
      publishWarningNotice: { _ in },
      appendAppLog: { _, _ in },
      recordNetworkEnvironmentChange: { recorder.networkChanges += 1 }
    )
    return Fixture(coordinator: coordinator, recorder: recorder)
  }

  private func makeModel(provider: CountingNetworkProvider) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxNetworkPolicyTests-\(UUID().uuidString)", isDirectory: true)
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
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: makeDefaults(),
      currentNetworkProvider: provider,
      networkEnvironmentMonitor: CountingEnvironmentMonitor()
    )
  }

  private func makeDefaults() throws -> UserDefaults {
    try XCTUnwrap(UserDefaults(suiteName: "ClashMaxNetworkPolicyTests-\(UUID().uuidString)"))
  }

  private func waitUntil(_ isSatisfied: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSatisfied(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// Gives a debounced apply time to fire when the assertion is that it did not (or not again).
  private func settle(_ duration: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
  }
}

@MainActor
private final class RuntimeHookRecorder {
  var proxyRoutingMode: ProxyRoutingMode = .systemProxy
  var routingModes: [(mode: ProxyRoutingMode, preserveRestoreSnapshot: Bool)] = []
  var starts = 0
  var firstStartDelay: TimeInterval = 0
  var networkChanges = 0
}

private final class CountingNetworkProvider: CurrentNetworkProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var currentSSID: String?
  private var readCount = 0

  init(ssid: String?) {
    currentSSID = ssid
  }

  var ssid: String? {
    get { lock.withLock { currentSSID } }
    set { lock.withLock { currentSSID = newValue } }
  }

  var reads: Int {
    lock.withLock { readCount }
  }

  func currentNetwork() -> WiFiNetworkSnapshot {
    lock.withLock {
      readCount += 1
      return currentSSID.map(WiFiNetworkSnapshot.joined) ?? .unavailable(.notAssociated)
    }
  }
}

private final class CountingEnvironmentMonitor: NetworkEnvironmentMonitoring, @unchecked Sendable {
  private let stream: AsyncStream<NetworkEnvironmentEvent>
  private let continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation
  private(set) var starts = 0

  init() {
    var continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation!
    stream = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  var events: AsyncStream<NetworkEnvironmentEvent> {
    stream
  }

  func start() {
    starts += 1
  }

  func stop() {
    continuation.finish()
  }

  func emit(_ event: NetworkEnvironmentEvent) {
    continuation.yield(event)
  }
}
