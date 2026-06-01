import AppKit
import Combine
import ServiceManagement
import SwiftUI
import XCTest
import Yams
@testable import ClashMax

@MainActor
final class DashboardRuntimeStateTests: XCTestCase {
  private static let proxyRoutingModeDefaultsKey = "io.github.clashmax.proxyRoutingMode"
  private static let systemProxySettingsDefaultsKey = "io.github.clashmax.systemProxySettings"
  private static let runtimeSettingsDefaultsKey = "io.github.clashmax.runtimeSettings"
  private static let tunSettingsDefaultsKey = "io.github.clashmax.tunSettings"
  private static let tunDNSDefaultsVersionKey = "io.github.clashmax.tunDNSDefaultsVersion"
  private static let networkExtensionRoutingSettingsDefaultsKey = "io.github.clashmax.networkExtensionRoutingSettings"
  private static let delayTestSettingsDefaultsKey = "io.github.clashmax.delayTestSettings"
  private static let proxyPageSettingsDefaultsKey = "io.github.clashmax.proxyPageSettings"
  private static let externalControllerSettingsDefaultsKey = "io.github.clashmax.externalControllerSettings"
  private static let developerModeDefaultsKey = "io.github.clashmax.developerMode"

  override func setUp() {
    super.setUp()
    do {
      try Self.installFakeBundledCoreForAppModelTests()
    } catch {
      XCTFail("Could not install fake bundled core for AppModel tests: \(error)")
    }
    Self.clearSharedRoutingDefaults()
  }

  override func tearDown() {
    Self.clearSharedRoutingDefaults()
    super.tearDown()
  }

  func testNoActiveProfileBlocksDashboard() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
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
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(paths: paths, profileStore: store, bundledCoreURLProvider: { preflightCore })
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

