import AppKit
import Combine
import ServiceManagement
import SwiftUI
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

  func testEarlyRuntimeAPIClientDoesNotEnableDelayBeforeCoreIsRunning() async throws {
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
    let group = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 73)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertFalse(model.canControlRuntimeProxies)

    model.testDelay(for: group.nodes[0])

    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(model.lastError, "Start the core before selecting proxies or testing delay.")
    XCTAssertEqual(delayRequestCount, 0)
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

  func testDeveloperModeDefaultsOffAndPersists() throws {
    let paths = try Self.makeRuntimePaths()
    let suiteName = "ClashMaxDeveloperModeTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let firstModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertFalse(firstModel.developerMode)

    firstModel.developerMode = true

    let secondModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertTrue(secondModel.developerMode)
  }

  func testAppThemeDefaultsToSystemAndPersists() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let firstModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(firstModel.appTheme, .system)

    firstModel.appTheme = .dark

    let secondModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(secondModel.appTheme, .dark)
  }

  func testAppThemeMapsToSwiftUIColorSchemeAndAppKitAppearance() {
    XCTAssertNil(AppTheme.system.preferredColorScheme)
    XCTAssertNil(AppTheme.system.nsAppearanceName)

    XCTAssertEqual(AppTheme.light.preferredColorScheme, .light)
    XCTAssertEqual(AppTheme.light.nsAppearanceName, .aqua)

    XCTAssertEqual(AppTheme.dark.preferredColorScheme, .dark)
    XCTAssertEqual(AppTheme.dark.nsAppearanceName, .darkAqua)
  }

  func testExternalControllerSettingsPersistButRegeneratesRuntimeSecret() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let firstModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )
    let settings = ExternalControllerSettings(
      enabled: false,
      host: "localhost",
      port: 19197,
      secret: "saved-secret",
      cors: ExternalControllerCORSSettings(
        enabled: true,
        allowPrivateNetwork: false,
        allowedOrigins: ["https://yacd.metacubex.one"]
      )
    )

    firstModel.externalControllerSettings = settings

    XCTAssertEqual(firstModel.overrides.externalControllerHost, "localhost")
    XCTAssertEqual(firstModel.overrides.externalControllerPort, 19197)
    XCTAssertEqual(firstModel.overrides.secret, "saved-secret")
    XCTAssertFalse(firstModel.overrides.externalControllerCORS.enabled)

    let secondModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(secondModel.externalControllerSettings.enabled, settings.enabled)
    XCTAssertEqual(secondModel.externalControllerSettings.host, settings.host)
    XCTAssertEqual(secondModel.externalControllerSettings.port, settings.port)
    XCTAssertEqual(secondModel.externalControllerSettings.cors, settings.cors)
    XCTAssertNotEqual(secondModel.externalControllerSettings.secret, settings.secret)
    XCTAssertEqual(secondModel.overrides.externalControllerHost, "localhost")
    XCTAssertEqual(secondModel.overrides.externalControllerPort, 19197)
    XCTAssertNotEqual(secondModel.overrides.secret, "saved-secret")
    XCTAssertFalse(secondModel.overrides.secret.isEmpty)
    XCTAssertFalse(secondModel.overrides.externalControllerCORS.enabled)
  }

  func testLaunchSettingsUseMainAppLoginServiceAndPersistSilentStart() async throws {
    let paths = try Self.makeRuntimePaths()
    let suiteName = "ClashMaxLaunchSettingsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let service = FakeLoginItemService(status: .notRegistered)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      loginItemService: service,
      defaults: defaults
    )

    XCTAssertFalse(model.launchSettings.launchAtLogin)

    await model.updateLaunchAtLogin(true)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertTrue(model.launchSettings.launchAtLogin)

    model.setSilentStart(true)
    XCTAssertTrue(model.launchSettings.silentStart)

    model.openLoginItemsSettings()
    XCTAssertEqual(service.openSettingsCount, 1)

    let reloaded = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      loginItemService: FakeLoginItemService(status: .enabled),
      defaults: defaults
    )
    XCTAssertTrue(reloaded.launchSettings.silentStart)
  }

  func testLaunchAtLoginToggleReportsRegistrationErrors() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = FakeLoginItemService(
      status: .notRegistered,
      registerError: NSError(
        domain: "ClashMaxTests.LoginItem",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "registration denied"]
      )
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      loginItemService: service,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.setLaunchAtLogin(true)

    for _ in 0..<50 where model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(model.lastError, "registration denied")
    XCTAssertFalse(model.launchSettings.launchAtLogin)
  }

  func testSystemProxySettingsNormalizeUnspecifiedHostBeforeApplyingProxy() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults
    )
    var settings = SystemProxySettings.default
    settings.proxyHost = "0.0.0.0"
    settings.useDefaultBypass = false
    settings.customBypassDomains = ["localhost", "*.corp"]
    settings.guardEnabled = true
    settings.guardIntervalSeconds = 5

    XCTAssertEqual(settings.normalizedProxyHost, "127.0.0.1")
    XCTAssertTrue(model.updateSystemProxySettings(settings))
    model.setSystemProxyEnabled(true)

    for _ in 0..<40 where !model.systemProxyEnabled || controller.guardState != .active {
      await Task.yield()
    }

    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertEqual(controller.guardState, .active)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi localhost *.corp"))

    model.setSystemProxyEnabled(false)

    for _ in 0..<40 where model.systemProxyEnabled || controller.guardState != .idle {
      await Task.yield()
    }

    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertEqual(controller.guardState, .idle)
  }

  func testSystemProxyRestoreIgnoresUnspecifiedRawProxyHosts() async throws {
    try await assertSystemProxyRestoreIgnoresUnspecifiedRawProxyHost("0.0.0.0", residualServer: "0.0.0.0")
    try await assertSystemProxyRestoreIgnoresUnspecifiedRawProxyHost("::", residualServer: "::")
  }

  func testSystemProxySettingsNormalizeUnspecifiedBindHostsToLoopback() {
    var ipv4 = SystemProxySettings.default
    ipv4.proxyHost = "0.0.0.0"
    XCTAssertEqual(ipv4.normalizedProxyHost, "127.0.0.1")

    var ipv6 = SystemProxySettings.default
    ipv6.proxyHost = "::"
    XCTAssertEqual(ipv6.normalizedProxyHost, "127.0.0.1")

    var bracketedIPv6 = SystemProxySettings.default
    bracketedIPv6.proxyHost = "[::]"
    XCTAssertEqual(bracketedIPv6.normalizedProxyHost, "127.0.0.1")

    var ipv4Mapped = SystemProxySettings.default
    ipv4Mapped.proxyHost = "::ffff:0.0.0.0"
    XCTAssertEqual(ipv4Mapped.normalizedProxyHost, "127.0.0.1")

    var bracketedIPv4Mapped = SystemProxySettings.default
    bracketedIPv4Mapped.proxyHost = "[::ffff:0.0.0.0]"
    XCTAssertEqual(bracketedIPv4Mapped.normalizedProxyHost, "127.0.0.1")

    var expandedIPv4Mapped = SystemProxySettings.default
    expandedIPv4Mapped.proxyHost = "0:0:0:0:0:ffff:0:0"
    XCTAssertEqual(expandedIPv4Mapped.normalizedProxyHost, "127.0.0.1")

    var custom = SystemProxySettings.default
    custom.proxyHost = "192.168.1.20"
    XCTAssertEqual(custom.normalizedProxyHost, "192.168.1.20")
  }

  func testSystemProxyGuardQueryWarningDoesNotBecomeGlobalError() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = GuardWarningCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults
    )
    var settings = SystemProxySettings.default
    settings.guardEnabled = true
    settings.guardIntervalSeconds = 5

    XCTAssertTrue(model.updateSystemProxySettings(settings))
    model.setSystemProxyEnabled(true)

    for _ in 0..<100 where !model.logs.contains(where: { $0.message.contains("could not read Wi-Fi proxy settings") }) {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertNil(model.lastError)
    XCTAssertTrue(model.logs.contains { $0.level == "warn" && $0.message.contains("could not read Wi-Fi proxy settings") })
  }

  func testPublicIPRefreshSkipsDuplicateInFlightRequest() async throws {
    let paths = try Self.makeRuntimePaths()
    let info = Self.makePublicIPInfo(ip: "203.0.113.1", fetchedAt: Date(timeIntervalSince1970: 1_000))
    let fetcher = RecordingPublicIPInfoFetcher(infos: [info], delayNanoseconds: 150_000_000)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      publicIPInfoClient: fetcher
    )
    model.tunnelCoreRunning = true

    model.refreshPublicIPInfo(force: true)
    model.refreshPublicIPInfo(force: true)
    try? await Task.sleep(nanoseconds: 20_000_000)

    let inFlightRequestCount = await fetcher.requestCount()
    XCTAssertEqual(inFlightRequestCount, 1)
    try await Self.waitForPublicIPInfo(model)
    XCTAssertEqual(model.publicIPInfoState.info, info)
  }

  func testPublicIPRefreshIntervalPreventsEarlyAutomaticRefresh() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstFetch = Date(timeIntervalSince1970: 1_000)
    let secondFetch = Date(timeIntervalSince1970: 1_300)
    let first = Self.makePublicIPInfo(ip: "203.0.113.1", fetchedAt: firstFetch)
    let second = Self.makePublicIPInfo(ip: "198.51.100.9", fetchedAt: secondFetch)
    let fetcher = RecordingPublicIPInfoFetcher(infos: [first, second])
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      publicIPInfoClient: fetcher
    )
    model.tunnelCoreRunning = true

    model.refreshPublicIPInfo(force: true, now: firstFetch)
    try await Self.waitForPublicIPInfo(model)

    XCTAssertFalse(model.publicIPInfoNeedsRefresh(now: firstFetch.addingTimeInterval(299)))
    model.refreshPublicIPInfo(now: firstFetch.addingTimeInterval(299))
    let earlyRequestCount = await fetcher.requestCount()
    XCTAssertEqual(earlyRequestCount, 1)

    XCTAssertTrue(model.publicIPInfoNeedsRefresh(now: firstFetch.addingTimeInterval(300)))
    model.refreshPublicIPInfo(now: firstFetch.addingTimeInterval(300))
    try await Self.waitForPublicIPInfo(model, expectedIP: "198.51.100.9")
    let refreshedRequestCount = await fetcher.requestCount()
    XCTAssertEqual(refreshedRequestCount, 2)
    XCTAssertEqual(model.publicIPInfoState.info, second)
  }

  func testForcedPublicIPRefreshIgnoresFreshCache() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstFetch = Date(timeIntervalSince1970: 2_000)
    let first = Self.makePublicIPInfo(ip: "203.0.113.1", fetchedAt: firstFetch)
    let second = Self.makePublicIPInfo(ip: "198.51.100.9", fetchedAt: firstFetch.addingTimeInterval(10))
    let fetcher = RecordingPublicIPInfoFetcher(infos: [first, second])
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      publicIPInfoClient: fetcher
    )
    model.tunnelCoreRunning = true

    model.refreshPublicIPInfo(force: true, now: firstFetch)
    try await Self.waitForPublicIPInfo(model)
    model.refreshPublicIPInfo(force: true, now: firstFetch.addingTimeInterval(10))
    try await Self.waitForPublicIPInfo(model, expectedIP: "198.51.100.9")

    let forcedRequestCount = await fetcher.requestCount()
    XCTAssertEqual(forcedRequestCount, 2)
    XCTAssertEqual(model.publicIPInfoState.info, second)
  }

  func testStoppingRuntimeCancelsAndClearsPublicIPState() async throws {
    let paths = try Self.makeRuntimePaths()
    let info = Self.makePublicIPInfo(ip: "203.0.113.1", fetchedAt: Date(timeIntervalSince1970: 1_000))
    let fetcher = RecordingPublicIPInfoFetcher(infos: [info], delayNanoseconds: 800_000_000)
    let helperClient = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test-helper"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test-helper")
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helperClient,
      publicIPInfoClient: fetcher
    )
    model.tunnelCoreRunning = true

    model.refreshPublicIPInfo(force: true)
    try? await Task.sleep(nanoseconds: 20_000_000)
    model.stop()

    for _ in 0..<100 where model.publicIPInfoState != .idle {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    let stoppedRequestCount = await fetcher.requestCount()
    XCTAssertEqual(stoppedRequestCount, 1)
    XCTAssertEqual(model.publicIPInfoState, .idle)
  }

  func testTerminationRestoresEnabledSystemProxy() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner, snapshotDefaults: defaults)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults
    )

    model.setSystemProxyEnabled(true)

    for _ in 0..<100 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertTrue(model.needsTerminationCleanup)

    let didCleanUp = await model.prepareForTermination()

    XCTAssertTrue(didCleanUp)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertFalse(model.needsTerminationCleanup)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setsecurewebproxystate Wi-Fi off"))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxystate Wi-Fi off"))
  }

  func testStopAndTerminationShareSingleRuntimeTeardown() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = SlowRecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner, snapshotDefaults: defaults)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults
    )

    model.setSystemProxyEnabled(true)

    for _ in 0..<100 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTAssertTrue(model.systemProxyEnabled)

    model.stop()
    let didCleanUp = await model.prepareForTermination()

    XCTAssertTrue(didCleanUp)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertEqual(
      commandRunner.commands.filter { $0 == "/usr/sbin/networksetup -setwebproxystate Wi-Fi off" }.count,
      1
    )
    XCTAssertFalse(defaults.bool(forKey: "io.github.clashmax.systemProxyManaged"))
  }

  func testProxyDelayDisplayLabelsAndTones() {
    let noDelay = ProxyDelayDisplay(delay: nil)
    XCTAssertEqual(noDelay.label, "No delay")
    XCTAssertEqual(noDelay.tone, .unavailable)

    let fast = ProxyDelayDisplay(delay: 100)
    XCTAssertEqual(fast.label, "100 ms")
    XCTAssertEqual(fast.tone, .fast)

    XCTAssertEqual(ProxyDelayDisplay(delay: 101).tone, .good)
    XCTAssertEqual(ProxyDelayDisplay(delay: 150).tone, .good)
    XCTAssertEqual(ProxyDelayDisplay(delay: 151).tone, .moderate)
    XCTAssertEqual(ProxyDelayDisplay(delay: 250).tone, .moderate)
    XCTAssertEqual(ProxyDelayDisplay(delay: 251).tone, .slow)
  }

  func testProxyPreviewNoticeRequiresDeveloperMode() {
    XCTAssertNil(ProxyPreviewNoticeKind.resolve(
      developerMode: false,
      previewRuntimeActive: true,
      isShowingProxyPreview: false
    ))
    XCTAssertNil(ProxyPreviewNoticeKind.resolve(
      developerMode: false,
      previewRuntimeActive: false,
      isShowingProxyPreview: true
    ))
    XCTAssertEqual(
      ProxyPreviewNoticeKind.resolve(
        developerMode: true,
        previewRuntimeActive: true,
        isShowingProxyPreview: false
      ),
      .previewRuntime
    )
    XCTAssertEqual(
      ProxyPreviewNoticeKind.resolve(
        developerMode: true,
        previewRuntimeActive: false,
        isShowingProxyPreview: true
      ),
      .offlinePreview
    )
  }

  func testProviderSummaryRequiresDeveloperMode() {
    XCTAssertFalse(ProxyPageVisibilityPolicy.showsProviderSummary(developerMode: false, providerCount: 3))
    XCTAssertFalse(ProxyPageVisibilityPolicy.showsProviderSummary(developerMode: true, providerCount: 0))
    XCTAssertTrue(ProxyPageVisibilityPolicy.showsProviderSummary(developerMode: true, providerCount: 3))
  }

  func testProxyGroupExpansionPolicyKeepsNormalRowsExpandable() {
    let groups = [
      ProxyGroup(
        name: "Elite",
        type: "select",
        selected: "Japan",
        nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
      )
    ]

    let initialExpansion = ProxyGroupExpansionPolicy.resolvedExpansion(
      current: nil,
      groups: groups,
      searchQuery: ""
    )
    XCTAssertEqual(initialExpansion, Set(["Elite"]))

    XCTAssertEqual(ProxyGroupExpansionPolicy.toggled(groupID: "Elite", in: initialExpansion), Set<String>())
  }

  func testDeveloperOnlyLogsAreHiddenUntilDeveloperMode() {
    let entries = [
      LogEntry(level: "info", message: "Core ready"),
      LogEntry(level: "debug", message: "controller request body"),
      LogEntry(level: "info", message: "GET https://www.gstatic.com/generate_204"),
      LogEntry(level: "trace", message: "raw stream frame")
    ]

    let normalMessages = LogVisibility.visibleEntries(in: entries, developerMode: false).map(\.message)
    XCTAssertEqual(normalMessages, ["Core ready"])

    let developerMessages = LogVisibility.visibleEntries(in: entries, developerMode: true).map(\.message)
    XCTAssertEqual(developerMessages, entries.map(\.message))
  }

  func testProxyGroupExpansionDefaultsToSelectedGroup() {
    let groups = [
      ProxyGroup(name: "General", type: "select", selected: nil, nodes: []),
      ProxyGroup(name: "Streaming", type: "select", selected: "Japan", nodes: [])
    ]

    XCTAssertEqual(
      ProxyGroupExpansionPolicy.resolvedExpansion(current: nil, groups: groups, searchQuery: ""),
      Set(["Streaming"])
    )
  }

  func testProxyGroupExpansionDefaultsToFirstGroupWithoutSelection() {
    let groups = [
      ProxyGroup(name: "General", type: "select", selected: nil, nodes: []),
      ProxyGroup(name: "Streaming", type: "select", selected: nil, nodes: [])
    ]

    XCTAssertEqual(
      ProxyGroupExpansionPolicy.resolvedExpansion(current: nil, groups: groups, searchQuery: ""),
      Set(["General"])
    )
  }

  func testProxyGroupExpansionRetainsExistingGroupsAfterRefresh() {
    let refreshedGroups = [
      ProxyGroup(name: "General", type: "select", selected: nil, nodes: []),
      ProxyGroup(name: "Auto", type: "url-test", selected: nil, nodes: [])
    ]

    XCTAssertEqual(
      ProxyGroupExpansionPolicy.retainedExpansion(current: Set(["General", "Missing"]), groups: refreshedGroups),
      Set(["General"])
    )
  }

  func testProxyGroupExpansionOpensSearchResults() {
    let groups = [
      ProxyGroup(name: "General", type: "select", selected: nil, nodes: []),
      ProxyGroup(name: "Streaming", type: "select", selected: nil, nodes: [])
    ]

    XCTAssertEqual(
      ProxyGroupExpansionPolicy.resolvedExpansion(current: Set(["General"]), groups: groups, searchQuery: "jp"),
      Set(["General", "Streaming"])
    )
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
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
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
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
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
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults()
    )
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

  func testUnifiedMihomoDelayRunsTwiceAndUsesSecondResult() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try "proxies:\n  - { name: Japan, type: vless, server: jp.example, port: 443 }\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let group = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true, serverHost: "jp.example", serverPort: 443)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResults: [111, 73]
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.delayTestSettings = DelayTestSettings(mode: .mihomoURL, unifiedDelay: true)
    model.proxyGroups = [group]

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.testDelay(for: group.nodes[0])

    for _ in 0..<30 where await client.delayRequestCount() < 2 {
      await Task.yield()
    }
    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.delay != 73 {
      await Task.yield()
    }

    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(delayRequestCount, 2)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
  }

  func testNativePingDelayUsesNodeServerHost() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try "proxies:\n  - { name: Japan, type: vless, server: jp.example, port: 443 }\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let group = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true, serverHost: "jp.example", serverPort: 443)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 99)
    let pingTester = RecordingPingTester(results: [44])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      pingTester: pingTester,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.delayTestSettings = DelayTestSettings(mode: .nativePing, unifiedDelay: false)
    model.proxyGroups = [group]

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.testDelay(for: group.nodes[0])

    for _ in 0..<30 where await pingTester.requestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.delay != 44 {
      await Task.yield()
    }

    let requestedHosts = await pingTester.hosts()
    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(requestedHosts, ["jp.example"])
    XCTAssertEqual(delayRequestCount, 0)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 44)
  }

  func testNativePingDelayUsesPreviewServerHostWhenRuntimeOmitsEndpoint() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - { name: '[Hy2]HK Hysteria', type: hysteria2, server: example.com, port: 23006, password: password }
    proxy-groups:
      - { name: Elite, type: select, proxies: ['[Hy2]HK Hysteria', DIRECT] }
    rules:
      - MATCH,Elite
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let runtimeGroup = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "[Hy2]HK Hysteria",
      nodes: [ProxyNode(name: "[Hy2]HK Hysteria", type: "Hysteria2", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [runtimeGroup], testDelayResult: 99)
    let pingTester = RecordingPingTester(results: [51])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      pingTester: pingTester,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.delayTestSettings = DelayTestSettings(mode: .nativePing, unifiedDelay: false)
    model.proxyGroups = [runtimeGroup]

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.testDelay(for: runtimeGroup.nodes[0])

    for _ in 0..<30 where await pingTester.requestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.delay != 51 {
      await Task.yield()
    }

    let requestedHosts = await pingTester.hosts()
    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(requestedHosts, ["example.com"])
    XCTAssertEqual(delayRequestCount, 0)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.serverHost, "example.com")
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.serverPort, 23006)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 51)
  }

  func testNativePingDelayUsesProviderServerHostWhenRuntimeOmitsEndpoint() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxy-providers:
      Remote:
        type: http
        url: https://sub.example/profile
        path: ./remote.yaml
    proxy-groups:
      - { name: Elite, type: select, use: [Remote] }
    rules:
      - MATCH,Elite
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let runtimeGroup = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "[Hy2]HK Hysteria",
      nodes: [ProxyNode(name: "[Hy2]HK Hysteria", type: "Hysteria2", delay: nil, isSelectable: true)]
    )
    let provider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: "HTTP",
      updatedAt: nil,
      proxies: [
        ProxyNode(
          name: "[Hy2]HK Hysteria",
          type: "Hysteria2",
          delay: nil,
          isSelectable: true,
          serverHost: "provider.example",
          serverPort: 443
        )
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [runtimeGroup],
      proxyProvidersResponse: [provider],
      testDelayResult: 99
    )
    let pingTester = RecordingPingTester(results: [62])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      pingTester: pingTester,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.delayTestSettings = DelayTestSettings(mode: .nativePing, unifiedDelay: false)

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.reloadRuntimeData()

    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.serverHost == nil {
      await Task.yield()
    }

    let node = try XCTUnwrap(model.proxyGroups.first?.nodes.first)
    model.testDelay(for: node)

    for _ in 0..<30 where await pingTester.requestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.delay != 62 {
      await Task.yield()
    }

    let requestedHosts = await pingTester.hosts()
    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(requestedHosts, ["provider.example"])
    XCTAssertEqual(delayRequestCount, 0)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.serverHost, "provider.example")
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.serverPort, 443)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 62)
  }

  func testNativePingDelayRequiresNodeServerHost() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let group = ProxyGroup(
      name: "Elite",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 99)
    let pingTester = RecordingPingTester(results: [44])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      pingTester: pingTester,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.delayTestSettings = DelayTestSettings(mode: .nativePing, unifiedDelay: false)
    model.proxyGroups = [group]

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.testDelay(for: group.nodes[0])

    for _ in 0..<30 where model.lastError == nil {
      await Task.yield()
    }

    XCTAssertTrue(model.lastError?.contains("Native ping needs a server host") == true)
    let pingRequestCount = await pingTester.requestCount()
    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(pingRequestCount, 0)
    XCTAssertEqual(delayRequestCount, 0)
  }

  func testReloadRuntimeDataIncludesProxyProvidersAndConnections() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let provider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: "HTTP",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      proxies: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let connection = ConnectionSnapshot(
      id: "conn-1",
      network: "tcp",
      host: "example.com",
      upload: 4,
      download: 8,
      chain: ["Proxy", "Japan"],
      rule: "MATCH",
      startedAt: nil
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(
          name: "Proxy",
          type: "select",
          selected: "Japan",
          nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
        )
      ],
      proxyProvidersResponse: [provider],
      connectionsResponse: [connection],
      testDelayResult: 73
    )
    let model = AppModel(paths: paths, profileStore: store, coreController: controller, apiClient: client)

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.reloadRuntimeData()

    for _ in 0..<20 where model.proxyProviders.isEmpty || model.connections.isEmpty {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyProviders, [provider])
    XCTAssertEqual(model.connections, [connection])
  }

  func testProviderHealthAndConnectionCloseUseRuntimeAPI() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let provider = ProxyProvider(
      name: "Remote/sub",
      type: "http",
      vehicleType: "HTTP",
      updatedAt: nil,
      proxies: []
    )
    let connection = ConnectionSnapshot(
      id: "abc/123",
      network: "tcp",
      host: "example.com",
      upload: 4,
      download: 8,
      chain: ["Proxy"],
      rule: nil,
      startedAt: nil
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [provider],
      connectionsResponse: [],
      testDelayResult: 73
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client
    )

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.connections = [connection]

    model.healthCheckProvider(provider)
    model.closeConnection(connection)

    for _ in 0..<80 {
      let healthCheckCount = await client.healthCheckRequestCount()
      let closedConnectionIDs = await client.closedConnectionIDs()
      if healthCheckCount > 0
        && !closedConnectionIDs.isEmpty
        && model.closingConnectionIDs.isEmpty
        && model.connections.isEmpty {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let healthCheckProviders = await client.healthCheckProviders()
    let closedConnectionIDs = await client.closedConnectionIDs()
    XCTAssertEqual(healthCheckProviders, ["Remote/sub"])
    XCTAssertEqual(closedConnectionIDs, ["abc/123"])
    XCTAssertTrue(model.connections.isEmpty)

    model.connections = [connection]
    model.closeAllRuntimeConnections()

    for _ in 0..<80 {
      let closeAllRequestCount = await client.closeAllRequestCount()
      if closeAllRequestCount > 0 && !model.closingAllConnections && model.connections.isEmpty {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let closeAllRequestCount = await client.closeAllRequestCount()
    XCTAssertEqual(closeAllRequestCount, 1)
    XCTAssertTrue(model.connections.isEmpty)
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
    XCTAssertEqual(
      model.lastError,
      String(localized: "Profile must include at least one proxy or proxy provider.")
    )
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
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      defaults: try Self.makeIsolatedDefaults()
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

  func testTunStartWaitsForControllerReadinessBeforePublishingRunningState() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let helperTransport = ReadyTunnelHelperTransport()
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      helperClient: helper,
      tunnelReadinessProbe: FailingCoreReadinessProbe(message: "controller refused connection")
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }
    XCTAssertTrue(model.tunHelperPreparationState.isReady)

    model.start()

    for _ in 0..<40 where model.startInFlight || model.lastError == nil {
      await Task.yield()
    }

    let startCount = await helperTransport.startCount()
    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(startCount, 1)
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(model.tunnelCoreRunning)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.lastError?.contains("controller refused connection") == true)
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
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      defaults: try Self.makeIsolatedDefaults()
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

  func testRequestingProxyRoutingModeDefersPublishedChangesUntilNextActorTurn() async throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore())
    )
    var changeCount = 0
    let cancellable = model.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    model.requestProxyRoutingMode(.tun)

    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertEqual(changeCount, 0)

    for _ in 0..<20 where model.proxyRoutingMode != .tun {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .tun)
    XCTAssertGreaterThan(changeCount, 0)
  }

  func testCoreControllerStatusChangesPublishAppModelChanges() async throws {
    let paths = try Self.makeRuntimePaths()
    let launcher = FakeProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      coreController: controller
    )
    var changeCount = 0
    let cancellable = model.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )
    changeCount = 0

    launcher.process.finish(exitCode: 2)

    for _ in 0..<20 where changeCount == 0 {
      await Task.yield()
    }

    XCTAssertEqual(model.statusSummary, "Crashed: mihomo exited with code 2")
    XCTAssertGreaterThan(changeCount, 0)
  }

  func testSelectingTunPreparesHelperAndBlocksStartDuringApproval() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let helperTransport = ReadyTunnelHelperTransport()
    let service = StaticHelperService(status: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.requestProxyRoutingMode(.tun)

    for _ in 0..<40 where model.proxyRoutingMode != .tun || model.tunHelperPreparationState == .checking || model.tunHelperPreparationState == .idle {
      await Task.yield()
    }

    guard case .requiresApproval = model.tunHelperPreparationState else {
      XCTFail("Expected TUN helper approval state, got \(model.tunHelperPreparationState)")
      return
    }
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertNil(model.lastError)
    XCTAssertNotNil(model.readinessIssue)

    model.start()

    let startCount = await helperTransport.startCount()
    XCTAssertEqual(startCount, 0)
    XCTAssertNil(model.lastError)
  }

  func testSelectingTunRegistersAndMarksReadyHelper() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try store.importLocalConfig(from: configURL)
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .enabled)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.requestProxyRoutingMode(.tun)

    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .tun)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertTrue(model.tunHelperPreparationState.isReady)
    XCTAssertNil(model.readinessIssue)
    XCTAssertNil(model.lastError)
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

  func testHomeBackgroundUsesSingleSystemFillAcrossStates() {
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .blocked(reason: "No profile")), "system-window")
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .running), "system-window")
    XCTAssertEqual(DashboardHomeBackgroundStyle.fillID(for: .crashed(message: "boom")), "system-window")
  }

  func testCoreVisualActiveOnlyForOperationalStates() {
    XCTAssertFalse(DashboardRuntimeState.blocked(reason: "No profile").isVisualActive)
    XCTAssertFalse(DashboardRuntimeState.stopped.isVisualActive)
    XCTAssertFalse(DashboardRuntimeState.crashed(message: "boom").isVisualActive)
    XCTAssertTrue(DashboardRuntimeState.starting.isVisualActive)
    XCTAssertTrue(DashboardRuntimeState.running.isVisualActive)
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
      "TUN helper could not be registered because ClashMax or its helper is not correctly signed, notarized, or approved by macOS. Verify signing, approve the helper in System Settings, then retry."
    )
  }

  func testHelperOperationNotPermittedExplainsDebugLaunchDaemonConstraint() {
    let error = NSError(
      domain: "SMAppServiceErrorDomain",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Operation not permitted"
      ]
    )

    XCTAssertEqual(
      UserFacingError.message(for: error),
      "macOS rejected TUN helper registration. LaunchDaemon helpers registered with SMAppService must come from a trusted signed and notarized app. Run the exported/notarized app instead of a Debug or Products archive build, approve ClashMax in System Settings, then retry."
    )
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

  private static func makeIsolatedDefaults() throws -> UserDefaults {
    let suiteName = "ClashMaxDashboardTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func assertSystemProxyRestoreIgnoresUnspecifiedRawProxyHost(
    _ rawHost: String,
    residualServer: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = SequencedRecordingCommandRunner(
      outputs: Self.networkSetupOutputsWithResidualServer(residualServer)
    )
    let controller = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults
    )
    var settings = SystemProxySettings.default
    settings.proxyHost = rawHost

    XCTAssertTrue(model.updateSystemProxySettings(settings), file: file, line: line)
    model.setSystemProxyEnabled(true)

    for _ in 0..<40 where !model.systemProxyEnabled {
      await Task.yield()
    }
    XCTAssertTrue(model.systemProxyEnabled, file: file, line: line)

    model.setSystemProxyEnabled(false)

    for _ in 0..<40 where model.systemProxyEnabled {
      await Task.yield()
    }

    let webProxyDisableCount = commandRunner.commands.filter {
      $0 == "/usr/sbin/networksetup -setwebproxystate Wi-Fi off"
    }.count
    XCTAssertEqual(webProxyDisableCount, 1, file: file, line: line)
    XCTAssertFalse(model.systemProxyEnabled, file: file, line: line)
    XCTAssertNil(model.lastError, file: file, line: line)
  }

  private static func networkSetupOutputsWithResidualServer(_ server: String) -> [String: [String]] {
    [
      "/usr/sbin/networksetup -listallnetworkservices": [
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n"
      ],
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: Yes\nServer: \(server)\nPort: 7890\n",
        "Enabled: Yes\nServer: \(server)\nPort: 7890\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": [
        "There aren't any bypass domains set.\n",
        "There aren't any bypass domains set.\n",
        "There aren't any bypass domains set.\n",
        "There aren't any bypass domains set.\n"
      ]
    ]
  }

  private static func makePublicIPInfo(ip: String, fetchedAt: Date) -> PublicIPInfo {
    PublicIPInfo(
      ipAddress: ip,
      countryCode: "NZ",
      countryName: "New Zealand",
      region: "Auckland",
      city: "Auckland",
      asn: "AS23655",
      isp: "2degrees",
      organization: "Two Degrees Networks Limited",
      timezone: "Pacific/Auckland",
      latitude: -36.85,
      longitude: 174.76,
      sourceName: "test",
      fetchedAt: fetchedAt
    )
  }

  private static func waitForPublicIPInfo(
    _ model: AppModel,
    expectedIP: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<120 {
      if let info = model.publicIPInfoState.info,
         !model.publicIPInfoState.isLoading,
         expectedIP == nil || info.ipAddress == expectedIP {
        return
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Timed out waiting for public IP info.", file: file, line: line)
  }
}

private actor RecordingPublicIPInfoFetcher: PublicIPInfoFetching {
  private let infos: [PublicIPInfo]
  private let delayNanoseconds: UInt64
  private var requests = 0

  init(infos: [PublicIPInfo], delayNanoseconds: UInt64 = 0) {
    self.infos = infos
    self.delayNanoseconds = delayNanoseconds
  }

  func fetchPublicIPInfo() async throws -> PublicIPInfo {
    requests += 1
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    let index = min(requests - 1, max(infos.count - 1, 0))
    return infos[index]
  }

  func requestCount() -> Int {
    requests
  }
}

private actor RecordingMihomoController: MihomoAPIControlling {
  private let proxyGroupsResponse: [ProxyGroup]
  private let proxyProvidersResponse: [ProxyProvider]
  private let connectionsResponse: [ConnectionSnapshot]
  private let testDelayResults: [Int]
  private var delayRequests: [String] = []
  private var healthCheckRequests: [String] = []
  private var closedConnections: [String] = []
  private var closedAllRequestCount = 0

  init(
    proxyGroupsResponse: [ProxyGroup],
    proxyProvidersResponse: [ProxyProvider] = [],
    connectionsResponse: [ConnectionSnapshot] = [],
    testDelayResult: Int
  ) {
    self.init(
      proxyGroupsResponse: proxyGroupsResponse,
      proxyProvidersResponse: proxyProvidersResponse,
      connectionsResponse: connectionsResponse,
      testDelayResults: [testDelayResult]
    )
  }

  init(
    proxyGroupsResponse: [ProxyGroup],
    proxyProvidersResponse: [ProxyProvider] = [],
    connectionsResponse: [ConnectionSnapshot] = [],
    testDelayResults: [Int]
  ) {
    self.proxyGroupsResponse = proxyGroupsResponse
    self.proxyProvidersResponse = proxyProvidersResponse
    self.connectionsResponse = connectionsResponse
    self.testDelayResults = testDelayResults
  }

  func updateMode(_ mode: RunMode) async throws {}

  func proxyGroups() async throws -> [ProxyGroup] {
    proxyGroupsResponse
  }

  func structuredProxyProviders() async throws -> [ProxyProvider] {
    proxyProvidersResponse
  }

  func rules() async throws -> [String] {
    []
  }

  func connections() async throws -> [ConnectionSnapshot] {
    connectionsResponse
  }

  func selectProxy(group: String, proxy: String) async throws {}

  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int {
    delayRequests.append(proxy)
    let index = min(delayRequests.count - 1, max(testDelayResults.count - 1, 0))
    return testDelayResults[index]
  }

  func healthCheckProvider(named provider: String) async throws {
    healthCheckRequests.append(provider)
  }

  func closeConnection(id: String) async throws {
    closedConnections.append(id)
  }

  func closeAllConnections() async throws {
    closedAllRequestCount += 1
  }

  func reloadConfig(path: String) async throws {}

  func restart(configPath: String?) async throws {}

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

  func healthCheckRequestCount() -> Int {
    healthCheckRequests.count
  }

  func healthCheckProviders() -> [String] {
    healthCheckRequests
  }

  func closedConnectionIDs() -> [String] {
    closedConnections
  }

  func closeAllRequestCount() -> Int {
    closedAllRequestCount
  }
}

private actor RecordingPingTester: PingTesting {
  private let results: [Int]
  private var requestedHosts: [String] = []

  init(results: [Int]) {
    self.results = results
  }

  func ping(host: String, timeoutMilliseconds: Int) async throws -> Int {
    requestedHosts.append(host)
    let index = min(requestedHosts.count - 1, max(results.count - 1, 0))
    return results[index]
  }

  func requestCount() -> Int {
    requestedHosts.count
  }

  func hosts() -> [String] {
    requestedHosts
  }
}

private struct EmptyRuntimePortChecker: RuntimePortChecking {
  func listeners(on ports: [Int]) async -> [PortListener] {
    []
  }
}

private actor ReadyTunnelHelperTransport: HelperXPCTransport {
  private var starts = 0
  private var stops = 0

  func status() async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: false))
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    starts += 1
    return HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: true, pid: 99))
  }

  func stopTunnel() async throws -> HelperClientResponse {
    stops += 1
    return HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: false))
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await stopTunnel()
    return try await startTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func recentLogs() async throws -> [String] {
    []
  }

  func startCount() -> Int { starts }
  func stopCount() -> Int { stops }
}

