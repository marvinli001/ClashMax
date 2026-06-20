import Foundation
import Combine
import XCTest
@testable import ClashMax

@MainActor
final class ProfileStoreTests: XCTestCase {
  func testImportRenameDeleteAndPersistActiveProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())

    let profile = try await store.importLocalConfig(from: fixture.configURL)
    try await store.rename(profile, to: "Work")

    let renamed = try XCTUnwrap(store.profiles.first)
    XCTAssertEqual(renamed.name, "Work")
    XCTAssertEqual(store.activeProfileID, profile.id)

    let reloaded = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.name, "Work")
    XCTAssertEqual(reloaded.activeProfileID, profile.id)

    try await store.delete(renamed)
    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.originalConfigPath))
  }

  func testConcurrentRenameAndDeleteDoNotRestoreDeletedProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let profile = try await store.importLocalConfig(from: fixture.configURL)

    let renameTask = Task { @MainActor in
      try await store.rename(profile, to: "Work")
    }
    let deleteTask = Task { @MainActor in
      try await store.delete(profile)
    }

    try await renameTask.value
    try await deleteTask.value

    XCTAssertFalse(store.profiles.contains { $0.id == profile.id })
    XCTAssertNil(store.activeProfileID)

    let reloaded = ProfileStore(paths: fixture.paths, keychain: secrets)
    await reloaded.waitForManifestLoad()
    XCTAssertFalse(reloaded.profiles.contains { $0.id == profile.id })
    XCTAssertNil(reloaded.activeProfileID)
  }

  func testDeleteUsesStoredProfileSnapshotInsteadOfStaleArgumentPath() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: fixture.configURL)
    let unrelatedURL = fixture.root.appendingPathComponent("unrelated.yaml")
    try "proxies:\n  - name: unrelated\n    type: direct\n"
      .write(to: unrelatedURL, atomically: true, encoding: .utf8)
    var staleProfile = profile
    staleProfile.originalConfigPath = unrelatedURL.path

    try await store.delete(staleProfile)

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: profile.originalConfigPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
  }

  func testDeletingUnknownProfileDoesNotRewriteManifestOrRemoveFiles() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: fixture.configURL)
    let unknown = Profile(
      name: "Unknown",
      source: .localFile(originalPath: nil),
      originalConfigPath: profile.originalConfigPath
    )

    try await store.delete(unknown)

    XCTAssertEqual(store.profiles.map(\.id), [profile.id])
    XCTAssertEqual(store.activeProfileID, profile.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: profile.originalConfigPath))
  }

  func testSelectingAlreadyActiveProfileDoesNotPublishChanges() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try await store.importLocalConfig(from: fixture.configURL)
    var changeCount = 0
    let cancellable = store.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    try await store.select(profile)

    XCTAssertEqual(changeCount, 0)
  }

  func testProfileDecodesDefaultSubscriptionProviderOptionsFromOldManifest() throws {
    let id = UUID()
    let data = Data("""
    {
      "id": "\(id.uuidString)",
      "name": "Remote",
      "nameIsUserCustomized": true,
      "source": {
        "kind": "subscription",
        "subscriptionID": "\(id.uuidString)"
      },
      "originalConfigPath": "/tmp/profile.yaml",
      "createdAt": 0,
      "updatedAt": 0
    }
    """.utf8)

    let profile = try JSONDecoder().decode(Profile.self, from: data)

    XCTAssertEqual(profile.subscriptionProviderOptions, .default)
    XCTAssertEqual(profile.subscriptionUpdatePolicy, .default)
    XCTAssertEqual(profile.subscriptionUpdateStatus, .empty)
    XCTAssertEqual(profile.subscriptionDiagnostics, .empty)
  }

  func testSubscriptionURLIsStoredOutsideManifestAndUpdateRefreshesConfig() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let recorder = URLProtocolRecorder(
      responseBody: "mixed-port: 9000\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: [
        "subscription-userinfo": "upload=1; download=2; total=3; expire=1893456000",
        "profile-update-interval": "6",
        "profile-web-page-url": "https://example.com/dashboard"
      ]
    )
    let session = URLSession(configuration: recorder.configuration)

    let profile = try await store.addSubscription(
      name: "",
      url: URL(string: "https://example.com/sub.yaml")!,
      session: session
    )

    XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "clash.meta")
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/sub.yaml")
    XCTAssertEqual(profile.subscriptionMetadata?.traffic?.download, 2)
    XCTAssertEqual(profile.subscriptionMetadata?.updateIntervalMinutes, 360)
    XCTAssertEqual(profile.subscriptionMetadata?.webPageURL, URL(string: "https://example.com/dashboard"))
    XCTAssertEqual(profile.subscriptionDiagnostics.latestFetch?.sanitizedURL, "https://example.com/sub.yaml")
    XCTAssertEqual(profile.subscriptionDiagnostics.latestFetch?.userAgent, "clash.meta")
    XCTAssertEqual(profile.subscriptionDiagnostics.latestFetch?.subscriptionUserInfo, "upload=1; download=2; total=3; expire=1893456000")
    XCTAssertEqual(profile.subscriptionDiagnostics.latestFetch?.rawProfileUpdateInterval, "6")
    XCTAssertEqual(profile.subscriptionDiagnostics.latestFetch?.parsedProfileUpdateIntervalMinutes, 360)
    XCTAssertEqual(profile.subscriptionDiagnostics.latestPreflight?.result, .succeeded)
    XCTAssertEqual(profile.subscriptionDiagnostics.latestPreflight?.messageKind, .mihomoAccepted)
    XCTAssertEqual(profile.subscriptionDiagnostics.updateHistory.first?.trigger, .importProfile)
    XCTAssertEqual(profile.subscriptionDiagnostics.updateHistory.first?.result, .succeeded)
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertFalse(manifest.contains("https://example.com/sub.yaml"))

    let updateRecorder = URLProtocolRecorder(
      responseBody: "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["subscription-userinfo": "upload=4; download=5; total=6"]
    )
    let updateSession = URLSession(configuration: updateRecorder.configuration)
    try await store.updateSubscription(profile, session: updateSession)
    try await store.markSubscriptionUpdateSucceeded(
      profileID: profile.id,
      trigger: .manual,
      at: Date(timeIntervalSince1970: 100),
      nextUpdateAt: nil
    )
    XCTAssertEqual(updateRecorder.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "clash.meta")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n")
    XCTAssertEqual(store.profiles.first?.subscriptionMetadata?.traffic?.download, 5)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.latestFetch?.subscriptionUserInfo, "upload=4; download=5; total=6")
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.trigger, .manual)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.result, .succeeded)
  }

  func testSubscriptionDeepLinksNormalizeFetchURLAndUseNameFallback() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let cases = [
      (
        "clash://install-config?url=https%3A%2F%2Fexample.com%2Fapi%2Fv1%2Fclient%2Fsubscribe%3Ftoken%3Dabc&name=Airport%20One",
        "https://example.com/api/v1/client/subscribe?token=abc",
        "Airport One"
      ),
      (
        "clash-verge://install-config?url=https%3A%2F%2Fverge.example%2Fsub%3Ftoken%3Ddef&name=Verge%20Airport",
        "https://verge.example/sub?token=def",
        "Verge Airport"
      )
    ]

    for testCase in cases {
      let recorder = URLProtocolRecorder(
        responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n"
      )
      let profile = try await store.addSubscription(
        url: URL(string: testCase.0)!,
        session: URLSession(configuration: recorder.configuration)
      )

      XCTAssertEqual(recorder.lastRequest?.url?.absoluteString, testCase.1)
      XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), testCase.1)
      XCTAssertEqual(profile.name, testCase.2)
      XCTAssertFalse(profile.nameIsUserCustomized)
    }
  }

  func testSubscriptionDirtyURLRepairsMissingQueryMarkerBeforeFetchAndStorage() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let recorder = URLProtocolRecorder(responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n")

    let profile = try await store.addSubscription(
      url: URL(string: "https://example.com/subscriptions/%E6%B5%8B%E8%AF%95.yaml&token=abc")!,
      session: URLSession(configuration: recorder.configuration)
    )

    XCTAssertEqual(
      recorder.lastRequest?.url?.absoluteString,
      "https://example.com/subscriptions/%E6%B5%8B%E8%AF%95.yaml?token=abc"
    )
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString)"),
      "https://example.com/subscriptions/%E6%B5%8B%E8%AF%95.yaml?token=abc"
    )
    XCTAssertEqual(profile.name, "测试")
  }

  func testSubscriptionNameUsesRemoteNameThenYamlThenPathThenHostFallback() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let remoteSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxy-groups:\n  - name: YAML Group\n    type: select\n    proxies: [DIRECT]\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename*=UTF-8''Elite.yaml"]
    ).configuration)

    let remoteProfile = try await store.addSubscription(
      url: URL(string: "https://example.com/sub")!,
      session: remoteSession
    )

    XCTAssertEqual(remoteProfile.name, "Elite")
    XCTAssertFalse(remoteProfile.nameIsUserCustomized)

    let yamlSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxy-groups:\n  - name: YAML Group\n    type: select\n    proxies: [DIRECT]\nproxies:\n  - name: DIRECT\n    type: direct\n"))
    let yamlProfile = try await store.addSubscription(
      url: URL(string: "https://yaml.example/sub")!,
      session: yamlSession
    )

    XCTAssertEqual(yamlProfile.name, "YAML Group")

    let pathSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let pathProfile = try await store.addSubscription(
      url: URL(string: "https://path.example/subscriptions/%E6%B5%8B%E8%AF%95.yaml?token=abc")!,
      session: pathSession
    )

    XCTAssertEqual(pathProfile.name, "测试")

    let hostSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let hostProfile = try await store.addSubscription(
      url: URL(string: "https://host.example")!,
      session: hostSession
    )

    XCTAssertEqual(hostProfile.name, "host.example")
  }

  func testSubscriptionUpdateDoesNotOverwriteCustomizedName() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let initialSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=Remote.yaml"]
    ).configuration)
    let profile = try await store.addSubscription(
      url: URL(string: "https://example.com/sub.yaml")!,
      session: initialSession
    )

    try await store.rename(profile, to: "Custom")

    let updateSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=Updated.yaml"]
    ).configuration)
    try await store.updateSubscription(profile, session: updateSession)

    XCTAssertEqual(store.profiles.first?.name, "Custom")
    XCTAssertEqual(store.profiles.first?.subscriptionMetadata?.remoteFileName, "Updated.yaml")
  }

  func testEditingSubscriptionSourceValidatesBeforeMutatingStoredURLAndConfig() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      url: URL(string: "https://example.com/old")!,
      session: initialSession
    )
    let originalConfig = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)

    let invalidSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("rules: []\n"))
    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionSource(
        profile,
        url: URL(string: "https://example.com/bad")!,
        session: invalidSession
      )
    }

    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/old")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), originalConfig)

    let validSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=New.yaml"]
    ).configuration)
    try await store.updateSubscriptionSource(
      profile,
      url: URL(string: "https://example.com/new")!,
      session: validSession
    )

    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/new")
    XCTAssertEqual(store.profiles.first?.name, "New")
  }

  func testEditingSubscriptionSourceRestoresConfigWhenURLStorageFails() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/old")!,
      session: initialSession
    )
    let originalConfig = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    secrets.rejectSaving("https://example.com/new")

    let validSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: New\n    type: direct\n"))
    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionSource(
        profile,
        url: URL(string: "https://example.com/new")!,
        session: validSession
      )
    }

    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/old")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), originalConfig)
    XCTAssertEqual(store.profiles.first?.name, "Remote")
  }

  func testSubscriptionProviderOptionsPersistWithoutChangingStoredURL() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: session
    )
    let header = SubscriptionRequestHeader(name: "X-Token", value: "secret")
    let runtimeMergeYAML = """
    proxies:
      - name: Secret Runtime Node
        type: trojan
        server: secret.example
        password: hidden-password
    """
    let options = SubscriptionProviderOptions(
      intervalSeconds: 900,
      filter: "HK",
      runtimeMergeYAML: runtimeMergeYAML,
      requestHeaders: [header],
      fetchProxy: .systemProxy,
      ruleOverlay: RuleOverlaySettings(
        enabled: true,
        prependRules: [
          ManagedRuleOverlayRule(kind: .domainSuffix, value: "corp.example", policy: "DIRECT")
        ],
        disabledRuleMatchers: [
          ManagedRuleDisableMatcher(mode: .contains, pattern: "ads.example")
        ]
      )
    )

    try await store.updateSubscriptionProviderOptions(profile, options: options)

    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, options)
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/sub")
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).header.\(header.id.uuidString)"),
      "secret"
    )
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).runtimeMergeYAML"),
      runtimeMergeYAML
    )
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertTrue(manifest.contains(header.id.uuidString))
    XCTAssertTrue(manifest.contains("X-Token"))
    XCTAssertTrue(manifest.contains("runtimeMergeYAMLEnabled"))
    XCTAssertFalse(manifest.contains("secret"))
    XCTAssertFalse(manifest.contains("hidden-password"))
    XCTAssertFalse(manifest.contains("Secret Runtime Node"))
    let reloaded = ProfileStore(paths: fixture.paths, keychain: secrets)
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.subscriptionProviderOptions, options)
  }

  func testAddSubscriptionPersistsProviderOptionsAndUpdatePolicy() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let header = SubscriptionRequestHeader(name: "User-Agent", value: "Clash Verge/2.0.0")
    let options = SubscriptionProviderOptions(
      intervalSeconds: 7200,
      requestHeaders: [header],
      fetchProxy: .localClashProxy,
      ruleOverlay: RuleOverlaySettings(
        enabled: true,
        prependRules: [
          ManagedRuleOverlayRule(kind: .domainSuffix, value: "front.example", policy: "DIRECT")
        ],
        disabledRuleMatchers: [
          ManagedRuleDisableMatcher(mode: .exact, pattern: "DOMAIN-SUFFIX,ads.example,REJECT")
        ]
      )
    )
    let updatePolicy = SubscriptionUpdatePolicy(
      automaticUpdatesEnabled: false,
      intervalOverrideMinutes: 120,
      prefersRemoteInterval: false
    )

    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      providerOptions: options,
      updatePolicy: updatePolicy,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    )

    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, options)
    XCTAssertEqual(store.profiles.first?.subscriptionUpdatePolicy, updatePolicy)
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).header.\(header.id.uuidString)"),
      "Clash Verge/2.0.0"
    )
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertTrue(manifest.contains(header.id.uuidString))
    XCTAssertTrue(manifest.contains("User-Agent"))
    XCTAssertFalse(manifest.contains("Clash Verge/2.0.0"))

    let reloaded = ProfileStore(paths: fixture.paths, keychain: secrets)
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.subscriptionProviderOptions, options)
    XCTAssertEqual(reloaded.profiles.first?.subscriptionUpdatePolicy, updatePolicy)
  }

  func testLegacyHeaderValuesAreMigratedOutOfManifestOnLoad() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let profileID = UUID()
    let headerID = UUID()
    try """
    {
      "activeProfileID": "\(profileID.uuidString)",
      "profiles": [
        {
          "id": "\(profileID.uuidString)",
          "name": "Remote",
          "nameIsUserCustomized": true,
          "source": {
            "kind": "subscription",
            "subscriptionID": "\(profileID.uuidString)"
          },
          "originalConfigPath": "\(fixture.configURL.path)",
          "subscriptionProviderOptions": {
            "runtimeMergeYAML": "proxies:\\n  - name: Legacy Runtime Node\\n    type: trojan\\n    password: legacy-secret\\n",
            "requestHeaders": [
              {
                "id": "\(headerID.uuidString)",
                "name": "Authorization",
                "value": "Bearer legacy"
              }
            ]
          },
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
      ]
    }
    """.write(to: fixture.paths.manifestURL, atomically: true, encoding: .utf8)

    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    await store.waitForManifestLoad()

    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions.requestHeaders.first?.value, "Bearer legacy")
    XCTAssertEqual(
      store.profiles.first?.subscriptionProviderOptions.runtimeMergeYAML,
      "proxies:\n  - name: Legacy Runtime Node\n    type: trojan\n    password: legacy-secret\n"
    )
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profileID.uuidString).header.\(headerID.uuidString)"),
      "Bearer legacy"
    )
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profileID.uuidString).runtimeMergeYAML"),
      "proxies:\n  - name: Legacy Runtime Node\n    type: trojan\n    password: legacy-secret\n"
    )
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertTrue(manifest.contains("Authorization"))
    XCTAssertFalse(manifest.contains("Bearer legacy"))
    XCTAssertFalse(manifest.contains("legacy-secret"))
  }

  func testSubscriptionProviderOptionsRuntimeMergeSecretFailureRestoresPreviousValue() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: session
    )
    let initialOptions = SubscriptionProviderOptions(runtimeMergeYAML: "rules:\n  - MATCH,DIRECT\n")
    try await store.updateSubscriptionProviderOptions(profile, options: initialOptions)

    let rejectedRuntimeMergeYAML = "rules:\n  - MATCH,Proxy\n"
    secrets.rejectSaving(rejectedRuntimeMergeYAML)

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionProviderOptions(
        profile,
        options: SubscriptionProviderOptions(runtimeMergeYAML: rejectedRuntimeMergeYAML)
      )
    }

    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, initialOptions)
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).runtimeMergeYAML"),
      initialOptions.runtimeMergeYAML
    )
  }

  func testProviderOptionsPreflightBeforePersistence() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let providerContent = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent))
    )
    let invalidOptions = SubscriptionProviderOptions(overrideYAML: "override: [")
    let validator = MihomoSubscriptionProfilePreflightValidator(
      paths: fixture.paths,
      overrides: .defaultForLaunch(secret: "secret-token"),
      coreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      runtimeConfigValidator: RecordingRuntimeConfigValidator(result: .success(()))
    )

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionProviderOptions(
        profile,
        options: invalidOptions,
        preflightValidator: validator
      )
    }

    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, .default)
    let reloaded = ProfileStore(paths: fixture.paths, keychain: secrets)
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.subscriptionProviderOptions, .default)
  }

  func testRuleOverlayProviderOptionsPreflightFailureDoesNotPersist() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(
        "proxies:\n  - name: DIRECT\n    type: direct\nrules:\n  - MATCH,DIRECT\n"
      ))
    )
    let rejectedOptions = SubscriptionProviderOptions(
      ruleOverlay: RuleOverlaySettings(
        enabled: true,
        prependRules: [
          ManagedRuleOverlayRule(kind: .ruleSet, value: "RemoteRules", policy: "Proxy")
        ]
      )
    )
    let validator = RecordingSubscriptionPreflightValidator(
      result: .failure(NSError(domain: "RuleOverlayPreflight", code: 1))
    )

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionProviderOptions(
        profile,
        options: rejectedOptions,
        preflightValidator: validator
      )
    }

    XCTAssertEqual(validator.validatedProviderOptions, [rejectedOptions])
    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, .default)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.latestPreflight?.result, .failed)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.trigger, .providerOptionsEdit)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.result, .failed)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.updateHistory.first?.failureKind, .preflight)
    let reloaded = ProfileStore(paths: fixture.paths, keychain: secrets)
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.subscriptionProviderOptions, .default)
  }

  func testSubscriptionSourceAndProviderOptionsPersistAsSingleFinalProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/old")!,
      session: initialSession
    )
    let header = SubscriptionRequestHeader(name: "Authorization", value: "Bearer new")
    let options = SubscriptionProviderOptions(requestHeaders: [header], fetchProxy: .direct)
    let recorder = URLProtocolRecorder(responseBody: "proxies:\n  - name: New\n    type: direct\n")
    let session = URLSession(configuration: recorder.configuration)

    try await store.updateSubscriptionSourceAndProviderOptions(
      profile,
      url: URL(string: "https://example.com/new")!,
      options: options,
      session: session,
      fetchOptions: options.fetchOptions(from: SubscriptionFetchOptions())
    )

    XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/new")
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).header.\(header.id.uuidString)"),
      "Bearer new"
    )
    XCTAssertEqual(store.profiles.first?.subscriptionProviderOptions, options)
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), "proxies:\n  - name: New\n    type: direct\n")
  }

  func testSubscriptionAcceptsBase64URIProviderContentAndStoresRawSource() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let uriSubscription = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#VLESS%20Node
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Hysteria2%20Node
    """
    let encodedSubscription = Data(uriSubscription.utf8).base64EncodedString()
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning(encodedSubscription))

    let profile = try await store.addSubscription(
      name: "Xboard",
      url: URL(string: "https://example.com/api/v1/client/subscribe?token=test")!,
      session: session
    )

    XCTAssertEqual(profile.name, "Xboard")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), encodedSubscription)
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/api/v1/client/subscribe?token=test")
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertFalse(manifest.contains("token=test"))
  }

  func testSubscriptionDiagnosticsManifestRedactsURLAndHeaderValues() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let header = SubscriptionRequestHeader(name: "X-Panel-Token", value: "super-secret-token")
    let providerOptions = SubscriptionProviderOptions(
      requestHeaders: [header],
      fetchProxy: .direct
    )
    let recorder = URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: [
        "Content-Type": "text/yaml; charset=UTF-8",
        "subscription-userinfo": "upload=1; download=2; total=3"
      ]
    )

    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://user:password@example.com/sub?token=abc&flag=enabled")!,
      providerOptions: providerOptions,
      session: URLSession(configuration: recorder.configuration),
      fetchOptions: providerOptions.fetchOptions(from: SubscriptionFetchOptions(userAgent: "Custom UA"))
    )

    let diagnostics = try XCTUnwrap(store.profiles.first?.subscriptionDiagnostics.latestFetch)
    XCTAssertEqual(diagnostics.sanitizedURL, "https://example.com/sub?token=<redacted>&flag=<redacted>")
    XCTAssertEqual(diagnostics.userAgent, "Custom UA")
    XCTAssertEqual(diagnostics.requestHeaders.first(where: { $0.name == "X-Panel-Token" })?.hasValue, true)
    XCTAssertTrue(diagnostics.requestHeaders.contains { $0.name == "User-Agent" && $0.hasValue })
    XCTAssertEqual(diagnostics.contentType, "text/yaml; charset=UTF-8")
    XCTAssertEqual(diagnostics.declaredCharset, "UTF-8")
    XCTAssertEqual(diagnostics.decodedCharset, "utf-8")

    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertTrue(manifest.contains("https:\\/\\/example.com\\/sub?token=<redacted>&flag=<redacted>"))
    XCTAssertTrue(manifest.contains("X-Panel-Token"))
    XCTAssertFalse(manifest.contains("super-secret-token"))
    XCTAssertFalse(manifest.contains("token=abc"))
    XCTAssertFalse(manifest.contains("user:password"))
    XCTAssertEqual(
      try secrets.load(account: "subscription.\(profile.id.uuidString).header.\(header.id.uuidString)"),
      "super-secret-token"
    )
  }

  func testSubscriptionDiagnosticsPersistRedactedPathToken() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let recorder = URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["Content-Type": "text/yaml; charset=UTF-8"]
    )

    _ = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/link/super-secret-path-token?flag=enabled")!,
      session: URLSession(configuration: recorder.configuration)
    )

    let diagnostics = try XCTUnwrap(store.profiles.first?.subscriptionDiagnostics.latestFetch)
    XCTAssertEqual(diagnostics.sanitizedURL, "https://example.com/link/<redacted>?flag=<redacted>")
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertTrue(manifest.contains("https:\\/\\/example.com\\/link\\/<redacted>?flag=<redacted>"))
    XCTAssertFalse(manifest.contains("super-secret-path-token"))
  }

  func testSubscriptionDiagnosticsHistoryTrimsToTenEntriesWhenPersisted() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    )

    for index in 0..<12 {
      try await store.markSubscriptionUpdateFailed(
        profileID: profile.id,
        trigger: .automatic,
        message: "failure \(index)",
        failureKind: .network,
        at: Date(timeIntervalSince1970: TimeInterval(index)),
        backoffUntil: nil,
        nextUpdateAt: nil
      )
    }

    let history = try XCTUnwrap(store.profiles.first?.subscriptionDiagnostics.updateHistory)
    XCTAssertEqual(history.count, 10)
    XCTAssertEqual(history.first?.message, "failure 11")
    XCTAssertEqual(history.last?.message, "failure 2")

    let reloaded = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await reloaded.waitForManifestLoad()
    let reloadedHistory = try XCTUnwrap(reloaded.profiles.first?.subscriptionDiagnostics.updateHistory)
    XCTAssertEqual(reloadedHistory.count, 10)
    XCTAssertEqual(reloadedHistory.first?.message, "failure 11")
    XCTAssertEqual(reloadedHistory.last?.message, "failure 2")
  }

  func testSubscriptionProviderContentPreflightRunsBeforeSavingProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let validator = RecordingSubscriptionPreflightValidator(
      result: .failure(AppError.configValidationFailed("provider content failed mihomo validation"))
    )
    let providerContent = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent))

    await XCTAssertThrowsErrorAsync {
      try await store.addSubscription(
        name: "Remote",
        url: URL(string: "https://example.com/sub")!,
        session: session,
        preflightValidator: validator
      )
    } handler: { error in
      XCTAssertTrue(String(describing: error).contains("provider content failed mihomo validation"))
    }

    XCTAssertEqual(validator.validatedNames, ["Remote"])
    XCTAssertEqual(validator.validatedSources, [providerContent])
    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertTrue(secrets.storedValues.isEmpty)
  }

  func testSubscriptionFullYamlPreflightRunsBeforeSavingProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let validator = RecordingSubscriptionPreflightValidator(
      result: .failure(AppError.configValidationFailed("full config failed mihomo validation"))
    )
    let source = """
    proxies:
      - name: Node
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Node, DIRECT]
    rules:
      - MATCH,Proxy
    """
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning(source))

    await XCTAssertThrowsErrorAsync {
      try await store.addSubscription(
        name: "Remote",
        url: URL(string: "https://example.com/sub")!,
        session: session,
        preflightValidator: validator
      )
    } handler: { error in
      XCTAssertTrue(String(describing: error).contains("full config failed mihomo validation"))
    }

    XCTAssertEqual(validator.validatedNames, ["Remote"])
    XCTAssertEqual(validator.validatedSources, [source])
    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertTrue(secrets.storedValues.isEmpty)
  }

  func testSubscriptionProviderContentUpdatePreflightFailureKeepsExistingProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    )
    let originalConfig = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    let validator = RecordingSubscriptionPreflightValidator(
      result: .failure(AppError.configValidationFailed("wrapped provider config failed"))
    )
    let providerContent = "vless://00000000-0000-0000-0000-000000000000@example.com:443#Node\n"

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscription(
        profile,
        session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
        preflightValidator: validator
      )
    }

    XCTAssertEqual(validator.validatedSources, [providerContent])
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), originalConfig)
  }

  func testSubscriptionPreflightFailurePreservesFullMihomoOutputForDiagnostics() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let providerContent = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent))
    )

    // Mirrors real bundled Mihomo v1.19.27 `-t` output: a benign info line
    // (the part previously surfaced by issue #7), the real cause as a logfmt
    // `level=error` line, then a generic trailer last.
    let multilineMihomoOutput = """
    time="2026-06-19T10:21:33+08:00" level=info msg="Start initial configuration in progress"
    time="2026-06-19T10:21:33+08:00" level=warning msg="[Config] geox-url not configured, fallback to internal default"
    time="2026-06-19T10:21:34+08:00" level=error msg="proxy 0: '' has unset fields: cipher, password"
    configuration file /tmp/runtime.yaml test failed
    """

    let validator = RecordingSubscriptionPreflightValidator(
      result: .failure(AppError.configValidationFailed(multilineMihomoOutput))
    )

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscription(
        profile,
        session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
        preflightValidator: validator
      )
    } handler: { error in
      let preflightError = error as? SubscriptionPreflightValidationError
      XCTAssertNotNil(preflightError, "Expected wrapped SubscriptionPreflightValidationError, got \(error)")
      let fullMessage = preflightError?.fullMessage ?? ""
      XCTAssertTrue(
        fullMessage.contains(#"level=error msg="proxy 0: '' has unset fields: cipher, password""#),
        "Full preflight message should retain the real error line, got: \(fullMessage)"
      )
      // The wrapped error's headline message (used for the global banner) must be
      // the extracted cause, not the truncated Mihomo log head.
      XCTAssertEqual(preflightError?.message, "proxy 0: '' has unset fields: cipher, password")
    }

    let persistedPreflight = store.profiles.first?.subscriptionDiagnostics.latestPreflight
    XCTAssertEqual(persistedPreflight?.result, .failed)
    let persistedFull = try XCTUnwrap(persistedPreflight?.fullMessage)
    XCTAssertTrue(
      persistedFull.contains(#"level=error msg="proxy 0: '' has unset fields: cipher, password""#),
      "Persisted fullMessage lost the real error line: \(persistedFull)"
    )
    XCTAssertTrue(
      persistedFull.contains("Start initial configuration in progress"),
      "Persisted fullMessage should keep the earlier log lines too"
    )
    XCTAssertTrue(
      persistedFull.contains("test failed"),
      "Persisted fullMessage should keep the trailing line too"
    )

    let summary = try XCTUnwrap(persistedPreflight?.message)
    XCTAssertEqual(
      summary,
      "proxy 0: '' has unset fields: cipher, password",
      "Short summary should be the extracted error cause, not the info head or trailer"
    )
  }

  // A geodata-stall preflight timeout arrives as a *raw* NSError from
  // `MihomoRuntimeConfigValidator` (domain "ClashMax.CoreValidation", ETIMEDOUT),
  // not as an `AppError.configValidationFailed`. Its `localizedDescription` carries
  // the clean "timed out…" headline plus the captured Mihomo log, whereas
  // `String(describing:)` wraps the same text in the noisy
  // `Error Domain=… Code=… "…" UserInfo={…}` form. The diagnostics surfaced to the
  // user must come from the clean copy: the actionable geodata-timeout hint as the
  // summary, and a full message free of the NSError wrapper (which would otherwise
  // both mask the hint and leak internal error plumbing into the details view).
  func testSubscriptionPreflightTimeoutSurfacesGeodataHintFromCleanNSError() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let providerContent = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent))
    )

    // Synthetic geodata-stall log: only benign info lines plus geodata download
    // markers, with no failure-level line. (No real subscription content.)
    let geodataStallOutput = """
    time="2026-06-20T10:00:00+12:00" level=info msg="Start initial configuration in progress"
    time="2026-06-20T10:00:00+12:00" level=info msg="Geodata Loader mode: memconservative"
    time="2026-06-20T10:00:00+12:00" level=info msg="Can't find MMDB, start download"
    time="2026-06-20T10:00:30+12:00" level=info msg="Can't find GeoSite.dat, start download"
    """
    let timeoutError = NSError(
      domain: "ClashMax.CoreValidation",
      code: Int(ETIMEDOUT),
      userInfo: [
        NSLocalizedDescriptionKey: "Runtime config validation timed out after 30.0s.\n\(geodataStallOutput)"
      ]
    )
    let validator = RecordingSubscriptionPreflightValidator(result: .failure(timeoutError))

    let geodataHint =
      "Mihomo preflight timed out while preparing geodata. Retry after geodata downloads or check network access."

    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscription(
        profile,
        session: URLSession(configuration: URLProtocolRecorder.configurationReturning(providerContent)),
        preflightValidator: validator
      )
    } handler: { error in
      let preflightError = error as? SubscriptionPreflightValidationError
      XCTAssertNotNil(preflightError, "Expected wrapped SubscriptionPreflightValidationError, got \(error)")
      XCTAssertEqual(
        preflightError?.message,
        geodataHint,
        "Headline should be the actionable geodata-timeout hint, not the NSError head"
      )
      let fullMessage = preflightError?.fullMessage ?? ""
      XCTAssertFalse(
        fullMessage.contains("Error Domain="),
        "Full message must come from the clean localizedDescription, not the NSError wrapper: \(fullMessage)"
      )
    }

    let persistedPreflight = store.profiles.first?.subscriptionDiagnostics.latestPreflight
    XCTAssertEqual(persistedPreflight?.result, .failed)
    XCTAssertEqual(
      persistedPreflight?.message,
      geodataHint,
      "Persisted summary should be the geodata-timeout hint"
    )
    let persistedFull = try XCTUnwrap(persistedPreflight?.fullMessage)
    XCTAssertFalse(
      persistedFull.contains("Error Domain="),
      "Persisted fullMessage leaked the NSError wrapper: \(persistedFull)"
    )
    // The full diagnostic still preserves the captured geodata log for the details view.
    XCTAssertTrue(
      persistedFull.contains("Can't find GeoSite.dat, start download"),
      "Persisted fullMessage should retain the raw geodata log for the details view: \(persistedFull)"
    )
  }

  func testAppModelPublishesPreflightSummaryAsLastErrorAndFullOutputAsDetails() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let model = AppModel(paths: fixture.paths, profileStore: store)

    let fullOutput = """
    time="2026-06-19T10:21:33+08:00" level=info msg="Start initial configuration in progress"
    time="2026-06-19T10:21:34+08:00" level=error msg="proxy 0: '' has unset fields: cipher, password"
    configuration file /tmp/runtime.yaml test failed
    """
    let diagnostics = SubscriptionPreflightDiagnostics(
      result: .failed,
      message: SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: fullOutput),
      fullMessage: SubscriptionPreflightDiagnosticFormatter.fullDiagnostic(fromFullMessage: fullOutput)
    )
    let wrapped = SubscriptionPreflightValidationError(
      error: AppError.configValidationFailed(fullOutput),
      diagnostics: diagnostics
    )

    model.publishSubscriptionFailure(wrapped)

    XCTAssertEqual(
      model.lastError,
      "proxy 0: '' has unset fields: cipher, password",
      "Global banner headline should be the extracted cause, not the truncated log head"
    )
    XCTAssertEqual(
      model.lastErrorDetails,
      diagnostics.fullMessage,
      "Global banner should expose the full Mihomo output for copying"
    )

    // Assigning a new lastError must clear the stale details (didSet behavior).
    model.lastError = "Some unrelated error"
    XCTAssertNil(model.lastErrorDetails)
  }

  func testAppModelPublishesNonPreflightFailureWithoutDetails() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let model = AppModel(paths: fixture.paths, profileStore: store)

    model.publishSubscriptionFailure(AppError.invalidSubscriptionResponse)

    XCTAssertEqual(model.lastError, UserFacingError.message(for: AppError.invalidSubscriptionResponse))
    XCTAssertNil(model.lastErrorDetails, "Non-preflight failures have no copyable full diagnostic")
  }

  func testImportRejectsConfigWithoutProxyDefinitions() async throws {
    let fixture = try TemporaryProfileFixture(config: "mixed-port: 7890\nrules: []\n")
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())

    await XCTAssertThrowsErrorAsync {
      try await store.importLocalConfig(from: fixture.configURL)
    } handler: { error in
      XCTAssertTrue(
        String(describing: error)
          .contains(String(localized: "Profile must include at least one proxy or proxy provider."))
      )
    }

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertNil(store.activeProfileID)
  }

  func testSubscriptionUpdateRejectsInvalidConfigAndKeepsExistingProfileConfig() async throws {
    let fixture = try TemporaryProfileFixture(config: "proxies:\n  - name: DIRECT\n    type: direct\n")
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub.yaml")!,
      session: initialSession
    )

    let updateSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("rules: []\n"))
    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscription(profile, session: updateSession)
    }

    XCTAssertEqual(
      try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8),
      "proxies:\n  - name: DIRECT\n    type: direct\n"
    )
  }

  func testSubscriptionUpdateAcceptsValidYamlWithTextHTMLContentType() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: initialSession
    )
    let updatedSource = """
    mixed-port: 7890
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [DIRECT]
    proxies:
      - name: DIRECT
        type: direct
    rules:
      - MATCH,DIRECT
    """
    let updateRecorder = URLProtocolRecorder(
      responseBody: updatedSource,
      responseHeaders: [
        "Content-Type": "text/html; charset=UTF-8",
        "subscription-userinfo": "upload=4; download=5; total=6"
      ]
    )

    try await store.updateSubscription(
      profile,
      session: URLSession(configuration: updateRecorder.configuration)
    )

    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), updatedSource)
    XCTAssertEqual(store.profiles.first?.subscriptionMetadata?.traffic?.download, 5)
  }

  func testSubscriptionUpdateAcceptsURIProviderContent() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: initialSession
    )

    let updatedSubscription = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let updateSession = URLSession(configuration: URLProtocolRecorder.configurationReturning(updatedSubscription))
    try await store.updateSubscription(profile, session: updateSession)

    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), updatedSubscription)
    XCTAssertEqual(store.profiles.first?.subscriptionDiagnostics.latestPreflight?.result, .succeeded)
    XCTAssertEqual(
      store.profiles.first?.subscriptionDiagnostics.latestPreflight?.messageKind,
      .mihomoAccepted
    )
    XCTAssertNil(store.profiles.first?.subscriptionDiagnostics.latestPreflight?.message)
  }

  func testRuntimePathsPrepareDirectoriesUseOwnerOnlyPermissions() throws {
    let fixture = try TemporaryProfileFixture()

    for directory in [fixture.paths.appSupport, fixture.paths.profiles, fixture.paths.runtime, fixture.paths.subscriptions, fixture.paths.logs] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    try fixture.paths.prepareDirectories()

    for directory in [fixture.paths.appSupport, fixture.paths.profiles, fixture.paths.runtime, fixture.paths.subscriptions, fixture.paths.logs] {
      XCTAssertEqual(try posixPermissions(at: directory), SecureFileIO.privateDirectoryPermissions)
    }
  }

  func testProfileDiskIOWritesManifestAndProfileSourcesWithOwnerOnlyPermissions() async throws {
    let fixture = try TemporaryProfileFixture()
    let diskIO = ProfileDiskIO()
    let profileURL = fixture.paths.profiles.appendingPathComponent("profile.yaml")
    let subscriptionURL = fixture.paths.profiles.appendingPathComponent("subscription.yaml")

    try await diskIO.saveManifest(ProfileManifest(profiles: [], activeProfileID: nil), to: fixture.paths.manifestURL)
    _ = try await diskIO.importLocalConfig(from: fixture.configURL, to: profileURL)
    try await diskIO.writeProfileSource("proxies:\n  - name: DIRECT\n    type: direct\n", to: subscriptionURL)

    XCTAssertEqual(try posixPermissions(at: fixture.paths.manifestURL), SecureFileIO.privateFilePermissions)
    XCTAssertEqual(try posixPermissions(at: profileURL), SecureFileIO.privateFilePermissions)
    XCTAssertEqual(try posixPermissions(at: subscriptionURL), SecureFileIO.privateFilePermissions)
  }

  private func posixPermissions(at url: URL) throws -> Int {
    let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
  }
}

private struct TemporaryProfileFixture {
  let root: URL
  let paths: RuntimePaths
  let configURL: URL

  init(config: String = "mixed-port: 7890\nproxies:\n  - name: DIRECT\n    type: direct\n") throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxTests-\(UUID().uuidString)", isDirectory: true)
    self.root = root
    paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    try paths.prepareDirectories()
    configURL = root.appendingPathComponent("sample.yaml")
    try config.write(to: configURL, atomically: true, encoding: .utf8)
  }
}

final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
  private var values: [String: String] = [:]
  private var rejectedSavedValues: Set<String> = []

  var storedValues: [String: String] {
    values
  }

  func rejectSaving(_ value: String) {
    rejectedSavedValues.insert(value)
  }

  func save(_ value: String, account: String) throws {
    if rejectedSavedValues.contains(value) {
      throw NSError(domain: "InMemorySecretStore", code: 1)
    }
    values[account] = value
  }

  func load(account: String) throws -> String? {
    values[account]
  }

  func delete(account: String) throws {
    values.removeValue(forKey: account)
  }
}

@MainActor
final class RecordingSubscriptionPreflightValidator: SubscriptionProfilePreflightValidating {
  private let result: Result<Void, Error>
  private(set) var validatedSources: [String] = []
  private(set) var validatedNames: [String] = []
  private(set) var validatedProviderOptions: [SubscriptionProviderOptions] = []

  init(result: Result<Void, Error> = .success(())) {
    self.result = result
  }

  func validate(
    subscriptionSource: String,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {
    validatedSources.append(subscriptionSource)
    validatedNames.append(profileName)
    validatedProviderOptions.append(providerOptions)
    try result.get()
  }
}