  func testDeletingActiveProfilePublishesStatusMessage() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    await model.deleteProfileAsync(profile)

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertNil(store.activeProfileID)
    XCTAssertEqual(model.profileOperationMessage, "Deleted profile profile.")
  }

  func testRenamingSpecificProfileDoesNotChangeActiveSelection() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let firstProfile = try await store.importLocalConfig(from: configURL)
    let secondProfile = try await store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    await model.renameProfileAsync(firstProfile, to: "Office")

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
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(paths: paths, profileStore: store, bundledCoreURLProvider: { preflightCore })
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

    XCTAssertTrue(didUpdate, model.lastError ?? "subscription update returned false without lastError")
    XCTAssertFalse(model.updatingProfileIDs.contains(profile.id))
    XCTAssertEqual(
      try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8),
      "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n"
    )
    XCTAssertEqual(recorder.lastRequest?.url?.absoluteString, "https://example.com/sub")
    XCTAssertEqual(model.profileOperationMessage, "Updated subscription Remote.")
  }

  func testUpdatingSubscriptionSourceAndProviderOptionsReloadsRunningRuntimeOnceWithFinalProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: paths, keychain: secrets)
    let oldSource = """
    proxies:
      - { name: Old Node, type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [Old Node, DIRECT] }
    rules:
      - MATCH,Proxy
    """
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/old")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(oldSource))
    )
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { preflightCore }
    )
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: profile.originalConfigPath),
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )
    await model.refreshEffectiveRuntimeConfigPreview()
    guard case .loaded = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }

    let header = SubscriptionRequestHeader(name: "X-Panel-Token", value: "secret")
    let options = SubscriptionProviderOptions(requestHeaders: [header], fetchProxy: .direct)
    let newSource = """
    proxies:
      - { name: New Node, type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [New Node, DIRECT] }
    rules:
      - MATCH,Proxy
    """
    let recorder = URLProtocolRecorder(responseBody: newSource)
    let didUpdate = await model.updateSubscriptionSourceAndProviderOptions(
      profile,
      urlString: "https://example.com/new",
      options: options,
      session: URLSession(configuration: recorder.configuration)
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "X-Panel-Token"), "secret")
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/new")
    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, options)
    XCTAssertEqual(model.effectiveRuntimeConfigState, .idle)
    let reloadPaths = await client.reloadRequestPaths()
    XCTAssertEqual(reloadPaths.count, 1)
    let runtimePath = try XCTUnwrap(reloadPaths.first)
    let runtimeConfig = try String(contentsOfFile: runtimePath, encoding: .utf8)
    XCTAssertTrue(runtimeConfig.contains("New Node"))
    XCTAssertFalse(runtimeConfig.contains("Old Node"))
  }

  func testRuntimeSnippetChangesReloadOnlyWhenActiveProfileBindingChanges() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let activeProfile = try await store.importLocalConfig(from: firstConfigURL)
    let inactiveProfile = try await store.importLocalConfig(from: secondConfigURL)
    try await store.select(activeProfile)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults()
    )
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: activeProfile.originalConfigPath),
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )
    let inactiveSnippet = RuntimeSnippet(
      name: "Inactive",
      binding: .profiles([inactiveProfile.id]),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "inactive.example", policy: "DIRECT")
          ]
        )
      )
    )
    let activeSnippet = RuntimeSnippet(
      name: "Active",
      binding: .profiles([activeProfile.id]),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "active.example", policy: "DIRECT")
          ]
        )
      )
    )

    let didSaveInactiveSnippet = await model.saveRuntimeSnippet(inactiveSnippet)
    XCTAssertTrue(didSaveInactiveSnippet)
    let inactiveReloadPaths = await client.reloadRequestPaths()
    XCTAssertEqual(inactiveReloadPaths.count, 0)

    let didSaveActiveSnippet = await model.saveRuntimeSnippet(activeSnippet)
    XCTAssertTrue(didSaveActiveSnippet)
    let reloadPaths = await client.reloadRequestPaths()
    XCTAssertEqual(reloadPaths.count, 1)
    let runtimeConfig = try String(contentsOfFile: try XCTUnwrap(reloadPaths.first), encoding: .utf8)
    XCTAssertTrue(runtimeConfig.contains("DOMAIN-SUFFIX,active.example,DIRECT"))
    XCTAssertFalse(runtimeConfig.contains("inactive.example"))
  }

  func testActiveRuntimeSnippetRollsBackWhenReloadFails() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessage: "reload rejected"
    )
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { preflightCore }
    )
    await model.runtimeSnippetLibrary.waitForLoad()
    let stableSnippet = RuntimeSnippet(
      name: "Stable",
      binding: .profiles([profile.id]),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "stable.example", policy: "DIRECT")
          ]
        )
      )
    )
    try await model.runtimeSnippetLibrary.saveSnippet(stableSnippet)
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: profile.originalConfigPath),
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )
    let rejectedSnippet = RuntimeSnippet(
      name: "Rejected",
      binding: .profiles([profile.id]),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "rejected.example", policy: "DIRECT")
          ]
        )
      )
    )

    let didSave = await model.saveRuntimeSnippet(rejectedSnippet)

    XCTAssertFalse(didSave)
    XCTAssertEqual(model.runtimeSnippetLibrary.snippets, [stableSnippet])
    XCTAssertTrue(model.lastError?.contains("reload rejected") == true)
    let reloadRequestCount = await client.reloadRequestPaths().count
    XCTAssertEqual(reloadRequestCount, 1)

    let reloadedLibrary = RuntimeSnippetLibraryStore(paths: paths)
    await reloadedLibrary.waitForLoad()
    XCTAssertEqual(reloadedLibrary.snippets, [stableSnippet])
  }

  func testUpdatingProviderOptionsRollsBackWhenActiveRuntimeReloadFails() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let source = """
    proxies:
      - { name: Old Node, type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [Old Node, DIRECT] }
    rules:
      - MATCH,Proxy
    """
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(source))
    )
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessage: "reload rejected"
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults()
    )
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: profile.originalConfigPath),
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    let nextOptions = SubscriptionProviderOptions(primaryGroupName: "Manual")
    let didUpdate = await model.updateSubscriptionProviderOptions(profile, options: nextOptions)

    XCTAssertFalse(didUpdate)
    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, profile.subscriptionProviderOptions)
    let reloadRequestCount = await client.reloadRequestPaths().count
    XCTAssertEqual(reloadRequestCount, 1)
    XCTAssertTrue(model.lastError?.contains("reload rejected") == true)
  }

  func testRuntimeReloadFailureKeepsPreviousActiveArtifactsProtected() async throws {
    let paths = try Self.makeRuntimePaths()
    let source = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#Provider%20Node
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(source))
    )
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessages: [nil, "reload rejected", "reload rejected", "reload rejected"]
    )
    let fakeCoreURL = paths.appSupport.appendingPathComponent("mihomo")
    try """
    #!/bin/sh
    exit 0
    """.write(to: fakeCoreURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCoreURL.path)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { fakeCoreURL }
    )
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: profile.originalConfigPath),
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    let firstOptions = SubscriptionProviderOptions(primaryGroupName: "Manual 1")
    let didApplyFirstOptions = await model.updateSubscriptionProviderOptions(profile, options: firstOptions)
    XCTAssertTrue(didApplyFirstOptions)
    let reloadPathsAfterSuccess = await client.reloadRequestPaths()
    let firstRuntimePath = try XCTUnwrap(reloadPathsAfterSuccess.first)
    let firstRuntimeURL = URL(fileURLWithPath: firstRuntimePath)
    let firstProviderPath = try Self.providerContentPath(in: firstRuntimeURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstRuntimeURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstProviderPath))

    for index in 2...4 {
      let currentProfile = try XCTUnwrap(store.activeProfile)
      let didUpdate = await model.updateSubscriptionProviderOptions(
        currentProfile,
        options: SubscriptionProviderOptions(primaryGroupName: "Manual \(index)")
      )
      XCTAssertFalse(didUpdate)
    }

    let reloadPathsAfterFailures = await client.reloadRequestPaths()
    XCTAssertEqual(reloadPathsAfterFailures.count, 4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstRuntimeURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstProviderPath))
    XCTAssertTrue(model.lastError?.contains("reload rejected") == true)
  }

  func testProxyGroupsUnavailableMessageExplainsMissingProfileGroupsBeforeStart() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)

    XCTAssertEqual(
      model.proxyGroupsUnavailableMessage,
      "No proxy groups were found in the active profile. Start it to let Mihomo parse provider subscriptions."
    )
  }

  func testStoppedProfileShowsLocalProxyPreview() async throws {
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
    _ = try await store.importLocalConfig(from: configURL)
    let model = AppModel(paths: paths, profileStore: store)
    await model.waitForProfilePreviewRefresh()

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
    _ = try await store.importLocalConfig(from: configURL)
    let defaults = UserDefaults(suiteName: "ClashMaxPreviewTests-\(UUID().uuidString)")!
    let model = AppModel(paths: paths, profileStore: store, defaults: defaults)
    await model.waitForProfilePreviewRefresh()
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
    _ = try await store.importLocalConfig(from: configURL)
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

  func testPreviewRuntimeWarmupStartsWhenProfilePreviewBecomesAvailable() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    await model.waitForProfilePreviewRefresh()
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "direct", delay: nil, isSelectable: true)]
    )
    model.profilePreviewGroups = []

    model.warmPreviewRuntimeOnLaunch()
    model.profilePreviewGroups = [group]

    for _ in 0..<500 where launcher.launchCount < 1 || !model.previewRuntimeActive {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(model.previewRuntimeActive)
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.canControlRuntimeProxies)
    XCTAssertEqual(model.runtimeOwner, .preview)

    let runtimeConfigPath = try XCTUnwrap(launcher.launchedConfigPaths.first)
    let runtimeConfig = try String(contentsOfFile: runtimeConfigPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: runtimeConfig) as? [String: Any])
    XCTAssertEqual(yaml["mixed-port"] as? Int, 17_890)
    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:19097")
    XCTAssertEqual(yaml["allow-lan"] as? Bool, false)
    XCTAssertEqual(yaml["mode"] as? String, "direct")
    XCTAssertNil(yaml["external-controller-cors"])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])
    XCTAssertEqual(tun["enable"] as? Bool, false)
  }

  func testPreviewRuntimeFallsBackToProfilePreviewGroupsWhenRuntimeGroupsAreUnavailable() async throws {
    let previewGroup = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "direct", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let model = try await makeRunningRuntimeModel(client: client)
    model.previewRuntimeActive = true
    model.proxyGroups = []
    model.profilePreviewGroups = [previewGroup]

    XCTAssertTrue(model.isCoreRunning)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.visibleProxyGroups.map(\.name), ["Proxy"])
    XCTAssertEqual(model.visibleProxyGroups.first?.nodes.map(\.name), ["Japan"])
  }

  func testPreviewRuntimeWarmupIsIdempotent() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    await model.waitForProfilePreviewRefresh()

    model.warmPreviewRuntimeOnLaunch()

    for _ in 0..<500 where launcher.launchCount < 1 || !model.previewRuntimeActive {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    model.warmPreviewRuntimeOnLaunch()
    try? await Task.sleep(nanoseconds: 120_000_000)

    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(model.previewRuntimeActive)
  }

  func testStartCancelsPendingPreviewRuntimeRequestBeforeItCanLaunch() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "direct", delay: nil, isSelectable: true)]
    )
    model.profilePreviewGroups = [group]

    model.warmPreviewRuntimeOnLaunch()
    model.start()

    for _ in 0..<300 where !model.isRunning {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    try? await Task.sleep(nanoseconds: 120_000_000)

    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(model.isRunning, model.lastError ?? model.statusSummary)
    XCTAssertFalse(model.previewRuntimeActive)
    XCTAssertEqual(model.runtimeOwner, .user)
  }

  func testStartStopsActivePreviewRuntimeBeforeStartingUserRuntime() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
    await model.waitForProfilePreviewRefresh()
    model.warmPreviewRuntimeOnLaunch()
    for _ in 0..<500 where launcher.launchCount < 1 || !model.previewRuntimeActive {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    model.start()

    for _ in 0..<500 where !model.isRunning || model.runtimeOwner != .user {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertTrue(model.isRunning, model.lastError ?? model.statusSummary)
    XCTAssertFalse(model.previewRuntimeActive)
    XCTAssertEqual(model.runtimeOwner, .user)
  }

  func testStopRestartsPreviewRuntimeWhenWarmupWasRequested() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
    await model.waitForProfilePreviewRefresh()
    model.warmPreviewRuntimeOnLaunch()
    for _ in 0..<500 where launcher.launchCount < 1 || !model.previewRuntimeActive {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    model.start()
    for _ in 0..<500 where !model.isRunning || model.runtimeOwner != .user {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    model.stop()

    for _ in 0..<700 where launcher.launchCount < 3 || !model.previewRuntimeActive || model.runtimeOwner != .preview {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(launcher.launchCount, 3)
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.previewRuntimeActive)
    XCTAssertEqual(model.runtimeOwner, .preview)
  }

  func testSelectingProfileRestartsActivePreviewRuntimeForNewProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let firstProfile = try await store.importLocalConfig(from: firstConfigURL)
    let secondProfile = try await store.importLocalConfig(from: secondConfigURL)
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
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    let didSelectFirstProfile = await model.selectProfileAsync(firstProfile)
    XCTAssertTrue(didSelectFirstProfile)
    model.warmPreviewRuntimeOnLaunch()
    for _ in 0..<500 where launcher.launchCount < 1 || !model.previewRuntimeActive {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let didSelectSecondProfile = await model.selectProfileAsync(secondProfile)
    XCTAssertTrue(didSelectSecondProfile)

    for _ in 0..<700 where launcher.launchCount < 2 || !model.previewRuntimeActive || model.runtimeOwner != .preview {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertTrue(model.previewRuntimeActive)
    let runtimeConfigPath = try XCTUnwrap(launcher.launchedConfigPaths.last)
    let runtimeConfig = try String(contentsOfFile: runtimeConfigPath, encoding: .utf8)
    XCTAssertTrue(runtimeConfig.contains("Singapore"))
    XCTAssertFalse(runtimeConfig.contains("Japan"))
  }

  func testPreviewRuntimeAllowsDelayTestingWhileMainProxySwitchIsOff() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "direct", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 73)
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
    model.previewRuntimeActive = true

    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.canControlRuntimeProxies)

    model.testDelay(for: group.nodes[0])

    for _ in 0..<30 where await client.delayRequestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<30 where model.proxyGroups.first?.nodes.first?.delay != 73 {
      await Task.yield()
    }

    let delayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(delayRequestCount, 1)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
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

  func testProxyPageLoadingSkeletonUsesUnfilteredGroups() {
    XCTAssertTrue(
      ProxyPageVisibilityPolicy.showsLoadingSkeleton(
        unfilteredGroupCount: 0,
        hasActiveProfile: true,
        isRuntimeDataLoading: true,
        isStarting: false
      )
    )
    XCTAssertFalse(
      ProxyPageVisibilityPolicy.showsLoadingSkeleton(
        unfilteredGroupCount: 1,
        hasActiveProfile: true,
        isRuntimeDataLoading: true,
        isStarting: false
      )
    )
    XCTAssertFalse(
      ProxyPageVisibilityPolicy.showsLoadingSkeleton(
        unfilteredGroupCount: 0,
        hasActiveProfile: false,
        isRuntimeDataLoading: true,
        isStarting: false
      )
    )
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
        allowedOrigins: ["https://custom.example"]
      )
    )

    firstModel.externalControllerSettings = settings

    XCTAssertEqual(firstModel.overrides.externalControllerHost, "127.0.0.1")
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
    XCTAssertEqual(secondModel.overrides.externalControllerHost, "127.0.0.1")
    XCTAssertEqual(secondModel.overrides.externalControllerPort, 19197)
    XCTAssertNotEqual(secondModel.overrides.secret, "saved-secret")
    XCTAssertFalse(secondModel.overrides.secret.isEmpty)
    XCTAssertFalse(secondModel.overrides.externalControllerCORS.enabled)
  }

  func testExternalControllerSettingsValidationRequiresIPv4LoopbackHost() {
    var settings = ExternalControllerSettings(host: "127.0.0.1", port: 9097, secret: "secret-token")

    XCTAssertNil(settings.validationError)

    for host in ["localhost", "::1", "", "0.0.0.0"] {
      settings.host = host

      XCTAssertEqual(settings.normalizedHost, "127.0.0.1")
      XCTAssertEqual(settings.address, "127.0.0.1:9097")
      XCTAssertEqual(
        settings.validationError,
        String(localized: "Controller host must stay on 127.0.0.1.")
      )
    }
  }

  func testRuntimeDiagnosticsReportRedactsControllerSecret() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.externalControllerSettings = ExternalControllerSettings(
      host: "127.0.0.1",
      port: 19097,
      secret: "secret-token"
    )
    model.lastError = "Controller rejected Bearer secret-token"
    model.helperLogs = ["state = running", "last exit code = 0", "debug secret-token"]
    model.runtimeData.appendLog(level: "debug", message: "curl -H Authorization: Bearer secret-token")
    model.runtimeData.flushPendingLogs()

    let report = model.runtimeDiagnosticsReport(now: Date(timeIntervalSince1970: 1_700_000_000))
    let text = report.plainText

    XCTAssertFalse(text.contains("secret-token"))
    XCTAssertTrue(text.contains("Controller Secret: \(RuntimeDiagnosticsReport.redactedSecret)"))
    XCTAssertTrue(text.contains("Bearer \(RuntimeDiagnosticsReport.redactedSecret)"))
    XCTAssertTrue(text.contains("debug \(RuntimeDiagnosticsReport.redactedSecret)"))
  }

  func testRuntimeDiagnosticsReportUsesPreciseHelperFingerprintState() {
    func report(fingerprintRecorded: Bool, fingerprintMatches: Bool?) -> String {
      var helperDetail = TunnelHelperStatusDetail.unknown
      helperDetail.fingerprintRecorded = fingerprintRecorded
      helperDetail.fingerprintMatches = fingerprintMatches

      return RuntimeDiagnosticsReport(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        statusSummary: "Stopped",
        profileName: "No Profile",
        runtimeOwner: .stopped,
        routingMode: .systemProxy,
        runMode: .rule,
        controllerHost: "127.0.0.1",
        controllerPort: 9097,
        controllerSecret: "secret",
        coreStatus: "Stopped",
        systemProxyEnabled: false,
        tunEnabled: false,
        networkExtensionEnabled: false,
        tunSystemDNS: "Off",
        networkExtensionSystemDNS: "Off",
        tunDNSMode: "profile",
        ruleOverlaySummary: "Disabled",
        helperDetail: helperDetail,
        tunDiagnostics: .empty,
        networkExtensionDiagnostics: .empty,
        readinessIssue: nil,
        lastError: nil,
        recentLogs: [],
        helperLogs: []
      ).plainText
    }

    XCTAssertTrue(report(fingerprintRecorded: false, fingerprintMatches: nil).contains("Helper Fingerprint: not recorded"))
    XCTAssertTrue(report(fingerprintRecorded: true, fingerprintMatches: nil).contains("Helper Fingerprint: unknown"))
    XCTAssertTrue(report(fingerprintRecorded: true, fingerprintMatches: true).contains("Helper Fingerprint: match"))
    XCTAssertTrue(report(fingerprintRecorded: true, fingerprintMatches: false).contains("Helper Fingerprint: mismatch"))
  }

  func testRuleOverlaySettingsPersistIntoRuntimeOverrides() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let firstModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )
    let overlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "corp.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .match, policy: "Proxy")
      ],
      disabledRuleMatchers: [
        ManagedRuleDisableMatcher(mode: .contains, pattern: "ads.example")
      ]
    )

    firstModel.ruleOverlaySettings = overlay

    let secondModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(secondModel.ruleOverlaySettings, overlay)
    XCTAssertEqual(secondModel.overrides.ruleOverlay, overlay)
  }

  func testGlobalRuleOverlayPreflightFailureDoesNotPersistWithActiveProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - MATCH,DIRECT
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let rejectingCore = try Self.makeRuleOverlayPreflightCore(
      in: paths.appSupport,
      rejectedToken: "bad-preflight.example"
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: defaults,
      bundledCoreURLProvider: { rejectingCore }
    )
    let overlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "bad-preflight.example", policy: "DIRECT")
      ]
    )

    let didUpdate = await model.updateGlobalRuleOverlay(overlay)

    XCTAssertFalse(didUpdate)
    XCTAssertEqual(model.ruleOverlaySettings, .disabled)
    XCTAssertTrue(model.lastError?.contains("rejected by test core") == true)

    let reloadedModel = AppModel(
      paths: paths,
      profileStore: store,
      defaults: defaults,
      bundledCoreURLProvider: { rejectingCore }
    )
    XCTAssertEqual(reloadedModel.ruleOverlaySettings, .disabled)
  }

  func testGlobalRuleOverlaySavesWithoutActiveProfileWhenCoreWouldReject() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let rejectingCore = try Self.makeRuleOverlayPreflightCore(
      in: paths.appSupport,
      rejectedToken: "bad-preflight.example"
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults,
      bundledCoreURLProvider: { rejectingCore }
    )
    let overlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "bad-preflight.example", policy: "DIRECT")
      ]
    )

    let didUpdate = await model.updateGlobalRuleOverlay(overlay)

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(model.ruleOverlaySettings, overlay)
    XCTAssertNil(model.lastError)
  }

  func testTunSettingsMigratesMissingRouteExcludeAddressesFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "stack": "gvisor",
        "device": "utun9",
        "autoRoute": false,
        "strictRoute": true,
        "autoDetectInterface": false,
        "dnsHijack": ["any:53"],
        "mtu": 1400
      ],
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.tunSettings.stack, .gvisor)
    XCTAssertEqual(model.tunSettings.device, "utun9")
    XCTAssertFalse(model.tunSettings.autoRoute)
    XCTAssertTrue(model.tunSettings.strictRoute)
    XCTAssertFalse(model.tunSettings.autoDetectInterface)
    XCTAssertEqual(model.tunSettings.dnsHijack, ["any:53"])
    XCTAssertEqual(model.tunSettings.mtu, 1400)
    XCTAssertEqual(model.tunSettings.routeExcludeAddresses, [])
    XCTAssertTrue(model.tunSettings.dnsFakeIPEnabled)
    XCTAssertEqual(model.tunSettings.fakeIPRange, "198.18.0.1/16")
    XCTAssertTrue(model.tunSettings.systemDNSOverrideEnabled)
    XCTAssertEqual(model.tunSettings.effectiveSystemDNSServers, ["114.114.114.114"])
    XCTAssertEqual(model.tunSettings.dns, .default)
    XCTAssertEqual(model.overrides.tunSettings, model.tunSettings)
  }

  func testNewTunSettingsUseDefaultDNSOverlay() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.tunSettings.dns, .default)
    XCTAssertEqual(model.tunSettings.dns.nameserver, ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"])
    XCTAssertEqual(model.tunSettings.dns.fallback, ["tls://8.8.4.4", "tls://1.1.1.1"])
    XCTAssertTrue(model.tunSettings.dns.fakeIPFilter.contains("*.local"))
  }

  func testTunDNSDefaultsMigrationFillsEmptyLegacyOverlay() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "stack": "mixed",
        "device": "utun1024",
        "autoRoute": true,
        "strictRoute": false,
        "autoDetectInterface": true,
        "dnsHijack": ["any:53"],
        "mtu": 1500,
        "routeExcludeAddresses": [],
        "dnsFakeIPEnabled": true,
        "fakeIPRange": "198.18.0.1/16",
        "systemDNSOverrideEnabled": true,
        "systemDNSServers": ["114.114.114.114"],
        "dns": [:]
      ],
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.tunSettings.dns, .default)
    XCTAssertEqual(defaults.integer(forKey: Self.tunDNSDefaultsVersionKey), 1)
  }

  func testTunDNSDefaultsMigrationPreservesCustomOverlay() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "stack": "mixed",
        "device": "utun1024",
        "autoRoute": true,
        "strictRoute": false,
        "autoDetectInterface": true,
        "dnsHijack": ["any:53"],
        "mtu": 1500,
        "routeExcludeAddresses": [],
        "dnsFakeIPEnabled": true,
        "fakeIPRange": "198.18.0.1/16",
        "systemDNSOverrideEnabled": true,
        "systemDNSServers": ["114.114.114.114"],
        "dns": [
          "nameserver": ["https://dns.example/dns-query"],
          "fakeIPFilter": ["*.custom"]
        ]
      ],
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.tunSettings.dns.nameserver, ["https://dns.example/dns-query"])
    XCTAssertEqual(model.tunSettings.dns.fakeIPFilter, ["*.custom"])
    XCTAssertEqual(defaults.integer(forKey: Self.tunDNSDefaultsVersionKey), 1)
  }

  func testNetworkExtensionRoutingSettingsMigratesMissingFieldsFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [:],
      forKey: Self.networkExtensionRoutingSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertTrue(model.networkExtensionRoutingSettings.excludeLAN)
    XCTAssertTrue(model.networkExtensionRoutingSettings.dnsCaptureEnabled)
    XCTAssertTrue(model.networkExtensionRoutingSettings.dnsFakeIPEnabled)
    XCTAssertEqual(model.networkExtensionRoutingSettings.dnsListenPort, 1053)
    XCTAssertTrue(model.networkExtensionRoutingSettings.systemDNSOverrideEnabled)
    XCTAssertEqual(model.networkExtensionRoutingSettings.effectiveSystemDNSServers, ["114.114.114.114"])
    XCTAssertEqual(model.networkExtensionRoutingSettings.customRouteExcludeCIDRs, [])
    XCTAssertEqual(
      model.networkExtensionRoutingSettings.effectiveRouteExcludeCIDRs,
      NetworkExtensionRoutingSettings.defaultLANRouteExcludeCIDRs
    )
  }

  func testNetworkExtensionRoutingSettingsMigratesPersistedLegacyFakeIPDNS() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      ["excludeLAN": false, "dnsFakeIP": true, "customRouteExcludeCIDRs": ["100.64.0.0/10"]],
      forKey: Self.networkExtensionRoutingSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertFalse(model.networkExtensionRoutingSettings.excludeLAN)
    XCTAssertTrue(model.networkExtensionRoutingSettings.dnsFakeIPEnabled)
    XCTAssertEqual(model.networkExtensionRoutingSettings.customRouteExcludeCIDRs, ["100.64.0.0/10"])
  }

  func testUpdatingTunSettingsRejectsInvalidCIDRAndSystemDNS() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
    )

    var settings = TunSettings.default
    settings.routeExcludeAddresses = ["foo/24"]

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN route exclude CIDR: foo/24")

    settings = .default
    settings.systemDNSServers = ["not-a-dns-server"]

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN system DNS server: not-a-dns-server")

    settings = .default
    settings.dns = TunDNSSettings(nameserver: ["bad resolver"])

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN DNS nameserver: bad resolver")

    settings = .default
    settings.dns = TunDNSSettings(nameserver: ["999.1.1.1"])

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN DNS nameserver: 999.1.1.1")

    settings = .default
    settings.dns = TunDNSSettings(nameserver: ["https://999.1.1.1/dns-query"])

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN DNS nameserver: https://999.1.1.1/dns-query")

    settings = .default
    settings.dns = TunDNSSettings(defaultNameserver: ["https://dns.alidns.com/dns-query"])

    XCTAssertFalse(model.updateTunSettings(settings))
    XCTAssertEqual(model.lastError, "Invalid TUN DNS default-nameserver: https://dns.alidns.com/dns-query")
  }

  func testExternalControllerSettingsMigratesMissingCORSFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "enabled": false,
        "host": "localhost",
        "port": 19197,
        "secret": "saved-secret"
      ],
      forKey: Self.externalControllerSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertFalse(model.externalControllerSettings.enabled)
    XCTAssertEqual(model.externalControllerSettings.host, "localhost")
    XCTAssertEqual(model.externalControllerSettings.port, 19197)
    XCTAssertEqual(model.externalControllerSettings.cors, .default)
    XCTAssertNotEqual(model.externalControllerSettings.secret, "saved-secret")
    XCTAssertFalse(model.externalControllerSettings.secret.isEmpty)
    XCTAssertEqual(model.overrides.externalControllerHost, "127.0.0.1")
    XCTAssertEqual(model.overrides.externalControllerPort, 19197)
    XCTAssertFalse(model.overrides.externalControllerCORS.enabled)
  }

  func testExternalDashboardProfileStoresSecretOutsidePersistedProfileAndDowngradesRemoteWriteToCopy() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let dashboardSecrets = InMemorySecretStore()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults,
      externalDashboardSecretStore: dashboardSecrets
    )

    let profile = ExternalDashboardProfile(
      name: "Local YACD",
      url: URL(string: "https://yacd.example")!,
      readOnly: false
    )

    XCTAssertTrue(model.saveExternalDashboardProfile(profile, secret: "dashboard-secret"))
    let saved = try XCTUnwrap(model.externalDashboardProfiles.first { $0.name == "Local YACD" })
    let account = try XCTUnwrap(saved.secretAccount)
    let encodedProfiles = String(data: try JSONEncoder().encode(model.externalDashboardProfiles), encoding: .utf8)

    XCTAssertEqual(dashboardSecrets.storedValues[account], "dashboard-secret")
    XCTAssertFalse(encodedProfiles?.contains("dashboard-secret") == true)
    let plan = model.externalDashboardOpenPlan(for: saved)
    let queryItems = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    XCTAssertEqual(plan.secretDelivery, .manualCopy)
    XCTAssertEqual(plan.secretForManualCopy, "dashboard-secret")
    XCTAssertNil(queryItems.first { $0.name.caseInsensitiveCompare("secret") == .orderedSame })
    XCTAssertNil(URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.fragment)
    XCTAssertFalse(model.externalControllerSettings.cors.allowedOrigins.contains("https://yacd.example"))
  }

  func testReadOnlyExternalDashboardDoesNotExposeControllerSecret() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let dashboardSecrets = InMemorySecretStore()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults,
      externalDashboardSecretStore: dashboardSecrets
    )
    let profile = ExternalDashboardProfile(
      name: "Read Only",
      url: URL(string: "https://yacd.example?theme=dark&secret=embedded")!,
      readOnly: true
    )

    XCTAssertTrue(model.saveExternalDashboardProfile(profile, secret: "dashboard-secret"))
    let saved = try XCTUnwrap(model.externalDashboardProfiles.first { $0.name == "Read Only" })
    let url = model.externalDashboardURL(for: saved)
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    XCTAssertEqual(queryItems.first { $0.name == "theme" }?.value, "dark")
    XCTAssertEqual(queryItems.first { $0.name == "hostname" }?.value, model.externalControllerSettings.normalizedHost)
    XCTAssertEqual(queryItems.first { $0.name == "port" }?.value, "\(model.externalControllerSettings.normalizedPort)")
    XCTAssertNil(queryItems.first { $0.name.caseInsensitiveCompare("secret") == .orderedSame })
    XCTAssertNil(saved.secretAccount)
    XCTAssertEqual(model.externalDashboardOpenPlan(for: saved).secretDelivery, .none)
  }

  func testTrustedExternalDashboardUsesFragmentSecretAndRemovesQuerySecret() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let dashboardSecrets = InMemorySecretStore()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults,
      externalDashboardSecretStore: dashboardSecrets
    )
    let profile = ExternalDashboardProfile(
      name: "Trusted Remote",
      url: URL(string: "https://yacd.example/app?theme=dark&secret=embedded#/proxies?secret=old&tab=rules")!,
      readOnly: false,
      trustedForSecretAutofill: true
    )

    XCTAssertTrue(model.saveExternalDashboardProfile(profile, secret: "dashboard secret"))
    let saved = try XCTUnwrap(model.externalDashboardProfiles.first { $0.name == "Trusted Remote" })
    let plan = model.externalDashboardOpenPlan(for: saved)
    let components = try XCTUnwrap(URLComponents(url: plan.url, resolvingAgainstBaseURL: false))
    let queryItems = components.queryItems ?? []
    let fragment = try XCTUnwrap(components.fragment)
    let fragmentQuery = String(fragment.split(separator: "?", maxSplits: 1).last ?? "")
    var fragmentComponents = URLComponents()
    fragmentComponents.query = fragmentQuery
    let fragmentItems = fragmentComponents.queryItems ?? []

    XCTAssertEqual(plan.secretDelivery, .fragment)
    XCTAssertNil(plan.secretForManualCopy)
    XCTAssertEqual(queryItems.first { $0.name == "theme" }?.value, "dark")
    XCTAssertEqual(queryItems.first { $0.name == "hostname" }?.value, model.externalControllerSettings.normalizedHost)
    XCTAssertEqual(queryItems.first { $0.name == "port" }?.value, "\(model.externalControllerSettings.normalizedPort)")
    XCTAssertNil(queryItems.first { $0.name.caseInsensitiveCompare("secret") == .orderedSame })
    XCTAssertTrue(fragment.hasPrefix("/proxies?"))
    XCTAssertEqual(fragmentItems.first { $0.name == "tab" }?.value, "rules")
    XCTAssertEqual(fragmentItems.first { $0.name.caseInsensitiveCompare("secret") == .orderedSame }?.value, "dashboard secret")
    XCTAssertEqual(model.externalControllerSettings.cors.allowedOrigins, ["https://yacd.example"])
    XCTAssertEqual(model.overrides.externalControllerCORS.allowedOrigins, ["https://yacd.example"])
  }

  func testLocalExternalDashboardAutofillsSecretWithoutTrustedFlag() throws {
    let plan = AppModel.dashboardOpenPlan(
      baseURL: URL(string: "http://localhost:9090/ui?secret=old")!,
      controllerHost: "127.0.0.1",
      controllerPort: 9097,
      readOnly: false,
      trustedForSecretAutofill: false,
      secret: "local-secret"
    )
    let components = try XCTUnwrap(URLComponents(url: plan.url, resolvingAgainstBaseURL: false))

    XCTAssertEqual(plan.secretDelivery, .fragment)
    XCTAssertNil((components.queryItems ?? []).first { $0.name.caseInsensitiveCompare("secret") == .orderedSame })
    XCTAssertEqual(components.fragment, "secret=local-secret")
  }

  func testExternalDashboardProfileDecodesTrustedAutofillAsFalseByDefault() throws {
    let data = """
    {
      "id": "\(UUID().uuidString)",
      "name": "Legacy",
      "url": "https://yacd.example",
      "readOnly": false,
      "secretAccount": "external-dashboard-legacy"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ExternalDashboardProfile.self, from: data)

    XCTAssertFalse(decoded.trustedForSecretAutofill)
  }

  func testExternalControllerSettingsMigratesPartialNestedCORSFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "enabled": true,
        "host": "localhost",
        "port": 19198,
        "secret": "saved-secret",
        "cors": [
          "enabled": true
        ]
      ],
      forKey: Self.externalControllerSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertTrue(model.externalControllerSettings.enabled)
    XCTAssertEqual(model.externalControllerSettings.host, "localhost")
    XCTAssertEqual(model.externalControllerSettings.port, 19198)
    XCTAssertTrue(model.externalControllerSettings.cors.enabled)
    XCTAssertEqual(model.externalControllerSettings.cors.allowPrivateNetwork, ExternalControllerCORSSettings.default.allowPrivateNetwork)
    XCTAssertEqual(model.externalControllerSettings.cors.allowedOrigins, ExternalControllerCORSSettings.default.allowedOrigins)
    XCTAssertNotEqual(model.externalControllerSettings.secret, "saved-secret")
    XCTAssertEqual(model.overrides.externalControllerHost, "127.0.0.1")
    XCTAssertTrue(model.overrides.externalControllerCORS.enabled)
    XCTAssertEqual(model.overrides.externalControllerCORS.allowedOrigins, ExternalControllerCORSSettings.default.allowedOrigins)
  }

  func testExternalControllerSettingsRemovesLegacyDefaultPanelCORSOriginsOnLoad() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "enabled": true,
        "host": "127.0.0.1",
        "port": 19198,
        "secret": "saved-secret",
        "cors": [
          "enabled": true,
          "allowPrivateNetwork": true,
          "allowedOrigins": [
            "https://custom.example",
            "https://yacd.metacubex.one",
            "https://metacubex.github.io",
            "https://board.zash.run.place"
          ]
        ]
      ],
      forKey: Self.externalControllerSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.externalControllerSettings.cors.allowedOrigins, ["https://custom.example"])
    XCTAssertEqual(model.overrides.externalControllerCORS.allowedOrigins, ["https://custom.example"])
  }

  func testRuntimeOverridesMigratesMissingNestedSettings() throws {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "mixedPort": 7891,
        "externalControllerHost": "localhost",
        "externalControllerPort": 19197,
        "secret": "secret-token",
        "allowLan": true,
        "mode": "global",
        "logLevel": "debug",
        "unifiedDelay": true,
        "dnsEnabled": true,
        "tunEnabled": true
      ]
    )

    let decoded = try JSONDecoder().decode(RuntimeOverrides.self, from: data)

    XCTAssertEqual(decoded.mixedPort, 7891)
    XCTAssertEqual(decoded.externalControllerHost, "127.0.0.1")
    XCTAssertEqual(decoded.externalControllerPort, 19197)
    XCTAssertEqual(decoded.secret, "secret-token")
    XCTAssertTrue(decoded.allowLan)
    XCTAssertFalse(decoded.ipv6Enabled)
    XCTAssertEqual(decoded.mode, .global)
    XCTAssertEqual(decoded.logLevel, "debug")
    XCTAssertTrue(decoded.unifiedDelay)
    XCTAssertEqual(decoded.dnsEnabled, true)
    XCTAssertTrue(decoded.tunEnabled)
    XCTAssertEqual(decoded.externalControllerCORS, .default)
    XCTAssertEqual(decoded.tunSettings, .default)
  }

  func testDelayTestSettingsMigratesMissingTimeoutFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "mode": "nativePing",
        "unifiedDelay": true
      ],
      forKey: Self.delayTestSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.delayTestSettings.mode, .nativePing)
    XCTAssertTrue(model.delayTestSettings.unifiedDelay)
    XCTAssertEqual(model.delayTestSettings.timeoutMilliseconds, DelayTestSettings.default.timeoutMilliseconds)
    XCTAssertTrue(model.overrides.unifiedDelay)
  }

  func testProxyPageSettingsPersistAcrossStoreReloads() throws {
    let defaults = try Self.makeIsolatedDefaults()
    let first = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    first.proxyPageSettings = ProxyPageSettings(
      viewMode: .allGroups,
      sortOrder: .delay,
      nodePresentation: .list,
      showsNodeDetails: false,
      closesOldConnectionsAfterSwitch: true,
      customDelayTestURLsByGroupName: [
        "Proxy": " https://example.com/delay ",
        "Auto": "https://example.com/auto"
      ]
    )

    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(reloaded.proxyPageSettings.viewMode, .allGroups)
    XCTAssertEqual(reloaded.proxyPageSettings.sortOrder, .delay)
    XCTAssertEqual(reloaded.proxyPageSettings.nodePresentation, .list)
    XCTAssertFalse(reloaded.proxyPageSettings.showsNodeDetails)
    XCTAssertTrue(reloaded.proxyPageSettings.closesOldConnectionsAfterSwitch)
    XCTAssertEqual(
      reloaded.proxyPageSettings.customDelayTestURLText(forGroupName: "Proxy"),
      "https://example.com/delay"
    )
    XCTAssertEqual(
      reloaded.proxyPageSettings.customDelayTestURLText(forGroupName: "Auto"),
      "https://example.com/auto"
    )
  }

  func testProxyPageSettingsMigratesMissingFieldsFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "sortOrder": "delay",
        "customDelayTestURLsByGroupName": [
          " Proxy ": " https://example.com/delay ",
          "Empty": ""
        ]
      ],
      forKey: Self.proxyPageSettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.proxyPageSettings.viewMode, ProxyPageSettings.default.viewMode)
    XCTAssertEqual(model.proxyPageSettings.sortOrder, .delay)
    XCTAssertEqual(model.proxyPageSettings.nodePresentation, ProxyPageSettings.default.nodePresentation)
    XCTAssertEqual(
      model.proxyPageSettings.customDelayTestURLText(forGroupName: "Proxy"),
      "https://example.com/delay"
    )
    XCTAssertEqual(model.proxyPageSettings.customDelayTestURLText(forGroupName: "Empty"), "")
  }

  func testIPv6SettingPersistsAndSyncsRuntimeOverrides() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let firstModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertFalse(firstModel.ipv6Enabled)
    XCTAssertFalse(firstModel.overrides.ipv6Enabled)

    firstModel.setIPv6Enabled(true)

    XCTAssertTrue(firstModel.ipv6Enabled)
    XCTAssertTrue(firstModel.overrides.ipv6Enabled)

    let secondModel = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertTrue(secondModel.ipv6Enabled)
    XCTAssertTrue(secondModel.overrides.ipv6Enabled)
  }

  func testSystemProxySettingsMigratesMissingGuardIntervalFromUserDefaults() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    try Self.storeJSON(
      [
        "proxyHost": "192.168.1.20",
        "customBypassDomains": ["localhost", "*.corp"],
        "useDefaultBypass": false,
        "validateBypass": false,
        "guardEnabled": true
      ],
      forKey: Self.systemProxySettingsDefaultsKey,
      defaults: defaults
    )

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertEqual(model.systemProxySettings.proxyHost, "192.168.1.20")
    XCTAssertEqual(model.systemProxySettings.customBypassDomains, ["localhost", "*.corp"])
    XCTAssertFalse(model.systemProxySettings.useDefaultBypass)
    XCTAssertFalse(model.systemProxySettings.validateBypass)
    XCTAssertTrue(model.systemProxySettings.guardEnabled)
    XCTAssertEqual(model.systemProxySettings.guardIntervalSeconds, SystemProxySettings.default.guardIntervalSeconds)
  }

  func testSystemProxySettingsFallsBackForWrongTypedGuardIntervalWithoutResettingSiblings() throws {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "proxyHost": "192.168.1.20",
        "customBypassDomains": ["localhost", "*.corp"],
        "useDefaultBypass": false,
        "validateBypass": false,
        "guardEnabled": true,
        "guardIntervalSeconds": "slow"
      ]
    )

    let decoded = try JSONDecoder().decode(SystemProxySettings.self, from: data)

    XCTAssertEqual(decoded.proxyHost, "192.168.1.20")
    XCTAssertEqual(decoded.customBypassDomains, ["localhost", "*.corp"])
    XCTAssertFalse(decoded.useDefaultBypass)
    XCTAssertFalse(decoded.validateBypass)
    XCTAssertTrue(decoded.guardEnabled)
    XCTAssertEqual(decoded.guardIntervalSeconds, SystemProxySettings.default.guardIntervalSeconds)
  }

  func testExternalControllerCORSSettingsNormalizesOriginsWhenDecoded() throws {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "enabled": true,
        "allowPrivateNetwork": false,
        "allowedOrigins": [
          " https://custom.example ",
          "https://custom.example",
          "\n",
          "HTTPS://PANEL.EXAMPLE"
        ]
      ]
    )

    let decoded = try JSONDecoder().decode(ExternalControllerCORSSettings.self, from: data)

    XCTAssertTrue(decoded.enabled)
    XCTAssertFalse(decoded.allowPrivateNetwork)
    XCTAssertEqual(decoded.allowedOrigins, ["https://custom.example", "HTTPS://PANEL.EXAMPLE"])
  }

  func testSystemProxySettingsNormalizesCustomBypassDomainsWhenDecoded() throws {
    let data = try JSONSerialization.data(
      withJSONObject: [
        "proxyHost": "192.168.1.20",
        "customBypassDomains": [
          " localhost ",
          "LOCALHOST",
          "",
          "\n",
          " *.corp ",
          "*.corp"
        ],
        "useDefaultBypass": false,
        "validateBypass": true,
        "guardEnabled": true,
        "guardIntervalSeconds": 10
      ]
    )

    let decoded = try JSONDecoder().decode(SystemProxySettings.self, from: data)

    XCTAssertEqual(decoded.customBypassDomains, ["localhost", "*.corp"])
    XCTAssertFalse(decoded.useDefaultBypass)
    XCTAssertTrue(decoded.validateBypass)
    XCTAssertTrue(decoded.guardEnabled)
    XCTAssertEqual(decoded.guardIntervalSeconds, 10)
  }

  func testPersistedSettingsRoundTripCurrentSchema() throws {
    try assertRoundTrip(
      DelayTestSettings(mode: .nativePing, unifiedDelay: true, timeoutMilliseconds: 2_500)
    )
    try assertRoundTrip(
      SubscriptionFetchSettings(
        userAgent: "Clash Verge/2.0.0",
        timeoutSeconds: 45,
        useLocalClashProxy: false,
        useSystemProxy: true,
        allowsInsecureTLS: true,
        automaticUpdatesEnabled: false,
        defaultUpdateIntervalMinutes: 2_880,
        backgroundCheckIntervalMinutes: 120,
        retryCapMinutes: 360,
        notifyOnUpdateFailure: true
      )
    )
    try assertRoundTrip(
      MenuBarPinnedGroupSettings(groupNames: ["Proxy", "Auto", "Fallback", "Ignored"])
    )
    try assertRoundTrip(
      ProxyPageSettings(
        viewMode: .allGroups,
        sortOrder: .delay,
        nodePresentation: .list,
        showsNodeDetails: false,
        closesOldConnectionsAfterSwitch: true,
        customDelayTestURLsByGroupName: ["Proxy": "https://example.com/delay"]
      )
    )
    try assertRoundTrip(
      NetworkPolicySettings(
        rules: [
          NetworkPolicyRule(
            name: "Office",
            ssid: "CorpWiFi",
            proxyRoutingMode: .systemProxy,
            enableSystemProxy: true
          )
        ]
      )
    )
    try assertRoundTrip(
      ExternalControllerCORSSettings(
        enabled: true,
        allowPrivateNetwork: false,
        allowedOrigins: ["https://custom.example", "https://yacd.metacubex.one"]
      )
    )
    try assertRoundTrip(
      PersistedRuntimeSettings(
        mixedPort: 7891,
        allowLan: true,
        dnsEnabled: true,
        mode: .global,
        logLevel: "debug"
      )
    )
    try assertRoundTrip(
      ExternalControllerSettings(
        enabled: true,
        host: "localhost",
        port: 19197,
        secret: "secret-token",
        cors: ExternalControllerCORSSettings(enabled: false, allowPrivateNetwork: false, allowedOrigins: ["https://custom.example"])
      )
    )
    try assertRoundTrip(
      SystemProxySettings(
        proxyHost: "127.0.0.1",
        customBypassDomains: ["localhost", "*.corp"],
        useDefaultBypass: false,
        validateBypass: true,
        guardEnabled: true,
        guardIntervalSeconds: 10
      )
    )
    try assertRoundTrip(
      TunSettings(
        stack: .gvisor,
        device: "utun9",
        autoRoute: false,
        strictRoute: true,
        autoDetectInterface: false,
        dnsHijack: ["any:53"],
        mtu: 1400,
        routeExcludeAddresses: ["10.0.0.0/8"],
        dns: TunDNSSettings(
          fakeIPFilter: ["*.lan"],
          nameserver: ["223.5.5.5"],
          fallback: ["https://dns.google/dns-query"],
          proxyServerNameserver: ["119.29.29.29"],
          directNameserver: ["114.114.114.114"],
          nameserverPolicy: ["geosite:cn": "223.5.5.5"],
          hosts: ["router.lan": "192.168.1.1"]
        )
      )
    )
    try assertRoundTrip(
      NetworkExtensionRoutingSettings(
        excludeLAN: false,
        customRouteExcludeCIDRs: ["100.64.0.0/10", "2001:db8::/32"]
      )
    )
    try assertRoundTrip(
      RuntimeOverrides(
        mixedPort: 7891,
        externalControllerHost: "127.0.0.1",
        externalControllerPort: 19197,
        secret: "secret-token",
        allowLan: true,
        ipv6Enabled: true,
        mode: .global,
        logLevel: "debug",
        dnsEnabled: true,
        tunEnabled: true,
        unifiedDelay: true,
        externalControllerCORS: ExternalControllerCORSSettings(enabled: true, allowPrivateNetwork: false, allowedOrigins: ["https://custom.example"]),
        tunSettings: TunSettings(
          stack: .system,
          device: "utun10",
          autoRoute: true,
          strictRoute: true,
          autoDetectInterface: true,
          dnsHijack: ["any:53"],
          mtu: 1500,
          routeExcludeAddresses: ["192.168.0.0/16"]
        )
      )
    )
  }

  func testRuntimeSettingsPersistAcrossStoreReloads() throws {
    let defaults = try Self.makeIsolatedDefaults()
    let first = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    first.overrides.mixedPort = 17_891
    first.overrides.allowLan = true
    first.overrides.dnsEnabled = true
    first.overrides.logLevel = "debug"
    first.overrides.mode = .global

    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(reloaded.overrides.mixedPort, 17_891)
    XCTAssertTrue(reloaded.overrides.allowLan)
    XCTAssertEqual(reloaded.overrides.dnsEnabled, true)
    XCTAssertEqual(reloaded.overrides.logLevel, "debug")
    XCTAssertEqual(reloaded.overrides.mode, .global)
  }

  func testRuntimeSettingsPersistenceExcludesEphemeralRuntimeOverrides() throws {
    let defaults = try Self.makeIsolatedDefaults()
    let first = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    first.overrides.mixedPort = 17_892
    first.overrides.secret = "must-not-persist"
    first.overrides.tunEnabled = true

    let persistedData = try XCTUnwrap(defaults.data(forKey: Self.runtimeSettingsDefaultsKey))
    let persistedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
    )
    XCTAssertEqual(persistedObject["mixedPort"] as? Int, 17_892)
    XCTAssertNil(persistedObject["secret"])
    XCTAssertNil(persistedObject["tunEnabled"])
    XCTAssertNil(persistedObject["externalControllerHost"])

    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(reloaded.overrides.mixedPort, 17_892)
    XCTAssertNotEqual(reloaded.overrides.secret, "must-not-persist")
    XCTAssertFalse(reloaded.overrides.secret.isEmpty)
    XCTAssertFalse(reloaded.overrides.tunEnabled)
  }

  func testPartialRuntimeSettingsDecodeUsesLaunchDefaults() throws {
    let data = try JSONSerialization.data(withJSONObject: ["mixedPort": 17_893])
    let decoded = try JSONDecoder().decode(PersistedRuntimeSettings.self, from: data)

    XCTAssertEqual(decoded.mixedPort, 17_893)
    XCTAssertFalse(decoded.allowLan)
    XCTAssertNil(decoded.dnsEnabled)
    XCTAssertEqual(decoded.mode, .rule)
    XCTAssertEqual(decoded.logLevel, "info")
  }

  func testAppModelRuntimeOverridesPersistAcrossModelReloads() throws {
    let defaults = try Self.makeIsolatedDefaults()
    let paths = try Self.makeRuntimePaths()
    let first = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    first.overrides.mixedPort = 17_894
    first.overrides.allowLan = true
    first.overrides.dnsEnabled = true
    first.overrides.logLevel = "warning"
    first.setMode(.direct)

    let reloaded = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(reloaded.overrides.mixedPort, 17_894)
    XCTAssertTrue(reloaded.overrides.allowLan)
    XCTAssertEqual(reloaded.overrides.dnsEnabled, true)
    XCTAssertEqual(reloaded.overrides.logLevel, "warning")
    XCTAssertEqual(reloaded.overrides.mode, .direct)
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

  func testApplyingCurrentNetworkPolicyUsesSavedRuleOnly() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults,
      currentNetworkProvider: StaticCurrentNetworkProvider(ssid: "corpnet")
    )
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule])

    model.applyMatchingNetworkPolicyForCurrentNetwork()

    for _ in 0..<40 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.currentNetworkSSID, "corpnet")
    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertEqual(model.networkPolicyStatusMessage, "Applied Office Wi-Fi for corpnet.")
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
  }

  func testNetworkPolicyRuleAutoStartDefaultsOffForLegacyDecoding() throws {
    let decoded = try JSONDecoder().decode(NetworkPolicyRule.self, from: Data("""
    {
      "id": "\(UUID().uuidString)",
      "name": "Office",
      "ssid": "CorpNet",
      "proxyRoutingMode": "systemProxy",
      "enableSystemProxy": true
    }
    """.utf8))
    let settings = try JSONDecoder().decode(NetworkPolicySettings.self, from: Data("""
    {
      "rules": []
    }
    """.utf8))

    XCTAssertFalse(decoded.autoStartRuntime)
    XCTAssertTrue(settings.autoApplyEnabled)
    XCTAssertEqual(settings.unmatchedBehavior, .keepCurrent)
    XCTAssertEqual(NetworkPolicySettings.default.unmatchedBehavior, .restorePreviousState)
  }

  func testNetworkPolicyRestoresPreviousStateAfterLeavingMatchedSSID() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let provider = MutableCurrentNetworkProvider(ssid: "corpnet")
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults,
      currentNetworkProvider: provider
    )
    model.setProxyRoutingMode(.neProxy)
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: true)

    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)

    provider.ssid = "home"
    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where model.systemProxyEnabled || model.proxyRoutingMode != .neProxy {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertNil(model.lastAppliedNetworkPolicyID)
    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertTrue(model.networkPolicyStatusMessage?.localizedCaseInsensitiveContains("corpnet") == true)
  }

  func testManualApplyCurrentRestoresPreviousStateWhenNoSSIDMatches() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let provider = MutableCurrentNetworkProvider(ssid: "corpnet")
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults,
      currentNetworkProvider: provider
    )
    model.setProxyRoutingMode(.neProxy)
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: true)

    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)

    provider.ssid = "home"
    model.applyMatchingNetworkPolicyForCurrentNetwork()
    for _ in 0..<120 where model.systemProxyEnabled || model.proxyRoutingMode != .neProxy {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertNil(model.lastAppliedNetworkPolicyID)
    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertTrue(model.networkPolicyStatusMessage?.localizedCaseInsensitiveContains("home") == true)
  }

  func testNetworkPolicyRestoreSnapshotSurvivesAutomaticRoutingRestart() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let provider = MutableCurrentNetworkProvider(ssid: "corpnet")
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .neProxy,
      enableSystemProxy: false
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults(),
      currentNetworkProvider: provider,
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: true)
    model.start()
    for _ in 0..<500 where !model.isRunning || !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(model.isRunning, model.lastError ?? model.statusSummary)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)

    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<1_000 where model.runtimeOwner != .networkExtension || model.startInFlight || model.lastAppliedNetworkPolicyID != rule.id {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertGreaterThanOrEqual(launcher.launchCount, 2)

    provider.ssid = "home"
    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<1_000 where model.lastAppliedNetworkPolicyID != nil || model.proxyRoutingMode != .systemProxy || !model.systemProxyEnabled || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertNil(model.lastAppliedNetworkPolicyID)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)
  }

  func testNetworkPolicyRestoresOriginalStateAfterMovingBetweenMatchedSSIDs() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let provider = MutableCurrentNetworkProvider(ssid: "corpnet")
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let officeRule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let cafeRule = NetworkPolicyRule(
      name: "Cafe Wi-Fi",
      ssid: "CafeNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults,
      currentNetworkProvider: provider
    )
    model.setProxyRoutingMode(.neProxy)
    model.networkPolicySettings = NetworkPolicySettings(rules: [officeRule, cafeRule], autoApplyEnabled: true)

    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where !model.systemProxyEnabled || model.lastAppliedNetworkPolicyID != officeRule.id {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(model.lastAppliedNetworkPolicyID, officeRule.id)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)

    provider.ssid = "CafeNet"
    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where model.lastAppliedNetworkPolicyID != cafeRule.id {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(model.lastAppliedNetworkPolicyID, cafeRule.id)
    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)

    provider.ssid = "home"
    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where model.lastAppliedNetworkPolicyID != nil || model.systemProxyEnabled || model.proxyRoutingMode != .neProxy {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertNil(model.lastAppliedNetworkPolicyID)
    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertFalse(model.systemProxyEnabled)
  }

  func testManualRoutingChangePreventsNetworkPolicyRestore() async throws {
    let paths = try Self.makeRuntimePaths()
    let provider = MutableCurrentNetworkProvider(ssid: "corpnet")
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: try Self.makeIsolatedDefaults(),
      currentNetworkProvider: provider
    )
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: true)

    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    for _ in 0..<120 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    model.requestProxyRoutingMode(.neProxy)
    for _ in 0..<40 where model.proxyRoutingMode != .neProxy {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    provider.ssid = "home"
    model.handleNetworkEnvironmentMayHaveChanged(reason: "path")
    try? await Task.sleep(nanoseconds: 800_000_000)

    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertFalse(model.systemProxyEnabled)
  }

  func testNetworkEnvironmentMonitorAppliesMatchingPolicyAfterDebounce() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let monitor = ManualNetworkEnvironmentMonitor()
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: defaults,
      currentNetworkProvider: StaticCurrentNetworkProvider(ssid: "corpnet"),
      networkEnvironmentMonitor: monitor
    )
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: true)
    model.startNetworkEnvironmentMonitoring()

    monitor.emit(NetworkEnvironmentEvent(reason: "path", ssid: "corpnet", pathStatus: "satisfied", isExpensive: false, isConstrained: false))

    for _ in 0..<120 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
  }

  func testNetworkEnvironmentMonitorSkipsWhenAutoApplyIsDisabled() async throws {
    let paths = try Self.makeRuntimePaths()
    let monitor = ManualNetworkEnvironmentMonitor()
    let rule = NetworkPolicyRule(name: "Office Wi-Fi", ssid: "CorpNet", proxyRoutingMode: .systemProxy)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults(),
      currentNetworkProvider: StaticCurrentNetworkProvider(ssid: "corpnet"),
      networkEnvironmentMonitor: monitor
    )
    model.networkPolicySettings = NetworkPolicySettings(rules: [rule], autoApplyEnabled: false)
    model.startNetworkEnvironmentMonitoring()

    monitor.emit(NetworkEnvironmentEvent(reason: "path", ssid: "corpnet", pathStatus: "satisfied", isExpensive: false, isConstrained: false))
    try? await Task.sleep(nanoseconds: 800_000_000)

    XCTAssertNil(model.lastAppliedNetworkPolicyID)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertEqual(model.networkPolicyStatusMessage, "Automatic network policy application is off.")
  }

  func testNetworkPolicyCanAutoStartRuntimeWhenRuleRequestsIt() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    await model.waitForProfilePreviewRefresh()
    let rule = NetworkPolicyRule(
      name: "Office Wi-Fi",
      ssid: "CorpNet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: false,
      autoStartRuntime: true
    )

    model.applyNetworkPolicy(rule)

    for _ in 0..<500 where !model.isRunning {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.isRunning, model.lastError ?? model.statusSummary)
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertEqual(model.lastAppliedNetworkPolicyID, rule.id)
  }

  func testCommandURLTogglesSystemProxyWithoutSubscriptionImport() async throws {
    let paths = try Self.makeRuntimePaths()
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let controller = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      systemProxyController: controller,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.handleIncomingURL(try XCTUnwrap(URL(string: "clashmax://toggle-system-proxy")))

    for _ in 0..<40 where !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertNil(model.lastError)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
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

    for _ in 0..<100 {
      model.runtimeData.flushPendingLogs()
      if model.logs.contains(where: { $0.message.contains("could not read Wi-Fi proxy settings") }) {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    model.runtimeData.flushPendingLogs()

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
    XCTAssertEqual(noDelay.label, "Unknown")
    XCTAssertEqual(noDelay.tone, .unavailable)

    let fast = ProxyDelayDisplay(delay: 100)
    XCTAssertEqual(fast.label, "100 ms")
    XCTAssertEqual(fast.tone, .fast)

    XCTAssertEqual(ProxyDelayDisplay(state: .testing).label, "Testing")
    XCTAssertEqual(ProxyDelayDisplay(state: .testing).tone, .testing)
    XCTAssertEqual(ProxyDelayDisplay(state: .timeout).label, "Timeout")
    XCTAssertEqual(ProxyDelayDisplay(state: .timeout).tone, .timeout)
    XCTAssertEqual(ProxyDelayDisplay(state: .error("failed")).label, "Error")
    XCTAssertEqual(ProxyDelayDisplay(state: .error("failed")).tone, .error)

    XCTAssertEqual(ProxyDelayDisplay(delay: 101).tone, .good)
    XCTAssertEqual(ProxyDelayDisplay(delay: 150).tone, .good)
    XCTAssertEqual(ProxyDelayDisplay(delay: 151).tone, .moderate)
    XCTAssertEqual(ProxyDelayDisplay(delay: 250).tone, .moderate)
    XCTAssertEqual(ProxyDelayDisplay(delay: 251).tone, .slow)
  }

  func testProxyDelayFailureKindLabels() {
    XCTAssertEqual(ProxyDelayFailureKind.timeout.displayName, String(localized: "Timeout"))
    XCTAssertEqual(ProxyDelayFailureKind.missingEndpoint.displayName, String(localized: "Missing endpoint"))
    XCTAssertEqual(ProxyDelayFailureKind.controllerUnavailable.displayName, String(localized: "Controller unavailable"))
    XCTAssertEqual(ProxyDelayFailureKind.cancelled.displayName, String(localized: "Cancelled"))
    XCTAssertEqual(ProxyDelayFailureKind.other.displayName, String(localized: "Error"))
  }

  func testProxySearchQuerySupportsCaseSensitiveWholeWordAndRegexTokens() {
    let japanNode = ProxyNode(
      name: "JP Tokyo",
      type: "vless",
      delay: 83,
      isSelectable: true,
      providerName: "Remote"
    )
    let japaneseNode = ProxyNode(
      name: "Japanese Relay",
      type: "vless",
      delay: 120,
      isSelectable: true,
      providerName: "Remote"
    )
    let group = ProxyGroup(name: "Proxy", type: "select", selected: "JP Tokyo", nodes: [japanNode, japaneseNode])

    XCTAssertTrue(ProxySearchQuery(rawValue: "jp").matches(group: group, node: japanNode))
    XCTAssertFalse(ProxySearchQuery(rawValue: "case=true jp").matches(group: group, node: japanNode))
    XCTAssertTrue(ProxySearchQuery(rawValue: "case=true JP").matches(group: group, node: japanNode))
    XCTAssertFalse(ProxySearchQuery(rawValue: "word=true Japan").matches(group: group, node: japaneseNode))
    XCTAssertTrue(ProxySearchQuery(rawValue: "word=true Japanese").matches(group: group, node: japaneseNode))
    XCTAssertTrue(ProxySearchQuery(rawValue: "case=true regex=.*JP").matches(group: group, node: japanNode))
    XCTAssertFalse(ProxySearchQuery(rawValue: "case=true regex=.*jp").matches(group: group, node: japanNode))
  }

  func testProxyGroupSearchFilterNarrowsGroupsAndNodes() {
    let fastNode = ProxyNode(
      name: "JP Tokyo",
      type: "vless",
      delay: 83,
      isSelectable: true,
      providerName: "Remote"
    )
    let slowNode = ProxyNode(
      name: "US Relay",
      type: "trojan",
      delay: 260,
      isSelectable: true,
      providerName: "Backup"
    )
    let proxyGroup = ProxyGroup(name: "Proxy", type: "select", selected: "JP Tokyo", nodes: [fastNode, slowNode])
    let fallbackGroup = ProxyGroup(
      name: "Fallback",
      type: "select",
      selected: nil,
      nodes: [ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)]
    )

    let providerFiltered = ProxyGroupSearchFilter.filteredGroups(
      from: [proxyGroup, fallbackGroup],
      searchQuery: ProxySearchQuery(rawValue: "provider=Remote delay<100")
    )
    XCTAssertEqual(providerFiltered.map(\.name), ["Proxy"])
    XCTAssertEqual(providerFiltered.first?.nodes.map(\.name), ["JP Tokyo"])

    let groupFiltered = ProxyGroupSearchFilter.filteredGroups(
      from: [proxyGroup, fallbackGroup],
      searchQuery: ProxySearchQuery(rawValue: "fallback")
    )
    XCTAssertEqual(groupFiltered.map(\.name), ["Fallback"])
    XCTAssertEqual(groupFiltered.first?.nodes.map(\.name), ["DIRECT"])
  }

  func testProxyPreviewNoticeShowsOutsideDeveloperMode() {
    XCTAssertEqual(
      ProxyPreviewNoticeKind.resolve(
        developerMode: false,
        previewRuntimeActive: true,
        isShowingProxyPreview: false
      ),
      .previewRuntime
    )
    XCTAssertEqual(
      ProxyPreviewNoticeKind.resolve(
        developerMode: false,
        previewRuntimeActive: false,
        isShowingProxyPreview: true
      ),
      .offlinePreview
    )
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

  func testProviderSummaryRequiresDeveloperModeAndProviders() {
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

  func testDashboardProxySelectionIgnoresAutomaticGroups() throws {
    let groups = [
      ProxyGroup(
        name: "Auto",
        type: "URLTest",
        selected: "Japan",
        nodes: [
          ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
          ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
        ]
      ),
      ProxyGroup(
        name: "Fallback",
        type: "Fallback",
        selected: "Singapore",
        nodes: [
          ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
          ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
        ]
      ),
      ProxyGroup(
        name: "Elite",
        type: "Selector",
        selected: "Japan",
        nodes: [
          ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
          ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)
        ]
      )
    ]

    XCTAssertEqual(DashboardProxySelectionState.selectableGroups(from: groups).map(\.name), ["Elite"])

    let group = try XCTUnwrap(DashboardProxySelectionState.resolvedGroup(from: groups, preferredName: "Auto"))
    XCTAssertEqual(group.name, "Elite")
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
    _ = try await store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let model = AppModel(paths: paths, profileStore: store, coreController: controller)
    await model.waitForProfilePreviewRefresh()

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
    _ = try await store.importLocalConfig(from: configURL)
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
    _ = try await store.importLocalConfig(from: configURL)
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
    _ = try await store.importLocalConfig(from: configURL)
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
    await model.waitForProfilePreviewRefresh()
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
    _ = try await store.importLocalConfig(from: configURL)
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
    await model.waitForProfilePreviewRefresh()
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
    _ = try await store.importLocalConfig(from: configURL)
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
    _ = try await store.importLocalConfig(from: configURL)
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
    _ = try await store.importLocalConfig(from: configURL)
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
    let ruleProvider = RuleProvider(
      name: "RemoteRules",
      type: "http",
      vehicleType: "HTTP",
      behavior: "domain",
      format: "yaml",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      ruleCount: 12
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
      ruleProvidersResponse: [ruleProvider],
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

    for _ in 0..<20 where model.proxyProviders.isEmpty || model.ruleProviders.isEmpty || model.connections.isEmpty {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyProviders, [provider])
    XCTAssertEqual(model.ruleProviders, [ruleProvider])
    XCTAssertEqual(model.connections, [connection])
  }

  func testRuntimeDataLoadingTracksInFlightReload() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResult: 73,
      proxyGroupsDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)

    XCTAssertFalse(model.runtimeDataLoading)

    model.reloadRuntimeData()

    for _ in 0..<40 where !model.runtimeDataLoading {
      await Task.yield()
    }

    XCTAssertTrue(model.runtimeDataLoading)

    for _ in 0..<160 where model.runtimeDataLoading {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertFalse(model.runtimeDataLoading)
    XCTAssertEqual(model.proxyGroups, [group])
  }

  func testRuntimeDataLoadingClearsWhenReloadCannotRun() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
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
      testDelayResult: 73,
      proxyGroupsDelayNanoseconds: 200_000_000
    )
    let model = AppModel(paths: paths, profileStore: store, coreController: controller, apiClient: client)

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.reloadRuntimeData()

    for _ in 0..<40 where !model.runtimeDataLoading {
      await Task.yield()
    }

    XCTAssertTrue(model.runtimeDataLoading)

    _ = await controller.stop()
    model.reloadRuntimeData()

    XCTAssertFalse(model.runtimeDataLoading)
    XCTAssertTrue(model.proxyGroups.isEmpty)
  }

  func testRuntimeDataLoadingClearsWhenRuntimeActionsAreCancelled() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(
          name: "Proxy",
          type: "select",
          selected: "Japan",
          nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
        )
      ],
      testDelayResult: 73,
      proxyGroupsDelayNanoseconds: 200_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)

    model.reloadRuntimeData()

    for _ in 0..<40 where !model.runtimeDataLoading {
      await Task.yield()
    }

    XCTAssertTrue(model.runtimeDataLoading)

    _ = await model.prepareForTermination()

    XCTAssertFalse(model.runtimeDataLoading)
  }

  func testProviderHealthAndConnectionCloseUseRuntimeAPI() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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

  func testRuntimeModeUpdatesUseLatestRequestOnly() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73,
      modeUpdateDelayNanoseconds: 60_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)

    model.setMode(.global)
    model.setMode(.direct)

    try? await Task.sleep(nanoseconds: 120_000_000)

    let modes = await client.updatedModes()
    XCTAssertEqual(modes, [.direct])
  }

  func testRuntimeIPv6TogglePatchesRunningCore() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client)

    model.setIPv6Enabled(true)

    for _ in 0..<20 {
      let values = await client.ipv6UpdateValues()
      if values == [true] {
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let values = await client.ipv6UpdateValues()
    XCTAssertEqual(values, [true])
  }

  func testRuntimeIPv6ToggleReloadsManagedDNSConfig() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client)
    var overrides = model.overrides
    overrides.dnsEnabled = true
    model.overrides = overrides

    model.setIPv6Enabled(true)

    for _ in 0..<40 {
      let paths = await client.reloadRequestPaths()
      if !paths.isEmpty {
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let reloadPaths = await client.reloadRequestPaths()
    let configPath = try XCTUnwrap(reloadPaths.first)
    let output = try String(contentsOfFile: configPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let ipv6Updates = await client.ipv6UpdateValues()
    let reloadForces = await client.reloadRequestForces()

    XCTAssertEqual(ipv6Updates, [])
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(yaml["ipv6"] as? Bool, true)
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["ipv6"] as? Bool, true)
  }

  func testRunningRuntimeSettingsApplyReloadsRuntimeAndMovesSystemProxyUsingAppliedSnapshot() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 73)
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let proxyReadiness = RecordingProxyPortReadinessProbe()
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let defaults = try Self.makeIsolatedDefaults()
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      proxyPortReadinessProbe: proxyReadiness,
      apiClient: client,
      defaults: defaults
    )
    var proxySettings = SystemProxySettings.default
    proxySettings.guardEnabled = true
    model.systemProxySettings = proxySettings
    model.systemProxyEnabled = true

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.setMixedPort(17_891)
    model.setAllowLAN(true)
    model.setDNSOverrideEnabled(true)
    model.setLogLevel("debug")

    for _ in 0..<120 {
      let paths = await client.reloadRequestPaths()
      if !paths.isEmpty,
         commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 17891"),
         model.settings.appliedRuntimeSettingsSnapshot?.overrides.mixedPort == 17_891,
         model.runtimeSettingsApplyState == .idle {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    let reloadPaths = await client.reloadRequestPaths()
    let reloadPath = try XCTUnwrap(reloadPaths.last)
    let output = try String(contentsOfFile: reloadPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(yaml["mixed-port"] as? Int, 17_891)
    XCTAssertEqual(yaml["allow-lan"] as? Bool, true)
    XCTAssertEqual(yaml["log-level"] as? String, "debug")
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.mixedPort, 17_891)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.allowLan, true)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.dnsEnabled, true)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.logLevel, "debug")
    XCTAssertEqual(model.runtimeSettingsApplyState, .idle)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 17891"))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 17891"))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 17891"))
    XCTAssertEqual(proxyReadiness.requests.last, ProxyPortReadinessRequest(host: "127.0.0.1", port: 17_891))
    XCTAssertEqual(reloaded.overrides.mixedPort, 17_891)
    XCTAssertTrue(reloaded.overrides.allowLan)
    XCTAssertEqual(reloaded.overrides.dnsEnabled, true)
    XCTAssertEqual(reloaded.overrides.logLevel, "debug")
  }

  func testRuntimeSettingsApplyFailureKeepsPreviousAppliedSnapshot() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73,
      reloadFailureMessage: "reload refused"
    )
    let model = try await makeRunningRuntimeModel(client: client)

    XCTAssertTrue(model.canControlRuntimeProxies)
    model.setDNSOverrideEnabled(true)
    model.setLogLevel("debug")

    for _ in 0..<120 {
      if case .failed = model.runtimeSettingsApplyState {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.dnsEnabled, nil)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.logLevel, "info")
    XCTAssertEqual(model.currentRuntimeOverrides.dnsEnabled, nil)
    XCTAssertEqual(model.currentRuntimeOverrides.logLevel, "info")
    guard case let .failed(message) = model.runtimeSettingsApplyState else {
      return XCTFail("Expected failed runtime settings apply state, got \(model.runtimeSettingsApplyState).")
    }
    XCTAssertTrue(message.contains("reload refused"))
    XCTAssertEqual(model.overrides.dnsEnabled, true)
    XCTAssertEqual(model.overrides.logLevel, "debug")
  }

  func testRuntimeSettingsReloadSuccessKeepsAppliedSnapshotWhenReadinessFails() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 73)
    let proxyReadiness = RecordingProxyPortReadinessProbe(
      result: .failure(AppError.helperResponse("proxy readiness refused"))
    )
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let defaults = try Self.makeIsolatedDefaults()
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(
        commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
      ),
      proxyPortReadinessProbe: proxyReadiness,
      apiClient: client,
      defaults: defaults
    )

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    model.setDNSOverrideEnabled(true)
    model.setLogLevel("debug")

    for _ in 0..<120 {
      let reloadPaths = await client.reloadRequestPaths()
      if !reloadPaths.isEmpty,
         case .appliedWithFollowUpFailure = model.runtimeSettingsApplyState {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    let reloadPaths = await client.reloadRequestPaths()
    let reloadForces = await client.reloadRequestForces()
    let reloadPath = try XCTUnwrap(reloadPaths.last)
    let output = try String(contentsOfFile: reloadPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(yaml["log-level"] as? String, "debug")
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.dnsEnabled, true)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.logLevel, "debug")
    XCTAssertEqual(model.currentRuntimeOverrides.dnsEnabled, true)
    XCTAssertEqual(model.currentRuntimeOverrides.logLevel, "debug")
    guard case let .appliedWithFollowUpFailure(message) = model.runtimeSettingsApplyState else {
      return XCTFail("Expected post-reload failure state, got \(model.runtimeSettingsApplyState).")
    }
    XCTAssertTrue(message.contains("proxy readiness refused"))
    XCTAssertTrue(model.runtimeSettingsApplyStatusMessage?.contains("proxy readiness refused") == true)
    XCTAssertEqual(model.overrides.dnsEnabled, true)
    XCTAssertEqual(model.overrides.logLevel, "debug")
    XCTAssertEqual(reloaded.overrides.dnsEnabled, true)
    XCTAssertEqual(reloaded.overrides.logLevel, "debug")
    XCTAssertEqual(proxyReadiness.requests.last, ProxyPortReadinessRequest(host: "127.0.0.1", port: 7_890))
  }

  func testAppliedRuntimeSnapshotPersistsRecoveryValuesWithoutRuntimeSecret() throws {
    let defaults = try Self.makeIsolatedDefaults()
    let store = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )
    var overrides = store.overrides
    overrides.secret = "must-not-persist"
    overrides.tunEnabled = true

    store.recordAppliedRuntimeSettingsSnapshot(
      AppliedRuntimeSettingsSnapshot(
        overrides: overrides,
        proxyRoutingMode: .systemProxy,
        systemProxySettings: .default,
        networkExtensionRoutingSettings: .default,
        runtimeOwner: .user,
        appliedAt: Date()
      )
    )

    let persistedData = try XCTUnwrap(defaults.data(forKey: "io.github.clashmax.appliedRuntimeSettingsSnapshot"))
    let persistedString = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
    XCTAssertFalse(persistedString.contains("must-not-persist"))

    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    let snapshot = try XCTUnwrap(reloaded.appliedRuntimeSettingsSnapshot)
    XCTAssertEqual(snapshot.overrides.mixedPort, overrides.mixedPort)
    XCTAssertEqual(snapshot.overrides.tunEnabled, true)
    XCTAssertEqual(snapshot.proxyRoutingMode, .systemProxy)
    XCTAssertEqual(snapshot.runtimeOwner, .user)
    XCTAssertNotEqual(snapshot.overrides.secret, "must-not-persist")
    XCTAssertNotEqual(reloaded.overrides.secret, "must-not-persist")
    XCTAssertFalse(reloaded.overrides.tunEnabled)
  }

  func testPersistedRuntimePreferencesApplyOnNextGeneratedRuntimeConfig() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let defaults = try Self.makeIsolatedDefaults()
    let first = AppModel(
      paths: paths,
      profileStore: store,
      defaults: defaults
    )
    first.overrides.mixedPort = 17_891
    first.overrides.allowLan = true
    first.overrides.dnsEnabled = true
    first.overrides.logLevel = "debug"
    first.setMode(.global)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(
        commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
      ),
      defaults: defaults,
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )

    model.start()
    for _ in 0..<160 where launcher.launchCount < 1 || !model.isRunning {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let runtimeConfigPath = try XCTUnwrap(launcher.launchedConfigPaths.last)
    let runtimeConfig = try String(contentsOfFile: runtimeConfigPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: runtimeConfig) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])

    XCTAssertEqual(model.overrides.mixedPort, 17_891)
    XCTAssertTrue(model.overrides.allowLan)
    XCTAssertEqual(model.overrides.dnsEnabled, true)
    XCTAssertEqual(model.overrides.logLevel, "debug")
    XCTAssertEqual(model.overrides.mode, .global)
    XCTAssertEqual(yaml["mixed-port"] as? Int, 17_891)
    XCTAssertEqual(yaml["allow-lan"] as? Bool, true)
    XCTAssertEqual(yaml["log-level"] as? String, "debug")
    XCTAssertEqual(yaml["mode"] as? String, "global")
    XCTAssertEqual(dns["enable"] as? Bool, true)
  }

  func testNetworkExtensionIPv6ToggleReloadsDNSCaptureConfig() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.proxyRoutingMode = .neProxy
    model.networkExtensionRoutingSettings = NetworkExtensionRoutingSettings(
      dnsCaptureEnabled: true,
      dnsFakeIPEnabled: false,
      systemDNSOverrideEnabled: false
    )

    model.setIPv6Enabled(true)

    for _ in 0..<40 {
      let paths = await client.reloadRequestPaths()
      if !paths.isEmpty {
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let reloadPaths = await client.reloadRequestPaths()
    let configPath = try XCTUnwrap(reloadPaths.first)
    let output = try String(contentsOfFile: configPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let ipv6Updates = await client.ipv6UpdateValues()
    let reloadForces = await client.reloadRequestForces()

    XCTAssertEqual(ipv6Updates, [])
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(yaml["ipv6"] as? Bool, true)
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["listen"] as? String, "127.0.0.1:1053")
    XCTAssertEqual(dns["ipv6"] as? Bool, true)
  }

  func testNetworkExtensionMixedPortChangeUsesCoordinatedRestartAndUpdatesAppliedSnapshot() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyReadiness = RecordingProxyPortReadinessProbe()
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let defaults = try Self.makeIsolatedDefaults()
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: proxyReadiness,
      defaults: defaults,
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") }
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where proxyManager.startConfigurations.count < 1 || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(proxyManager.startConfigurations.first?.socksPort, 7_890)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.mixedPort, 7_890)

    model.setMixedPort(17_891)

    for _ in 0..<260 {
      if proxyManager.startConfigurations.count >= 2, !model.startInFlight, model.runtimeSettingsApplyState == .idle {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 2_000_000)
    }

    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertEqual(proxyManager.startConfigurations.count, 2)
    XCTAssertEqual(proxyManager.startConfigurations.last?.socksPort, 17_891)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.runtimeOwner, .networkExtension)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.mixedPort, 17_891)
    XCTAssertTrue(proxyReadiness.requests.contains(ProxyPortReadinessRequest(host: "127.0.0.1", port: 7_890)))
    XCTAssertTrue(proxyReadiness.requests.contains(ProxyPortReadinessRequest(host: "127.0.0.1", port: 17_891)))
    XCTAssertEqual(model.runtimeSettingsApplyState, .idle)
  }

  func testSelectingProxyUsesLatestRequestPerGroup() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Hong Kong", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(name: "Proxy", type: "select", selected: "Singapore", nodes: group.nodes)
      ],
      testDelayResult: 73,
      selectProxyDelaysNanoseconds: [120_000_000, 10_000_000]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.selectProxy(group: group, node: group.nodes[1])
    model.selectProxy(group: group, node: group.nodes[2])

    try? await Task.sleep(nanoseconds: 180_000_000)

    let selectedProxyRequests = await client.selectedProxyRequests()
    let selectedNode = try XCTUnwrap(model.proxyGroups.first?.selected)
    XCTAssertEqual(selectedProxyRequests, ["Proxy:Singapore"])
    XCTAssertEqual(selectedNode, "Singapore")
    XCTAssertEqual(model.previewSelections["Proxy"], "Singapore")
  }

  func testSelectingProxyCanCloseConnectionsUsingPreviousNodeChain() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let staleConnection = ConnectionSnapshot(
      id: "stale",
      network: "tcp",
      host: "old.example",
      upload: 0,
      download: 0,
      chain: ["Proxy", "Japan"],
      rule: nil,
      startedAt: nil
    )
    let currentConnection = ConnectionSnapshot(
      id: "current",
      network: "tcp",
      host: "new.example",
      upload: 0,
      download: 0,
      chain: ["Proxy", "Singapore"],
      rule: nil,
      startedAt: nil
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(name: "Proxy", type: "select", selected: "Singapore", nodes: group.nodes)
      ],
      connectionsResponse: [currentConnection],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])
    model.connections = [staleConnection, currentConnection]

    model.selectProxy(group: group, node: group.nodes[1], closeOldConnections: true)

    for _ in 0..<80 {
      let selectedProxyRequests = await client.selectedProxyRequests()
      let closedConnectionIDs = await client.closedConnectionIDs()
      if selectedProxyRequests == ["Proxy:Singapore"], closedConnectionIDs == ["stale"] {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let selectedProxyRequests = await client.selectedProxyRequests()
    let closedConnectionIDs = await client.closedConnectionIDs()
    XCTAssertEqual(selectedProxyRequests, ["Proxy:Singapore"])
    XCTAssertEqual(closedConnectionIDs, ["stale"])
    XCTAssertFalse(model.connections.contains(where: { $0.id == "stale" }))
    XCTAssertTrue(model.connections.contains(where: { $0.id == "current" }))
  }

  func testSelectingAutomaticProxyGroupDoesNotCallRuntimeAPI() async throws {
    let group = ProxyGroup(
      name: "Auto",
      type: "url-test",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 73)
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.selectProxy(group: group, node: group.nodes[1])

    let selectedProxyRequestCount = await client.selectedProxyRequestCount()
    XCTAssertEqual(selectedProxyRequestCount, 0)
    XCTAssertEqual(model.proxyGroups.first?.selected, "Japan")
    XCTAssertEqual(model.lastError, "Auto is managed automatically by Mihomo.")
    XCTAssertNil(model.previewSelections["Auto"])
  }

  func testSelectingProxyInPreviewRuntimePersistsAndCallsRuntimeAPI() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(name: "Proxy", type: "select", selected: "DIRECT", nodes: group.nodes)
      ],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])
    model.previewRuntimeActive = true

    model.selectProxy(group: group, node: group.nodes[1])

    XCTAssertEqual(model.previewSelections["Proxy"], "DIRECT")
    XCTAssertEqual(model.proxyGroups.first?.selected, "DIRECT")
    for _ in 0..<40 where await client.selectedProxyRequestCount() == 0 {
      await Task.yield()
    }

    let selectedProxyRequests = await client.selectedProxyRequests()
    XCTAssertEqual(selectedProxyRequests, ["Proxy:DIRECT"])
  }

  func testSelectingProxyInPreviewRuntimeRollsBackOnAPIError() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResult: 73,
      selectProxyFailureMessage: "switch refused"
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])
    model.previewRuntimeActive = true

    model.selectProxy(group: group, node: group.nodes[1])

    for _ in 0..<40 where model.lastError == nil {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyGroups.first?.selected, "Japan")
    XCTAssertEqual(model.previewSelections["Proxy"], "Japan")
    XCTAssertEqual(model.lastError, "switch refused")
  }

  func testSelectingProxyInRuntimePersistsSelectionAfterSuccessfulAPIRequest() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [
        ProxyGroup(name: "Proxy", type: "select", selected: "DIRECT", nodes: group.nodes)
      ],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.selectProxy(group: group, node: group.nodes[1])

    for _ in 0..<40 where await client.selectedProxyRequestCount() == 0 {
      await Task.yield()
    }
    for _ in 0..<40 where model.proxyGroups.first?.selected != "DIRECT" {
      await Task.yield()
    }

    let selectedProxyRequests = await client.selectedProxyRequests()
    XCTAssertEqual(selectedProxyRequests, ["Proxy:DIRECT"])
    XCTAssertEqual(model.proxyGroups.first?.selected, "DIRECT")
    XCTAssertEqual(model.previewSelections["Proxy"], "DIRECT")
  }

  func testDelayTestingKeepsLatestResultForSameNode() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResults: [111, 73],
      testDelayDelaysNanoseconds: [120_000_000, 10_000_000]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelay(for: group.nodes[0])
    for _ in 0..<40 where await client.delayRequestCount() == 0 {
      await Task.yield()
    }
    model.testDelay(for: group.nodes[0])

    try? await Task.sleep(nanoseconds: 180_000_000)

    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
  }

  func testDelayTestingKeepsLatestResultForSameNodeWithDifferentURLs() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let slowURL = try XCTUnwrap(URL(string: "https://slow.example.com/delay"))
    let fastURL = try XCTUnwrap(URL(string: "https://fast.example.com/delay"))
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResults: [111, 73],
      testDelayDelaysNanoseconds: [120_000_000, 10_000_000]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelay(in: group, for: group.nodes[0], testURL: slowURL)
    for _ in 0..<40 where await client.delayRequestCount() == 0 {
      await Task.yield()
    }
    model.testDelay(in: group, for: group.nodes[0], testURL: fastURL)

    try? await Task.sleep(nanoseconds: 180_000_000)

    let delayRequestURLs = await client.delayRequestURLs()
    XCTAssertEqual(delayRequestURLs, [slowURL, fastURL])
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
  }

  func testDelayTestingUsesGroupAwareKeysForDuplicateNodeNames() async throws {
    let groupA = ProxyGroup(
      name: "Proxy A",
      type: "select",
      selected: "Shared",
      nodes: [ProxyNode(name: "Shared", type: "vless", delay: nil, isSelectable: true)]
    )
    let groupB = ProxyGroup(
      name: "Proxy B",
      type: "select",
      selected: "Shared",
      nodes: [ProxyNode(name: "Shared", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [groupA, groupB],
      testDelayResults: [101, 202]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [groupA, groupB])

    model.testDelay(in: groupA, for: groupA.nodes[0])
    model.testDelay(in: groupB, for: groupB.nodes[0])

    for _ in 0..<50 where await client.delayRequestCount() < 2 {
      await Task.yield()
    }
    for _ in 0..<50 where model.proxyGroups.compactMap({ $0.nodes.first?.delay }).count < 2 {
      await Task.yield()
    }

    let duplicateNameDelayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(duplicateNameDelayRequestCount, 2)
    XCTAssertEqual(model.proxyGroups.first(where: { $0.name == "Proxy A" })?.nodes.first?.delay, 101)
    XCTAssertEqual(model.proxyGroups.first(where: { $0.name == "Proxy B" })?.nodes.first?.delay, 202)
  }

  func testCustomDelayURLStateSurvivesRuntimeReload() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let customURL = try XCTUnwrap(URL(string: "https://example.com/custom-delay"))
    let client = RecordingMihomoController(
      proxyGroupsResponses: [[group], [group]],
      testDelayResults: [73]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelay(in: group, for: group.nodes[0], testURL: customURL)

    for _ in 0..<80 {
      let requestCount = await client.proxyGroupsRequestCount()
      if requestCount > 0, !model.runtimeDataLoading {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let delayRequestURLs = await client.delayRequestURLs()
    XCTAssertEqual(delayRequestURLs, [customURL])
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.resolvedDelayState, .measured(73))
  }

  func testGroupDelayTestingRunsSelectableNodesInGroup() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Provider: remote", type: "provider", delay: nil, isSelectable: false)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResults: [73, 88]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelay(in: group)

    for _ in 0..<50 where await client.delayRequestCount() < 2 {
      await Task.yield()
    }

    let groupDelayRequestCount = await client.delayRequestCount()
    XCTAssertEqual(groupDelayRequestCount, 2)
    XCTAssertEqual(model.proxyGroups.first?.nodes[0].delay, 73)
    XCTAssertEqual(model.proxyGroups.first?.nodes[1].delay, 88)
    XCTAssertNil(model.proxyGroups.first?.nodes[2].delay)
  }

  func testBatchDelayTestingRunsAllVisibleSelectableNodesWithPerGroupCustomURLs() async throws {
    let groupA = ProxyGroup(
      name: "Proxy A",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Provider: remote", type: "provider", delay: nil, isSelectable: false)
      ]
    )
    let groupB = ProxyGroup(
      name: "Proxy B",
      type: "select",
      selected: "US",
      nodes: [
        ProxyNode(name: "US", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [groupA, groupB],
      testDelayResults: [73, 88, 99]
    )
    let defaults = try Self.makeIsolatedDefaults()
    let model = try await makeRunningRuntimeModel(
      client: client,
      initialProxyGroups: [groupA, groupB],
      defaults: defaults
    )
    model.updateProxyPageSettings { settings in
      settings.setCustomDelayTestURLText("https://a.example.com/delay", forGroupName: "Proxy A")
      settings.setCustomDelayTestURLText("https://b.example.com/delay", forGroupName: "Proxy B")
    }

    model.testDelayForAllProxyGroups()
    try await waitForBatchProgress(model) { !$0.isRunning && $0.completed == 3 }

    let delayRequestProxies = await client.delayRequestProxies()
    let delayRequestURLs = await client.delayRequestURLs()
    XCTAssertEqual(delayRequestProxies.sorted(), ["Japan", "Singapore", "US"])
    XCTAssertEqual(delayRequestURLs.filter { $0.absoluteString == "https://a.example.com/delay" }.count, 2)
    XCTAssertEqual(delayRequestURLs.filter { $0.absoluteString == "https://b.example.com/delay" }.count, 1)
    XCTAssertEqual(model.proxyDelayBatchProgress?.succeeded, 3)
    XCTAssertEqual(model.proxyDelayBatchProgress?.failureCount, 0)
    XCTAssertNil(model.proxyGroups.first(where: { $0.name == "Proxy A" })?.nodes[2].delay)
  }

  func testBatchDelayTestingClassifiesFailures() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Timeout", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Controller", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Broken", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponses: [[group]],
      testDelayResults: [73, 0, 0, 0],
      testDelayFailureMessages: [
        nil,
        "request timed out",
        "Could not connect to the server.",
        "provider failed"
      ]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelayForAllProxyGroups()
    try await waitForBatchProgress(model) { !$0.isRunning && $0.completed == 4 }

    let progress = try XCTUnwrap(model.proxyDelayBatchProgress)
    XCTAssertEqual(progress.succeeded, 1)
    XCTAssertEqual(progress.timedOut, 1)
    XCTAssertEqual(progress.failed, 2)
    XCTAssertEqual(Set(progress.failures.map(\.kind)), [.timeout, .controllerUnavailable, .other])
    let states = try XCTUnwrap(model.proxyGroups.first?.nodes.map(\.resolvedDelayState))
    XCTAssertEqual(states.filter { $0 == .measured(73) }.count, 1)
    XCTAssertEqual(states.filter { $0 == .timeout }.count, 1)
    XCTAssertTrue(states.contains { state in
      if case .error = state { return true }
      return false
    })
    XCTAssertTrue(model.lastError?.contains("3") == true)
  }

  func testBatchDelayTestingReportsMissingEndpointForNativePing() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(proxyGroupsResponse: [group], testDelayResult: 0)
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])
    model.delayTestSettings = DelayTestSettings(mode: .nativePing, unifiedDelay: false, timeoutMilliseconds: 1_000)

    model.testDelayForAllProxyGroups()
    try await waitForBatchProgress(model) { !$0.isRunning && $0.completed == 1 }

    XCTAssertEqual(model.proxyDelayBatchProgress?.failures.first?.kind, .missingEndpoint)
  }

  func testBatchDelayTestingCanBeCancelledWithoutLosingCompletedResults() async throws {
    let nodes = (0..<8).map { index in
      ProxyNode(name: "Node \(index)", type: "vless", delay: nil, isSelectable: true)
    }
    let group = ProxyGroup(name: "Proxy", type: "select", selected: "Node 0", nodes: nodes)
    let client = RecordingMihomoController(
      proxyGroupsResponse: [group],
      testDelayResults: [73, 88, 99, 101, 102, 103, 104, 105],
      testDelayDelaysNanoseconds: [
        10_000_000,
        600_000_000,
        600_000_000,
        600_000_000,
        600_000_000,
        600_000_000,
        600_000_000,
        600_000_000
      ]
    )
    let model = try await makeRunningRuntimeModel(client: client, initialProxyGroups: [group])

    model.testDelayForAllProxyGroups()
    try await waitForBatchProgress(model) { $0.succeeded == 1 }
    model.cancelProxyDelayBatch()
    try await waitForBatchProgress(model) { !$0.isRunning && $0.wasCancelled }

    let progress = try XCTUnwrap(model.proxyDelayBatchProgress)
    XCTAssertEqual(progress.succeeded, 1)
    XCTAssertEqual(progress.cancelled, 7)
    XCTAssertEqual(progress.completed, 8)
    let measuredResults = model.proxyGroups
      .flatMap(\.nodes)
      .compactMap { node -> Int? in
        guard case let .measured(delay) = node.resolvedDelayState else { return nil }
        return delay
      }
    XCTAssertEqual(measuredResults.count, 1)
    XCTAssertTrue(Set([73, 88, 99, 101, 102, 103, 104, 105]).isSuperset(of: measuredResults))
    XCTAssertFalse(
      model.proxyGroups.flatMap(\.nodes).contains { node in
        node.resolvedDelayState == .testing
      }
    )
  }

  func testDelayCacheTTLStopsPreservingExpiredDelayAcrossReloads() async throws {
    let group = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponses: [[group], [group], [group], [group]],
      testDelayResults: [73]
    )
    let model = try await makeRunningRuntimeModel(
      client: client,
      initialProxyGroups: [group],
      delayStateCacheTTL: 0.01
    )

    model.testDelay(in: group, for: group.nodes[0])
    for _ in 0..<80 where model.proxyGroups.first?.nodes.first?.delay != 73 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.delay, 73)

    try? await Task.sleep(nanoseconds: 25_000_000)
    let requestCountBeforeReload = await client.proxyGroupsRequestCount()
    model.reloadRuntimeData()
    for _ in 0..<80 {
      let requestCount = await client.proxyGroupsRequestCount()
      if requestCount > requestCountBeforeReload, !model.runtimeDataLoading {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertNil(model.proxyGroups.first?.nodes.first?.delay)
    XCTAssertEqual(model.proxyGroups.first?.nodes.first?.resolvedDelayState, .unknown)
  }

  func testProviderHealthCheckIgnoresDuplicateProviderWhileRunning() async throws {
    let provider = ProxyProvider(name: "Remote", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 73,
      healthCheckDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)

    model.healthCheckProvider(provider)
    model.healthCheckProvider(provider)

    try? await Task.sleep(nanoseconds: 120_000_000)

    let healthCheckProviders = await client.healthCheckProviders()
    XCTAssertEqual(healthCheckProviders, ["Remote"])
    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    XCTAssertFalse(
      model.providerAnalytics.summary(
        profileID: profileID,
        profileTraffic: nil,
        currentProxyProviders: nil,
        currentRuleProviders: nil
      ).hasData
    )
  }

  func testProviderUpdatesUseRuntimeAPIAndReload() async throws {
    let proxyProvider = ProxyProvider(name: "Remote/sub", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let ruleProvider = RuleProvider(
      name: "Rules/sub",
      type: "http",
      vehicleType: "HTTP",
      behavior: "domain",
      format: "yaml",
      updatedAt: nil,
      ruleCount: 3
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [proxyProvider],
      ruleProvidersResponse: [ruleProvider],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.proxyProviders = [proxyProvider]
    model.ruleProviders = [ruleProvider]

    model.updateProxyProvider(proxyProvider)
    model.updateRuleProvider(ruleProvider)

    for _ in 0..<80 {
      let proxyUpdates = await client.updatedProxyProviders()
      let ruleUpdates = await client.updatedRuleProviders()
      if proxyUpdates == ["Remote/sub"] && ruleUpdates == ["Rules/sub"] {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let updatedProxyProviders = await client.updatedProxyProviders()
    let updatedRuleProviders = await client.updatedRuleProviders()
    let proxyGroupsRequestCount = await client.proxyGroupsRequestCount()
    XCTAssertEqual(updatedProxyProviders, ["Remote/sub"])
    XCTAssertEqual(updatedRuleProviders, ["Rules/sub"])
    XCTAssertTrue(model.proxyProviderUpdatesInFlight.isEmpty)
    XCTAssertTrue(model.ruleProviderUpdatesInFlight.isEmpty)
    XCTAssertGreaterThanOrEqual(proxyGroupsRequestCount, 1)

    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    let summary = model.providerAnalytics.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    )
    XCTAssertEqual(summary.rows.first(where: { $0.kind == .proxy })?.successRate, 1)
    XCTAssertEqual(summary.rows.first(where: { $0.kind == .rule })?.successRate, 1)
  }

  func testDuplicateProviderUpdateWhileRunningDoesNotRecordExtraAttempt() async throws {
    let provider = ProxyProvider(name: "Remote", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [provider],
      testDelayResult: 73,
      proxyProviderUpdateDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.proxyProviders = [provider]

    model.updateProxyProvider(provider)
    model.updateProxyProvider(provider)

    for _ in 0..<120 {
      let updates = await client.updatedProxyProviders()
      if updates.count == 1 && model.proxyProviderUpdatesInFlight.isEmpty {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let updatedProxyProviders = await client.updatedProxyProviders()
    XCTAssertEqual(updatedProxyProviders, ["Remote"])

    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    let summary = model.providerAnalytics.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    )
    XCTAssertEqual(summary.updateAttemptCount, 1)
    XCTAssertEqual(summary.rows.first?.successRateSampleCount, 1)
  }

  func testUpdateAllProvidersSkipsDuplicateBatchWhileRunning() async throws {
    let first = ProxyProvider(name: "Remote A", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let second = ProxyProvider(name: "Remote B", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [first, second],
      testDelayResult: 73
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.proxyProviders = [first, second]

    model.updateAllProxyProviders()
    model.updateAllProxyProviders()

    for _ in 0..<80 where await client.updatedProxyProviders().count < 2 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let updatedProxyProviders = await client.updatedProxyProviders()
    XCTAssertEqual(updatedProxyProviders, ["Remote A", "Remote B"])
    XCTAssertTrue(model.proxyProviderUpdatesInFlight.isEmpty)

    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    let summary = model.providerAnalytics.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    )
    XCTAssertEqual(summary.updateAttemptCount, 2)
    XCTAssertEqual(summary.rows.first { $0.providerName == "Remote A" }?.successRateSampleCount, 1)
    XCTAssertEqual(summary.rows.first { $0.providerName == "Remote B" }?.successRateSampleCount, 1)
  }

  func testUpdateAllProvidersContinuesAfterPartialFailures() async throws {
    let firstProxyProvider = ProxyProvider(name: "Remote A", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let secondProxyProvider = ProxyProvider(name: "Remote B", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
    let firstRuleProvider = RuleProvider(
      name: "Rules A",
      type: "http",
      vehicleType: "HTTP",
      behavior: "domain",
      format: "yaml",
      updatedAt: nil,
      ruleCount: nil
    )
    let secondRuleProvider = RuleProvider(
      name: "Rules B",
      type: "http",
      vehicleType: "HTTP",
      behavior: "classical",
      format: "text",
      updatedAt: nil,
      ruleCount: nil
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [firstProxyProvider, secondProxyProvider],
      ruleProvidersResponse: [firstRuleProvider, secondRuleProvider],
      testDelayResult: 73,
      proxyProviderUpdateFailures: ["Remote A": "proxy update refused"],
      ruleProviderUpdateFailures: ["Rules A": "rule update refused"]
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.proxyProviders = [firstProxyProvider, secondProxyProvider]
    model.ruleProviders = [firstRuleProvider, secondRuleProvider]

    model.updateAllProxyProviders()

    for _ in 0..<80 {
      let updates = await client.updatedProxyProviders()
      if updates.count == 2 && model.lastError?.contains("Remote A: proxy update refused") == true {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let updatedProxyProviders = await client.updatedProxyProviders()
    XCTAssertEqual(updatedProxyProviders, ["Remote A", "Remote B"])
    XCTAssertTrue(model.proxyProviderUpdatesInFlight.isEmpty)
    XCTAssertEqual(model.lastError, "Failed to update 1 proxy provider: Remote A: proxy update refused")

    model.lastError = nil
    model.updateAllRuleProviders()

    for _ in 0..<80 {
      let updates = await client.updatedRuleProviders()
      if updates.count == 2 && model.lastError?.contains("Rules A: rule update refused") == true {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let updatedRuleProviders = await client.updatedRuleProviders()
    XCTAssertEqual(updatedRuleProviders, ["Rules A", "Rules B"])
    XCTAssertTrue(model.ruleProviderUpdatesInFlight.isEmpty)
    XCTAssertEqual(model.lastError, "Failed to update 1 rule provider: Rules A: rule update refused")

    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    let summary = model.providerAnalytics.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    )
    XCTAssertEqual(summary.rows.first { $0.kind == .proxy && $0.providerName == "Remote A" }?.successRate, 0)
    XCTAssertEqual(summary.rows.first { $0.kind == .proxy && $0.providerName == "Remote B" }?.successRate, 1)
    XCTAssertEqual(summary.rows.first { $0.kind == .rule && $0.providerName == "Rules A" }?.successRate, 0)
    XCTAssertEqual(summary.rows.first { $0.kind == .rule && $0.providerName == "Rules B" }?.successRate, 1)
  }

  func testClosingConnectionIgnoresDuplicateConnectionWhileRunning() async throws {
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
      testDelayResult: 73,
      closeConnectionDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.connections = [connection]

    model.closeConnection(connection)
    model.closeConnection(connection)

    try? await Task.sleep(nanoseconds: 120_000_000)

    let closedConnectionIDs = await client.closedConnectionIDs()
    XCTAssertEqual(closedConnectionIDs, ["abc/123"])
  }

  func testReloadRuntimeDataRunsTrailingRefreshForRequestsDuringInFlightReload() async throws {
    let initialGroup = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Japan",
      nodes: [
        ProxyNode(name: "Japan", type: "vless", delay: nil, isSelectable: true),
        ProxyNode(name: "Singapore", type: "vless", delay: nil, isSelectable: true)
      ]
    )
    let refreshedGroup = ProxyGroup(
      name: "Proxy",
      type: "select",
      selected: "Singapore",
      nodes: initialGroup.nodes
    )
    let client = RecordingMihomoController(
      proxyGroupsResponses: [[initialGroup], [refreshedGroup]],
      testDelayResults: [73],
      proxyGroupsDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)

    model.reloadRuntimeData()
    for _ in 0..<40 where await client.proxyGroupsRequestCount() == 0 {
      await Task.yield()
    }
    model.reloadRuntimeData()
    model.reloadRuntimeData()

    for _ in 0..<160 {
      let proxyGroupsRequestCount = await client.proxyGroupsRequestCount()
      if proxyGroupsRequestCount == 2 && model.proxyGroups.first?.selected == "Singapore" {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let proxyGroupsRequestCount = await client.proxyGroupsRequestCount()
    XCTAssertEqual(proxyGroupsRequestCount, 2)
    XCTAssertEqual(model.proxyGroups.first?.selected, "Singapore")
  }

  func testRuntimeReloadSnapshotsUseCapturedActiveProfileID() async throws {
    let provider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: "HTTP",
      updatedAt: nil,
      proxies: [ProxyNode(name: "Japan", type: "Vless", delay: nil, isSelectable: true)]
    )
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      proxyProvidersResponse: [provider],
      testDelayResult: 73,
      proxyGroupsDelayNanoseconds: 80_000_000
    )
    let model = try await makeRunningRuntimeModel(client: client)
    guard let firstProfileID = model.profileStore.activeProfileID else {
      return XCTFail("Expected an active profile before runtime reload.")
    }

    model.reloadRuntimeData()
    for _ in 0..<40 where await client.proxyGroupsRequestCount() == 0 {
      await Task.yield()
    }

    let secondConfigURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxSecondProfile-\(UUID().uuidString).yaml")
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let secondProfile = try await model.profileStore.importLocalConfig(from: secondConfigURL)
    XCTAssertEqual(model.profileStore.activeProfileID, secondProfile.id)

    for _ in 0..<120 where model.runtimeDataLoading {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let firstSummary = model.providerAnalytics.summary(
      profileID: firstProfileID,
      profileTraffic: nil as SubscriptionTrafficUsage?,
      currentProxyProviders: nil as [ProxyProvider]?,
      currentRuleProviders: nil as [RuleProvider]?
    )
    let secondSummary = model.providerAnalytics.summary(
      profileID: secondProfile.id,
      profileTraffic: nil as SubscriptionTrafficUsage?,
      currentProxyProviders: nil as [ProxyProvider]?,
      currentRuleProviders: nil as [RuleProvider]?
    )
    XCTAssertEqual(firstSummary.rows.first?.providerName, "Remote")
    XCTAssertFalse(secondSummary.hasData)
  }

  func testCancelledRuntimeActionsDoNotPublishStaleErrorsAfterTermination() async throws {
    let provider = ProxyProvider(name: "Remote", type: "http", vehicleType: "HTTP", updatedAt: nil, proxies: [])
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
      testDelayResult: 73,
      healthCheckDelayNanoseconds: 80_000_000,
      closeConnectionDelayNanoseconds: 80_000_000,
      proxyProviderUpdateDelayNanoseconds: 80_000_000,
      healthCheckFailureMessage: "stale provider failure",
      closeConnectionFailureMessage: "stale close failure",
      ignoreHealthCheckCancellation: true,
      ignoreCloseConnectionCancellation: true
    )
    let model = try await makeRunningRuntimeModel(client: client)
    model.connections = [connection]

    model.healthCheckProvider(provider)
    model.updateProxyProvider(provider)
    model.closeConnection(connection)

    for _ in 0..<40 {
      let healthCheckRequestCount = await client.healthCheckRequestCount()
      let closedConnectionIDs = await client.closedConnectionIDs()
      if healthCheckRequestCount > 0
        && model.proxyProviderUpdatesInFlight.contains(provider.id)
        && !closedConnectionIDs.isEmpty {
        break
      }
      await Task.yield()
    }

    let didCleanUp = await model.prepareForTermination()
    XCTAssertTrue(didCleanUp)

    try? await Task.sleep(nanoseconds: 120_000_000)

    XCTAssertNil(model.lastError)
    XCTAssertFalse(model.providerHealthChecksInFlight.contains(provider.id))
    XCTAssertFalse(model.proxyProviderUpdatesInFlight.contains(provider.id))
    XCTAssertFalse(model.closingConnectionIDs.contains(connection.id))

    let profileID = try XCTUnwrap(model.profileStore.activeProfileID)
    XCTAssertFalse(
      model.providerAnalytics.summary(
        profileID: profileID,
        profileTraffic: nil,
        currentProxyProviders: nil,
        currentRuleProviders: nil
      ).hasData
    )
  }

  func testSubscriptionUpdateFailureRecordsClassificationHistoryAndBackoff() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let originalSource = "proxies:\n  - name: DIRECT\n    type: direct\n"
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(originalSource))
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults()
    )
    let failureRecorder = URLProtocolRecorder(
      responseBody: "Forbidden",
      responseHeaders: ["Content-Type": "text/plain"],
      statusCode: 403
    )

    let didUpdate = await model.updateSubscription(
      profile,
      session: URLSession(configuration: failureRecorder.configuration)
    )

    XCTAssertFalse(didUpdate)
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), originalSource)
    let updatedProfile = try XCTUnwrap(store.profiles.first)
    XCTAssertEqual(updatedProfile.subscriptionUpdateStatus.result, .failed)
    XCTAssertEqual(updatedProfile.subscriptionUpdateStatus.consecutiveFailures, 1)
    XCTAssertNotNil(updatedProfile.subscriptionUpdateStatus.backoffUntil)
    XCTAssertEqual(updatedProfile.subscriptionUpdateStatus.backoffUntil, updatedProfile.subscriptionUpdateStatus.nextUpdateAt)
    XCTAssertEqual(updatedProfile.subscriptionDiagnostics.latestFetch?.httpStatusCode, 403)
    XCTAssertEqual(updatedProfile.subscriptionDiagnostics.updateHistory.first?.trigger, .manual)
    XCTAssertEqual(updatedProfile.subscriptionDiagnostics.updateHistory.first?.result, .failed)
    XCTAssertEqual(updatedProfile.subscriptionDiagnostics.updateHistory.first?.failureKind, .httpStatus)
    XCTAssertEqual(updatedProfile.subscriptionDiagnostics.updateHistory.first?.httpStatusCode, 403)
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
    XCTAssertEqual(store.profiles.first?.subscriptionUpdateStatus.result, .succeeded)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.trigger, .manual)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.result, .succeeded)
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
    let profile = try await store.importLocalConfig(from: configURL)
    try "mixed-port: 7890\nrules: []\n"
      .write(to: URL(fileURLWithPath: profile.originalConfigPath), atomically: true, encoding: .utf8)
    let model = AppModel(paths: paths, profileStore: store)

    model.start()

    XCTAssertFalse(model.startInFlight)
    XCTAssertNil(model.lastError)

    for _ in 0..<100 where model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
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
    _ = try await store.importLocalConfig(from: configURL)
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

    for _ in 0..<120 where !model.isRunning || !model.systemProxyEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.proxyRoutingMode, .systemProxy)
    XCTAssertTrue(model.systemProxyEnabled)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
  }

  func testNetworkExtensionModeStartsUserCoreWithoutSystemProxyOrTunHelper() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let helperTransport = ReadyTunnelHelperTransport()
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let proxyPortReadiness = RecordingProxyPortReadinessProbe()
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
      transparentProxyManager: proxyManager
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      networkExtensionController: networkExtensionController,
      proxyPortReadinessProbe: proxyPortReadiness,
      defaults: try Self.makeIsolatedDefaults()
    )
    XCTAssertTrue(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(excludeLAN: true, customRouteExcludeCIDRs: ["100.64.0.0/10"])
      )
    )
    model.requestProxyRoutingMode(.neProxy)
    for _ in 0..<40 where model.proxyRoutingMode != .neProxy {
      await Task.yield()
    }

    model.start()

    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertFalse(model.startInFlight)
    XCTAssertTrue(model.isRunning)
    XCTAssertFalse(model.systemProxyEnabled)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertEqual(launcher.launchCount, 1)
    let helperStartCount = await helperTransport.startCount()
    XCTAssertEqual(helperStartCount, 0)
    XCTAssertFalse(commandRunner.commands.contains { $0.contains("-setwebproxy") })
    XCTAssertEqual(proxyManager.legacyCleanupIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(proxyManager.startConfigurations.count, 1)
    XCTAssertEqual(proxyManager.startConfigurations.first?.socksHost, "127.0.0.1")
    XCTAssertEqual(proxyManager.startConfigurations.first?.socksPort, 7890)
    XCTAssertEqual(proxyManager.startConfigurations.first?.dnsCaptureEnabled, true)
    XCTAssertEqual(proxyManager.startConfigurations.first?.dnsListenHost, "127.0.0.1")
    XCTAssertEqual(proxyManager.startConfigurations.first?.dnsListenPort, 1053)
    XCTAssertEqual(proxyManager.startConfigurations.first?.dnsFakeIPEnabled, true)
    XCTAssertEqual(proxyManager.startConfigurations.first?.systemDNSOverrideEnabled, true)
    XCTAssertEqual(proxyManager.startConfigurations.first?.systemDNSServers, ["114.114.114.114"])
    XCTAssertEqual(proxyManager.startConfigurations.first?.systemDNSOverrideApplied, false)
    XCTAssertEqual(
      proxyManager.startConfigurations.first?.routeExcludeCIDRs,
      NetworkExtensionRoutingSettings.defaultLANRouteExcludeCIDRs + ["100.64.0.0/10"]
    )
    XCTAssertEqual(
      proxyPortReadiness.requests,
      [
        ProxyPortReadinessRequest(host: "127.0.0.1", port: 7890),
        ProxyPortReadinessRequest(host: "127.0.0.1", port: 1053, serviceName: "Mihomo DNS")
      ]
    )
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"))
    XCTAssertEqual(model.networkExtensionSystemDNSState, .applied(serviceCount: 1))

    let runtimeConfigPath = try XCTUnwrap(launcher.launchedConfigPaths.last)
    let runtimeConfig = try String(contentsOfFile: runtimeConfigPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: runtimeConfig) as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])
    XCTAssertEqual(tun["enable"] as? Bool, false)
    XCTAssertNil(tun["auto-redirect"])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["listen"] as? String, "127.0.0.1:1053")
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(yaml["mixed-port"] as? Int, 7890)
    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
  }

  func testRepairNetworkExtensionDNSWhileRunningReappliesOverrideWithoutRestore() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let systemProxyController = SystemProxyController(commandRunner: commandRunner)
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: systemProxyController,
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()

    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertEqual(model.networkExtensionSystemDNSState, .applied(serviceCount: 1))
    XCTAssertTrue(systemProxyController.hasManagedSystemDNSState)
    XCTAssertTrue(model.canRepairNetworkExtensionDNS)

    let commandsBeforeRepair = commandRunner.commands
    model.repairNetworkExtensionDNS()

    for _ in 0..<80 {
      let commands = commandRunner.commands
      let newCommands = commands.dropFirst(commandsBeforeRepair.count)
      if commands.filter({ $0 == "/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114" }).count >= 2
          || newCommands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty") {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    for _ in 0..<20 where model.networkExtensionSystemDNSState == .applying {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let commandsAfterRepair = commandRunner.commands
    XCTAssertEqual(
      commandsAfterRepair.filter { $0 == "/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114" }.count,
      2
    )
    XCTAssertFalse(
      commandsAfterRepair.dropFirst(commandsBeforeRepair.count).contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty")
    )
    XCTAssertEqual(model.networkExtensionSystemDNSState, .applied(serviceCount: 1))
    XCTAssertTrue(systemProxyController.hasManagedSystemDNSState)
  }

  func testUpdatingNetworkExtensionRoutingSettingsRestartsRunningNetworkExtension() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = CountingProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where proxyManager.startConfigurations.count < 1 || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(proxyManager.startConfigurations.count, 1)

    XCTAssertTrue(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(excludeLAN: false, customRouteExcludeCIDRs: ["100.64.0.0/10"])
      )
    )

    for _ in 0..<240 where proxyManager.startConfigurations.count < 2 || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertEqual(proxyManager.startConfigurations.last?.routeExcludeCIDRs, ["100.64.0.0/10"])
  }

  func testUpdatingNetworkExtensionRoutingSettingsOutsideNetworkExtensionModeOnlyPersists() throws {
    let paths = try Self.makeRuntimePaths()
    let launcher = CountingProcessLauncher()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      coreController: CoreProcessController(
        launcher: launcher,
        validator: RecordingRuntimeConfigValidator(result: .success(())),
        readinessProbe: RecordingCoreReadinessProbe(),
        reaper: RecordingCoreProcessReaper(),
        portChecker: EmptyRuntimePortChecker()
      ),
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertTrue(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(excludeLAN: false, customRouteExcludeCIDRs: ["100.64.0.0/10"])
      )
    )

    XCTAssertEqual(model.networkExtensionRoutingSettings.effectiveRouteExcludeCIDRs, ["100.64.0.0/10"])
    XCTAssertEqual(launcher.launchCount, 0)
    XCTAssertEqual(model.runtimeOwner, .stopped)
  }

  func testUpdatingNetworkExtensionRoutingSettingsRejectsInvalidCIDR() throws {
    let paths = try Self.makeRuntimePaths()
    let launcher = CountingProcessLauncher()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      coreController: CoreProcessController(
        launcher: launcher,
        validator: RecordingRuntimeConfigValidator(result: .success(())),
        readinessProbe: RecordingCoreReadinessProbe(),
        reaper: RecordingCoreProcessReaper(),
        portChecker: EmptyRuntimePortChecker()
      ),
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertFalse(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(excludeLAN: false, customRouteExcludeCIDRs: ["192.168.0.0/33"])
      )
    )

    XCTAssertEqual(model.networkExtensionRoutingSettings, .default)
    XCTAssertEqual(model.lastError, "Invalid NE route exclude CIDR: 192.168.0.0/33")
    XCTAssertEqual(launcher.launchCount, 0)
  }

  func testUpdatingNetworkExtensionRoutingSettingsRejectsInvalidDNSSettings() throws {
    let paths = try Self.makeRuntimePaths()
    let launcher = CountingProcessLauncher()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      coreController: CoreProcessController(
        launcher: launcher,
        validator: RecordingRuntimeConfigValidator(result: .success(())),
        readinessProbe: RecordingCoreReadinessProbe(),
        reaper: RecordingCoreProcessReaper(),
        portChecker: EmptyRuntimePortChecker()
      ),
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertFalse(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(dnsListenPort: 0)
      )
    )
    XCTAssertEqual(model.lastError, "Invalid NE DNS listen port: 0")

    XCTAssertFalse(
      model.updateNetworkExtensionRoutingSettings(
        NetworkExtensionRoutingSettings(systemDNSServers: ["not-a-dns-server"])
      )
    )
    XCTAssertEqual(model.lastError, "Invalid NE system DNS server: not-a-dns-server")
    XCTAssertEqual(model.networkExtensionRoutingSettings, .default)
    XCTAssertEqual(launcher.launchCount, 0)
  }

  func testNetworkExtensionDiagnosticsPollingPublishesEventsAndStopsAfterStop() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let diagnosticsURL = paths.appSupport
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent(NetworkExtensionRuntimeConstants.diagnosticsFilename)
    let controller = CoreProcessController(
      launcher: CountingProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
      transparentProxyManager: proxyManager,
      diagnosticsURL: diagnosticsURL
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: networkExtensionController,
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.runtimeOwner, .networkExtension)

    try Self.writeNetworkExtensionDiagnostics(
      NetworkExtensionDiagnosticsSnapshot(
        activeBridgeCount: 1,
        bypassCount: 1,
        errorCount: 0,
        recentBypasses: [
          NetworkExtensionDiagnosticEvent(
            id: "bypass-before-stop",
            message: "Bypassed self/core flow.",
            sourceAppSigningIdentifier: "io.github.clashmax.ClashMax"
          )
        ],
        recentErrors: [],
        updatedAt: Date()
      ),
      to: diagnosticsURL
    )

    for _ in 0..<300 {
      model.runtimeData.flushPendingLogs()
      if model.logs.contains(where: { $0.message.contains("bypass-before-stop") || $0.message.contains("NE bypass") }) {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    model.runtimeData.flushPendingLogs()
    XCTAssertTrue(model.logs.contains { $0.message.contains("NE bypass") && $0.message.contains("io.github.clashmax.ClashMax") })

    model.stop()
    for _ in 0..<160 where model.runtimeOwner != .stopped {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    model.runtimeData.flushPendingLogs()
    let logCountAfterStop = model.logs.count
    try Self.writeNetworkExtensionDiagnostics(
      NetworkExtensionDiagnosticsSnapshot(
        activeBridgeCount: 0,
        bypassCount: 2,
        errorCount: 0,
        recentBypasses: [
          NetworkExtensionDiagnosticEvent(id: "bypass-after-stop", message: "After stop bypass.")
        ],
        recentErrors: [],
        updatedAt: Date()
      ),
      to: diagnosticsURL
    )
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    model.runtimeData.flushPendingLogs()

    XCTAssertEqual(model.logs.count, logCountAfterStop)
    XCTAssertFalse(model.logs.contains { $0.message.contains("After stop bypass") })
  }

  func testNetworkExtensionManualRefreshUpdatesDiagnosticsSnapshotWithoutPublishingRuntimeLogs() async throws {
    let paths = try Self.makeRuntimePaths()
    let diagnosticsURL = paths.appSupport
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent(NetworkExtensionRuntimeConstants.diagnosticsFilename)
    let proxyManager = RecordingTransparentProxyManager(currentStatus: .notConfigured)
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(
        snapshots: [
          SystemExtensionSnapshot(
            isEnabled: true,
            isAwaitingUserApproval: false,
            isUninstalling: false
          )
        ]
      ),
      transparentProxyManager: proxyManager,
      diagnosticsURL: diagnosticsURL
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      networkExtensionController: networkExtensionController,
      defaults: try Self.makeIsolatedDefaults()
    )
    try Self.writeNetworkExtensionDiagnostics(
      NetworkExtensionDiagnosticsSnapshot(
        activeBridgeCount: 0,
        bypassCount: 1,
        errorCount: 1,
        recentBypasses: [
          NetworkExtensionDiagnosticEvent(id: "manual-refresh-bypass", message: "Manual refresh bypass.")
        ],
        recentErrors: [
          NetworkExtensionDiagnosticEvent(id: "manual-refresh-error", message: "Manual refresh error.")
        ],
        updatedAt: Date()
      ),
      to: diagnosticsURL
    )

    model.refreshNetworkExtensionStatus()
    for _ in 0..<60 where model.networkExtensionController.diagnostics.recentBypasses.isEmpty {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    model.runtimeData.flushPendingLogs()

    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertEqual(model.networkExtensionController.vpnStatus, .notConfigured)
    XCTAssertTrue(model.networkExtensionController.diagnostics.recentBypasses.contains { $0.id == "manual-refresh-bypass" })
    XCTAssertTrue(model.networkExtensionController.diagnostics.recentErrors.contains { $0.id == "manual-refresh-error" })
    XCTAssertFalse(model.logs.contains { $0.message.contains("NE bypass") || $0.message.contains("NE error") })
    XCTAssertFalse(model.logs.contains { $0.message.contains("Manual refresh") })
  }

  func testNetworkExtensionModeChecksMixedPortBeforeStartingTransparentProxy() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    proxyManager.onStart = { events.append("networkExtensionStart") }
    let proxyPortReadiness = RecordingProxyPortReadinessProbe()
    proxyPortReadiness.onProbe = { events.append("proxyPortReady") }
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: proxyPortReadiness,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)

    model.start()

    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(Array(events.values.prefix(3)), ["proxyPortReady", "proxyPortReady", "networkExtensionStart"])
    XCTAssertEqual(
      proxyPortReadiness.requests,
      [
        ProxyPortReadinessRequest(host: "127.0.0.1", port: 7890),
        ProxyPortReadinessRequest(host: "127.0.0.1", port: 1053, serviceName: "Mihomo DNS")
      ]
    )
  }

  func testNetworkExtensionMixedPortReadinessFailureStopsCoreAndSkipsTransparentProxy() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let proxyPortReadiness = RecordingProxyPortReadinessProbe(
      result: .failure(AppError.coreNotReady("mixed-port refused"))
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: proxyPortReadiness,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)

    model.start()

    for _ in 0..<160 where model.startInFlight || model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.lastError?.contains("mixed-port refused") == true)
    XCTAssertEqual(proxyManager.startConfigurations, [])
    XCTAssertEqual(events.values, ["coreStop"])
  }

  func testStoppingNetworkExtensionStopsTunnelBeforeMihomoCore() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let commandRunner = DNSRestoreEventCommandRunner(outputs: Self.defaultNetworkSetupOutputs(), events: events)
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
      transparentProxyManager: proxyManager
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      networkExtensionController: networkExtensionController,
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertFalse(model.startInFlight)

    model.stop()

    for _ in 0..<160 where model.runtimeOwner != .stopped {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(Array(events.values.prefix(3)), ["networkExtensionStop", "dnsRestore", "coreStop"])
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
  }

  func testNetworkExtensionCoreCrashKeepsStopAvailableAndStopsTransparentProxy() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let launcher = FakeProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    launcher.process.finish(exitCode: 2)
    for _ in 0..<60 {
      if case .crashed = model.dashboardRuntimeState {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.dashboardRuntimeState, .crashed(message: "mihomo exited with code 2"))
    XCTAssertEqual(model.statusSummary, "Crashed: mihomo exited with code 2")
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.canStopRuntime)

    let redundantCoreStop = await controller.stop()
    XCTAssertTrue(redundantCoreStop.succeeded)
    XCTAssertEqual(model.dashboardRuntimeState, .crashed(message: "mihomo exited with code 2"))
    XCTAssertEqual(model.statusSummary, "Crashed: mihomo exited with code 2")
    XCTAssertTrue(model.canStopRuntime)

    model.stop()

    for _ in 0..<160 where model.runtimeOwner != .stopped {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
  }

  func testNetworkExtensionStopErrorKeepsMihomoCoreRunning() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    proxyManager.stopError = AppError.coreNotReady("transparent proxy stop refused")
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let systemProxyController = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: systemProxyController,
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertFalse(model.startInFlight)

    model.stop()

    for _ in 0..<160 where proxyManager.stopIdentifiers.isEmpty {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    for _ in 0..<160 where model.lastError?.contains("Could not stop Network Extension cleanly") != true {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(events.values, ["networkExtensionStop"])
    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertTrue(model.isRunning)
    XCTAssertTrue(systemProxyController.hasManagedSystemDNSState)
    XCTAssertFalse(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
    XCTAssertTrue(model.lastError?.contains("Could not stop Network Extension cleanly") == true)
    XCTAssertTrue(model.lastError?.contains("transparent proxy stop refused") == true)
  }

  func testNetworkExtensionStopStillActiveKeepsMihomoCoreRunning() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected, stopStatus: .disconnecting)
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let systemProxyController = SystemProxyController(commandRunner: commandRunner)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: systemProxyController,
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<400 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertFalse(model.startInFlight)

    model.stop()

    for _ in 0..<160 where proxyManager.stopIdentifiers.isEmpty {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    for _ in 0..<160 where model.lastError?.contains("Could not stop Network Extension cleanly") != true {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(events.values, ["networkExtensionStop"])
    XCTAssertEqual(model.runtimeOwner, .networkExtension)
    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(model.networkExtensionController.vpnStatus, .disconnecting)
    XCTAssertTrue(systemProxyController.hasManagedSystemDNSState)
    XCTAssertFalse(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
    XCTAssertTrue(model.lastError?.contains("Could not stop Network Extension cleanly") == true)
    XCTAssertTrue(model.lastError?.contains("Disconnecting") == true)
  }

  func testTerminationAfterNetworkExtensionStopErrorStopsMihomoCoreAndClearsLocalRuntime() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    proxyManager.stopError = AppError.coreNotReady("transparent proxy stop refused")
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let publicIPInfo = Self.makePublicIPInfo(ip: "203.0.113.9", fetchedAt: Date(timeIntervalSince1970: 1_000))
    let publicIPFetcher = RecordingPublicIPInfoFetcher(infos: [publicIPInfo], delayNanoseconds: 800_000_000)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      publicIPInfoClient: publicIPFetcher,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    model.refreshPublicIPInfo(force: true)
    try? await Task.sleep(nanoseconds: 20_000_000)

    let didCleanUp = await model.prepareForTermination()

    XCTAssertTrue(didCleanUp)
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(Array(events.values.prefix(2)), ["networkExtensionStop", "coreStop"])
    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.publicIPInfoState, .idle)
    XCTAssertTrue(model.lastError?.contains("Could not stop Network Extension cleanly") == true)
    XCTAssertTrue(model.lastError?.contains("transparent proxy stop refused") == true)
  }

  func testTerminationAfterNetworkExtensionStopStillActiveStopsMihomoCoreAndKeepsError() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected, stopStatus: .disconnecting)
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let didCleanUp = await model.prepareForTermination()

    XCTAssertTrue(didCleanUp)
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
    XCTAssertEqual(Array(events.values.prefix(2)), ["networkExtensionStop", "coreStop"])
    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.networkExtensionController.vpnStatus, .disconnecting)
    XCTAssertTrue(model.lastError?.contains("Could not stop Network Extension cleanly") == true)
    XCTAssertTrue(model.lastError?.contains("Disconnecting") == true)
  }

  func testTerminationReturnsFalseWhenMihomoCoreCannotStop() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = UnstoppableProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .connected)
    proxyManager.stopError = AppError.coreNotReady("transparent proxy stop refused")
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
        transparentProxyManager: proxyManager
      ),
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()
    for _ in 0..<160 where model.runtimeOwner != .networkExtension || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let didCleanUp = await model.prepareForTermination()

    XCTAssertFalse(didCleanUp)
    XCTAssertEqual(Array(events.values.prefix(3)), ["networkExtensionStop", "coreStop", "coreKill"])
    XCTAssertTrue(launcher.process.isRunning)
    XCTAssertTrue(model.lastError?.contains("Could not stop Network Extension cleanly") == true)
  }

  func testNetworkExtensionStartFailureStopsMihomoCore() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(startStatus: .disconnected)
    proxyManager.lastDisconnectErrorMessage = "transparent proxy refused"
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
      transparentProxyManager: proxyManager
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: networkExtensionController,
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()

    for _ in 0..<160 where model.startInFlight || model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.lastError, "transparent proxy refused")
    XCTAssertEqual(events.values, ["coreStop"])
    XCTAssertEqual(proxyManager.stopIdentifiers, [])
  }

  func testNetworkExtensionStartTimeoutWithActiveStatusStopsTransparentProxyBeforeCore() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let events = StopEventRecorder()
    let launcher = OrderedProcessLauncher(events: events)
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let proxyManager = RecordingTransparentProxyManager(currentStatus: .connecting, startStatus: .connecting)
    proxyManager.startError = NetworkExtensionControllerError.transparentProxyStartTimedOut(.connecting)
    proxyManager.onStop = { events.append("networkExtensionStop") }
    let networkExtensionController = NetworkExtensionController(
      systemExtensionRequester: StaticSystemExtensionRequester(activationState: .activated),
      transparentProxyManager: proxyManager
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      networkExtensionController: networkExtensionController,
      proxyPortReadinessProbe: RecordingProxyPortReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.setProxyRoutingMode(.neProxy)
    model.start()

    for _ in 0..<160 where model.startInFlight || model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.runtimeOwner, .stopped)
    XCTAssertFalse(model.isRunning)
    XCTAssertTrue(model.lastError?.contains("NE transparent proxy did not become connected before timeout") == true)
    XCTAssertEqual(Array(events.values.prefix(2)), ["networkExtensionStop", "coreStop"])
    XCTAssertEqual(proxyManager.stopIdentifiers, [NetworkExtensionController.providerBundleIdentifier])
  }

  func testProxyRoutingModesIncludeNEProxyWhenDeveloperModeIsOff() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertFalse(model.developerMode)
    XCTAssertTrue(ProxyRoutingMode.allCases.contains(.neProxy))
    XCTAssertEqual(ProxyRoutingMode.neProxy.displayName, String(localized: "NE Proxy"))
  }

  func testNetworkExtensionLegacyPersistedModeLoadsWhenDeveloperModeIsOff() throws {
    let defaults = try Self.makeIsolatedDefaults()
    defaults.set(
      try XCTUnwrap("\"networkExtensionExperimental\"".data(using: .utf8)),
      forKey: Self.proxyRoutingModeDefaultsKey
    )
    let paths = try Self.makeRuntimePaths()

    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults
    )

    XCTAssertFalse(model.developerMode)
    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertNil(model.lastError)
    XCTAssertNil(model.appNotice)
    let persistedData = try XCTUnwrap(defaults.data(forKey: Self.proxyRoutingModeDefaultsKey))
    let persistedMode = try JSONDecoder().decode(ProxyRoutingMode.self, from: persistedData)
    XCTAssertEqual(persistedMode, .neProxy)
    XCTAssertEqual(persistedMode.rawValue, "networkExtensionExperimental")
  }

  func testNetworkExtensionCanBeSelectedWhenDeveloperModeIsOff() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
    )

    XCTAssertFalse(model.developerMode)
    model.setProxyRoutingMode(.neProxy)

    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertNil(model.lastError)
    XCTAssertNil(model.appNotice)
  }

  func testDisablingDeveloperModeKeepsNetworkExtensionSelected() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
    )

    model.developerMode = true
    model.setProxyRoutingMode(.neProxy)
    model.developerMode = false

    XCTAssertEqual(model.proxyRoutingMode, .neProxy)
    XCTAssertNil(model.lastError)
    XCTAssertNil(model.appNotice)
  }

  func testDeveloperModeOffPreventsGlobalShortcutRegistration() throws {
    let paths = try Self.makeRuntimePaths()
    let registrar = RecordingAppGlobalShortcutRegistrar()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults(),
      globalShortcutRegistrar: registrar
    )
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))

    model.globalShortcutSettings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    XCTAssertFalse(model.developerMode)
    XCTAssertTrue(registrar.registrations.isEmpty)
    XCTAssertGreaterThanOrEqual(registrar.unregisterCount, 1)
    XCTAssertNil(model.shortcutRegistrationStatus)
  }

  func testDeveloperModeToggleRegistersAndUnregistersGlobalShortcuts() throws {
    let paths = try Self.makeRuntimePaths()
    let registrar = RecordingAppGlobalShortcutRegistrar()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults(),
      globalShortcutRegistrar: registrar
    )
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))

    model.globalShortcutSettings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])
    model.setDeveloperMode(true)

    XCTAssertEqual(registrar.registrations.map(\.action), [.startStop])
    XCTAssertEqual(model.shortcutRegistrationStatus?.registeredCount, 1)
    XCTAssertTrue(model.shortcutRegistrationStatus?.failures.isEmpty == true)

    model.setDeveloperMode(false)

    XCTAssertTrue(registrar.registrations.isEmpty)
    XCTAssertNil(model.shortcutRegistrationStatus)
  }

  func testGlobalShortcutRegistrationFailureUpdatesPublishedStatus() throws {
    let paths = try Self.makeRuntimePaths()
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))
    let failure = GlobalShortcutRegistrationFailure(
      action: .startStop,
      shortcut: shortcut,
      osStatus: -9876
    )
    let registrar = RecordingAppGlobalShortcutRegistrar(failuresToReturn: [failure])
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults(),
      globalShortcutRegistrar: registrar
    )

    model.setDeveloperMode(true)
    model.globalShortcutSettings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    XCTAssertEqual(model.shortcutRegistrationStatus?.failures, [failure])
    XCTAssertTrue(model.shortcutRegistrationStatus?.errorMessage?.contains("OSStatus -9876") == true)
  }

  func testNetworkExtensionRefreshClearsPublishedApprovalErrorAfterApproval() async throws {
    let paths = try Self.makeRuntimePaths()
    let requester = StaticSystemExtensionRequester(activationState: .requiresApproval)
    let proxyManager = RecordingTransparentProxyManager(currentStatus: .notConfigured)
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: requester,
        transparentProxyManager: proxyManager
      ),
      defaults: try Self.makeIsolatedDefaults()
    )

    model.installNetworkExtension()
    for _ in 0..<60 where model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(model.lastError, "System Extension requires approval in System Settings.")

    requester.snapshots = [
      SystemExtensionSnapshot(
        isEnabled: true,
        isAwaitingUserApproval: false,
        isUninstalling: false
      )
    ]
    model.refreshNetworkExtensionStatus()
    for _ in 0..<60 where model.lastError != nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertNil(model.lastError)
    XCTAssertEqual(model.networkExtensionController.systemExtensionState, .activated)
    XCTAssertEqual(model.networkExtensionController.vpnStatus, .notConfigured)
  }

  func testNetworkExtensionRefreshDoesNotClearNonNetworkExtensionError() async throws {
    let paths = try Self.makeRuntimePaths()
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
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      networkExtensionController: NetworkExtensionController(
        systemExtensionRequester: requester,
        transparentProxyManager: proxyManager
      ),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.lastError = "Non-NE validation failed."

    model.refreshNetworkExtensionStatus()
    for _ in 0..<60 where requester.propertyIdentifiers.isEmpty {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.lastError, "Non-NE validation failed.")
    XCTAssertEqual(model.networkExtensionController.systemExtensionState, .activated)
  }

  func testTunStartWaitsForControllerReadinessBeforePublishingRunningState() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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

    for _ in 0..<120 where model.startInFlight || model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
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

  func testTunStartAppliesSystemDNSAndStopRestoresIt() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helperTransport = ReadyTunnelHelperTransport()
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }

    model.start()

    for _ in 0..<160 where !model.isRunning && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.isRunning)
    XCTAssertTrue(model.tunEnabled)
    XCTAssertEqual(model.tunHelperPID, 99)
    XCTAssertEqual(model.tunSystemDNSState, .applied(serviceCount: 1))
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"))

    model.stop()
    for _ in 0..<160 where model.isRunning || model.tunnelCoreRunning || model.tunEnabled {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertFalse(model.isRunning)
    XCTAssertNil(model.tunHelperPID)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
    XCTAssertEqual(model.tunSystemDNSState, .restored)
  }

  func testTunSystemDNSApplyFailureStopsHelperAndDoesNotPublishRunningState() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helperTransport = ReadyTunnelHelperTransport()
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let commandRunner = FailingDNSApplyCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }

    model.start()

    for _ in 0..<160 where model.startInFlight || model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(model.isRunning)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertNil(model.tunHelperPID)
    XCTAssertTrue(model.lastError?.contains("Injected DNS failure") == true)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
  }

  func testTunStartPublishesDiagnosticsAfterSystemDNSApply() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let snapshot = Self.tunDiagnosticsSnapshot(
      checks: [
        TunDiagnosticCheck(id: "controller", title: "Controller", status: .pass, message: "ready"),
        TunDiagnosticCheck(id: "system-dns", title: "System DNS", status: .pass, message: "applied")
      ],
      includeExternal: true,
      time: 1
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [snapshot])
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: inspector,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }

    model.start()

    for _ in 0..<160 where model.tunDiagnostics.checks.isEmpty && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(model.tunDiagnostics, snapshot)
    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.count, 1)
    XCTAssertEqual(configurations.first?.helperPID, 99)
    XCTAssertEqual(configurations.first?.systemDNSState, .applied(serviceCount: 1))
    XCTAssertEqual(configurations.first?.includeExternal, true)
  }

  func testTunDiagnosticFailureDoesNotUndoRunningTunnel() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let snapshot = Self.tunDiagnosticsSnapshot(
      checks: [
        TunDiagnosticCheck(
          id: "interface",
          title: "TUN Interface",
          status: .fail,
          message: "No utun interface was found."
        )
      ],
      includeExternal: true,
      time: 2
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [snapshot])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: inspector,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }

    model.start()

    for _ in 0..<160 where model.tunDiagnostics.checks.isEmpty && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.isRunning)
    XCTAssertTrue(model.tunEnabled)
    XCTAssertNil(model.lastError)
    XCTAssertEqual(model.tunDiagnostics.overallStatus, .fail)
  }

  func testTunDiagnosticsManualRefreshUsesRequestedExternalProbeFlag() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let first = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "controller", title: "Controller", status: .pass, message: "ready")],
      includeExternal: true,
      time: 3
    )
    let second = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "external-tcp", title: "External TCP", status: .skipped, message: "skipped")],
      includeExternal: false,
      time: 4
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [first, second])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: inspector,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }
    model.start()
    for _ in 0..<160 where model.tunDiagnostics.updatedAt != first.updatedAt && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    model.refreshTunDiagnostics(includeExternal: false)
    for _ in 0..<160 where model.tunDiagnostics.updatedAt != second.updatedAt {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.tunDiagnostics, second)
    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.map(\.includeExternal), [true, false])
  }

  func testTunDiagnosticsRefreshUsesLiveHelperStatusInsteadOfCachedStartupPID() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helper = TunnelHelperClient(
      transport: StoppedStatusAfterStartTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let snapshot = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "helper-pid", title: "Helper PID", status: .fail, message: "stopped")],
      includeExternal: false,
      time: 41
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [snapshot])
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: inspector,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }
    model.start()

    for _ in 0..<160 where model.tunDiagnostics.updatedAt != snapshot.updatedAt && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(model.isRunning)
    XCTAssertNil(model.tunHelperPID)
    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.first?.helperPID, nil)
  }

  func testRepairTunDNSReappliesOverrideAndRefreshesDiagnostics() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let first = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "system-dns", title: "System DNS", status: .pass, message: "applied")],
      includeExternal: true,
      time: 5
    )
    let repaired = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "system-dns", title: "System DNS", status: .pass, message: "repaired")],
      includeExternal: false,
      time: 6
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [first, repaired])
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: inspector,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }
    model.start()
    for _ in 0..<160 where model.tunDiagnostics.updatedAt != first.updatedAt && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let applyCommand = "/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"
    let initialApplyCount = commandRunner.commands.filter { $0 == applyCommand }.count
    model.lastError = nil
    model.repairTunDNS()

    for _ in 0..<160 where commandRunner.commands.filter({ $0 == applyCommand }).count <= initialApplyCount
      || model.tunDiagnostics.updatedAt != repaired.updatedAt {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(model.tunSystemDNSState, .applied(serviceCount: 1))
    XCTAssertNil(model.lastError)
    XCTAssertEqual(model.tunDiagnostics, repaired)
    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.last?.includeExternal, false)
  }

  func testTunStopDisablesMihomoTunBeforeStoppingHelper() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let model = try await makeRunningTunnelModel(client: client, helperTransport: helperTransport)

    model.stop()
    for _ in 0..<160 {
      let currentStopCount = await helperTransport.stopCount()
      if currentStopCount > 0, !model.tunnelCoreRunning, !model.tunEnabled { break }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let tunEnabledUpdates = await client.tunEnabledUpdateValues()
    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(tunEnabledUpdates, [false])
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(model.tunnelCoreRunning)
    XCTAssertFalse(model.tunEnabled)
  }

  func testRunningTunSettingsSaveReloadsRuntimeConfig() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let model = try await makeRunningTunnelModel(client: client, helperTransport: helperTransport)
    var settings = TunSettings.default
    settings.mtu = 1400

    XCTAssertTrue(model.updateTunSettings(settings))
    for _ in 0..<160 {
      let reloadPaths = await client.reloadRequestPaths()
      if !reloadPaths.isEmpty || model.lastError != nil { break }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 0)
    XCTAssertNil(model.lastError)
  }

  func testRunningTunSettingsSaveInspectsTargetSettingsWhenAppliedSnapshotIsStale() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let inspector = RecordingTunRuntimeInspector(snapshots: [.empty, .empty])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )
    var staleSettings = TunSettings.default
    staleSettings.device = "utun-old"
    staleSettings.autoRoute = false
    staleSettings.routeExcludeAddresses = ["10.0.0.0/8"]
    staleSettings.dnsHijack = ["127.0.0.1:53"]
    staleSettings.dnsFakeIPEnabled = false
    staleSettings.systemDNSOverrideEnabled = false
    recordAppliedTunnelSnapshot(on: model, tunSettings: staleSettings)
    var targetSettings = TunSettings.default
    targetSettings.device = "utun2048"
    targetSettings.autoRoute = true
    targetSettings.routeExcludeAddresses = ["192.0.2.0/24"]
    targetSettings.dnsHijack = ["198.18.0.2:53"]
    targetSettings.dnsFakeIPEnabled = true
    targetSettings.systemDNSOverrideEnabled = false

    XCTAssertTrue(model.updateTunSettings(targetSettings))
    for _ in 0..<160 {
      let reloadPaths = await client.reloadRequestPaths()
      let configurations = await inspector.configurations()
      if !reloadPaths.isEmpty, configurations.count >= 2 {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.count, 2)
    XCTAssertTrue(configurations.allSatisfy { $0.tunSettings == targetSettings })
    XCTAssertFalse(configurations.contains { $0.tunSettings == staleSettings })
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(restartCount, 0)
    XCTAssertNil(model.lastError)
  }

  func testRunningTunRuntimeOverrideChangeReloadsConfigAndUpdatesAppliedSnapshotAfterVerification() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let inspector = RecordingTunRuntimeInspector(snapshots: [.empty])
    let defaults = try Self.makeIsolatedDefaults()
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector,
      defaults: defaults
    )

    model.setAllowLAN(true)

    for _ in 0..<160 {
      let reloadPaths = await client.reloadRequestPaths()
      let inspected = await inspector.configurations()
      if !reloadPaths.isEmpty, !inspected.isEmpty, model.runtimeSettingsApplyState == .idle {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadPaths = await client.reloadRequestPaths()
    let reloadPath = try XCTUnwrap(reloadPaths.last)
    let output = try String(contentsOfFile: reloadPath, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    let inspectionConfigurations = await inspector.configurations()
    let reloaded = PersistedSettingsStore(
      loginItemService: FakeLoginItemService(status: .notRegistered),
      defaults: defaults
    )

    XCTAssertEqual(yaml["allow-lan"] as? Bool, true)
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 0)
    XCTAssertFalse(inspectionConfigurations.isEmpty)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.runtimeOwner, .tunnel)
    XCTAssertEqual(model.settings.appliedRuntimeSettingsSnapshot?.overrides.allowLan, true)
    XCTAssertEqual(model.runtimeSettingsApplyState, .idle)
    XCTAssertTrue(model.overrides.allowLan)
    XCTAssertTrue(reloaded.overrides.allowLan)
    XCTAssertNil(model.lastError)
  }

  func testRunningTunSettingsSaveFallsBackToHelperRestartWhenReloadFails() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessage: "reload refused"
    )
    let helperTransport = ReadyTunnelHelperTransport()
    let model = try await makeRunningTunnelModel(client: client, helperTransport: helperTransport)
    var settings = TunSettings.default
    settings.mtu = 1400

    XCTAssertTrue(model.updateTunSettings(settings))
    for _ in 0..<160 {
      let currentRestartCount = await helperTransport.restartCount()
      if currentRestartCount > 0 || model.lastError != nil { break }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertTrue(model.tunEnabled)
    XCTAssertNil(model.lastError)
  }

  func testRunningTunSettingsSaveRestartsHelperWhenReloadLeavesRouteIssue() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 44
    )
    let repaired = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .pass, message: "ok")],
      includeExternal: false,
      time: 45
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue, repaired])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )
    var settings = TunSettings.default
    settings.mtu = 1400

    XCTAssertTrue(model.updateTunSettings(settings))
    for _ in 0..<160 {
      let currentRestartCount = await helperTransport.restartCount()
      if currentRestartCount > 0, model.tunDiagnostics.updatedAt == repaired.updatedAt {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(model.tunDiagnostics, repaired)
    XCTAssertNil(model.lastError)
  }

  func testRunningTunSettingsSaveSurfacesErrorWhenHelperRestartLeavesRouteIssue() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 46
    )
    let stillBroken = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "still stale")],
      includeExternal: false,
      time: 47
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue, stillBroken])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )
    var settings = TunSettings.default
    settings.mtu = 1400

    XCTAssertTrue(model.updateTunSettings(settings))
    for _ in 0..<160 where model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertTrue(model.tunEnabled)
    XCTAssertTrue(model.lastError?.contains("Could not apply TUN settings without restart") == true)
    XCTAssertTrue(model.lastError?.contains("Default Route: still stale") == true)
  }

  func testRunningTunSettingsSaveSurfacesDNSApplyFailureWithoutHelperRestart() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let commandRunner = FailingDNSApplyCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      systemProxyController: SystemProxyController(commandRunner: commandRunner)
    )
    var settings = TunSettings.default
    settings.mtu = 1400

    XCTAssertTrue(model.updateTunSettings(settings))
    for _ in 0..<160 where model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 0)
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"))
    XCTAssertTrue(model.lastError?.contains("Could not apply TUN settings without restart") == true)
    XCTAssertTrue(model.lastError?.contains("Injected DNS failure") == true)
  }

  func testRepairTunRoutingReloadsConfigWhenDiagnosticsClear() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let snapshot = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .pass, message: "ok")],
      includeExternal: false,
      time: 51
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [snapshot])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )

    model.repairTunRouting()
    for _ in 0..<160 where model.tunDiagnostics.updatedAt != snapshot.updatedAt && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 0)
    XCTAssertEqual(model.tunDiagnostics, snapshot)
    XCTAssertNil(model.lastError)
  }

  func testRepairTunRoutingInspectsTargetSettingsWhenAppliedSnapshotIsStale() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 57
    )
    let repaired = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .pass, message: "ok")],
      includeExternal: false,
      time: 58
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue, repaired])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )
    var staleSettings = TunSettings.default
    staleSettings.device = "utun-old"
    staleSettings.autoRoute = false
    staleSettings.routeExcludeAddresses = ["10.0.0.0/8"]
    staleSettings.dnsHijack = ["127.0.0.1:53"]
    staleSettings.dnsFakeIPEnabled = false
    staleSettings.systemDNSOverrideEnabled = false
    recordAppliedTunnelSnapshot(on: model, tunSettings: staleSettings)
    var targetSettings = TunSettings.default
    targetSettings.device = "utun2048"
    targetSettings.autoRoute = true
    targetSettings.routeExcludeAddresses = ["192.0.2.0/24"]
    targetSettings.dnsHijack = ["198.18.0.2:53"]
    targetSettings.dnsFakeIPEnabled = true
    targetSettings.systemDNSOverrideEnabled = false
    model.tunSettings = targetSettings

    model.repairTunRouting()
    for _ in 0..<160 {
      let restartCount = await helperTransport.restartCount()
      let configurations = await inspector.configurations()
      if restartCount > 0, configurations.count >= 2 {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let configurations = await inspector.configurations()
    XCTAssertEqual(configurations.count, 2)
    XCTAssertTrue(configurations.allSatisfy { $0.tunSettings == targetSettings })
    XCTAssertFalse(configurations.contains { $0.tunSettings == staleSettings })
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(model.tunDiagnostics, repaired)
    XCTAssertNil(model.lastError)
  }

  func testRepairTunRoutingRestartsHelperWhenReloadLeavesRouteIssue() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 52
    )
    let repaired = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .pass, message: "ok")],
      includeExternal: false,
      time: 53
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue, repaired])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )

    model.repairTunRouting()
    for _ in 0..<160 {
      let currentRestartCount = await helperTransport.restartCount()
      if currentRestartCount > 0, model.tunDiagnostics.updatedAt == repaired.updatedAt {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(model.tunDiagnostics, repaired)
    XCTAssertNil(model.lastError)
  }

  func testRepairTunRoutingStopsTunnelWhenRestartLeavesRouteIssue() async throws {
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 54
    )
    let stillBroken = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "still stale")],
      includeExternal: false,
      time: 55
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue, stillBroken])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )

    model.repairTunRouting()
    for _ in 0..<160 {
      if !model.tunnelCoreRunning,
         !model.tunEnabled,
         model.tunDiagnostics == .empty,
         model.lastError?.contains("stopped TUN safely") == true {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(stopCount, 2)
    XCTAssertFalse(model.tunnelCoreRunning)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertTrue(model.lastError?.contains("stopped TUN safely") == true)
    XCTAssertTrue(model.lastError?.contains("Default Route: still stale") == true)
  }

  func testRepairTunRoutingStopsTunnelWhenReloadFallbackRestartStillHasRouteIssue() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessage: "reload refused"
    )
    let helperTransport = ReadyTunnelHelperTransport()
    let routeIssue = Self.tunDiagnosticsSnapshot(
      checks: [
        Self.nonRoutingControllerFailureCheck(),
        TunDiagnosticCheck(id: "default-route", title: "Default Route", status: .fail, message: "stale")
      ],
      includeExternal: false,
      time: 56
    )
    let inspector = RecordingTunRuntimeInspector(snapshots: [routeIssue])
    let model = try await makeRunningTunnelModel(
      client: client,
      helperTransport: helperTransport,
      tunRuntimeInspector: inspector
    )

    model.repairTunRouting()
    for _ in 0..<160 {
      if !model.tunnelCoreRunning,
         !model.tunEnabled,
         model.tunDiagnostics == .empty,
         model.lastError?.contains("stopped TUN safely") == true {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let reloadForces = await client.reloadRequestForces()
    let restartCount = await helperTransport.restartCount()
    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(reloadForces, [true])
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(stopCount, 2)
    XCTAssertFalse(model.tunnelCoreRunning)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertTrue(model.lastError?.contains("stopped TUN safely") == true)
    XCTAssertTrue(model.lastError?.contains("Default Route: stale") == true)
  }

  func testRepairTunRoutingStopsTunnelWhenRestartFails() async throws {
    let client = RecordingMihomoController(
      proxyGroupsResponse: [],
      testDelayResult: 0,
      reloadFailureMessage: "reload refused"
    )
    let helperTransport = FailingRestartTunnelHelperTransport()
    let model = try await makeRunningTunnelModel(client: client, helperTransport: helperTransport)

    model.repairTunRouting()
    for _ in 0..<160 {
      if !model.tunnelCoreRunning,
         !model.tunEnabled,
         model.tunDiagnostics == .empty,
         model.lastError?.contains("stopped TUN safely") == true {
        break
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let restartCount = await helperTransport.restartCount()
    let stopCount = await helperTransport.stopCount()
    XCTAssertEqual(restartCount, 1)
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(model.tunnelCoreRunning)
    XCTAssertFalse(model.tunEnabled)
    XCTAssertTrue(model.lastError?.contains("stopped TUN safely") == true)
  }

  func testTunTerminationRestoresSystemDNSAndClearsDiagnostics() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let helperTransport = ReadyTunnelHelperTransport()
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let snapshot = Self.tunDiagnosticsSnapshot(
      checks: [TunDiagnosticCheck(id: "controller", title: "Controller", status: .pass, message: "ready")],
      includeExternal: true,
      time: 7
    )
    let commandRunner = RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(commandRunner: commandRunner),
      helperClient: helper,
      tunnelReadinessProbe: RecordingCoreReadinessProbe(),
      tunRuntimeInspector: RecordingTunRuntimeInspector(snapshots: [snapshot]),
      defaults: try Self.makeIsolatedDefaults()
    )
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where !model.tunHelperPreparationState.isReady {
      await Task.yield()
    }
    model.start()
    for _ in 0..<160 where model.tunDiagnostics.updatedAt != snapshot.updatedAt && model.lastError == nil {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    let didCleanUp = await model.prepareForTermination()
    let stopCount = await helperTransport.stopCount()

    XCTAssertTrue(didCleanUp)
    XCTAssertEqual(stopCount, 1)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.tunSystemDNSState, .restored)
    XCTAssertEqual(model.tunDiagnostics.checks, [])
    XCTAssertTrue(commandRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
  }

  func testSelectingProfileWhileRunningRestartsRuntimeWithNewProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: firstConfigURL)
    let secondProfile = try await store.importLocalConfig(from: secondConfigURL)
    try await store.select(store.profiles[0])
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
    for _ in 0..<120 where launcher.launchCount < 1 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    await model.selectProfileAsync(secondProfile)

    for _ in 0..<160 where launcher.launchCount < 2 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertEqual(store.activeProfileID, secondProfile.id)
    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertTrue(launcher.launchedConfigPaths.last?.contains(secondProfile.id.uuidString) == true)
  }

  func testDeletingRunningActiveProfileRestartsRuntimeWithNextProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let firstProfile = try await store.importLocalConfig(from: firstConfigURL)
    let secondProfile = try await store.importLocalConfig(from: secondConfigURL)
    try await store.select(firstProfile)
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
    for _ in 0..<160 where launcher.launchCount < 1 || !model.isRunning {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(model.isRunning)

    let didDelete = await model.deleteProfileAsync(firstProfile)

    for _ in 0..<240 where launcher.launchCount < 2 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(didDelete)
    XCTAssertEqual(store.activeProfileID, secondProfile.id)
    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertTrue(launcher.launchedConfigPaths.first?.contains(firstProfile.id.uuidString) == true)
    XCTAssertTrue(launcher.launchedConfigPaths.last?.contains(secondProfile.id.uuidString) == true)
  }

  func testDeletingOnlyRunningActiveProfileStopsRuntime() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: configURL)
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
    for _ in 0..<160 where launcher.launchCount < 1 || !model.isRunning {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertTrue(model.isRunning)

    let didDelete = await model.deleteProfileAsync(profile)

    for _ in 0..<240 where model.isRunning || model.startInFlight {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(didDelete)
    XCTAssertNil(store.activeProfileID)
    XCTAssertEqual(launcher.launchCount, 1)
    XCTAssertFalse(model.isRunning)
    XCTAssertNil(model.lastError)
  }

  func testSettingCurrentModeDoesNotPublishChanges() throws {
    let paths = try Self.makeRuntimePaths()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
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
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: try Self.makeIsolatedDefaults()
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
    _ = try await store.importLocalConfig(from: configURL)
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

  func testLaunchWarmupPreservesRegisteredTunHelperAcrossModeSwitches() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .enabled)
    let helper = TunnelHelperClient(
      transport: FailingStatusTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()

    for _ in 0..<40 where !model.tunHelperPreparationState.allowsStartAttempt {
      await Task.yield()
    }

    XCTAssertEqual(model.tunHelperPreparationState, .registered(TunnelHelperClient.registeredMessage))
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)

    model.requestProxyRoutingMode(.tun)
    for _ in 0..<20 where model.proxyRoutingMode != .tun {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .tun)
    XCTAssertEqual(model.tunHelperPreparationState, .registered(TunnelHelperClient.registeredMessage))

    model.requestProxyRoutingMode(.systemProxy)
    for _ in 0..<20 where model.proxyRoutingMode != .systemProxy {
      await Task.yield()
    }
    model.requestProxyRoutingMode(.tun)
    for _ in 0..<20 where model.proxyRoutingMode != .tun {
      await Task.yield()
    }

    XCTAssertEqual(model.tunHelperPreparationState, .registered(TunnelHelperClient.registeredMessage))
  }

  func testLaunchWarmupShowsInitialHelperPromptWithoutRegistering() throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()

    XCTAssertEqual(model.initialTunHelperPrompt?.primaryAction, .install)
    XCTAssertEqual(model.initialTunHelperPrompt?.statusMessage, TunnelHelperClient.statusMessage(for: .notRegistered))
    XCTAssertFalse(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)
  }

  func testSilentStartDefersInitialHelperPromptWithoutRegistering() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    defaults.set(true, forKey: AppModel.silentStartDefaultsKey)
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: defaults
    )

    model.warmTunHelperRegistrationOnLaunch()
    model.evaluateInitialTunHelperPromptOnLaunch()

    XCTAssertNil(model.initialTunHelperPrompt)
    XCTAssertFalse(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)
  }

  func testOpeningMainWindowAfterSilentStartDeferralPresentsInitialHelperPrompt() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    defaults.set(true, forKey: AppModel.silentStartDefaultsKey)
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: defaults
    )

    model.warmTunHelperRegistrationOnLaunch()
    model.resumeDeferredInitialTunHelperPromptAfterUserOpen()

    XCTAssertEqual(model.initialTunHelperPrompt?.primaryAction, .install)
    XCTAssertEqual(model.initialTunHelperPrompt?.statusMessage, TunnelHelperClient.statusMessage(for: .notRegistered))
    XCTAssertFalse(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)
  }

  func testSelectingTunDuringSilentStartDeferralUsesHelperPreparationPath() async throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    defaults.set(true, forKey: AppModel.silentStartDefaultsKey)
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: defaults
    )

    model.warmTunHelperRegistrationOnLaunch()
    model.requestProxyRoutingMode(.tun)

    for _ in 0..<40 where model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .tun)
    XCTAssertNil(model.initialTunHelperPrompt)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(
      model.tunHelperPreparationState,
      .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval))
    )
  }

  func testInitialHelperInstallRegistersAndShowsApprovalPrompt() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()
    model.installInitialTunHelper()

    for _ in 0..<40 where model.initialTunHelperPromptActionInFlight || model.initialTunHelperPrompt?.primaryAction != .openSettings {
      await Task.yield()
    }

    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(model.initialTunHelperPrompt?.primaryAction, .openSettings)
    XCTAssertEqual(model.initialTunHelperPrompt?.statusMessage, TunnelHelperClient.statusMessage(for: .requiresApproval))
    XCTAssertFalse(model.settings.initialTunHelperPromptHandled)
    XCTAssertNil(model.lastError)
  }

  func testDismissingInitialHelperPromptMarksHandledButTunFlowStillRegisters() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()
    model.dismissInitialTunHelperPrompt()

    XCTAssertNil(model.initialTunHelperPrompt)
    XCTAssertTrue(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)

    model.requestProxyRoutingMode(.tun)
    for _ in 0..<40 where model.proxyRoutingMode != .tun || model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(
      model.tunHelperPreparationState,
      .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval))
    )
  }

  func testLaunchWarmupSkipsInitialPromptAndMarksHandledWhenHelperEnabled() throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .enabled)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()

    XCTAssertNil(model.initialTunHelperPrompt)
    XCTAssertTrue(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)
  }

  func testLaunchWarmupSkipsInitialPromptWhenHelperIsMissing() throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .notFound)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.warmTunHelperRegistrationOnLaunch()

    XCTAssertNil(model.initialTunHelperPrompt)
    XCTAssertFalse(model.settings.initialTunHelperPromptHandled)
    XCTAssertEqual(service.registerCount, 0)
  }

  func testRepairHelperRefreshesVisibleApprovalStateWithoutReregistering() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.proxyRoutingMode = .tun

    model.repairHelperRegistration()

    for _ in 0..<40 where model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(
      model.tunHelperPreparationState,
      .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval))
    )
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertNil(model.lastError)
  }

  func testRefreshingHelperStatusReflectsApprovalStateInTunStatusRow() async throws {
    let paths = try Self.makeRuntimePaths()
    let service = StaticHelperService(status: .requiresApproval)
    let helper = TunnelHelperClient(
      transport: ReadyTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.proxyRoutingMode = .tun

    model.refreshHelperStatus()

    for _ in 0..<40 where model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(
      model.tunHelperPreparationState,
      .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval))
    )
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)
    XCTAssertNil(model.lastError)
  }

  func testRefreshingHelperStatusReflectsBootstrappingFailureInTunStatusRow() async throws {
    let paths = try Self.makeRuntimePaths()
    let helper = TunnelHelperClient(
      transport: FailingStatusTunnelHelperTransport(),
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )
    model.proxyRoutingMode = .tun

    model.refreshHelperStatus()

    for _ in 0..<40 where model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(
      model.tunHelperPreparationState,
      .notBootstrapped(TunnelHelperClient.notBootstrappedMessage)
    )
    XCTAssertEqual(model.lastError, TunnelHelperClient.notBootstrappedMessage)
  }

  func testSelectingTunStopsCheckingWhenHelperBootstrapFails() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let service = StaticHelperService(status: .enabled)
    let helper = TunnelHelperClient(
      transport: FailingStatusTunnelHelperTransport(),
      service: service,
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      helperClient: helper,
      defaults: try Self.makeIsolatedDefaults()
    )

    model.requestProxyRoutingMode(.tun)

    for _ in 0..<40 where model.tunHelperPreparationState == .idle || model.tunHelperPreparationState == .checking {
      await Task.yield()
    }

    XCTAssertEqual(model.proxyRoutingMode, .tun)
    XCTAssertEqual(
      model.tunHelperPreparationState,
      .notBootstrapped(TunnelHelperClient.notBootstrappedMessage)
    )
    XCTAssertEqual(model.readinessIssue, TunnelHelperClient.notBootstrappedMessage)
    XCTAssertEqual(model.lastError, TunnelHelperClient.notBootstrappedMessage)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
  }

  func testSelectingTunRegistersAndMarksReadyHelper() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
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

  func testHelperOperationNotPermittedExplainsApprovalAndBackgroundItemsRecovery() {
    let error = NSError(
      domain: "SMAppServiceErrorDomain",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Operation not permitted"
      ]
    )

    XCTAssertEqual(
      UserFacingError.message(for: error),
      "macOS did not permit TUN helper registration yet. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status. If this exported/notarized app is already approved and the helper still will not start, restart macOS or reset the Background Items approval state before retrying."
    )
  }

  func testNetworkExtensionAppNotInstalledErrorExplainsLaunchServicesRecovery() {
    XCTAssertEqual(
      UserFacingError.message(from: "VPN配置所使用的VPN App尚未安装"),
      "macOS has not registered /Applications/ClashMax.app for this Network Extension configuration yet. ClashMax refreshes LaunchServices before starting NE mode; retry once, and restart macOS if the stale system extension state still reports the VPN app is not installed."
    )
  }

  func testSavingActiveRuntimeSnippetPreflightsEvenWhenCoreStopped() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let rejectingCore = try Self.makeRuleOverlayPreflightCore(
      in: paths.appSupport,
      rejectedToken: "bad-preflight.example"
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { rejectingCore }
    )
    let snippet = RuntimeSnippet(
      name: "Rejected",
      enabled: true,
      binding: .allProfiles,
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "bad-preflight.example", policy: "DIRECT")
          ]
        )
      )
    )

    let didSave = await model.saveRuntimeSnippet(snippet)

    XCTAssertFalse(didSave)
    XCTAssertTrue(model.runtimeSnippetLibrary.snippets.isEmpty)
    XCTAssertTrue(model.lastError?.contains("rejected by test core") == true)
  }

  func testEffectiveRuntimeConfigPreviewUsesDraftSnippetWithoutPersistingIt() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let passingCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { passingCore }
    )
    let draftSnippet = RuntimeSnippet(
      name: "Draft",
      enabled: true,
      binding: .allProfiles,
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          appendRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "draft-only.example", policy: "DIRECT")
          ]
        )
      )
    )

    await model.refreshEffectiveRuntimeConfigPreview(draftSnippet: draftSnippet)

    guard case let .loaded(snapshot) = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    XCTAssertTrue(snapshot.redactedReportText.contains("DOMAIN-SUFFIX,draft-only.example,DIRECT"))
    XCTAssertTrue(model.runtimeSnippetLibrary.snippets.isEmpty)
  }

  func testEffectiveRuntimeConfigPreviewResetsWhenSelectingAnotherProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let firstConfigURL = paths.appSupport.appendingPathComponent("first.yaml")
    let secondConfigURL = paths.appSupport.appendingPathComponent("second.yaml")
    try Self.writeProxyConfig(named: "Japan", to: firstConfigURL)
    try Self.writeProxyConfig(named: "Singapore", to: secondConfigURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let firstProfile = try await store.importLocalConfig(from: firstConfigURL)
    let secondProfile = try await store.importLocalConfig(from: secondConfigURL)
    try await store.select(firstProfile)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { throw AppError.missingBundledCore }
    )

    await model.refreshEffectiveRuntimeConfigPreview()

    guard case let .loaded(snapshot) = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    XCTAssertEqual(snapshot.profileID, firstProfile.id)
    XCTAssertTrue(model.hasLoadedEffectiveRuntimeConfigForActiveProfile)

    let didSelect = await model.selectProfileAsync(secondProfile)

    XCTAssertTrue(didSelect)
    XCTAssertEqual(store.activeProfileID, secondProfile.id)
    XCTAssertEqual(model.effectiveRuntimeConfigState, .idle)
    XCTAssertFalse(model.hasLoadedEffectiveRuntimeConfigForActiveProfile)
  }

  func testEffectiveRuntimeConfigPreviewResetsWhenDeletingLoadedProfile() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: configURL)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { throw AppError.missingBundledCore }
    )

    await model.refreshEffectiveRuntimeConfigPreview()

    guard case let .loaded(snapshot) = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    XCTAssertEqual(snapshot.profileID, profile.id)

    let didDelete = await model.deleteProfileAsync(profile)

    XCTAssertTrue(didDelete)
    XCTAssertNil(store.activeProfileID)
    XCTAssertEqual(model.effectiveRuntimeConfigState, .unavailable("No active profile selected."))
    XCTAssertFalse(model.hasLoadedEffectiveRuntimeConfigForActiveProfile)
  }

  func testEffectiveRuntimeConfigPreviewReportsMissingCoreWithoutDroppingSnapshot() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { throw AppError.missingBundledCore }
    )

    await model.refreshEffectiveRuntimeConfigPreview()

    guard case let .loaded(snapshot) = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    guard case .failed = snapshot.preflightStatus else {
      return XCTFail("Expected missing core to be reported as a preflight failure.")
    }
    XCTAssertEqual(model.lastError, snapshot.preflightStatus.message)
    XCTAssertTrue(snapshot.redactedFinalYAML.contains("mixed-port"))
  }

  func testEffectiveRuntimeConfigPreviewResetsWhenActiveSubscriptionUpdates() async throws {
    let paths = try Self.makeRuntimePaths()
    let oldSource = """
    proxies:
      - { name: Old Node, type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [Old Node, DIRECT] }
    rules:
      - MATCH,Proxy
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(oldSource))
    )
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { preflightCore }
    )
    await model.refreshEffectiveRuntimeConfigPreview()
    guard case .loaded = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    let newSource = """
    proxies:
      - { name: New Node, type: direct }
    proxy-groups:
      - { name: Proxy, type: select, proxies: [New Node, DIRECT] }
    rules:
      - MATCH,Proxy
    """

    let didUpdate = await model.updateSubscription(
      profile,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(newSource))
    )

    XCTAssertTrue(didUpdate)
    XCTAssertEqual(model.effectiveRuntimeConfigState, .idle)
  }

  func testEffectiveRuntimeConfigPreviewResetsWhenActiveRuntimeSnippetChanges() async throws {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let preflightCore = try Self.makeRuleOverlayPreflightCore(in: paths.appSupport, rejectedToken: "never-matched")
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { preflightCore }
    )
    await model.refreshEffectiveRuntimeConfigPreview()
    guard case .loaded = model.effectiveRuntimeConfigState else {
      return XCTFail("Expected loaded effective runtime config snapshot.")
    }
    let snippet = RuntimeSnippet(
      name: "Active",
      binding: .allProfiles,
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          appendRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "snippet.example", policy: "DIRECT")
          ]
        )
      )
    )

    let didSave = await model.saveRuntimeSnippet(snippet)

    XCTAssertTrue(didSave)
    XCTAssertEqual(model.effectiveRuntimeConfigState, .idle)
  }

  func testProviderOptionPreflightIncludesActiveRuntimeSnippets() async throws {
    let paths = try Self.makeRuntimePaths()
    let providerContent = """
    trojan://password@example.com:443?sni=example.com#Node
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      url: try XCTUnwrap(URL(string: "https://example.com/sub")),
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
      preflightValidator: NoopSubscriptionProfilePreflightValidator()
    )
    let rejectingCore = try Self.makeRuleOverlayPreflightCore(
      in: paths.appSupport,
      rejectedToken: "active-snippet.example"
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { rejectingCore }
    )
    await model.runtimeSnippetLibrary.waitForLoad()
    try await model.runtimeSnippetLibrary.saveSnippet(
      RuntimeSnippet(
        name: "Active",
        enabled: true,
        binding: .allProfiles,
        payload: .rules(
          RuleOverlaySettings(
            enabled: true,
            appendRules: [
              ManagedRuleOverlayRule(kind: .domainSuffix, value: "active-snippet.example", policy: "DIRECT")
            ]
          )
        )
      )
    )

    let didUpdate = await model.updateSubscriptionProviderOptions(
      profile,
      options: SubscriptionProviderOptions(intervalSeconds: 600)
    )

    XCTAssertFalse(didUpdate)
    XCTAssertTrue(model.lastError?.contains("rejected by test core") == true)
  }

  func testProviderSideLoadPreflightRequiresDeveloperModeAndDoesNotReloadRuntime() async throws {
    let paths = try Self.makeRuntimePaths()
    let providerContent = """
    trojan://remote-password@example.com:443?sni=example.com#Remote
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      url: try XCTUnwrap(URL(string: "https://example.com/sub")),
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
      preflightValidator: NoopSubscriptionProfilePreflightValidator()
    )
    let localProviderURL = paths.appSupport.appendingPathComponent("local-provider.txt")
    try "vless://00000000-0000-0000-0000-000000000000@local.example:443?security=tls#Local\n"
      .write(to: localProviderURL, atomically: true, encoding: .utf8)
    let validator = RecordingRuntimeConfigValidator(result: .success(()))
    let client = RecordingMihomoController(proxyGroupsResponse: [], testDelayResult: 0)
    let model = AppModel(
      paths: paths,
      profileStore: store,
      apiClient: client,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      providerSideLoadPreflightRunner: MihomoProviderSideLoadPreflightRunner(runtimeConfigValidator: validator)
    )

    let blocked = await model.preflightSideLoadedProviderContent(for: profile, providerFileURL: localProviderURL)

    XCTAssertFalse(blocked)
    XCTAssertFalse(validator.didValidate)
    XCTAssertTrue(model.lastError?.contains("Developer Mode") == true)

    model.setDeveloperMode(true)
    model.overrides.tunEnabled = true
    let succeeded = await model.preflightSideLoadedProviderContent(for: profile, providerFileURL: localProviderURL)

    XCTAssertTrue(succeeded)
    XCTAssertTrue(validator.didValidate)
    XCTAssertTrue(validator.validatedConfigContent?.contains("tun:\n  enable: false") == true)
    let reloadPaths = await client.reloadRequestPaths()
    let reloadForces = await client.reloadRequestForces()
    XCTAssertEqual(reloadPaths, [])
    XCTAssertEqual(reloadForces, [])
    XCTAssertNil(model.lastError)
    guard case let .succeeded(result) = model.providerSideLoadPreflightStatus else {
      return XCTFail("Expected side-load preflight success.")
    }
    XCTAssertEqual(result.profileID, profile.id)
    XCTAssertEqual(result.fileName, "local-provider.txt")
  }

  func testProviderSideLoadPreflightRejectsNormalSubscriptionBeforeValidator() async throws {
    let paths = try Self.makeRuntimePaths()
    let configContent = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct]
    rules:
      - MATCH,Proxy
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      url: try XCTUnwrap(URL(string: "https://example.com/sub")),
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(configContent)),
      preflightValidator: NoopSubscriptionProfilePreflightValidator()
    )
    let localProviderURL = paths.appSupport.appendingPathComponent("local-provider.txt")
    try "trojan://password@local.example:443#Local\n".write(to: localProviderURL, atomically: true, encoding: .utf8)
    let validator = RecordingRuntimeConfigValidator(result: .success(()))
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      providerSideLoadPreflightRunner: MihomoProviderSideLoadPreflightRunner(runtimeConfigValidator: validator)
    )
    model.setDeveloperMode(true)

    let didPreflight = await model.preflightSideLoadedProviderContent(for: profile, providerFileURL: localProviderURL)

    let expectedMessage = String(localized: "Provider side-load preflight is only available for app-managed provider subscriptions.")
    XCTAssertFalse(didPreflight)
    XCTAssertFalse(validator.didValidate)
    XCTAssertEqual(model.lastError, expectedMessage)
    guard case let .failed(result) = model.providerSideLoadPreflightStatus else {
      return XCTFail("Expected side-load preflight failure.")
    }
    XCTAssertEqual(result.profileID, profile.id)
    XCTAssertEqual(result.message, expectedMessage)
  }

  func testProviderSideLoadPreflightFailureCleansTemporaryDirectory() async throws {
    let paths = try Self.makeRuntimePaths()
    let providerContent = """
    trojan://remote-password@example.com:443?sni=example.com#Remote
    """
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      url: try XCTUnwrap(URL(string: "https://example.com/sub")),
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
      preflightValidator: NoopSubscriptionProfilePreflightValidator()
    )
    let localProviderURL = paths.appSupport.appendingPathComponent("bad-local-provider.txt")
    try "trojan://bad-password@local.example:443#Bad\n".write(to: localProviderURL, atomically: true, encoding: .utf8)
    let validator = RecordingRuntimeConfigValidator(result: .failure(AppError.configValidationFailed("bad local provider")))
    let model = AppModel(
      paths: paths,
      profileStore: store,
      defaults: try Self.makeIsolatedDefaults(),
      bundledCoreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      providerSideLoadPreflightRunner: MihomoProviderSideLoadPreflightRunner(runtimeConfigValidator: validator)
    )
    model.setDeveloperMode(true)

    let didPreflight = await model.preflightSideLoadedProviderContent(for: profile, providerFileURL: localProviderURL)

    XCTAssertFalse(didPreflight)
    XCTAssertTrue(validator.didValidate)
    XCTAssertTrue(model.lastError?.contains("bad local provider") == true)
    let leftovers = try FileManager.default.contentsOfDirectory(at: paths.runtime, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("provider-side-load-preflight-") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  private func waitForBatchProgress(
    _ model: AppModel,
    file: StaticString = #filePath,
    line: UInt = #line,
    predicate: (ProxyDelayBatchProgress) -> Bool
  ) async throws {
    for _ in 0..<160 {
      if let progress = model.proxyDelayBatchProgress, predicate(progress) {
        return
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for proxy delay batch progress.", file: file, line: line)
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

  private static func providerContentPath(in runtimeConfigURL: URL) throws -> String {
    let runtimeConfig = try String(contentsOf: runtimeConfigURL, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: runtimeConfig) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let provider = try XCTUnwrap(providers["clashmax-subscription-provider"] as? [String: Any])
    return try XCTUnwrap(provider["path"] as? String)
  }

  private static func defaultNetworkSetupOutputs() -> [String: String] {
    [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n",
      "/usr/sbin/networksetup -getdnsservers Wi-Fi": "There aren't any DNS Servers set on Wi-Fi.\n"
    ]
  }

  private func assertRoundTrip<T: Codable & Equatable>(
    _ value: T,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    if decoded != value {
      XCTFail("Round-trip decoded value did not match.", file: file, line: line)
    }
  }

  private static func storeJSON(
    _ object: [String: Any],
    forKey key: String,
    defaults: UserDefaults
  ) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    defaults.set(data, forKey: key)
  }

  private static func writeNetworkExtensionDiagnostics(
    _ snapshot: NetworkExtensionDiagnosticsSnapshot,
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: url)
  }

  private static func tunDiagnosticsSnapshot(
    checks: [TunDiagnosticCheck],
    includeExternal: Bool,
    time: TimeInterval
  ) -> TunDiagnosticsSnapshot {
    TunDiagnosticsSnapshot(
      checks: checks,
      updatedAt: Date(timeIntervalSince1970: time),
      externalProbeIncluded: includeExternal
    )
  }

  private static func nonRoutingControllerFailureCheck() -> TunDiagnosticCheck {
    TunDiagnosticCheck(
      id: "controller",
      title: "Controller",
      status: .fail,
      message: "controller unavailable"
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

  private static func makeIsolatedDefaults() throws -> UserDefaults {
    let suiteName = "ClashMaxDashboardTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private static func makeRuleOverlayPreflightCore(in directory: URL, rejectedToken: String) throws -> URL {
    let coreURL = directory.appendingPathComponent("mihomo-preflight-\(UUID().uuidString)")
    let escapedToken = rejectedToken.replacingOccurrences(of: "'", with: "'\\''")
    try """
    #!/bin/sh
    config=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f)
          shift
          config="$1"
          ;;
      esac
      shift
    done
    if [ -n "$config" ] && grep -q '\(escapedToken)' "$config"; then
      echo "rejected by test core"
      exit 1
    fi
    exit 0
    """.write(to: coreURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)
    return coreURL
  }

  private static func clearSharedRoutingDefaults() {
    UserDefaults.standard.removeObject(forKey: proxyRoutingModeDefaultsKey)
    UserDefaults.standard.removeObject(forKey: developerModeDefaultsKey)
    UserDefaults.standard.removeObject(forKey: tunDNSDefaultsVersionKey)
  }

  private static func installFakeBundledCoreForAppModelTests() throws {
    let root = AppConstants.bundledCoreRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let architecture: String
    #if arch(x86_64)
      architecture = "amd64"
    #else
      architecture = "arm64"
    #endif
    let coreURL = root.appendingPathComponent("mihomo-darwin-\(architecture)")
    guard !FileManager.default.isExecutableFile(atPath: coreURL.path) else { return }
    try """
    #!/bin/sh
    sleep 3600
    """.write(to: coreURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)
  }

  private func makeRunningRuntimeModel(
    client: any MihomoAPIControlling,
    initialProxyGroups: [ProxyGroup] = [],
    delayStateCacheTTL: TimeInterval = 600,
    systemProxyController: SystemProxyController? = nil,
    defaults: UserDefaults? = nil
  ) async throws -> AppModel {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let resolvedDefaults: UserDefaults
    if let defaults {
      resolvedDefaults = defaults
    } else {
      resolvedDefaults = try Self.makeIsolatedDefaults()
    }
    let controller = CoreProcessController(
      launcher: FakeProcessLauncher(),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: EmptyRuntimePortChecker()
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      coreController: controller,
      systemProxyController: systemProxyController ?? SystemProxyController(
        commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
      ),
      apiClient: client,
      defaults: resolvedDefaults,
      delayStateCacheTTL: delayStateCacheTTL
    )
    model.proxyGroups = initialProxyGroups

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: configURL,
      workDirectory: paths.runtime,
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    return model
  }

  private func makeRunningTunnelModel(
    client: any MihomoAPIControlling,
    helperTransport: any HelperXPCTransport,
    tunRuntimeInspector: any TunRuntimeInspecting = RecordingTunRuntimeInspector(snapshots: []),
    systemProxyController: SystemProxyController? = nil,
    tunnelReadinessProbe: CoreReadinessProbing = RecordingCoreReadinessProbe(),
    defaults: UserDefaults? = nil
  ) async throws -> AppModel {
    let paths = try Self.makeRuntimePaths()
    let configURL = paths.appSupport.appendingPathComponent("profile.yaml")
    try Self.writeProxyConfig(named: "Japan", to: configURL)
    let store = ProfileStore(paths: paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: configURL)
    let effectiveDefaults: UserDefaults
    if let defaults {
      effectiveDefaults = defaults
    } else {
      effectiveDefaults = try Self.makeIsolatedDefaults()
    }
    let helper = TunnelHelperClient(
      transport: helperTransport,
      service: StaticHelperService(status: .enabled),
      fingerprintProvider: StaticFingerprintProvider(fingerprint: "test"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "test")
    )
    let model = AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: systemProxyController ?? SystemProxyController(
        commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs())
      ),
      helperClient: helper,
      tunnelReadinessProbe: tunnelReadinessProbe,
      tunRuntimeInspector: tunRuntimeInspector,
      apiClient: client,
      defaults: effectiveDefaults
    )
    model.proxyRoutingMode = .tun
    model.tunnelCoreRunning = true
    model.tunEnabled = true
    return model
  }

  private func recordAppliedTunnelSnapshot(
    on model: AppModel,
    tunSettings: TunSettings
  ) {
    var overrides = model.overrides
    overrides.tunEnabled = true
    overrides.tunSettings = tunSettings
    model.settings.recordAppliedRuntimeSettingsSnapshot(
      AppliedRuntimeSettingsSnapshot(
        overrides: overrides,
        proxyRoutingMode: .tun,
        systemProxySettings: model.systemProxySettings,
        networkExtensionRoutingSettings: model.networkExtensionRoutingSettings,
        runtimeOwner: .tunnel,
        appliedAt: Date()
      )
    )
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
  private let proxyGroupsResponses: [[ProxyGroup]]
  private let proxyProvidersResponse: [ProxyProvider]
  private let ruleProvidersResponse: [RuleProvider]
  private let connectionsResponse: [ConnectionSnapshot]
  private let testDelayResults: [Int]
  private let testDelayFailureMessages: [String?]
  private let modeUpdateDelayNanoseconds: UInt64
  private let proxyGroupsDelayNanoseconds: UInt64
  private let selectProxyDelaysNanoseconds: [UInt64]
  private let selectProxyFailureMessage: String?
  private let testDelayDelaysNanoseconds: [UInt64]
  private let healthCheckDelayNanoseconds: UInt64
  private let closeConnectionDelayNanoseconds: UInt64
  private let proxyProviderUpdateDelayNanoseconds: UInt64
  private let ruleProviderUpdateDelayNanoseconds: UInt64
  private let healthCheckFailureMessage: String?
  private let closeConnectionFailureMessage: String?
  private let proxyProviderUpdateFailures: [String: String]
  private let ruleProviderUpdateFailures: [String: String]
  private let reloadFailureMessage: String?
  private let reloadFailureMessages: [String?]
  private let restartFailureMessage: String?
  private let setTunEnabledFailureMessage: String?
  private let ignoreHealthCheckCancellation: Bool
  private let ignoreCloseConnectionCancellation: Bool
  private var modeUpdates: [RunMode] = []
  private var proxySelections: [String] = []
  private var proxySelectionAttempts = 0
  private var proxyGroupsRequests = 0
  private var delayRequests: [String] = []
  private var delayRequestURLValues: [URL] = []
  private var healthCheckRequests: [String] = []
  private var proxyProviderUpdateRequests: [String] = []
  private var ruleProviderUpdateRequests: [String] = []
  private var closedConnections: [String] = []
  private var closedAllRequestCount = 0
  private var reloadRequests: [(path: String, force: Bool)] = []
  private var restartRequests: [String?] = []
  private var tunEnabledUpdates: [Bool] = []
  private var ipv6Updates: [Bool] = []

  init(
    proxyGroupsResponse: [ProxyGroup],
    proxyProvidersResponse: [ProxyProvider] = [],
    ruleProvidersResponse: [RuleProvider] = [],
    connectionsResponse: [ConnectionSnapshot] = [],
    testDelayResult: Int,
    modeUpdateDelayNanoseconds: UInt64 = 0,
    proxyGroupsDelayNanoseconds: UInt64 = 0,
    selectProxyDelaysNanoseconds: [UInt64] = [],
    selectProxyFailureMessage: String? = nil,
    testDelayDelaysNanoseconds: [UInt64] = [],
    healthCheckDelayNanoseconds: UInt64 = 0,
    closeConnectionDelayNanoseconds: UInt64 = 0,
    proxyProviderUpdateDelayNanoseconds: UInt64 = 0,
    ruleProviderUpdateDelayNanoseconds: UInt64 = 0,
    healthCheckFailureMessage: String? = nil,
    closeConnectionFailureMessage: String? = nil,
    proxyProviderUpdateFailures: [String: String] = [:],
    ruleProviderUpdateFailures: [String: String] = [:],
    reloadFailureMessage: String? = nil,
    reloadFailureMessages: [String?] = [],
    restartFailureMessage: String? = nil,
    setTunEnabledFailureMessage: String? = nil,
    ignoreHealthCheckCancellation: Bool = false,
    ignoreCloseConnectionCancellation: Bool = false
  ) {
    self.init(
      proxyGroupsResponses: [proxyGroupsResponse],
      proxyProvidersResponse: proxyProvidersResponse,
      ruleProvidersResponse: ruleProvidersResponse,
      connectionsResponse: connectionsResponse,
      testDelayResults: [testDelayResult],
      modeUpdateDelayNanoseconds: modeUpdateDelayNanoseconds,
      proxyGroupsDelayNanoseconds: proxyGroupsDelayNanoseconds,
      selectProxyDelaysNanoseconds: selectProxyDelaysNanoseconds,
      selectProxyFailureMessage: selectProxyFailureMessage,
      testDelayDelaysNanoseconds: testDelayDelaysNanoseconds,
      healthCheckDelayNanoseconds: healthCheckDelayNanoseconds,
      closeConnectionDelayNanoseconds: closeConnectionDelayNanoseconds,
      proxyProviderUpdateDelayNanoseconds: proxyProviderUpdateDelayNanoseconds,
      ruleProviderUpdateDelayNanoseconds: ruleProviderUpdateDelayNanoseconds,
      healthCheckFailureMessage: healthCheckFailureMessage,
      closeConnectionFailureMessage: closeConnectionFailureMessage,
      proxyProviderUpdateFailures: proxyProviderUpdateFailures,
      ruleProviderUpdateFailures: ruleProviderUpdateFailures,
      reloadFailureMessage: reloadFailureMessage,
      reloadFailureMessages: reloadFailureMessages,
      restartFailureMessage: restartFailureMessage,
      setTunEnabledFailureMessage: setTunEnabledFailureMessage,
      ignoreHealthCheckCancellation: ignoreHealthCheckCancellation,
      ignoreCloseConnectionCancellation: ignoreCloseConnectionCancellation
    )
  }

  init(
    proxyGroupsResponse: [ProxyGroup],
    proxyProvidersResponse: [ProxyProvider] = [],
    ruleProvidersResponse: [RuleProvider] = [],
    connectionsResponse: [ConnectionSnapshot] = [],
    testDelayResults: [Int],
    modeUpdateDelayNanoseconds: UInt64 = 0,
    proxyGroupsDelayNanoseconds: UInt64 = 0,
    selectProxyDelaysNanoseconds: [UInt64] = [],
    selectProxyFailureMessage: String? = nil,
    testDelayDelaysNanoseconds: [UInt64] = [],
    healthCheckDelayNanoseconds: UInt64 = 0,
    closeConnectionDelayNanoseconds: UInt64 = 0,
    proxyProviderUpdateDelayNanoseconds: UInt64 = 0,
    ruleProviderUpdateDelayNanoseconds: UInt64 = 0,
    healthCheckFailureMessage: String? = nil,
    closeConnectionFailureMessage: String? = nil,
    proxyProviderUpdateFailures: [String: String] = [:],
    ruleProviderUpdateFailures: [String: String] = [:],
    reloadFailureMessage: String? = nil,
    reloadFailureMessages: [String?] = [],
    restartFailureMessage: String? = nil,
    setTunEnabledFailureMessage: String? = nil,
    ignoreHealthCheckCancellation: Bool = false,
    ignoreCloseConnectionCancellation: Bool = false
  ) {
    self.init(
      proxyGroupsResponses: [proxyGroupsResponse],
      proxyProvidersResponse: proxyProvidersResponse,
      ruleProvidersResponse: ruleProvidersResponse,
      connectionsResponse: connectionsResponse,
      testDelayResults: testDelayResults,
      modeUpdateDelayNanoseconds: modeUpdateDelayNanoseconds,
      proxyGroupsDelayNanoseconds: proxyGroupsDelayNanoseconds,
      selectProxyDelaysNanoseconds: selectProxyDelaysNanoseconds,
      selectProxyFailureMessage: selectProxyFailureMessage,
      testDelayDelaysNanoseconds: testDelayDelaysNanoseconds,
      healthCheckDelayNanoseconds: healthCheckDelayNanoseconds,
      closeConnectionDelayNanoseconds: closeConnectionDelayNanoseconds,
      proxyProviderUpdateDelayNanoseconds: proxyProviderUpdateDelayNanoseconds,
      ruleProviderUpdateDelayNanoseconds: ruleProviderUpdateDelayNanoseconds,
      healthCheckFailureMessage: healthCheckFailureMessage,
      closeConnectionFailureMessage: closeConnectionFailureMessage,
      proxyProviderUpdateFailures: proxyProviderUpdateFailures,
      ruleProviderUpdateFailures: ruleProviderUpdateFailures,
      reloadFailureMessage: reloadFailureMessage,
      reloadFailureMessages: reloadFailureMessages,
      restartFailureMessage: restartFailureMessage,
      setTunEnabledFailureMessage: setTunEnabledFailureMessage,
      ignoreHealthCheckCancellation: ignoreHealthCheckCancellation,
      ignoreCloseConnectionCancellation: ignoreCloseConnectionCancellation
    )
  }

  init(
    proxyGroupsResponses: [[ProxyGroup]],
    proxyProvidersResponse: [ProxyProvider] = [],
    ruleProvidersResponse: [RuleProvider] = [],
    connectionsResponse: [ConnectionSnapshot] = [],
    testDelayResults: [Int],
    testDelayFailureMessages: [String?] = [],
    modeUpdateDelayNanoseconds: UInt64 = 0,
    proxyGroupsDelayNanoseconds: UInt64 = 0,
    selectProxyDelaysNanoseconds: [UInt64] = [],
    selectProxyFailureMessage: String? = nil,
    testDelayDelaysNanoseconds: [UInt64] = [],
    healthCheckDelayNanoseconds: UInt64 = 0,
    closeConnectionDelayNanoseconds: UInt64 = 0,
    proxyProviderUpdateDelayNanoseconds: UInt64 = 0,
    ruleProviderUpdateDelayNanoseconds: UInt64 = 0,
    healthCheckFailureMessage: String? = nil,
    closeConnectionFailureMessage: String? = nil,
    proxyProviderUpdateFailures: [String: String] = [:],
    ruleProviderUpdateFailures: [String: String] = [:],
    reloadFailureMessage: String? = nil,
    reloadFailureMessages: [String?] = [],
    restartFailureMessage: String? = nil,
    setTunEnabledFailureMessage: String? = nil,
    ignoreHealthCheckCancellation: Bool = false,
    ignoreCloseConnectionCancellation: Bool = false
  ) {
    self.proxyGroupsResponses = proxyGroupsResponses
    self.proxyProvidersResponse = proxyProvidersResponse
    self.ruleProvidersResponse = ruleProvidersResponse
    self.connectionsResponse = connectionsResponse
    self.testDelayResults = testDelayResults
    self.testDelayFailureMessages = testDelayFailureMessages
    self.modeUpdateDelayNanoseconds = modeUpdateDelayNanoseconds
    self.proxyGroupsDelayNanoseconds = proxyGroupsDelayNanoseconds
    self.selectProxyDelaysNanoseconds = selectProxyDelaysNanoseconds
    self.selectProxyFailureMessage = selectProxyFailureMessage
    self.testDelayDelaysNanoseconds = testDelayDelaysNanoseconds
    self.healthCheckDelayNanoseconds = healthCheckDelayNanoseconds
    self.closeConnectionDelayNanoseconds = closeConnectionDelayNanoseconds
    self.proxyProviderUpdateDelayNanoseconds = proxyProviderUpdateDelayNanoseconds
    self.ruleProviderUpdateDelayNanoseconds = ruleProviderUpdateDelayNanoseconds
    self.healthCheckFailureMessage = healthCheckFailureMessage
    self.closeConnectionFailureMessage = closeConnectionFailureMessage
    self.proxyProviderUpdateFailures = proxyProviderUpdateFailures
    self.ruleProviderUpdateFailures = ruleProviderUpdateFailures
    self.reloadFailureMessage = reloadFailureMessage
    self.reloadFailureMessages = reloadFailureMessages
    self.restartFailureMessage = restartFailureMessage
    self.setTunEnabledFailureMessage = setTunEnabledFailureMessage
    self.ignoreHealthCheckCancellation = ignoreHealthCheckCancellation
    self.ignoreCloseConnectionCancellation = ignoreCloseConnectionCancellation
  }

  func updateMode(_ mode: RunMode) async throws {
    try await sleepIfNeeded(modeUpdateDelayNanoseconds)
    modeUpdates.append(mode)
  }

  func updateIPv6(_ enabled: Bool) async throws {
    ipv6Updates.append(enabled)
  }

  func proxyGroups() async throws -> [ProxyGroup] {
    let index = proxyGroupsRequests
    proxyGroupsRequests += 1
    try await sleepIfNeeded(proxyGroupsDelayNanoseconds)
    let responseIndex = min(index, max(proxyGroupsResponses.count - 1, 0))
    return proxyGroupsResponses[responseIndex]
  }

  func structuredProxyProviders() async throws -> [ProxyProvider] {
    proxyProvidersResponse
  }

  func ruleProviders() async throws -> [RuleProvider] {
    ruleProvidersResponse
  }

  func rules() async throws -> [RuntimeRule] {
    []
  }

  func connections() async throws -> [ConnectionSnapshot] {
    connectionsResponse
  }

  func selectProxy(group: String, proxy: String) async throws {
    let index = proxySelectionAttempts
    proxySelectionAttempts += 1
    try await sleepIfNeeded(delay(at: index, in: selectProxyDelaysNanoseconds))
    if let selectProxyFailureMessage {
      throw AppError.helperResponse(selectProxyFailureMessage)
    }
    proxySelections.append("\(group):\(proxy)")
  }

  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int {
    let index = delayRequests.count
    delayRequests.append(proxy)
    delayRequestURLValues.append(testURL)
    try await sleepIfNeeded(delay(at: index, in: testDelayDelaysNanoseconds))
    if let failureMessage = failureMessage(at: index, in: testDelayFailureMessages) {
      throw AppError.helperResponse(failureMessage)
    }
    let resultIndex = min(index, max(testDelayResults.count - 1, 0))
    return testDelayResults[resultIndex]
  }

  func healthCheckProvider(named provider: String) async throws {
    healthCheckRequests.append(provider)
    try await sleepIfNeeded(healthCheckDelayNanoseconds, ignoringCancellation: ignoreHealthCheckCancellation)
    if let healthCheckFailureMessage {
      throw AppError.helperResponse(healthCheckFailureMessage)
    }
  }

  func updateProxyProvider(named provider: String) async throws {
    try await sleepIfNeeded(proxyProviderUpdateDelayNanoseconds)
    proxyProviderUpdateRequests.append(provider)
    if let failure = proxyProviderUpdateFailures[provider] {
      throw AppError.helperResponse(failure)
    }
  }

  func updateRuleProvider(named provider: String) async throws {
    try await sleepIfNeeded(ruleProviderUpdateDelayNanoseconds)
    ruleProviderUpdateRequests.append(provider)
    if let failure = ruleProviderUpdateFailures[provider] {
      throw AppError.helperResponse(failure)
    }
  }

  func closeConnection(id: String) async throws {
    closedConnections.append(id)
    try await sleepIfNeeded(closeConnectionDelayNanoseconds, ignoringCancellation: ignoreCloseConnectionCancellation)
    if let closeConnectionFailureMessage {
      throw AppError.helperResponse(closeConnectionFailureMessage)
    }
  }

  func closeAllConnections() async throws {
    closedAllRequestCount += 1
  }

  func setTunEnabled(_ enabled: Bool) async throws {
    if let setTunEnabledFailureMessage {
      throw AppError.helperResponse(setTunEnabledFailureMessage)
    }
    tunEnabledUpdates.append(enabled)
  }

  func reloadConfig(path: String, force: Bool) async throws {
    let reloadIndex = reloadRequests.count
    reloadRequests.append((path, force))
    if reloadIndex < reloadFailureMessages.count, let failureMessage = reloadFailureMessages[reloadIndex] {
      throw AppError.helperResponse(failureMessage)
    }
    if let reloadFailureMessage {
      throw AppError.helperResponse(reloadFailureMessage)
    }
  }

  func restart(configPath: String?) async throws {
    if let restartFailureMessage {
      throw AppError.helperResponse(restartFailureMessage)
    }
    restartRequests.append(configPath)
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

  func delayRequestURLs() -> [URL] {
    delayRequestURLValues
  }

  func delayRequestProxies() -> [String] {
    delayRequests
  }

  func updatedModes() -> [RunMode] {
    modeUpdates
  }

  func selectedProxyRequestCount() -> Int {
    proxySelections.count
  }

  func selectedProxyRequests() -> [String] {
    proxySelections
  }

  func proxyGroupsRequestCount() -> Int {
    proxyGroupsRequests
  }

  func healthCheckRequestCount() -> Int {
    healthCheckRequests.count
  }

  func healthCheckProviders() -> [String] {
    healthCheckRequests
  }

  func updatedProxyProviders() -> [String] {
    proxyProviderUpdateRequests
  }

  func updatedRuleProviders() -> [String] {
    ruleProviderUpdateRequests
  }

  func closedConnectionIDs() -> [String] {
    closedConnections
  }

  func closeAllRequestCount() -> Int {
    closedAllRequestCount
  }

  func reloadRequestPaths() -> [String] {
    reloadRequests.map(\.path)
  }

  func reloadRequestForces() -> [Bool] {
    reloadRequests.map(\.force)
  }

  func restartRequestCount() -> Int {
    restartRequests.count
  }

  func tunEnabledUpdateValues() -> [Bool] {
    tunEnabledUpdates
  }

  func ipv6UpdateValues() -> [Bool] {
    ipv6Updates
  }

  private func delay(at index: Int, in delays: [UInt64]) -> UInt64 {
    guard !delays.isEmpty else { return 0 }
    return delays[min(index, delays.count - 1)]
  }

  private func failureMessage(at index: Int, in failures: [String?]) -> String? {
    guard !failures.isEmpty else { return nil }
    return failures[min(index, failures.count - 1)]
  }

  private func sleepIfNeeded(_ nanoseconds: UInt64, ignoringCancellation: Bool = false) async throws {
    guard nanoseconds > 0 else { return }
    do {
      try await Task.sleep(nanoseconds: nanoseconds)
    } catch {
      if ignoringCancellation, error is CancellationError {
        return
      }
      throw error
    }
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

@MainActor
private final class RecordingProxyPortReadinessProbe: ProxyPortReadinessProbing {
  private(set) var requests: [ProxyPortReadinessRequest] = []
  var result: Result<Void, Error>
  var onProbe: (() -> Void)?

  init(result: Result<Void, Error> = .success(())) {
    self.result = result
  }

  func waitUntilReady(host: String, port: Int) async throws {
    requests.append(ProxyPortReadinessRequest(host: host, port: port))
    onProbe?()
    try result.get()
  }

  func waitUntilOpen(host: String, port: Int, serviceName: String) async throws {
    requests.append(ProxyPortReadinessRequest(host: host, port: port, serviceName: serviceName))
    onProbe?()
    try result.get()
  }
}

private actor ReadyTunnelHelperTransport: HelperXPCTransport {
  private var starts = 0
  private var stops = 0
  private var restarts = 0

  func status() async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: starts > stops, pid: starts > stops ? 99 : 0))
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
    restarts += 1
    _ = try await stopTunnel()
    return try await startTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func recentLogs() async throws -> [String] {
    []
  }

  func startCount() -> Int { starts }
  func stopCount() -> Int { stops }
  func restartCount() -> Int { restarts }
}

private actor FailingRestartTunnelHelperTransport: HelperXPCTransport {
  private var restarts = 0
  private var stops = 0

  func status() async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: true, pid: 99))
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: true, pid: 99))
  }

  func stopTunnel() async throws -> HelperClientResponse {
    stops += 1
    return HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: false))
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    restarts += 1
    throw AppError.helperResponse("restart refused")
  }

  func recentLogs() async throws -> [String] {
    []
  }

  func restartCount() -> Int { restarts }
  func stopCount() -> Int { stops }
}

