import Foundation
import Combine
import XCTest
@testable import ClashMax

@MainActor
final class ProfileStoreTests: XCTestCase {
  func testAddSubscriptionRejectsUpstreamIDWithoutMatchingResolvedEndpoint() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let recorder = URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["Content-Type": "text/yaml"]
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await store.addSubscription(
        url: URL(string: "https://example.com/sub")!,
        upstreamEndpointID: UUID(),
        session: URLSession(configuration: recorder.configuration)
      )
    }

    XCTAssertNil(recorder.lastRequest)
    XCTAssertTrue(store.profiles.isEmpty)
  }

  func testProfileUpstreamCannotBeBypassedWithCustomURLSession() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let recorder = URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["Content-Type": "text/yaml"]
    )
    let customSession = URLSession(configuration: recorder.configuration)
    let unresolvedSecret = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Authenticated profile upstream",
        kind: .socks5,
        host: "proxy.example.com",
        port: 1080,
        authentication: OutboundProxyAuthentication(username: "sensitive-user")
      ),
      password: nil
    )

    do {
      _ = try await store.addSubscription(
        url: URL(string: "https://example.com/sub")!,
        session: customSession,
        fetchOptions: SubscriptionFetchOptions(
          timeout: 1,
          profileUpstreamEndpoint: unresolvedSecret
        )
      )
      XCTFail("Expected unresolved profile upstream secret to fail closed")
    } catch {
      let text = "\(error) \(error.localizedDescription)"
      XCTAssertFalse(text.contains("sensitive-user"))
    }

    XCTAssertNil(recorder.lastRequest)
    XCTAssertTrue(store.profiles.isEmpty)
  }

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
    XCTAssertNil(profile.upstreamEndpointID)
  }

  func testManualProxySourceUsesStableKindAndEndpointIDRoundTrip() throws {
    let endpointID = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
    let source = ProfileSource.manualProxy(endpointID: endpointID)

    let data = try JSONEncoder().encode(source)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

    XCTAssertEqual(object, [
      "kind": "manualProxy",
      "endpointID": endpointID.uuidString
    ])
    XCTAssertEqual(try JSONDecoder().decode(ProfileSource.self, from: data), source)
    XCTAssertEqual(source.displayName, String(localized: "Manual Proxy"))
    XCTAssertFalse(source.isSubscription)
  }

  func testManualProxyProfileWritesPrivateFailClosedMarkerWithoutEndpointData() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let endpointID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    let profile = try await store.addManualProxyProfile(
      name: "Office Proxy",
      endpointID: endpointID
    )

    XCTAssertEqual(profile.source, .manualProxy(endpointID: endpointID))
    XCTAssertNil(profile.upstreamEndpointID)
    let marker = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    XCTAssertTrue(marker.contains("MATCH,REJECT"))
    XCTAssertFalse(marker.localizedCaseInsensitiveContains("endpoint"))
    XCTAssertFalse(marker.contains(endpointID.uuidString))
    XCTAssertFalse(marker.localizedCaseInsensitiveContains("username"))
    XCTAssertFalse(marker.localizedCaseInsensitiveContains("password"))
    XCTAssertNoThrow(try ProfileConfigValidator.validate(marker))
    XCTAssertEqual(
      try posixPermissions(at: URL(fileURLWithPath: profile.originalConfigPath)),
      SecureFileIO.privateFilePermissions
    )

    let reloaded = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.map(\.id), [profile.id])
    XCTAssertEqual(reloaded.profiles.first?.name, profile.name)
    XCTAssertEqual(reloaded.profiles.first?.source, profile.source)
    XCTAssertEqual(reloaded.profiles.first?.originalConfigPath, profile.originalConfigPath)
    XCTAssertNil(reloaded.profiles.first?.upstreamEndpointID)
  }

  func testOnlyOneManualProfileMayReferenceAnEndpoint() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let endpointID = UUID()
    let first = try await store.addManualProxyProfile(name: "First", endpointID: endpointID)

    await XCTAssertThrowsErrorAsync {
      try await store.addManualProxyProfile(name: "Second", endpointID: endpointID)
    } handler: { error in
      XCTAssertEqual(
        error as? ProfileStoreError,
        .manualProfileAlreadyExists(endpointID)
      )
    }

    XCTAssertEqual(store.profiles, [first])
    let files = try FileManager.default.contentsOfDirectory(
      at: fixture.paths.profiles,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(files.map(\.lastPathComponent), [URL(fileURLWithPath: first.originalConfigPath).lastPathComponent])
  }

  func testManualProfileRejectsSelfUpstreamAndPersistsDifferentEndpoint() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let manualEndpointID = UUID()
    let otherEndpointID = UUID()
    let profile = try await store.addManualProxyProfile(
      name: "Manual",
      endpointID: manualEndpointID
    )

    await XCTAssertThrowsErrorAsync {
      try await store.updateUpstreamEndpoint(for: profile, endpointID: manualEndpointID)
    } handler: { error in
      XCTAssertEqual(
        error as? ProfileStoreError,
        .manualProfileCannotUseOwnEndpoint(manualEndpointID)
      )
    }
    XCTAssertNil(store.profiles.first?.upstreamEndpointID)

    try await store.updateUpstreamEndpoint(for: profile, endpointID: otherEndpointID)
    XCTAssertEqual(store.profiles.first?.upstreamEndpointID, otherEndpointID)

    let reloaded = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await reloaded.waitForManifestLoad()
    XCTAssertEqual(reloaded.profiles.first?.upstreamEndpointID, otherEndpointID)
  }

  func testEndpointReferencesListManualAndUpstreamProfilesByName() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let endpointID = UUID()
    let manual = try await store.addManualProxyProfile(name: "Manual", endpointID: endpointID)
    let local = try await store.importLocalConfig(from: fixture.configURL)
    try await store.rename(local, to: "Local via Office")
    try await store.updateUpstreamEndpoint(for: local, endpointID: endpointID)

    let references = try await store.references(to: endpointID)
    XCTAssertEqual(
      references,
      [
        OutboundProxyEndpointReference(
          profileID: manual.id,
          profileName: "Manual",
          kind: .manualProfile
        ),
        OutboundProxyEndpointReference(
          profileID: local.id,
          profileName: "Local via Office",
          kind: .upstream
        )
      ]
    )
  }

  func testEndpointReferencesWaitForManifestLoadBeforeReturningSnapshot() async throws {
    let fixture = try TemporaryProfileFixture()
    let endpointID = UUID()
    let manual = Profile(
      name: "Persisted Manual",
      source: .manualProxy(endpointID: endpointID),
      originalConfigPath: fixture.paths.profiles.appendingPathComponent("manual.yaml").path
    )
    let upstream = Profile(
      name: "Persisted Upstream",
      source: .localFile(originalPath: nil),
      originalConfigPath: fixture.paths.profiles.appendingPathComponent("upstream.yaml").path,
      upstreamEndpointID: endpointID
    )
    let diskIO = BlockingProfileManifestLoadDiskIO(
      manifest: ProfileManifest(
        profiles: [manual, upstream],
        activeProfileID: manual.id
      )
    )
    let store = ProfileStore(
      paths: fixture.paths,
      keychain: InMemorySecretStore(),
      diskIO: diskIO
    )
    await diskIO.waitUntilLoadStarts()

    let queryStarted = OutboundProxyEndpointTestSignal()
    let queryFinished = OutboundProxyEndpointTestSignal()
    let queryTask = Task { @MainActor in
      await queryStarted.signal()
      let references = try await store.references(to: endpointID)
      await queryFinished.signal()
      return references
    }
    await queryStarted.wait()
    await Task.yield()

    let didFinishBeforeLoad = await queryFinished.value()
    XCTAssertFalse(didFinishBeforeLoad)

    await diskIO.releaseLoad()
    let references = try await queryTask.value
    XCTAssertEqual(
      references,
      [
        OutboundProxyEndpointReference(
          profileID: manual.id,
          profileName: manual.name,
          kind: .manualProfile
        ),
        OutboundProxyEndpointReference(
          profileID: upstream.id,
          profileName: upstream.name,
          kind: .upstream
        )
      ]
    )
  }

  func testManualProfileManifestFailureRemovesMarkerAndDoesNotPublishProfile() async throws {
    let fixture = try TemporaryProfileFixture()
    let diskIO = ControllableProfileDiskIO()
    await diskIO.failNextManifestSave()
    let store = ProfileStore(
      paths: fixture.paths,
      keychain: InMemorySecretStore(),
      diskIO: diskIO
    )
    await store.waitForManifestLoad()

    await XCTAssertThrowsErrorAsync {
      try await store.addManualProxyProfile(name: "Manual", endpointID: UUID())
    }

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertNil(store.activeProfileID)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: fixture.paths.profiles,
        includingPropertiesForKeys: nil
      ),
      []
    )
  }

  func testUpstreamManifestFailureDoesNotPublishInMemoryChange() async throws {
    let fixture = try TemporaryProfileFixture()
    let diskIO = ControllableProfileDiskIO()
    let store = ProfileStore(
      paths: fixture.paths,
      keychain: InMemorySecretStore(),
      diskIO: diskIO
    )
    let profile = try await store.importLocalConfig(from: fixture.configURL)
    await diskIO.failNextManifestSave()

    await XCTAssertThrowsErrorAsync {
      try await store.updateUpstreamEndpoint(for: profile, endpointID: UUID())
    }

    XCTAssertNil(store.profiles.first?.upstreamEndpointID)
    let manifest = try await diskIO.loadManifest(from: fixture.paths.manifestURL)
    XCTAssertNil(manifest?.profiles.first?.upstreamEndpointID)
  }

  func testDeletingManualProfileDoesNotTouchSharedEndpointManifest() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let endpointManifest = #"{"sentinel":"shared endpoint metadata"}"#
    try SecureFileIO.writePrivateString(endpointManifest, to: fixture.paths.outboundProxyEndpointManifestURL)
    let profile = try await store.addManualProxyProfile(name: "Manual", endpointID: UUID())

    try await store.delete(profile)

    XCTAssertFalse(FileManager.default.fileExists(atPath: profile.originalConfigPath))
    XCTAssertEqual(
      try String(contentsOf: fixture.paths.outboundProxyEndpointManifestURL, encoding: .utf8),
      endpointManifest
    )
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

    // Mirrors captured Mihomo `-t` output: a benign info line
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