@MainActor
private final class StaticHelperService: HelperServiceManaging {
  var status: SMAppService.Status
  let statusAfterRegister: SMAppService.Status
  private(set) var registerCount = 0
  private(set) var unregisterCount = 0
  private(set) var openSettingsCount = 0

  init(status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled) {
    self.status = status
    self.statusAfterRegister = statusAfterRegister
  }

  func register() throws {
    registerCount += 1
    status = statusAfterRegister
  }

  func unregister() async throws {
    unregisterCount += 1
    status = .notRegistered
  }

  func openSystemSettingsLoginItems() {
    openSettingsCount += 1
  }
}

private final class FakeLoginItemService: LoginItemManaging {
  var status: SMAppService.Status
  private let registerError: Error?
  private let unregisterError: Error?
  private(set) var registerCount = 0
  private(set) var unregisterCount = 0
  private(set) var openSettingsCount = 0

  init(status: SMAppService.Status, registerError: Error? = nil, unregisterError: Error? = nil) {
    self.status = status
    self.registerError = registerError
    self.unregisterError = unregisterError
  }

  func register() throws {
    registerCount += 1
    if let registerError {
      throw registerError
    }
    status = .enabled
  }

  func unregister() async throws {
    unregisterCount += 1
    if let unregisterError {
      throw unregisterError
    }
    status = .notRegistered
  }