private actor StoppedStatusAfterStartTunnelHelperTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: false))
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: true, pid: 99))
  }

  func stopTunnel() async throws -> HelperClientResponse {
    HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: false))
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await startTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func recentLogs() async throws -> [String] {
    []
  }
}

private actor FailingStatusTunnelHelperTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    throw AppError.helperResponse("lookup failed")
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    .failure("unused")
  }

  func stopTunnel() async throws -> HelperClientResponse {
    .failure("unused")
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    .failure("unused")
  }

  func recentLogs() async throws -> [String] {
    []
  }
}

private actor RecordingTunRuntimeInspector: TunRuntimeInspecting {
  private var snapshots: [TunDiagnosticsSnapshot]
  private var fallbackSnapshot: TunDiagnosticsSnapshot = .empty
  private var requests: [TunRuntimeInspectionConfiguration] = []

  init(snapshots: [TunDiagnosticsSnapshot]) {
    self.snapshots = snapshots
  }

  func inspect(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticsSnapshot {
    requests.append(configuration)
    guard !snapshots.isEmpty else {
      return fallbackSnapshot
    }
    let snapshot = snapshots.removeFirst()
    fallbackSnapshot = snapshot
    return snapshot
  }

  func configurations() -> [TunRuntimeInspectionConfiguration] {
    requests
  }
}

@MainActor
private final class RecordingAppGlobalShortcutRegistrar: GlobalShortcutRegistering {
  let failuresToReturn: [GlobalShortcutRegistrationFailure]
  private(set) var registrations: [GlobalShortcutRegistration] = []
  private(set) var unregisterCount = 0

  init(failuresToReturn: [GlobalShortcutRegistrationFailure] = []) {
    self.failuresToReturn = failuresToReturn
  }

  func register(
    _ registrations: [GlobalShortcutRegistration],
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure] {
    self.registrations = registrations
    return failuresToReturn
  }

  func unregisterAll() {
    unregisterCount += 1
    registrations = []
  }
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

private final class FailingDNSApplyCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.FailingDNSApplyCommandRunner")
  private var _commands: [String] = []

  init(outputs: [String: String]) {
    self.outputs = outputs
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
    }
    if command == "/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114" {
      throw NSError(
        domain: "ClashMaxTests.FailingDNSApplyCommandRunner",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Injected DNS failure for \(command)"]
      )
    }
    return outputs[command] ?? ""
  }
}