final class OutboundProxyEndpointStoreTests: XCTestCase {
  func testSOCKS5DefaultsToTCPOnlyAndHTTPOptionsRoundTrip() throws {
    let socks5 = OutboundProxyEndpoint(
      name: "Office SOCKS",
      kind: .socks5,
      host: "127.0.0.1",
      port: 1080
    )
    XCTAssertFalse(socks5.socks5Options.udpEnabled)

    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      name: "Office HTTP",
      kind: .http,
      host: "proxy.example.com",
      port: 8443,
      authentication: OutboundProxyAuthentication(username: "alice"),
      httpOptions: OutboundProxyHTTPOptions(
        tlsEnabled: true,
        serverName: "edge.example.com",
        skipCertificateVerification: true
      )
    )

    let data = try JSONEncoder().encode(endpoint)
    let decoded = try JSONDecoder().decode(OutboundProxyEndpoint.self, from: data)

    XCTAssertEqual(decoded, endpoint)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-password"))
  }

  func testDiskRoundTripOmitsPasswordAndResolveLoadsExactKeychainAccount() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OutboundProxyStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appendingPathComponent("outbound-proxies.json")
    let secrets = InMemorySecretStore()
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Authenticated",
      kind: .socks5,
      host: "socks.example.com",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice"),
      socks5Options: OutboundProxySOCKS5Options(udpEnabled: true)
    )
    let store = OutboundProxyEndpointStore(manifestURL: manifestURL, secretStore: secrets)

    let saved = try await store.add(endpoint, password: "top-secret")

    XCTAssertEqual(saved, endpoint)
    XCTAssertEqual(
      try secrets.load(account: "outbound-proxy.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.password"),
      "top-secret"
    )
    let rawManifest = try String(contentsOf: manifestURL, encoding: .utf8)
    XCTAssertFalse(rawManifest.contains("top-secret"))
    XCTAssertEqual(try permissions(at: manifestURL), SecureFileIO.privateFilePermissions)

    let reloaded = OutboundProxyEndpointStore(manifestURL: manifestURL, secretStore: secrets)
    let reloadedEndpoints = try await reloaded.endpoints()
    XCTAssertEqual(reloadedEndpoints, [endpoint])
    let resolved = try await reloaded.resolve(id: endpoint.id)
    XCTAssertEqual(resolved.endpoint, endpoint)
    XCTAssertEqual(resolved.password, "top-secret")
    XCTAssertEqual(resolved.secretState, .ready)
  }

  func testNamesAreUniqueIgnoringCaseAndSurroundingWhitespace() async throws {
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    let secrets = InMemorySecretStore()
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )
    _ = try await store.add(
      OutboundProxyEndpoint(name: "Office", kind: .http, host: "one.example", port: 8080),
      password: nil
    )

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(name: " office ", kind: .socks5, host: "two.example", port: 1080),
        password: nil
      )
      XCTFail("Expected a duplicate-name error")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .duplicateName("office"))
    }

    let endpointNames = try await store.endpoints().map(\.name)
    XCTAssertEqual(endpointNames, ["Office"])
  }

  func testNamesAreUniqueUsingLocaleStableUnicodeCaseFolding() async throws {
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )
    _ = try await store.add(
      OutboundProxyEndpoint(name: "straße", kind: .http, host: "one.example", port: 8080),
      password: nil
    )

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(name: "STRASSE", kind: .socks5, host: "two.example", port: 1080),
        password: nil
      )
      XCTFail("Expected Unicode case-folded names to be treated as duplicates")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .duplicateName("strasse"))
    }
  }

  func testValidationRejectsInvalidEndpointAndRequiresPasswordForAuthentication() async throws {
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(name: " ", kind: .http, host: "proxy.example", port: 8080),
        password: nil
      )
      XCTFail("Expected name validation to fail")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .nameRequired)
    }

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(name: "Office", kind: .http, host: " ", port: 8080),
        password: nil
      )
      XCTFail("Expected host validation to fail")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .hostRequired)
    }

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(name: "Office", kind: .http, host: "proxy.example", port: 65_536),
        password: nil
      )
      XCTFail("Expected port validation to fail")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .invalidPort(65_536))
    }

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(
          name: "Office",
          kind: .http,
          host: "proxy.example",
          port: 8080,
          authentication: OutboundProxyAuthentication(username: " ")
        ),
        password: "secret"
      )
      XCTFail("Expected username validation to fail")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .usernameRequired)
    }

    do {
      _ = try await store.add(
        OutboundProxyEndpoint(
          name: "Office",
          kind: .http,
          host: "proxy.example",
          port: 8080,
          authentication: OutboundProxyAuthentication(username: "alice")
        ),
        password: " "
      )
      XCTFail("Expected password validation to fail")
    } catch {
      XCTAssertEqual(error as? OutboundProxyEndpointStoreError, .passwordRequired)
    }
  }

  func testResolveMakesMissingAuthenticationSecretExplicit() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Restored Endpoint",
      kind: .http,
      host: "proxy.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let disk = InMemoryOutboundProxyEndpointManifestStore(
      manifest: OutboundProxyEndpointManifest(endpoints: [endpoint])
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: disk
    )

    let resolved = try await store.resolve(id: endpoint.id)

    XCTAssertNil(resolved.password)
    XCTAssertEqual(resolved.secretState, .missingSecret)
    XCTAssertFalse(resolved.isReady)
  }

  func testFailedManifestSaveRollsBackNewSecret() async throws {
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    await disk.failNextSave()
    let secrets = InMemorySecretStore()
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .socks5,
      host: "proxy.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.add(endpoint, password: "top-secret")
    }

    XCTAssertNil(try secrets.load(account: OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)))
    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [])
  }

  func testFailedAddRestoresOrphanedSecretAfterAuthenticationOverwrite() async throws {
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    await disk.failNextSave()
    let secrets = InMemorySecretStore()
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .socks5,
      host: "proxy.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let account = OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    try secrets.save("orphaned-secret", account: account)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.add(endpoint, password: "new-secret")
    }

    XCTAssertEqual(try secrets.load(account: account), "orphaned-secret")
    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [])
  }

  func testFailedUnauthenticatedAddRestoresOrphanedSecretAfterCleanup() async throws {
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    await disk.failNextSave()
    let secrets = InMemorySecretStore()
    let endpoint = OutboundProxyEndpoint(
      name: "Unauthenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080
    )
    let account = OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    try secrets.save("orphaned-secret", account: account)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.add(endpoint, password: nil)
    }

    XCTAssertEqual(try secrets.load(account: account), "orphaned-secret")
    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [])
  }

  func testFailedAddAfterManifestWasStoredRestoresExactManifestAndSecret() async throws {
    let existing = OutboundProxyEndpoint(
      name: "Existing",
      kind: .http,
      host: "existing.example",
      port: 8080
    )
    let added = OutboundProxyEndpoint(
      name: "Added",
      kind: .socks5,
      host: "added.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [existing])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    await disk.failNextSave(afterStoring: true)
    let secrets = InMemorySecretStore()
    let addedAccount = OutboundProxyEndpointStore.passwordAccount(for: added.id)
    try secrets.save("preexisting-orphan", account: addedAccount)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.add(added, password: "new-secret")
    }

    let storedManifest = await disk.currentManifest()
    let endpoints = try await store.endpoints()
    XCTAssertEqual(storedManifest, originalManifest)
    XCTAssertEqual(endpoints, originalManifest.endpoints)
    XCTAssertEqual(try secrets.load(account: addedAccount), "preexisting-orphan")
  }

  func testFailedUpdateManifestSaveRestoresOldSecretAndMetadata() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .http,
      host: "old.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    let secrets = InMemorySecretStore()
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )
    _ = try await store.add(endpoint, password: "old-secret")
    var updatedDraft = endpoint
    updatedDraft.name = "Updated"
    updatedDraft.host = "new.example"
    let updated = updatedDraft
    await disk.failNextSave()

    await XCTAssertThrowsErrorAsync {
      try await store.update(updated, password: "new-secret")
    }

    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [endpoint])
    XCTAssertEqual(
      try secrets.load(account: OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)),
      "old-secret"
    )
  }

  func testFailedUpdateAfterManifestWasStoredRestoresExactManifestAndSecret() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Original",
      kind: .http,
      host: "old.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    var updated = endpoint
    updated.name = "Updated"
    updated.host = "new.example"
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [endpoint])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    await disk.failNextSave(afterStoring: true)
    let secrets = InMemorySecretStore()
    let account = OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    try secrets.save("old-secret", account: account)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.update(updated, password: "new-secret")
    }

    let storedManifest = await disk.currentManifest()
    let endpoints = try await store.endpoints()
    XCTAssertEqual(storedManifest, originalManifest)
    XCTAssertEqual(endpoints, originalManifest.endpoints)
    XCTAssertEqual(try secrets.load(account: account), "old-secret")
  }

  func testFailedDeleteManifestSaveRestoresSecretAndMetadata() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let disk = InMemoryOutboundProxyEndpointManifestStore()
    let secrets = InMemorySecretStore()
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )
    _ = try await store.add(endpoint, password: "top-secret")
    await disk.failNextSave()

    await XCTAssertThrowsErrorAsync {
      try await store.delete(id: endpoint.id)
    }

    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [endpoint])
    XCTAssertEqual(
      try secrets.load(account: OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)),
      "top-secret"
    )
  }

  func testFailedDeleteAfterManifestWasStoredRestoresExactManifestAndSecret() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [endpoint])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    await disk.failNextSave(afterStoring: true)
    let secrets = InMemorySecretStore()
    let account = OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    try secrets.save("old-secret", account: account)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.delete(id: endpoint.id)
    }

    let storedManifest = await disk.currentManifest()
    let endpoints = try await store.endpoints()
    XCTAssertEqual(storedManifest, originalManifest)
    XCTAssertEqual(endpoints, originalManifest.endpoints)
    XCTAssertEqual(try secrets.load(account: account), "old-secret")
  }

  func testConcurrentMutationsDoNotEnterDiskWhileEarlierSaveIsSuspended() async throws {
    let disk = BlockingOutboundProxyEndpointManifestStore()
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: disk
    )
    let first = OutboundProxyEndpoint(
      name: "First",
      kind: .http,
      host: "first.example",
      port: 8080
    )
    let second = OutboundProxyEndpoint(
      name: "Second",
      kind: .socks5,
      host: "second.example",
      port: 1080
    )

    let firstTask = Task {
      try await store.add(first, password: nil)
    }
    await disk.waitUntilFirstSaveStarts()

    let secondStarted = OutboundProxyEndpointTestSignal()
    let secondTask = Task {
      await secondStarted.signal()
      return try await store.add(second, password: nil)
    }
    await secondStarted.wait()
    try await Task.sleep(nanoseconds: 50_000_000)

    let suspendedSnapshot = await disk.snapshot()
    XCTAssertEqual(suspendedSnapshot.loadCount, 1)
    XCTAssertEqual(suspendedSnapshot.saveCount, 1)

    await disk.releaseFirstSave()
    _ = try await firstTask.value
    _ = try await secondTask.value

    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [first, second])
  }

  func testCancellingQueuedMutationDoesNotEnterDiskOrBlockLaterMutation() async throws {
    let disk = BlockingOutboundProxyEndpointManifestStore()
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: disk
    )
    let first = OutboundProxyEndpoint(
      name: "First",
      kind: .http,
      host: "first.example",
      port: 8080
    )
    let cancelled = OutboundProxyEndpoint(
      name: "Cancelled",
      kind: .http,
      host: "cancelled.example",
      port: 8081
    )
    let third = OutboundProxyEndpoint(
      name: "Third",
      kind: .socks5,
      host: "third.example",
      port: 1080
    )

    let firstTask = Task {
      try await store.add(first, password: nil)
    }
    await disk.waitUntilFirstSaveStarts()

    let cancelledStarted = OutboundProxyEndpointTestSignal()
    let cancelledTask = Task {
      await cancelledStarted.signal()
      return try await store.add(cancelled, password: nil)
    }
    await cancelledStarted.wait()
    try await Task.sleep(nanoseconds: 50_000_000)
    cancelledTask.cancel()

    await disk.releaseFirstSave()
    _ = try await firstTask.value
    await XCTAssertThrowsCancellationErrorAsync {
      try await cancelledTask.value
    }
    _ = try await store.add(third, password: nil)

    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, [first, third])
  }

  func testReadsWaitForPasswordAndManifestUpdateTransaction() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Old",
      kind: .http,
      host: "old.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    var updatedDraft = endpoint
    updatedDraft.name = "Updated"
    updatedDraft.host = "new.example"
    let updated = updatedDraft
    let disk = BlockingOutboundProxyEndpointManifestStore(
      manifest: OutboundProxyEndpointManifest(endpoints: [endpoint])
    )
    let secrets = InMemorySecretStore()
    try secrets.save(
      "old-secret",
      account: OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    let updateTask = Task {
      try await store.update(updated, password: "new-secret")
    }
    await disk.waitUntilFirstSaveStarts()

    let resolveStarted = OutboundProxyEndpointTestSignal()
    let resolveTask = Task {
      await resolveStarted.signal()
      return try await store.resolve(id: endpoint.id)
    }
    let endpointsStarted = OutboundProxyEndpointTestSignal()
    let endpointsTask = Task {
      await endpointsStarted.signal()
      return try await store.endpoints()
    }
    await resolveStarted.wait()
    await endpointsStarted.wait()
    try await Task.sleep(nanoseconds: 50_000_000)

    let suspendedSnapshot = await disk.snapshot()
    XCTAssertEqual(suspendedSnapshot.loadCount, 1)
    XCTAssertEqual(suspendedSnapshot.saveCount, 1)

    await disk.releaseFirstSave()
    _ = try await updateTask.value
    let resolved = try await resolveTask.value
    let endpoints = try await endpointsTask.value

    XCTAssertEqual(resolved.endpoint, updated)
    XCTAssertEqual(resolved.password, "new-secret")
    XCTAssertEqual(endpoints, [updated])
  }

  func testBackupExportDefaultsToMetadataOnlyAndCountsOnlyStoredAuthenticatedPasswords() async throws {
    let stored = OutboundProxyEndpoint(
      name: "Stored Password",
      kind: .http,
      host: "stored.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let missing = OutboundProxyEndpoint(
      name: "Missing Password",
      kind: .socks5,
      host: "missing.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "bob")
    )
    let unauthenticated = OutboundProxyEndpoint(
      name: "No Authentication",
      kind: .http,
      host: "public.example",
      port: 8081
    )
    let manifest = OutboundProxyEndpointManifest(
      endpoints: [stored, missing, unauthenticated]
    )
    let secrets = InMemorySecretStore()
    try secrets.save(
      "stored-secret",
      account: OutboundProxyEndpointStore.passwordAccount(for: stored.id)
    )
    try secrets.save(
      "orphaned-secret",
      account: OutboundProxyEndpointStore.passwordAccount(for: unauthenticated.id)
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: InMemoryOutboundProxyEndpointManifestStore(manifest: manifest)
    )

    let export = try await store.backupExport()

    XCTAssertEqual(export.manifest, manifest)
    XCTAssertEqual(export.passwords, [])
    XCTAssertEqual(export.omittedPasswordCount, 1)
  }

  func testBackupExportWithSecretsIncludesOnlyExistingNonblankAuthenticatedPasswords() async throws {
    let stored = OutboundProxyEndpoint(
      name: "Stored Password",
      kind: .http,
      host: "stored.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let missing = OutboundProxyEndpoint(
      name: "Missing Password",
      kind: .socks5,
      host: "missing.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "bob")
    )
    let blank = OutboundProxyEndpoint(
      name: "Blank Password",
      kind: .http,
      host: "blank.example",
      port: 8082,
      authentication: OutboundProxyAuthentication(username: "carol")
    )
    let secrets = InMemorySecretStore()
    try secrets.save(
      "stored-secret",
      account: OutboundProxyEndpointStore.passwordAccount(for: stored.id)
    )
    try secrets.save(
      "   ",
      account: OutboundProxyEndpointStore.passwordAccount(for: blank.id)
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: InMemoryOutboundProxyEndpointManifestStore(
        manifest: OutboundProxyEndpointManifest(endpoints: [stored, missing, blank])
      )
    )

    let export = try await store.backupExport(includeSecrets: true)
    let blankResolution = try await store.resolve(id: blank.id)

    XCTAssertEqual(
      export.passwords,
      [BackupOutboundProxyEndpointPassword(endpointID: stored.id, password: "stored-secret")]
    )
    XCTAssertEqual(export.omittedPasswordCount, 0)
    XCTAssertEqual(blankResolution.secretState, .missingSecret)
    XCTAssertFalse(blankResolution.isReady)
  }

  func testBackupExportManifestPlaintextNeverContainsPasswords() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let secrets = InMemorySecretStore()
    try secrets.save(
      "plaintext-must-not-contain-this",
      account: OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: InMemoryOutboundProxyEndpointManifestStore(
        manifest: OutboundProxyEndpointManifest(endpoints: [endpoint])
      )
    )

    let export = try await store.backupExport(includeSecrets: true)
    let plaintextMetadata = try JSONEncoder().encode(export.manifest)

    XCTAssertEqual(export.passwords.count, 1)
    XCTAssertFalse(
      String(decoding: plaintextMetadata, as: UTF8.self)
        .contains("plaintext-must-not-contain-this")
    )
  }

  func testMergeRestoreRemapsIdentifierAndUsesDeterministicUnicodeSafeRestoredName() async throws {
    let collidingID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let existing = OutboundProxyEndpoint(
      id: collidingID,
      name: "straße",
      kind: .http,
      host: "existing.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "existing")
    )
    let existingSuffix = OutboundProxyEndpoint(
      id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
      name: "STRASSE (restored)",
      kind: .socks5,
      host: "suffix.example",
      port: 1080
    )
    let imported = OutboundProxyEndpoint(
      id: collidingID,
      name: "STRASSE",
      kind: .socks5,
      host: "imported.example",
      port: 1081,
      authentication: OutboundProxyAuthentication(username: "restored")
    )
    let secrets = InMemorySecretStore()
    try secrets.save(
      "existing-secret",
      account: OutboundProxyEndpointStore.passwordAccount(for: existing.id)
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: InMemoryOutboundProxyEndpointManifestStore(
        manifest: OutboundProxyEndpointManifest(endpoints: [existing, existingSuffix])
      )
    )

    let result = try await store.mergeRestoreBackup(
      manifest: OutboundProxyEndpointManifest(endpoints: [imported]),
      passwords: [
        BackupOutboundProxyEndpointPassword(
          endpointID: imported.id,
          password: "restored-secret"
        )
      ]
    )

    let restoredID = try XCTUnwrap(result.idMap[imported.id])
    let endpointNames = try await store.endpoints().map(\.name)
    let restoredResolution = try await store.resolve(id: restoredID)
    let existingResolution = try await store.resolve(id: existing.id)
    XCTAssertNotEqual(restoredID, imported.id)
    XCTAssertEqual(result.importedEndpointCount, 1)
    XCTAssertEqual(result.restoredSecretCount, 1)
    XCTAssertEqual(endpointNames, ["straße", "STRASSE (restored)", "STRASSE (Restored 2)"])
    XCTAssertEqual(restoredResolution.password, "restored-secret")
    XCTAssertEqual(existingResolution.password, "existing-secret")
  }

  func testMergeRestoreAllowsAuthenticatedEndpointWithoutPasswordAsMissingSecret() async throws {
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
      name: "Missing Secret",
      kind: .http,
      host: "missing.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let secrets = InMemorySecretStore()
    let account = OutboundProxyEndpointStore.passwordAccount(for: endpoint.id)
    try secrets.save("orphaned-before-restore", account: account)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )

    let result = try await store.mergeRestoreBackup(
      manifest: OutboundProxyEndpointManifest(endpoints: [endpoint]),
      passwords: []
    )
    let resolved = try await store.resolve(id: endpoint.id)

    XCTAssertEqual(result.idMap, [endpoint.id: endpoint.id])
    XCTAssertEqual(result.restoredSecretCount, 0)
    XCTAssertNil(try secrets.load(account: account))
    XCTAssertNil(resolved.password)
    XCTAssertEqual(resolved.secretState, .missingSecret)
  }

  func testMergeRestoreRejectsDuplicateEndpointIdentifiersAndUnicodeFoldedNames() async throws {
    let duplicateID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    let duplicateIdentifiers = [
      OutboundProxyEndpoint(
        id: duplicateID,
        name: "First",
        kind: .http,
        host: "first.example",
        port: 8080
      ),
      OutboundProxyEndpoint(
        id: duplicateID,
        name: "Second",
        kind: .socks5,
        host: "second.example",
        port: 1080
      )
    ]
    let duplicateNames = [
      OutboundProxyEndpoint(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
        name: "straße",
        kind: .http,
        host: "one.example",
        port: 8080
      ),
      OutboundProxyEndpoint(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        name: "STRASSE",
        kind: .socks5,
        host: "two.example",
        port: 1080
      )
    ]
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )

    do {
      _ = try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(endpoints: duplicateIdentifiers),
        passwords: []
      )
      XCTFail("Expected duplicate endpoint identifiers to be rejected")
    } catch {
      XCTAssertEqual(
        error as? OutboundProxyEndpointStoreError,
        .invalidBackup("Endpoint manifest contains duplicate endpoint IDs.")
      )
    }

    do {
      _ = try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(endpoints: duplicateNames),
        passwords: []
      )
      XCTFail("Expected Unicode-folded duplicate endpoint names to be rejected")
    } catch {
      XCTAssertEqual(
        error as? OutboundProxyEndpointStoreError,
        .invalidBackup("Endpoint manifest contains duplicate endpoint names.")
      )
    }
  }

  func testMergeRestoreRejectsDuplicatePasswordRecords() async throws {
    let endpoint = OutboundProxyEndpoint(
      name: "Authenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )

    do {
      _ = try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(endpoints: [endpoint]),
        passwords: [
          BackupOutboundProxyEndpointPassword(endpointID: endpoint.id, password: "first"),
          BackupOutboundProxyEndpointPassword(endpointID: endpoint.id, password: "second")
        ]
      )
      XCTFail("Expected duplicate endpoint password records to be rejected")
    } catch {
      XCTAssertEqual(
        error as? OutboundProxyEndpointStoreError,
        .invalidBackup("Endpoint passwords contain duplicate endpoint IDs.")
      )
    }
  }

  func testMergeRestoreRejectsPasswordRecordsForMissingOrUnauthenticatedEndpoints() async throws {
    let unauthenticated = OutboundProxyEndpoint(
      name: "Unauthenticated",
      kind: .http,
      host: "proxy.example",
      port: 8080
    )
    let missingID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: InMemoryOutboundProxyEndpointManifestStore()
    )

    for invalidPassword in [
      BackupOutboundProxyEndpointPassword(
        endpointID: unauthenticated.id,
        password: "not-allowed"
      ),
      BackupOutboundProxyEndpointPassword(
        endpointID: missingID,
        password: "not-allowed"
      )
    ] {
      do {
        _ = try await store.mergeRestoreBackup(
          manifest: OutboundProxyEndpointManifest(endpoints: [unauthenticated]),
          passwords: [invalidPassword]
        )
        XCTFail("Expected the invalid endpoint password reference to be rejected")
      } catch {
        XCTAssertEqual(
          error as? OutboundProxyEndpointStoreError,
          .invalidBackup("Endpoint password does not reference an authenticated endpoint.")
        )
      }
    }
  }

  func testManifestDecodingRejectsMissingRequiredFields() {
    for malformedJSON in [
      "{}",
      #"{"schemaVersion":1}"#
    ] {
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          OutboundProxyEndpointManifest.self,
          from: Data(malformedJSON.utf8)
        )
      )
    }
  }

  func testStoreLoadRejectsManifestMissingRequiredFields() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OutboundProxyManifestDecodeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (index, malformedJSON) in [
      "{}",
      #"{"schemaVersion":1}"#
    ].enumerated() {
      let manifestURL = root.appendingPathComponent("malformed-\(index).json")
      try malformedJSON.write(to: manifestURL, atomically: true, encoding: .utf8)
      let store = OutboundProxyEndpointStore(
        manifestURL: manifestURL,
        secretStore: InMemorySecretStore()
      )

      await XCTAssertThrowsErrorAsync {
        try await store.endpoints()
      }
    }
  }

  func testUnsupportedEndpointManifestSchemaIsRejectedWithoutMutation() async throws {
    let existing = OutboundProxyEndpoint(
      name: "Existing",
      kind: .http,
      host: "existing.example",
      port: 8080
    )
    let disk = InMemoryOutboundProxyEndpointManifestStore(
      manifest: OutboundProxyEndpointManifest(endpoints: [existing])
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: InMemorySecretStore(),
      diskIO: disk
    )

    do {
      _ = try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(schemaVersion: 2, endpoints: []),
        passwords: []
      )
      XCTFail("Expected an unsupported endpoint manifest schema error")
    } catch {
      XCTAssertEqual(
        error as? OutboundProxyEndpointStoreError,
        .unsupportedSchema(2)
      )
    }

    let endpoints = try await store.endpoints()
    let storedManifest = await disk.currentManifest()
    XCTAssertEqual(endpoints, [existing])
    XCTAssertEqual(storedManifest, OutboundProxyEndpointManifest(endpoints: [existing]))
  }

  func testMergeRestoreManifestFailureRestoresExactMetadataAndOrphanedSecrets() async throws {
    let existing = OutboundProxyEndpoint(
      id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
      name: "Existing",
      kind: .http,
      host: "existing.example",
      port: 8080
    )
    let imported = OutboundProxyEndpoint(
      id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
      name: "Imported",
      kind: .socks5,
      host: "imported.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [existing])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    await disk.failNextSave(afterStoring: true)
    let secrets = InMemorySecretStore()
    let existingAccount = OutboundProxyEndpointStore.passwordAccount(for: existing.id)
    let importedAccount = OutboundProxyEndpointStore.passwordAccount(for: imported.id)
    try secrets.save("existing-orphan", account: existingAccount)
    try secrets.save("import-target-orphan", account: importedAccount)
    let originalSecrets = secrets.storedValues
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(endpoints: [imported]),
        passwords: [
          BackupOutboundProxyEndpointPassword(
            endpointID: imported.id,
            password: "new-secret"
          )
        ]
      )
    }

    let storedManifest = await disk.currentManifest()
    XCTAssertEqual(storedManifest, originalManifest)
    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, originalManifest.endpoints)
    XCTAssertEqual(secrets.storedValues, originalSecrets)
  }

  func testMergeRestoreResultCarriesExactRollbackSnapshotForActualRestoredIDs() async throws {
    let collidingID = UUID(uuidString: "65000000-0000-0000-0000-000000000001")!
    let existing = OutboundProxyEndpoint(
      id: collidingID,
      name: "Existing",
      kind: .http,
      host: "existing.example",
      port: 8080
    )
    let imported = OutboundProxyEndpoint(
      id: collidingID,
      name: "Imported",
      kind: .socks5,
      host: "imported.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [existing])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    let existingAccount = OutboundProxyEndpointStore.passwordAccount(for: existing.id)
    let secrets = RecordingRemappedEndpointSecretStore(
      originalAccount: existingAccount,
      originalValue: "original-id-orphan",
      remappedOrphanValue: "remapped-target-orphan"
    )
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    let result = try await store.mergeRestoreBackup(
      manifest: OutboundProxyEndpointManifest(endpoints: [imported]),
      passwords: [
        BackupOutboundProxyEndpointPassword(
          endpointID: imported.id,
          password: "restored-secret"
        )
      ]
    )

    let restoredID = try XCTUnwrap(result.idMap[imported.id])
    let restoredAccount = OutboundProxyEndpointStore.passwordAccount(for: restoredID)
    let existingSnapshot = try XCTUnwrap(
      result.rollbackSnapshot.passwords.first { $0.endpointID == existing.id }
    )
    let restoredSnapshot = try XCTUnwrap(
      result.rollbackSnapshot.passwords.first { $0.endpointID == restoredID }
    )
    XCTAssertNotEqual(restoredID, imported.id)
    XCTAssertEqual(secrets.recordedRemappedAccount, restoredAccount)
    XCTAssertEqual(result.rollbackSnapshot.manifest, originalManifest)
    XCTAssertEqual(existingSnapshot.password, "original-id-orphan")
    XCTAssertEqual(restoredSnapshot.password, "remapped-target-orphan")

    try await store.restoreRollbackSnapshot(result.rollbackSnapshot)

    let endpoints = try await store.endpoints()
    XCTAssertEqual(endpoints, originalManifest.endpoints)
    XCTAssertEqual(try secrets.load(account: existingAccount), "original-id-orphan")
    XCTAssertEqual(try secrets.load(account: restoredAccount), "remapped-target-orphan")
  }

  func testMergeRestoreSecretFailureRestoresEarlierOrphanedSecretsAndMetadata() async throws {
    let existing = OutboundProxyEndpoint(
      id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
      name: "Existing",
      kind: .http,
      host: "existing.example",
      port: 8080
    )
    let first = OutboundProxyEndpoint(
      id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
      name: "First Import",
      kind: .http,
      host: "first.example",
      port: 8081,
      authentication: OutboundProxyAuthentication(username: "first")
    )
    let second = OutboundProxyEndpoint(
      id: UUID(uuidString: "60000000-0000-0000-0000-000000000003")!,
      name: "Second Import",
      kind: .socks5,
      host: "second.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "second")
    )
    let originalManifest = OutboundProxyEndpointManifest(endpoints: [existing])
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: originalManifest)
    let secrets = InMemorySecretStore()
    try secrets.save(
      "first-orphan",
      account: OutboundProxyEndpointStore.passwordAccount(for: first.id)
    )
    try secrets.save(
      "second-orphan",
      account: OutboundProxyEndpointStore.passwordAccount(for: second.id)
    )
    secrets.rejectSaving("rejected-secret")
    let originalSecrets = secrets.storedValues
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )

    await XCTAssertThrowsErrorAsync {
      try await store.mergeRestoreBackup(
        manifest: OutboundProxyEndpointManifest(endpoints: [first, second]),
        passwords: [
          BackupOutboundProxyEndpointPassword(endpointID: first.id, password: "accepted-secret"),
          BackupOutboundProxyEndpointPassword(endpointID: second.id, password: "rejected-secret")
        ]
      )
    }

    let storedManifest = await disk.currentManifest()
    XCTAssertEqual(storedManifest, originalManifest)
    XCTAssertEqual(secrets.storedValues, originalSecrets)
  }

  func testRollbackSnapshotRemovesAddedEndpointAndRestoresOldMetadataAndSecrets() async throws {
    let authenticated = OutboundProxyEndpoint(
      id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
      name: "Authenticated",
      kind: .http,
      host: "old.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    let unauthenticated = OutboundProxyEndpoint(
      id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
      name: "Orphan Holder",
      kind: .socks5,
      host: "orphan.example",
      port: 1080
    )
    let added = OutboundProxyEndpoint(
      id: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
      name: "Added Later",
      kind: .http,
      host: "added.example",
      port: 8081,
      authentication: OutboundProxyAuthentication(username: "later")
    )
    let initialManifest = OutboundProxyEndpointManifest(
      endpoints: [authenticated, unauthenticated]
    )
    let disk = InMemoryOutboundProxyEndpointManifestStore(manifest: initialManifest)
    let secrets = InMemorySecretStore()
    let authenticatedAccount = OutboundProxyEndpointStore.passwordAccount(for: authenticated.id)
    let orphanAccount = OutboundProxyEndpointStore.passwordAccount(for: unauthenticated.id)
    let addedAccount = OutboundProxyEndpointStore.passwordAccount(for: added.id)
    try secrets.save("old-secret", account: authenticatedAccount)
    try secrets.save("old-orphan", account: orphanAccount)
    try secrets.save("added-orphan", account: addedAccount)
    let store = OutboundProxyEndpointStore(
      manifestURL: URL(fileURLWithPath: "/unused/outbound-proxies.json"),
      secretStore: secrets,
      diskIO: disk
    )
    let snapshot = try await store.rollbackSnapshot(
      additionalAffectedEndpointIDs: [added.id]
    )
    var changedAuthenticated = authenticated
    changedAuthenticated.name = "Changed"
    changedAuthenticated.host = "changed.example"

    _ = try await store.update(changedAuthenticated, password: "new-secret")
    try await store.delete(id: unauthenticated.id)
    _ = try await store.add(added, password: "added-secret")
    try await store.restoreRollbackSnapshot(snapshot)

    let endpoints = try await store.endpoints()
    let storedManifest = await disk.currentManifest()
    XCTAssertEqual(endpoints, initialManifest.endpoints)
    XCTAssertEqual(storedManifest, initialManifest)
    XCTAssertEqual(try secrets.load(account: authenticatedAccount), "old-secret")
    XCTAssertEqual(try secrets.load(account: orphanAccount), "old-orphan")
    XCTAssertEqual(try secrets.load(account: addedAccount), "added-orphan")
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
  }
}

