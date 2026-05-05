import Combine
import RiveRuntime
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

  func testRenamingSpecificProfileDoesNotChangeActiveSelection() throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let firstProfile = try store.importLocalConfig(from: configURL)
    let secondProfile = try store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    model.renameProfile(firstProfile, to: "Office")

    XCTAssertEqual(store.profiles.first(where: { $0.id == firstProfile.id })?.name, "Office")
    XCTAssertEqual(store.activeProfileID, secondProfile.id)
    XCTAssertEqual(model.profileOperationMessage, "Renamed profile to Office.")
  }

  func testUpdatingSpecificSubscriptionTracksRowAndRefreshesConfig() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let initialSession = URLSession(
      configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n")
    )
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: initialSession
    )
    let model = AppModel(paths: paths, profileStore: store)
    let recorder = URLProtocolRecorder(
      responseBody: "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseDelay: 0.2
    )
    let updateSession = URLSession(configuration: recorder.configuration)

    let updateTask = Task {
      await model.updateSubscription(profile, session: updateSession)
    }

    for _ in 0..<20 where !model.updatingProfileIDs.contains(profile.id) {
      await Task.yield()
    }

    XCTAssertTrue(model.updatingProfileIDs.contains(profile.id))

    let didUpdate = await updateTask.value

    XCTAssertTrue(didUpdate)
    XCTAssertFalse(model.updatingProfileIDs.contains(profile.id))
    XCTAssertEqual(
      try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8),
      "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n"
    )
    XCTAssertEqual(recorder.lastRequest?.url?.absoluteString, "https://example.com/sub")
    XCTAssertEqual(model.profileOperationMessage, "Updated subscription Remote.")
  }

  func testProxyGroupsUnavailableMessageExplainsMissingProfileGroupsBeforeStart() throws {
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
      "No proxy groups were found in the active profile. Start it to let Mihomo parse provider subscriptions."
    )
  }

  func testStoppedProfileShowsLocalProxyPreview() throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - { name: '[Hy2]HK Hysteria', type: hysteria2, server: example.com, port: 443, password: password }
      - { name: '[vless]JP Nano', type: vless, server: example.net, port: 443, uuid: 00000000-0000-0000-0000-000000000000 }
    proxy-groups:
      - { name: Elite, type: select, proxies: ['[Hy2]HK Hysteria', '[vless]JP Nano', DIRECT] }
    rules:
      - MATCH,Elite
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    XCTAssertEqual(model.visibleProxyGroups.map(\.name), ["Elite"])
    XCTAssertEqual(model.visibleProxyGroups.first?.nodes.map(\.type), ["hysteria2", "vless", "direct"])
  }

  func testStoppedProxySelectionPersistsAsPreviewWhileDelayRequiresRuntime() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - { name: Japan, type: vless, server: example.net, port: 443, uuid: 00000000-0000-0000-0000-000000000000 }
    proxy-groups:
      - { name: Elite, type: select, proxies: [Japan, DIRECT] }
    rules:
      - MATCH,Elite
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let defaults = UserDefaults(suiteName: "ClashMaxPreviewTests-\(UUID().uuidString)")!
    let model = AppModel(paths: paths, profileStore: store, defaults: defaults)
    let group = try XCTUnwrap(model.visibleProxyGroups.first)
    let node = try XCTUnwrap(group.nodes.first)

    model.selectProxy(group: group, node: node)

    XCTAssertNil(model.lastError)
    XCTAssertEqual(model.previewSelections[group.name], node.name)

    model.testDelay(for: node)

    XCTAssertEqual(model.lastError, "Start the core before selecting proxies or testing delay.")
  }

  func testProxyPageActionsAreDisabledWhileRuntimeIsStarting() {
    XCTAssertFalse(
      ProxiesPageActionState.canStart(
        isRunning: false,
        hasActiveProfile: true,
        isStarting: true,
        readinessIssue: nil
      )
    )
    XCTAssertFalse(ProxiesPageActionState.canRefresh(isStarting: true))
  }

  func testDashboardProxySelectionUsesPreferredGroupAndSelectedNode() throws {
    let groups = [
      ProxyGroup(
        name: "General",
        type: "Selector",
        selected: "Singapore",
        nodes: [
          ProxyNode(name: "Singapore", type: "proxy", delay: 82, isSelectable: true),
          ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: false)
        ]
      ),
      ProxyGroup(
        name: "Streaming",
        type: "Selector",
        selected: "Japan",
        nodes: [
          ProxyNode(name: "Japan", type: "hysteria2", delay: 157, isSelectable: true),
          ProxyNode(name: "Hong Kong", type: "vless", delay: 64, isSelectable: true)
        ]
      )
    ]

    let group = try XCTUnwrap(DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: "Streaming"))
    let node = try XCTUnwrap(DashboardProxySelectionState.currentNode(in: group))

    XCTAssertEqual(group.name, "Streaming")
    XCTAssertEqual(node.name, "Japan")
    XCTAssertEqual(DashboardProxySelectionState.delayLabel(for: node), "157 ms")
  }

  func testDashboardProxySelectionFallsBackToFirstSelectableGroup() throws {
    let groups = [
      ProxyGroup(
        name: "Provider Only",
        type: "Provider",
        selected: nil,
        nodes: []
      ),
      ProxyGroup(
        name: "Elite",
        type: "Selector",
        selected: nil,
        nodes: [
          ProxyNode(name: "Tokyo", type: "vless", delay: nil, isSelectable: true)
        ]
      )
    ]

    let group = try XCTUnwrap(DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: "Missing"))
    let node = try XCTUnwrap(DashboardProxySelectionState.currentNode(in: group))

    XCTAssertEqual(group.name, "Elite")
    XCTAssertEqual(node.name, "Tokyo")
    XCTAssertEqual(DashboardProxySelectionState.delayLabel(for: node), "No delay")
  }

  func testRunningWithoutRuntimeProxyGroupsDoesNotFallBackToStoppedPreview() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - { name: Japan, type: vless, server: example.net, port: 443, uuid: 00000000-0000-0000-0000-000000000000 }
    proxy-groups:
      - { name: Elite, type: select, proxies: [Japan, DIRECT] }
    rules:
      - MATCH,Elite
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
    )
    let model = AppModel(paths: paths, profileStore: store, coreController: controller)

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(model.visibleProxyGroups, [])
  }

  func testDelayResultRemainsVisibleWhenReloadedProxyGroupsDoNotIncludeHistory() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try "proxies:\n  - { name: Japan, type: vless }\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
    )
    let group = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResult: 73
    )
    let model = AppModel(paths: paths, profileStore: store, coreController: controller, apiClient: client)
    model.proxyGroups = [group]

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.testDelay(for: group.nodes[0])

    for _ in 0..<20 where await client.delayRequestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<20 where model.proxyGroups.first?.nodes.first?.delay != 73 {
      await Task.yield()
    }

    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(delayRequestCount, 1)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
  }

  func testUpdatingSubscriptionRefreshesStoppedProxyPreview() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("""
    proxies:
      - { name: Old Node, type: vless, server: old.example, port: 443, uuid: 00000000-0000-0000-0000-000000000000 }
    proxy-groups:
      - { name: Old, type: select, proxies: [Old Node, DIRECT] }
    rules:
      - MATCH,Old
    """))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: initialSession
    )
    let model = AppModel(paths: paths, profileStore: store)

    let updateSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("""
    proxies:
      - { name: New Node, type: hysteria2, server: new.example, port: 443, password: password }
    proxy-groups:
      - { name: New, type: select, proxies: [New Node, DIRECT] }
    rules:
      - MATCH,New
    """))
    await model.updateSubscription(profile, session: updateSession)

    XCTAssertEqual(model.visibleProxyGroups.map(\.name), ["New"])
    XCTAssertEqual(model.visibleProxyGroups.first?.nodes.map(\.type), ["hysteria2", "direct"])
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

  func testLaunchTitleForReadyStateOmitsAppName() {
    XCTAssertEqual(DashboardRuntimeState.stopped.launchTitle, "Ready")
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

  func testStartAppliesSelectedSystemProxyRoutingMode() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner)
    )

    model.start()

    for _ in 0..<40 where !model.isRunning || !model.systemProxyEnabled {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
  }

  func testSelectingProfileWhileRunningRestartsRuntimeWithNewProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: firstConfigURL)
    let secondProfile = try store.importLocalConfig(from: secondConfigURL)
    try store.select(store.profiles[0])
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs()))
    )

    model.start()
    for _ in 0..<40 where launcher.launchCount < 1 {
      await Task.yield()
    }

    model.selectProfile(secondProfile)

    for _ in 0..<60 where launcher.launchCount < 2 {
      await Task.yield()
    }

    XCTAssertEqual(store.activeProfileID, secondProfile.id)
    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertTrue(launcher.launchedConfigPaths.last?.contains(secondProfile.id.uuidString) == true)
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
    let activeLength = DashboardLayoutMetrics.launchVisualSideLength(
      availableWidth: 1180,
      availableHeight: 760,
      isVisualActive: true
    )
    let restingLength = DashboardLayoutMetrics.launchVisualSideLength(
      availableWidth: 1180,
      availableHeight: 760
    )

    XCTAssertGreaterThanOrEqual(activeLength, 180)
    XCTAssertLessThanOrEqual(activeLength, 220)
    XCTAssertLessThan(restingLength, activeLength)
    XCTAssertGreaterThanOrEqual(restingLength, 68)
  }

  func testPowerButtonRiveAssetIsBundled() {
    XCTAssertEqual(DashboardPowerButtonAsset.fileName, "2773-5719-egg-radio-button-v2")
    XCTAssertNotNil(
      Bundle.main.url(
        forResource: DashboardPowerButtonAsset.fileName,
        withExtension: DashboardPowerButtonAsset.fileExtension,
        subdirectory: DashboardPowerButtonAsset.bundleSubdirectory
      )
    )
  }

  func testPowerButtonRiveStateMachineInputsAreAvailable() throws {
    XCTAssertEqual(DashboardPowerButtonAsset.stateMachineName, "Radiobutton")
    XCTAssertEqual(DashboardPowerButtonAsset.hoverInputName, "isHover")
    XCTAssertEqual(DashboardPowerButtonAsset.pressedInputName, "Pressed")
    XCTAssertEqual(DashboardPowerButtonAsset.backInputName, "Back")

    let url = try XCTUnwrap(DashboardPowerButtonAsset.bundleURL())
    let data = try Data(contentsOf: url)
    let file = try RiveFile(data: data, loadCdn: false)
    let artboard = try file.artboard()
    let stateMachine = try artboard.stateMachine(fromName: DashboardPowerButtonAsset.stateMachineName)
    let inputNames = stateMachine.inputNames()

    XCTAssertTrue(inputNames.contains(DashboardPowerButtonAsset.hoverInputName))
    XCTAssertTrue(inputNames.contains(DashboardPowerButtonAsset.pressedInputName))
    XCTAssertTrue(inputNames.contains(DashboardPowerButtonAsset.backInputName))
  }

  func testPowerButtonRivePressedTransitionIsNotMaskedByIdleState() throws {
    try withPowerButtonStateMachine { stateMachine in
      XCTAssertTrue(stateMachine.advance(by: 0))
      XCTAssertEqual(stateMachine.stateChanges(), ["Idle"])

      stateMachine.getTrigger(DashboardPowerButtonAsset.pressedInputName).fire()

      XCTAssertTrue(stateMachine.advance(by: 0))
      XCTAssertEqual(stateMachine.stateChanges(), ["Pressed"])
    }
  }

  func testPowerButtonRiveHoverCanMaskPressedWhenAdvancedInSameFrame() throws {
    try withPowerButtonStateMachine { stateMachine in
      XCTAssertTrue(stateMachine.advance(by: 0))
      XCTAssertEqual(stateMachine.stateChanges(), ["Idle"])

      stateMachine.getBool(DashboardPowerButtonAsset.hoverInputName).setValue(true)
      stateMachine.getTrigger(DashboardPowerButtonAsset.pressedInputName).fire()

      XCTAssertTrue(stateMachine.advance(by: 0))
      XCTAssertEqual(stateMachine.stateChanges(), ["Hover"])
    }
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

  func testDashboardCardSurfaceAdaptsToColorScheme() {
    XCTAssertEqual(DashboardCardSurfaceStyle.surfaceID(for: .light), "light-flat-dashboard-card")
    XCTAssertNotEqual(
      DashboardCardSurfaceStyle.shadowOpacity(for: .light),
      DashboardCardSurfaceStyle.shadowOpacity(for: .dark)
    )
  }

  func testNetworkErrorsAreSummarizedForStatusSurfaces() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCannotConnectToHost,
      userInfo: [
        NSLocalizedDescriptionKey: "Could not connect to the server.",
        NSURLErrorFailingURLErrorKey: URL(string: "http://127.0.0.1:9097/version")!
      ]
    )

    XCTAssertEqual(
      UserFacingError.message(for: error),
      "Could not connect to the Mihomo controller at 127.0.0.1:9097. The core may still be starting or failed to open its controller port."
    )
  }

  func testHelperCodesigningErrorsAreSummarizedForTunRecovery() {
    let error = NSError(
      domain: "SMAppServiceErrorDomain",
      code: 3,
      userInfo: [
        NSLocalizedDescriptionKey: "Codesigning failure loading plist: io.github.clashmax.ClashMax.Helper.plist code: -67056"
      ]
    )

    XCTAssertEqual(
      UserFacingError.message(for: error),
      "TUN helper could not be registered because ClashMax or its helper is not code signed. Build and run with local code signing enabled, or switch Proxy Routing to System Proxy."
    )
  }

  private func withPowerButtonStateMachine(_ body: (RiveStateMachineInstance) throws -> Void) throws {
    let url = try XCTUnwrap(DashboardPowerButtonAsset.bundleURL())
    let data = try Data(contentsOf: url)
    let file = try RiveFile(data: data, loadCdn: false)
    let artboard = try file.artboard()
    let stateMachine = try artboard.stateMachine(fromName: DashboardPowerButtonAsset.stateMachineName)
    try body(stateMachine)
  }

  private static func writeProxyConfig(named proxyName: String, to url: URL) throws {
    try """
    proxies:
      - { name: \(proxyName), type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [\(proxyName), DIRECT] }
    rules:
      - MATCH,Proxy
    """.write(to: url, atomically: true, encoding: .utf8)
  }

  private static func defaultNetworkSetupOutputs() -> [String: String] {
    [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n"
    ]
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

private actor RecordingMihomoController: MihomoAPIControlling {
  private let proxyGroupsResponse: [ProxyGroup]
  private let testDelayResult: Int
  private var delayRequests: [String] = []

  init(proxyGroupsResponse: [ProxyGroup], testDelayResult: Int) {
    self.proxyGroupsResponse = proxyGroupsResponse
    self.testDelayResult = testDelayResult
  }

  func updateMode(_ mode: RunMode) async throws {}

  func proxyGroups() async throws -> [ProxyGroup] {
    proxyGroupsResponse
  }

  func rules() async throws -> [String] {
    []
  }

  func connections() async throws -> [ConnectionSnapshot] {
    []
  }

  func selectProxy(group: String, proxy: String) async throws {}

  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int {
    delayRequests.append(proxy)
    return testDelayResult
  }

  nonisolated func trafficStream() -> AsyncThrowingStream<TrafficSample, Error> {
    AsyncThrowingStream { _ in }
  }

  nonisolated func logStream(level: String) -> AsyncThrowingStream<LogEntry, Error> {
    AsyncThrowingStream { _ in }
  }

  nonisolated func connectionStream(interval: Int) -> AsyncThrowingStream<[ConnectionSnapshot], Error> {
    AsyncThrowingStream { _ in }
  }

  func delayRequestCount() -> Int {
    delayRequests.count
  }
}

@MainActor
private final class CountingProcessLauncher: CoreProcessLaunching {
  private(set) var launchCount = 0
  private(set) var launchedConfigPaths: [String] = []

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    launchCount += 1
    if let configFlagIndex = arguments.firstIndex(of: "-f"),
       arguments.indices.contains(configFlagIndex + 1) {
      launchedConfigPaths.append(arguments[configFlagIndex + 1])
    }
    return FakeRunningProcess(processIdentifier: Int32(1000 + launchCount))
  }
}