private final class DNSRestoreEventCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let events: StopEventRecorder
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.DNSRestoreEventCommandRunner")
  private var _commands: [String] = []

  init(outputs: [String: String], events: StopEventRecorder) {
    self.outputs = outputs
    self.events = events
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
    }
    if command == "/usr/sbin/networksetup -setdnsservers Wi-Fi Empty" {
      await MainActor.run {
        events.append("dnsRestore")
      }
    }
    return outputs[command] ?? ""
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

@MainActor
private final class StopEventRecorder {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

@MainActor
private final class OrderedProcessLauncher: CoreProcessLaunching {
  private let events: StopEventRecorder

  init(events: StopEventRecorder) {
    self.events = events
  }

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    OrderedRunningProcess(events: events)
  }
}

@MainActor
private final class OrderedRunningProcess: RunningCoreProcess {
  let processIdentifier: Int32 = 4242
  var onTermination: ((Int32) -> Void)?
  private(set) var isRunning = true
  private let events: StopEventRecorder

  init(events: StopEventRecorder) {
    self.events = events
  }

  func terminate() {
    events.append("coreStop")
    isRunning = false
    onTermination?(0)
  }

  func kill() {
    isRunning = false
  }

  func recentOutputTail(maxBytes: Int) -> String {
    ""
  }
}

