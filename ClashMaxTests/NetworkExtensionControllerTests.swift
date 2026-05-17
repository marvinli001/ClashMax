import XCTest
@testable import ClashMax

@MainActor
final class NetworkExtensionControllerTests: XCTestCase {
  func testActivationRequiresApprovalSetsStatusAndRecentError() async {
    let requester = StaticSystemExtensionRequester(activationState: .requiresApproval)
    let proxyManager = RecordingTransparentProxyManager()
    let registrar = RecordingLaunchServicesRegistrar()
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager,
      launchServicesRegistrar: registrar
    )

    await controller.activateSystemExtension()

    XCTAssertEqual(controller.systemExtensionState, .requiresApproval)
    XCTAssertEqual(controller.recentError, "System Extension requires approval in System Settings.")
    XCTAssertEqual(requester.activatedIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(registrar.registerCallCount, 1)
  }

  func testActivationStopsBeforeSystemExtensionRequestWhenLaunchServicesRegistrationFails() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let registrar = RecordingLaunchServicesRegistrar()
    registrar.error = NSError(
      domain: "ClashMax.LaunchServicesRegistration",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Could not refresh LaunchServices registration for /Applications/ClashMax.app."]
    )
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: RecordingTransparentProxyManager(),
      launchServicesRegistrar: registrar
    )

    await controller.activateSystemExtension()

    XCTAssertEqual(
      controller.systemExtensionState,
      .failed("Could not refresh LaunchServices registration for /Applications/ClashMax.app.")
    )
    XCTAssertEqual(controller.recentError, "Could not refresh LaunchServices registration for /Applications/ClashMax.app.")
    XCTAssertEqual(requester.activatedIdentifiers, [])
  }

  func testRefreshMapsAwaitingApprovalSnapshotAndTunnelStatus() async {
    let requester = StaticSystemExtensionRequester(
      snapshots: [
        SystemExtensionSnapshot(
          isEnabled: false,
          isAwaitingUserApproval: true,
          isUninstalling: false
        )
      ]
    )
    let proxyManager = RecordingTransparentProxyManager(currentStatus: .connecting)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )

    await controller.refreshStatus()

    XCTAssertEqual(controller.systemExtensionState, .requiresApproval)
    XCTAssertEqual(controller.vpnStatus, .connecting)
    XCTAssertEqual(proxyManager.statusIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
  }

  func testApprovedSystemExtensionWithNoTunnelConfigurationShowsReadyToStart() async {
    let requester = StaticSystemExtensionRequester(
      snapshots: [
        SystemExtensionSnapshot(
          isEnabled: true,
          isAwaitingUserApproval: false,
          isUninstalling: false
        )
      ]
    )
    let proxyManager = RecordingTransparentProxyManager(currentStatus: .notConfigured)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )

    await controller.refreshStatus()

    XCTAssertEqual(controller.systemExtensionState, .activated)
    XCTAssertEqual(controller.vpnStatus, .notConfigured)
    XCTAssertEqual(controller.vpnStatus.displayName, "Ready to Start")
    XCTAssertEqual(
      controller.tunnelStatusMessage,
      "System Extension is approved. The transparent proxy is not created until Network Extension mode starts."
    )
    XCTAssertNil(controller.recentError)
  }

  func testRefreshPrefersEnabledSnapshotOverOldUninstallingSnapshot() async {
    let requester = StaticSystemExtensionRequester(
      snapshots: [
        SystemExtensionSnapshot(
          isEnabled: false,
          isAwaitingUserApproval: false,
          isUninstalling: true
        ),
        SystemExtensionSnapshot(
          isEnabled: true,
          isAwaitingUserApproval: false,
          isUninstalling: false
        )
      ]
    )
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: RecordingTransparentProxyManager(currentStatus: .notConfigured)
    )

    await controller.refreshStatus()

    XCTAssertEqual(controller.systemExtensionState, .activated)
    XCTAssertEqual(controller.vpnStatus, .notConfigured)
    XCTAssertNil(controller.recentError)
  }

  func testSuccessfulStopClearsPriorRecentError() async throws {
    let requester = StaticSystemExtensionRequester(activationState: .requiresApproval)
    let proxyManager = RecordingTransparentProxyManager(stopStatus: .disconnected)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    await controller.activateSystemExtension()
    XCTAssertEqual(controller.recentError, "System Extension requires approval in System Settings.")

    let status = try await controller.stopTransparentProxy()

    XCTAssertEqual(status, .disconnected)
    XCTAssertNil(controller.recentError)
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
  }

  func testRefreshPrioritizesUninstallingSnapshotOverEnabledState() async {
    let requester = StaticSystemExtensionRequester(
      snapshots: [
        SystemExtensionSnapshot(
          isEnabled: true,
          isAwaitingUserApproval: false,
          isUninstalling: true
        )
      ]
    )
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: RecordingTransparentProxyManager()
    )

    await controller.refreshStatus()

    XCTAssertEqual(
      controller.systemExtensionState,
      .failed("System Extension is uninstalling. Restart macOS before retrying.")
    )
  }

  func testSystemExtensionDelegateStoreRetainsConcurrentDelegatesIndependently() {
    let store = SystemExtensionDelegateStore()
    let first = NSObject()
    let second = NSObject()

    let firstID = store.retain(first)
    let secondID = store.retain(second)

    XCTAssertEqual(store.retainedDelegateCount, 2)
    store.release(firstID)
    XCTAssertEqual(store.retainedDelegateCount, 1)
    store.release(secondID)
    XCTAssertEqual(store.retainedDelegateCount, 0)
  }

  func testRuntimeConfigurationProviderConfigurationExcludesControllerSecret() {
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    XCTAssertEqual(configuration.providerConfiguration["socksHost"] as? String, "127.0.0.1")
    XCTAssertEqual(configuration.providerConfiguration["socksPort"] as? Int, 7890)
    XCTAssertNil(configuration.providerConfiguration["controllerHost"])
    XCTAssertNil(configuration.providerConfiguration["controllerPort"])
    XCTAssertNil(configuration.providerConfiguration["secret"])
  }

  func testNetworkExtensionsSettingsURLTargetsSystemExtensionCategory() {
    let url = NetworkExtensionController.networkExtensionsSettingsURL?.absoluteString

    XCTAssertEqual(
      url,
      "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points=com.apple.system_extension.network_extension.extension-point"
    )
  }

  func testStartActivatesSystemExtensionBeforeSavingTransparentProxyConfiguration() async throws {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let registrar = RecordingLaunchServicesRegistrar()
    var events: [String] = []
    registrar.onRegister = {
      events.append("register")
    }
    proxyManager.onStart = {
      events.append("start")
    }
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager,
      launchServicesRegistrar: registrar
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    try await controller.startTransparentProxy(configuration: configuration)

    XCTAssertEqual(controller.systemExtensionState, .activated)
    XCTAssertEqual(controller.vpnStatus, .connected)
    XCTAssertEqual(requester.activatedIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(proxyManager.legacyCleanupIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(proxyManager.startConfigurations, [configuration])
    XCTAssertEqual(registrar.registerCallCount, 2)
    XCTAssertEqual(events, ["register", "register", "start"])
  }

  func testStartFailsBeforeTunnelSaveWhenLaunchServicesRegistrationFails() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let registrar = RecordingLaunchServicesRegistrar()
    registrar.error = NSError(
      domain: "ClashMax.LaunchServicesRegistration",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Could not refresh LaunchServices registration for /Applications/ClashMax.app."]
    )
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager,
      launchServicesRegistrar: registrar
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    }

    XCTAssertEqual(controller.systemExtensionState, .failed("Could not refresh LaunchServices registration for /Applications/ClashMax.app."))
    XCTAssertEqual(controller.recentError, "Could not refresh LaunchServices registration for /Applications/ClashMax.app.")
    XCTAssertEqual(proxyManager.legacyCleanupIdentifiers, [])
    XCTAssertEqual(proxyManager.startConfigurations, [])
  }

  func testStartFailsBeforeTunnelSaveWhenActivationNeedsApproval() async {
    let requester = StaticSystemExtensionRequester(activationState: .requiresApproval)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    }

    XCTAssertEqual(controller.systemExtensionState, .requiresApproval)
    XCTAssertEqual(proxyManager.legacyCleanupIdentifiers, [])
    XCTAssertEqual(proxyManager.startConfigurations, [])
  }

  func testStartTreatsImmediateDisconnectionAsFailure() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .disconnected)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    }

    XCTAssertEqual(controller.vpnStatus, .disconnected)
    XCTAssertEqual(controller.recentError, "NE transparent proxy disconnected before it became usable.")
  }

  func testStartWaiterIgnoresInitialDisconnectedBeforeConnectingAndConnected() async throws {
    let waiter = NetworkExtensionStartStatusWaiter(timing: NetworkExtensionStartTiming(
      timeoutNanoseconds: 200_000_000,
      disconnectedGraceNanoseconds: 50_000_000,
      pollIntervalNanoseconds: 1_000_000
    ))
    var statuses: [NetworkExtensionTunnelStatus] = [.disconnected, .connecting, .connected]

    let result = try await waiter.wait(
      currentStatus: {
        if statuses.count > 1 {
          return statuses.removeFirst()
        }
        return statuses[0]
      },
      observeStatusChanges: { _ in .none }
    )

    XCTAssertEqual(result, .connected)
  }

  func testStartWaiterTreatsPersistentlyDisconnectedAfterGraceAsFailureStatus() async throws {
    let waiter = NetworkExtensionStartStatusWaiter(timing: NetworkExtensionStartTiming(
      timeoutNanoseconds: 100_000_000,
      disconnectedGraceNanoseconds: 5_000_000,
      pollIntervalNanoseconds: 1_000_000
    ))

    let result = try await waiter.wait(
      currentStatus: { .disconnected },
      observeStatusChanges: { _ in .none }
    )

    XCTAssertEqual(result, .disconnected)
  }

  func testStartWaiterTimesOutWhileStillConnecting() async {
    let waiter = NetworkExtensionStartStatusWaiter(timing: NetworkExtensionStartTiming(
      timeoutNanoseconds: 5_000_000,
      disconnectedGraceNanoseconds: 1_000_000,
      pollIntervalNanoseconds: 1_000_000
    ))

    await XCTAssertThrowsErrorAsync {
      try await waiter.wait(
        currentStatus: { .connecting },
        observeStatusChanges: { _ in .none }
      )
    } handler: { error in
      XCTAssertEqual(error as? NetworkExtensionControllerError, .transparentProxyStartTimedOut(.connecting))
    }
  }

  func testStartUsesLastDisconnectErrorWhenTransparentProxyFails() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .disconnected)
    proxyManager.lastDisconnectErrorMessage = "Provider failed while opening SOCKS5 bridge."
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    }

    XCTAssertEqual(controller.recentError, "Provider failed while opening SOCKS5 bridge.")
  }

  func testStartTreatsConnectingTimeoutAsFailure() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connecting)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    } handler: { error in
      XCTAssertEqual(error as? NetworkExtensionControllerError, .transparentProxyStartTimedOut(.connecting))
    }

    XCTAssertEqual(controller.vpnStatus, .connecting)
    XCTAssertEqual(
      controller.recentError,
      "NE transparent proxy did not become connected before timeout. Last status: Connecting."
    )
  }

  func testStartTreatsReassertingTimeoutAsFailure() async {
    let requester = StaticSystemExtensionRequester(activationState: .activated)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .reasserting)
    let controller = NetworkExtensionController(
      systemExtensionRequester: requester,
      transparentProxyManager: proxyManager
    )
    let configuration = NetworkExtensionRuntimeConfiguration.clashMax(
      overrides: RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startTransparentProxy(configuration: configuration)
    } handler: { error in
      XCTAssertEqual(error as? NetworkExtensionControllerError, .transparentProxyStartTimedOut(.reasserting))
    }

    XCTAssertEqual(controller.vpnStatus, .reasserting)
    XCTAssertEqual(
      controller.recentError,
      "NE transparent proxy did not become connected before timeout. Last status: Reasserting."
    )
  }
}