  func openSystemSettingsLoginItems() {
    openSettingsCount += 1
  }
}

private struct StaticFingerprintProvider: HelperFingerprintProviding {
  let fingerprint: String

  func currentFingerprint() throws -> String {
    fingerprint
  }
}

private final class InMemoryHelperRegistrationRecordStore: HelperRegistrationRecordStoring, @unchecked Sendable {
  var storedFingerprint: String?

  init(storedFingerprint: String?) {
    self.storedFingerprint = storedFingerprint
  }

  func helperFingerprint() -> String? {
    storedFingerprint
  }

  func setHelperFingerprint(_ fingerprint: String?) {
    storedFingerprint = fingerprint
  }
}

private struct FailingCoreReadinessProbe: CoreReadinessProbing {
  let message: String

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    throw AppError.coreNotReady(message)
  }
}

private final class GuardWarningCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.GuardWarningCommandRunner")
  private var secureWebReads = 0

  init(outputs: [String: String]) {
    self.outputs = outputs
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    var shouldFail = false
    queue.sync {
      if command == "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi" {
        secureWebReads += 1
        shouldFail = secureWebReads > 1
      }
    }
    if shouldFail {
      throw NSError(
        domain: "ClashMaxTests.GuardWarningCommandRunner",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Injected guard query failure for \(command)"]
      )
    }
    return outputs[command] ?? ""
  }
}

private final class SlowRecordingCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let delayNanoseconds: UInt64
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.SlowRecordingCommandRunner")
  private var _commands: [String] = []

  init(outputs: [String: String], delayNanoseconds: UInt64 = 10_000_000) {
    self.outputs = outputs
    self.delayNanoseconds = delayNanoseconds
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
    }
    try? await Task.sleep(nanoseconds: delayNanoseconds)
    return outputs[command] ?? ""
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