@MainActor
private final class UnstoppableProcessLauncher: CoreProcessLaunching {
  private let events: StopEventRecorder
  let process: UnstoppableRunningProcess

  init(events: StopEventRecorder) {
    self.events = events
    process = UnstoppableRunningProcess(events: events)
  }

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    process
  }
}

@MainActor
private final class UnstoppableRunningProcess: RunningCoreProcess {
  let processIdentifier: Int32 = 4343
  var onTermination: ((Int32) -> Void)?
  let isRunning = true
  private let events: StopEventRecorder

  init(events: StopEventRecorder) {
    self.events = events
  }

  func terminate() {
    events.append("coreStop")
  }

  func kill() {
    events.append("coreKill")
  }

  func recentOutputTail(maxBytes: Int) -> String {
    ""
  }
}

private final class ManualNetworkEnvironmentMonitor: NetworkEnvironmentMonitoring, @unchecked Sendable {
  private let stream: AsyncStream<NetworkEnvironmentEvent>
  private let continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation

  init() {
    var continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation!
    stream = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  var events: AsyncStream<NetworkEnvironmentEvent> {
    stream
  }

  func start() {}

  func stop() {
    continuation.finish()
  }

  func emit(_ event: NetworkEnvironmentEvent) {
    continuation.yield(event)
  }
}

private struct StaticCurrentNetworkProvider: CurrentNetworkProviding {
  let ssid: String?

  func currentSSID() -> String? {
    ssid
  }
}

private final class MutableCurrentNetworkProvider: CurrentNetworkProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  var ssid: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }

  init(ssid: String?) {
    value = ssid
  }

  func currentSSID() -> String? {
    ssid
  }
}