private struct OutboundProxyEndpointDiskSnapshot: Equatable, Sendable {
  var loadCount: Int
  var saveCount: Int
}

private actor OutboundProxyEndpointTestSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isSignaled else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    isSignaled = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }

  func value() -> Bool {
    isSignaled
  }
}

private actor BlockingOutboundProxyEndpointManifestStore: OutboundProxyEndpointManifestStoring {
  private var manifest: OutboundProxyEndpointManifest?
  private var loadCount = 0
  private var saveCount = 0
  private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstSaveContinuation: CheckedContinuation<Void, Never>?
  private var shouldReleaseFirstSave = false

  init(manifest: OutboundProxyEndpointManifest? = nil) {
    self.manifest = manifest
  }

  func loadManifest(from url: URL) async throws -> OutboundProxyEndpointManifest? {
    loadCount += 1
    return manifest
  }

  func saveManifest(_ manifest: OutboundProxyEndpointManifest, to url: URL) async throws {
    saveCount += 1
    if saveCount == 1 {
      let waiters = firstSaveWaiters
      firstSaveWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { continuation in
        if shouldReleaseFirstSave {
          continuation.resume()
        } else {
          firstSaveContinuation = continuation
        }
      }
    }
    self.manifest = manifest
  }

  func waitUntilFirstSaveStarts() async {
    guard saveCount == 0 else { return }
    await withCheckedContinuation { continuation in
      firstSaveWaiters.append(continuation)
    }
  }

  func releaseFirstSave() {
    shouldReleaseFirstSave = true
    let continuation = firstSaveContinuation
    firstSaveContinuation = nil
    continuation?.resume()
  }

  func snapshot() -> OutboundProxyEndpointDiskSnapshot {
    OutboundProxyEndpointDiskSnapshot(loadCount: loadCount, saveCount: saveCount)
  }
}

private actor InMemoryOutboundProxyEndpointManifestStore: OutboundProxyEndpointManifestStoring {
  private var manifest: OutboundProxyEndpointManifest?
  private var shouldFailNextSave = false
  private var shouldStoreBeforeFailure = false

  init(manifest: OutboundProxyEndpointManifest? = nil) {
    self.manifest = manifest
  }

  func loadManifest(from url: URL) throws -> OutboundProxyEndpointManifest? {
    manifest
  }

  func saveManifest(_ manifest: OutboundProxyEndpointManifest, to url: URL) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      if shouldStoreBeforeFailure {
        shouldStoreBeforeFailure = false
        self.manifest = manifest
      }
      throw NSError(domain: "OutboundProxyEndpointManifestStoreTests", code: 1)
    }
    self.manifest = manifest
  }

  func failNextSave(afterStoring: Bool = false) {
    shouldFailNextSave = true
    shouldStoreBeforeFailure = afterStoring
  }

  func currentManifest() -> OutboundProxyEndpointManifest? {
    manifest
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

private actor ControllableProfileDiskIO: ProfileDiskStoring {
  private let fileManager = FileManager.default
  private var shouldFailNextManifestSave = false

  func failNextManifestSave() {
    shouldFailNextManifestSave = true
  }

  func loadManifest(from url: URL) throws -> ProfileManifest? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProfileManifest.self, from: Data(contentsOf: url))
  }

  func saveManifest(_ manifest: ProfileManifest, to url: URL) throws {
    if shouldFailNextManifestSave {
      shouldFailNextManifestSave = false
      throw NSError(domain: "ControllableProfileDiskIO", code: 1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try SecureFileIO.writePrivateData(try encoder.encode(manifest), to: url, fileManager: fileManager)
  }

  func importLocalConfig(from sourceURL: URL, to destinationURL: URL) throws -> String {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    try ProfileConfigValidator.validate(source)
    try SecureFileIO.writePrivateString(source, to: destinationURL, fileManager: fileManager)
    return source
  }

  func readProfileSource(atPath path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  func writeProfileSource(_ source: String, to url: URL) throws {
    try SecureFileIO.writePrivateString(source, to: url, fileManager: fileManager)
  }

  func removeProfileConfig(atPath path: String) throws {
    guard fileManager.fileExists(atPath: path) else { return }
    try fileManager.removeItem(atPath: path)
  }
}

private actor BlockingProfileManifestLoadDiskIO: ProfileDiskStoring {
  private let manifest: ProfileManifest
  private var loadStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var loadContinuation: CheckedContinuation<Void, Never>?
  private var didStartLoad = false
  private var shouldReleaseLoad = false

  init(manifest: ProfileManifest) {
    self.manifest = manifest
  }

  func waitUntilLoadStarts() async {
    guard !didStartLoad else { return }
    await withCheckedContinuation { continuation in
      loadStartedWaiters.append(continuation)
    }
  }

  func releaseLoad() {
    shouldReleaseLoad = true
    let continuation = loadContinuation
    loadContinuation = nil
    continuation?.resume()
  }

  func loadManifest(from url: URL) async throws -> ProfileManifest? {
    didStartLoad = true
    let waiters = loadStartedWaiters
    loadStartedWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      if shouldReleaseLoad {
        continuation.resume()
      } else {
        loadContinuation = continuation
      }
    }
    return manifest
  }

  func saveManifest(_ manifest: ProfileManifest, to url: URL) async throws {
    throw POSIXError(.ENOTSUP)
  }

  func importLocalConfig(from sourceURL: URL, to destinationURL: URL) async throws -> String {
    throw POSIXError(.ENOTSUP)
  }

  func readProfileSource(atPath path: String) async throws -> String {
    throw POSIXError(.ENOTSUP)
  }

  func writeProfileSource(_ source: String, to url: URL) async throws {
    throw POSIXError(.ENOTSUP)
  }

  func removeProfileConfig(atPath path: String) async throws {
    throw POSIXError(.ENOTSUP)
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

private final class RecordingRemappedEndpointSecretStore: SecretStoring, @unchecked Sendable {
  private let originalAccount: String
  private let remappedOrphanValue: String
  private var values: [String: String]
  private(set) var recordedRemappedAccount: String?

  init(
    originalAccount: String,
    originalValue: String,
    remappedOrphanValue: String
  ) {
    self.originalAccount = originalAccount
    self.remappedOrphanValue = remappedOrphanValue
    values = [originalAccount: originalValue]
  }

  func save(_ value: String, account: String) throws {
    values[account] = value
  }

  func load(account: String) throws -> String? {
    if let value = values[account] {
      return value
    }
    guard
      account != originalAccount,
      account.hasPrefix("outbound-proxy."),
      account.hasSuffix(".password")
    else {
      return nil
    }
    if let recordedRemappedAccount {
      return recordedRemappedAccount == account ? values[account] : nil
    }
    recordedRemappedAccount = account
    values[account] = remappedOrphanValue
    return remappedOrphanValue
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
