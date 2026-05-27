import Foundation
import ServiceManagement
import XCTest
@testable import ClashMax

@MainActor
final class BackupRestoreServiceTests: XCTestCase {
  private let service = BackupRestoreService()

  func testDefaultExportOmitsSubscriptionProviderAndControllerSecrets() async throws {
    let fixture = try BackupFixture()
    let secrets = InMemorySecretStore()
    let (store, _) = try await makeSubscriptionStore(paths: fixture.paths, secrets: secrets)
    let settings = makeSettings(defaults: fixture.defaults)
    settings.externalControllerSettings = ExternalControllerSettings(secret: "controller-secret")
    let preview = ProxyPreviewStore(defaults: fixture.defaults)
    let backupURL = fixture.root.appendingPathComponent("default.clashmax-backup")

    let summary = try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: settings,
      proxyPreview: preview,
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: fixture.paths),
      includeSecrets: false,
      password: nil
    )
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)

    XCTAssertEqual(summary.skippedSecretCount, 3)
    XCTAssertFalse(backupText.contains("https://example.com/sub.yaml"))
    XCTAssertFalse(backupText.contains("Bearer provider-secret"))
    XCTAssertFalse(backupText.contains("MATCH,DIRECT"))
    XCTAssertFalse(backupText.contains("controller-secret"))
  }

  func testPasswordExportRestoresSecretsAndRejectsWrongPassword() async throws {
    let source = try BackupFixture()
    let sourceSecrets = InMemorySecretStore()
    let (sourceStore, _) = try await makeSubscriptionStore(paths: source.paths, secrets: sourceSecrets)
    let sourceSettings = makeSettings(defaults: source.defaults)
    let sourcePreview = ProxyPreviewStore(defaults: source.defaults)
    let backupURL = source.root.appendingPathComponent("encrypted.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: sourceSettings,
      proxyPreview: sourcePreview,
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: true,
      password: "correct-password"
    )
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)

    XCTAssertEqual(exportSummary.restoredSecretCount, 3)
    XCTAssertFalse(backupText.contains("https://example.com/sub.yaml"))
    XCTAssertFalse(backupText.contains("Bearer provider-secret"))
    XCTAssertFalse(backupText.contains("MATCH,DIRECT"))

    let wrongPasswordFixture = try BackupFixture()
    let wrongPasswordStore = ProfileStore(paths: wrongPasswordFixture.paths, keychain: InMemorySecretStore())
    await wrongPasswordStore.waitForManifestLoad()
    await XCTAssertThrowsErrorAsync {
      try await service.restoreBackup(
        from: backupURL,
        password: "wrong-password",
        profileStore: wrongPasswordStore,
        settings: makeSettings(defaults: wrongPasswordFixture.defaults),
        proxyPreview: ProxyPreviewStore(defaults: wrongPasswordFixture.defaults),
        runtimeSnippetLibrary: await makeSnippetLibrary(paths: wrongPasswordFixture.paths)
      )
    } handler: { error in
      XCTAssertEqual(error as? BackupRestoreError, .invalidPassword)
    }

    let restore = try BackupFixture()
    let restoreSecrets = InMemorySecretStore()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: restoreSecrets)
    await restoreStore.waitForManifestLoad()
    let summary = try await service.restoreBackup(
      from: backupURL,
      password: "correct-password",
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    let restoredProfile = try XCTUnwrap(restoreStore.profiles.first)
    XCTAssertEqual(summary.restoredSecretCount, 3)
    XCTAssertEqual(restoreStore.subscriptionURLString(for: restoredProfile), "https://example.com/sub.yaml")
    XCTAssertEqual(restoredProfile.subscriptionProviderOptions.requestHeaders.first?.value, "Bearer provider-secret")
    XCTAssertEqual(restoredProfile.subscriptionProviderOptions.runtimeMergeYAML, "rules:\n  - MATCH,DIRECT\n")
  }

  func testPasswordExportEncryptsFullProfileSourcesAndRestoresOriginalYAML() async throws {
    let source = try BackupFixture()
    try credentialedProfileSource.write(to: source.localProfileURL, atomically: true, encoding: .utf8)
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let backupURL = source.root.appendingPathComponent("encrypted-sources.clashmax-backup")

    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: true,
      password: "correct-password"
    )

    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    XCTAssertFalse(backupText.contains("11111111-1111-1111-1111-111111111111"))
    XCTAssertFalse(backupText.contains("node-password"))
    XCTAssertFalse(backupText.contains("source-token"))

    let backup = try readBackup(at: backupURL)
    XCTAssertNotNil(backup.encryptedProfileSources)
    XCTAssertEqual(backup.omittedSecretSummary.totalCount, 0)
    let publicSource = try XCTUnwrap(backup.profileSources.first?.source)
    XCTAssertTrue(publicSource.contains("<redacted>"))

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    try await service.restoreBackup(
      from: backupURL,
      password: "correct-password",
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    let restoredProfile = try XCTUnwrap(restoreStore.profiles.first)
    let restoredSource = try String(contentsOfFile: restoredProfile.originalConfigPath, encoding: .utf8)
    XCTAssertTrue(restoredSource.contains("11111111-1111-1111-1111-111111111111"))
    XCTAssertTrue(restoredSource.contains("node-password"))
    XCTAssertTrue(restoredSource.contains("source-token"))
  }

  func testPasswordlessExportRedactsProfileSourceCredentialsAndRestoresRedactedYAML() async throws {
    let source = try BackupFixture()
    try credentialedProfileSource.write(to: source.localProfileURL, atomically: true, encoding: .utf8)
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let backupURL = source.root.appendingPathComponent("redacted-sources.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: false,
      password: nil
    )

    XCTAssertEqual(exportSummary.skippedSecretCount, 3)
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    XCTAssertFalse(backupText.contains("11111111-1111-1111-1111-111111111111"))
    XCTAssertFalse(backupText.contains("node-password"))
    XCTAssertFalse(backupText.contains("source-token"))

    let backup = try readBackup(at: backupURL)
    XCTAssertNil(backup.encryptedProfileSources)
    XCTAssertEqual(backup.omittedSecretSummary.profileSourceCredentialCount, 3)
    XCTAssertTrue(try XCTUnwrap(backup.profileSources.first?.source).contains("<redacted>"))

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    let restoreSummary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    let restoredProfile = try XCTUnwrap(restoreStore.profiles.first)
    let restoredSource = try String(contentsOfFile: restoredProfile.originalConfigPath, encoding: .utf8)
    XCTAssertEqual(restoreSummary.skippedSecretCount, 3)
    XCTAssertTrue(restoredSource.contains("<redacted>"))
    XCTAssertFalse(restoredSource.contains("11111111-1111-1111-1111-111111111111"))
    XCTAssertFalse(restoredSource.contains("node-password"))
    XCTAssertFalse(restoredSource.contains("source-token"))
  }

  func testRestoreWithoutPasswordUsesRedactedProfileSourcesFromEncryptedBackup() async throws {
    let source = try BackupFixture()
    try credentialedProfileSource.write(to: source.localProfileURL, atomically: true, encoding: .utf8)
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let backupURL = source.root.appendingPathComponent("encrypted-sources-without-password.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: true,
      password: "correct-password"
    )

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    let summary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    let restoredProfile = try XCTUnwrap(restoreStore.profiles.first)
    let restoredSource = try String(contentsOfFile: restoredProfile.originalConfigPath, encoding: .utf8)
    XCTAssertEqual(summary.skippedSecretCount, 3)
    XCTAssertTrue(restoredSource.contains("<redacted>"))
    XCTAssertFalse(restoredSource.contains("node-password"))
  }

  func testTamperedEncryptedProfileSourcesAreRejected() async throws {
    let source = try BackupFixture()
    try credentialedProfileSource.write(to: source.localProfileURL, atomically: true, encoding: .utf8)
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let backupURL = source.root.appendingPathComponent("tampered-sources.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: true,
      password: "correct-password"
    )

    var backup = try readBackup(at: backupURL)
    var encryptedProfileSources = try XCTUnwrap(backup.encryptedProfileSources)
    encryptedProfileSources.sealedPayload[encryptedProfileSources.sealedPayload.startIndex] ^= 0x01
    backup.encryptedProfileSources = encryptedProfileSources
    try writeBackup(backup, to: backupURL)

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    await XCTAssertThrowsErrorAsync {
      try await service.restoreBackup(
        from: backupURL,
        password: "correct-password",
        profileStore: restoreStore,
        settings: makeSettings(defaults: restore.defaults),
        proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
        runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
      )
    } handler: { error in
      XCTAssertEqual(error as? BackupRestoreError, .invalidPassword)
    }
  }

  func testMergeRestoreRemapsConflictingProfileIDAndProxySelections() async throws {
    let fixture = try BackupFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let sourceProfile = try await store.importLocalConfig(from: fixture.localProfileURL)
    let preview = ProxyPreviewStore(defaults: fixture.defaults)
    preview.previewSelections = ["Elite": "Japan"]
    preview.saveSelections(for: sourceProfile.id)
    let backupURL = fixture.root.appendingPathComponent("merge.clashmax-backup")

    try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: preview,
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: fixture.paths),
      includeSecrets: false,
      password: nil
    )
    let summary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: preview,
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: fixture.paths)
    )

    XCTAssertEqual(summary.importedProfileCount, 1)
    XCTAssertEqual(store.profiles.count, 2)
    XCTAssertEqual(Set(store.profiles.map(\.id)).count, 2)
    XCTAssertNotEqual(store.activeProfileID, sourceProfile.id)
    XCTAssertEqual(preview.previewSelections["Elite"], "Japan")
  }

  func testSettingsRestoreRegeneratesControllerSecretAndClearsAppliedSnapshot() async throws {
    let source = try BackupFixture()
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let sourceSettings = makeSettings(defaults: source.defaults)
    sourceSettings.overrides.mixedPort = 17_777
    sourceSettings.appTheme = .dark
    sourceSettings.proxyPageSettings = ProxyPageSettings(
      viewMode: .allGroups,
      sortOrder: .delay,
      nodePresentation: .list,
      showsNodeDetails: false,
      closesOldConnectionsAfterSwitch: true,
      customDelayTestURLsByGroupName: ["Elite": "https://latency.example.com/generate_204"]
    )
    sourceSettings.externalControllerSettings = ExternalControllerSettings(secret: "source-controller-secret")
    let backupURL = source.root.appendingPathComponent("settings.clashmax-backup")

    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: sourceSettings,
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: false,
      password: nil
    )

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    let restoreSettings = makeSettings(defaults: restore.defaults)
    restoreSettings.recordAppliedRuntimeSettingsSnapshot(
      AppliedRuntimeSettingsSnapshot(
        overrides: .defaultForLaunch(secret: "old-applied-secret"),
        proxyRoutingMode: .systemProxy,
        systemProxySettings: .default,
        networkExtensionRoutingSettings: .default,
        runtimeOwner: .user,
        appliedAt: Date()
      )
    )

    try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreStore,
      settings: restoreSettings,
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    XCTAssertEqual(restoreSettings.overrides.mixedPort, 17_777)
    XCTAssertEqual(restoreSettings.appTheme, .dark)
    XCTAssertEqual(restoreSettings.proxyPageSettings, sourceSettings.proxyPageSettings)
    XCTAssertNil(restoreSettings.appliedRuntimeSettingsSnapshot)
    XCTAssertNotEqual(restoreSettings.externalControllerSettings.secret, "source-controller-secret")
    XCTAssertFalse(try String(contentsOf: backupURL, encoding: .utf8).contains("source-controller-secret"))
  }

  func testRestoreWithoutPasswordImportsProfilesAndSkipsEncryptedSecrets() async throws {
    let source = try BackupFixture()
    let sourceSecrets = InMemorySecretStore()
    let (sourceStore, _) = try await makeSubscriptionStore(paths: source.paths, secrets: sourceSecrets)
    let backupURL = source.root.appendingPathComponent("skip-secrets.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: true,
      password: "correct-password"
    )

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    let summary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    let restoredProfile = try XCTUnwrap(restoreStore.profiles.first)
    XCTAssertEqual(summary.importedProfileCount, 1)
    XCTAssertEqual(summary.restoredSecretCount, 0)
    XCTAssertEqual(summary.skippedSecretCount, 3)
    XCTAssertNil(restoreStore.subscriptionURLString(for: restoredProfile))
    XCTAssertEqual(restoredProfile.subscriptionProviderOptions.requestHeaders.first?.value, "")
    XCTAssertEqual(restoredProfile.subscriptionProviderOptions.runtimeMergeYAML, "")
  }

  func testMalformedEncryptedSecretEnvelopeIsRejectedBeforeDerivation() async throws {
    let source = try BackupFixture()
    let backup = try await exportEncryptedSubscriptionBackup(in: source)
    let malformedBackups: [(String, (inout BackupEncryptedSecrets) -> Void)] = [
      ("negative-iterations", { secrets in
        secrets.iterations = -1
      }),
      ("zero-iterations", { secrets in
        secrets.iterations = 0
      }),
      ("excessive-iterations", { secrets in
        secrets.iterations = 1_000_001
      }),
      ("short-salt", { secrets in
        secrets.salt = Data(repeating: 0, count: 15)
      }),
      ("short-payload", { secrets in
        secrets.sealedPayload = Data(repeating: 0, count: 27)
      })
    ]

    for (name, mutate) in malformedBackups {
      var malformed = backup
      var encryptedSecrets = try XCTUnwrap(malformed.encryptedSecrets)
      mutate(&encryptedSecrets)
      malformed.encryptedSecrets = encryptedSecrets
      let malformedURL = source.root.appendingPathComponent("\(name).clashmax-backup")
      try writeBackup(malformed, to: malformedURL)

      XCTAssertThrowsError(try service.previewBackup(at: malformedURL), name) { error in
        self.assertInvalidBackup(error)
      }

      let restore = try BackupFixture()
      let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
      await restoreStore.waitForManifestLoad()
      await XCTAssertThrowsErrorAsync {
        try await service.restoreBackup(
          from: malformedURL,
          password: "correct-password",
          profileStore: restoreStore,
          settings: makeSettings(defaults: restore.defaults),
          proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
          runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
        )
      } handler: { error in
        self.assertInvalidBackup(error)
      }
    }
  }

  func testRestoreRejectsEncryptedHeaderSecretsMissingFromManifestBeforeMutation() async throws {
    let source = try BackupFixture()
    var backup = try await exportEncryptedSubscriptionBackup(in: source)
    let manifestProfile = try XCTUnwrap(backup.profilesManifest.profiles.first)
    let manifestIndex = try XCTUnwrap(backup.profilesManifest.profiles.firstIndex(where: { $0.id == manifestProfile.id }))
    backup.profilesManifest.profiles[manifestIndex].subscriptionProviderOptions.requestHeaders = [
      SubscriptionRequestHeader(id: UUID(), name: "Authorization", value: "")
    ]
    let malformedURL = source.root.appendingPathComponent("unknown-encrypted-header.clashmax-backup")
    try writeBackup(backup, to: malformedURL)

    let restore = try BackupFixture()
    let restoreSecrets = InMemorySecretStore()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: restoreSecrets)
    await restoreStore.waitForManifestLoad()
    let settings = makeSettings(defaults: restore.defaults)
    let settingsBefore = settings.backupSnapshot()
    let profileIDsBefore = restoreStore.profiles.map(\.id)
    let activeProfileIDBefore = restoreStore.activeProfileID

    await XCTAssertThrowsErrorAsync {
      try await service.restoreBackup(
        from: malformedURL,
        password: "correct-password",
        profileStore: restoreStore,
        settings: settings,
        proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
        runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }

    XCTAssertEqual(restoreStore.profiles.map(\.id), profileIDsBefore)
    XCTAssertEqual(restoreStore.activeProfileID, activeProfileIDBefore)
    XCTAssertEqual(settings.backupSnapshot(), settingsBefore)
    XCTAssertTrue(restoreSecrets.storedValues.isEmpty)
  }

  func testPreviewRejectsDuplicateManifestProfileIDs() async throws {
    let fixture = try BackupFixture()
    var backup = try await exportLocalBackup(in: fixture)
    backup.profilesManifest.profiles.append(try XCTUnwrap(backup.profilesManifest.profiles.first))
    let malformedURL = fixture.root.appendingPathComponent("duplicate-manifest.clashmax-backup")
    try writeBackup(backup, to: malformedURL)

    XCTAssertThrowsError(try service.previewBackup(at: malformedURL)) { error in
      self.assertInvalidBackup(error)
    }
  }

  func testPreviewRejectsDuplicateProfileSourceIDs() async throws {
    let fixture = try BackupFixture()
    var backup = try await exportLocalBackup(in: fixture)
    backup.profileSources.append(try XCTUnwrap(backup.profileSources.first))
    let malformedURL = fixture.root.appendingPathComponent("duplicate-sources.clashmax-backup")
    try writeBackup(backup, to: malformedURL)

    XCTAssertThrowsError(try service.previewBackup(at: malformedURL)) { error in
      self.assertInvalidBackup(error)
    }
  }

  func testPreviewRejectsMismatchedProfileSourceIDs() async throws {
    let fixture = try BackupFixture()
    var backup = try await exportLocalBackup(in: fixture)
    backup.profileSources[0].profileID = UUID()
    let malformedURL = fixture.root.appendingPathComponent("mismatched-source.clashmax-backup")
    try writeBackup(backup, to: malformedURL)

    XCTAssertThrowsError(try service.previewBackup(at: malformedURL)) { error in
      self.assertInvalidBackup(error)
    }
  }

  func testProfileStoreRejectsDuplicateBackupSourceIDsWithoutTrapping() async throws {
    let fixture = try BackupFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await store.waitForManifestLoad()
    let profileID = UUID()
    let profile = makeBackupProfile(id: profileID)
    let source = BackupProfileSource(
      profileID: profileID,
      fileName: "\(profileID.uuidString).yaml",
      source: validProfileSource
    )

    await XCTAssertThrowsErrorAsync {
      try await store.mergeRestoreBackup(
        manifest: ProfileManifest(profiles: [profile], activeProfileID: profileID),
        profileSources: [source, source],
        secrets: nil
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }
  }

  func testProfileStoreRejectsDuplicateBackupHeaderIDsWithoutTrapping() async throws {
    let fixture = try BackupFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await store.waitForManifestLoad()
    let profileID = UUID()
    let headerID = UUID()
    let profile = makeBackupProfile(
      id: profileID,
      source: .subscription(id: profileID),
      requestHeaders: [
        SubscriptionRequestHeader(id: headerID, name: "Authorization", value: "")
      ]
    )
    let source = BackupProfileSource(
      profileID: profileID,
      fileName: "\(profileID.uuidString).yaml",
      source: validProfileSource
    )
    let secrets = BackupSecretsBundle(
      subscriptions: [
        BackupSubscriptionSecrets(
          profileID: profileID,
          subscriptionURL: nil,
          requestHeaders: [
            BackupRequestHeaderSecret(headerID: headerID, value: "Bearer one"),
            BackupRequestHeaderSecret(headerID: headerID, value: "Bearer two")
          ],
          runtimeMergeYAML: nil
        )
      ]
    )

    await XCTAssertThrowsErrorAsync {
      try await store.mergeRestoreBackup(
        manifest: ProfileManifest(profiles: [profile], activeProfileID: profileID),
        profileSources: [source],
        secrets: secrets
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }
  }

  func testProfileStoreRejectsUnknownBackupHeaderIDsWithoutWritingHiddenSecrets() async throws {
    let fixture = try BackupFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    await store.waitForManifestLoad()
    let profileID = UUID()
    let headerID = UUID()
    let unknownHeaderID = UUID()
    let profile = makeBackupProfile(
      id: profileID,
      source: .subscription(id: profileID),
      requestHeaders: [
        SubscriptionRequestHeader(id: headerID, name: "Authorization", value: "")
      ]
    )
    let source = BackupProfileSource(
      profileID: profileID,
      fileName: "\(profileID.uuidString).yaml",
      source: validProfileSource
    )
    let secretsBundle = BackupSecretsBundle(
      subscriptions: [
        BackupSubscriptionSecrets(
          profileID: profileID,
          subscriptionURL: nil,
          requestHeaders: [
            BackupRequestHeaderSecret(headerID: unknownHeaderID, value: "Bearer hidden")
          ],
          runtimeMergeYAML: nil
        )
      ]
    )

    await XCTAssertThrowsErrorAsync {
      try await store.mergeRestoreBackup(
        manifest: ProfileManifest(profiles: [profile], activeProfileID: profileID),
        profileSources: [source],
        secrets: secretsBundle
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }

    XCTAssertFalse(secrets.storedValues.values.contains("Bearer hidden"))
  }

  func testRuntimeSnippetLibraryExportsAndRestoresWithProfileIDRemapping() async throws {
    let fixture = try BackupFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let sourceProfile = try await store.importLocalConfig(from: fixture.localProfileURL)
    let snippetLibrary = await makeSnippetLibrary(paths: fixture.paths)
    let boundSnippet = RuntimeSnippet(
      name: "Bound Rule",
      binding: .profiles([sourceProfile.id]),
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "snippet.example", policy: "DIRECT")
          ]
        )
      )
    )
    let globalSnippet = RuntimeSnippet(
      name: "Global DNS",
      payload: .dnsPatch(
        TunDNSSettings(
          respectRules: true,
          nameserver: ["https://snippet-private.example/dns-query"]
        )
      )
    )
    try await snippetLibrary.saveSnippet(boundSnippet)
    try await snippetLibrary.saveSnippet(globalSnippet)
    let backupURL = fixture.root.appendingPathComponent("snippets.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: snippetLibrary,
      includeSecrets: true,
      password: "correct-password"
    )
    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    let backup = try readBackup(at: backupURL)
    XCTAssertEqual(exportSummary.restoredSecretCount, 2)
    XCTAssertNil(backup.runtimeSnippets)
    XCTAssertNotNil(backup.encryptedRuntimeSnippets)
    XCTAssertFalse(backupText.contains("\"runtimeSnippets\""))
    XCTAssertFalse(backupText.contains("Bound Rule"))
    XCTAssertFalse(backupText.contains("snippet.example"))
    XCTAssertFalse(backupText.contains("snippet-private.example"))

    try await snippetLibrary.deleteSnippet(id: boundSnippet.id)
    try await snippetLibrary.deleteSnippet(id: globalSnippet.id)
    try await snippetLibrary.saveSnippet(
      RuntimeSnippet(
        name: "Local Only",
        payload: .rules(RuleOverlaySettings(enabled: true))
      )
    )
    try await service.restoreBackup(
      from: backupURL,
      password: "correct-password",
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: snippetLibrary
    )

    let restoredProfileID = try XCTUnwrap(store.profiles.map(\.id).first { $0 != sourceProfile.id })
    let restoredBoundSnippet = try XCTUnwrap(snippetLibrary.snippets.first { $0.id == boundSnippet.id })
    let restoredGlobalSnippet = try XCTUnwrap(snippetLibrary.snippets.first { $0.id == globalSnippet.id })
    XCTAssertFalse(snippetLibrary.snippets.contains { $0.name == "Local Only" })
    XCTAssertEqual(restoredBoundSnippet.binding.profileIDs, [restoredProfileID])
    XCTAssertNotEqual(restoredBoundSnippet.binding.profileIDs, [sourceProfile.id])
    XCTAssertEqual(restoredGlobalSnippet.binding, .allProfiles)
  }

  func testPasswordlessExportOmitsRuntimeSnippetsAndRestoreLeavesLocalLibraryUntouched() async throws {
    let fixture = try BackupFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: fixture.localProfileURL)
    let snippetLibrary = await makeSnippetLibrary(paths: fixture.paths)
    let privateSnippet = RuntimeSnippet(
      name: "Private DNS",
      payload: .dnsPatch(
        TunDNSSettings(
          nameserver: ["https://private.example/dns-query"],
          hosts: ["internal.corp": "10.0.0.10"]
        )
      )
    )
    try await snippetLibrary.saveSnippet(privateSnippet)
    let backupURL = fixture.root.appendingPathComponent("snippets-omitted.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: snippetLibrary,
      includeSecrets: false,
      password: nil
    )

    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    let backup = try readBackup(at: backupURL)
    XCTAssertEqual(exportSummary.skippedSecretCount, 1)
    XCTAssertNil(backup.runtimeSnippets)
    XCTAssertNil(backup.encryptedRuntimeSnippets)
    XCTAssertEqual(backup.omittedSecretSummary.runtimeSnippetCount, 1)
    XCTAssertFalse(backupText.contains("Private DNS"))
    XCTAssertFalse(backupText.contains("private.example"))
    XCTAssertFalse(backupText.contains("internal.corp"))

    try await snippetLibrary.deleteSnippet(id: privateSnippet.id)
    let localSnippet = RuntimeSnippet(
      name: "Local Runtime",
      payload: .rules(RuleOverlaySettings(enabled: true))
    )
    try await snippetLibrary.saveSnippet(localSnippet)
    let restoreSummary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: snippetLibrary
    )

    XCTAssertEqual(restoreSummary.skippedSecretCount, 1)
    XCTAssertEqual(snippetLibrary.snippets.map(\.id), [localSnippet.id])
  }

  func testInvalidRuntimeSnippetBackupIsRejectedBeforeRestoreMutatesState() async throws {
    let source = try BackupFixture()
    var backup = try await exportLocalBackup(in: source)
    backup.runtimeSnippets = [
      RuntimeSnippet(
        name: " ",
        payload: .rules(
          RuleOverlaySettings(
            enabled: true,
            prependRules: [
              ManagedRuleOverlayRule(kind: .domainSuffix, value: "bad.example", policy: "DIRECT")
            ]
          )
        )
      )
    ]
    let backupURL = source.root.appendingPathComponent("invalid-snippet.clashmax-backup")
    try writeBackup(backup, to: backupURL)

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    let existingProfile = try await restoreStore.importLocalConfig(from: restore.localProfileURL)
    let settings = makeSettings(defaults: restore.defaults)
    settings.appTheme = .dark
    let preview = ProxyPreviewStore(defaults: restore.defaults)
    preview.previewSelections = ["Elite": "Japan"]
    preview.saveSelections(for: existingProfile.id)
    let snippetLibrary = await makeSnippetLibrary(paths: restore.paths)
    let localSnippet = RuntimeSnippet(
      name: "Local Runtime",
      payload: .dnsPatch(TunDNSSettings(respectRules: true))
    )
    try await snippetLibrary.saveSnippet(localSnippet)
    let profileIDsBefore = restoreStore.profiles.map(\.id)
    let activeProfileIDBefore = restoreStore.activeProfileID
    let settingsBefore = settings.backupSnapshot()
    let selectionsBefore = preview.backupSelections()
    let snippetsBefore = snippetLibrary.snippets

    await XCTAssertThrowsErrorAsync {
      try await service.restoreBackup(
        from: backupURL,
        password: nil,
        profileStore: restoreStore,
        settings: settings,
        proxyPreview: preview,
        runtimeSnippetLibrary: snippetLibrary
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }

    XCTAssertEqual(restoreStore.profiles.map(\.id), profileIDsBefore)
    XCTAssertEqual(restoreStore.activeProfileID, activeProfileIDBefore)
    XCTAssertEqual(settings.backupSnapshot(), settingsBefore)
    XCTAssertEqual(preview.backupSelections(), selectionsBefore)
    XCTAssertEqual(snippetLibrary.snippets, snippetsBefore)

    let reloadedLibrary = RuntimeSnippetLibraryStore(paths: restore.paths)
    await reloadedLibrary.waitForLoad()
    XCTAssertEqual(reloadedLibrary.snippets, snippetsBefore)
  }

  func testRuntimeSnippetWriteFailureRollsBackRestoreMutations() async throws {
    let source = try BackupFixture()
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceStore.importLocalConfig(from: source.localProfileURL)
    let sourceSnippetLibrary = await makeSnippetLibrary(paths: source.paths)
    try await sourceSnippetLibrary.saveSnippet(
      RuntimeSnippet(
        name: "Source Runtime",
        payload: .dnsPatch(TunDNSSettings(respectRules: true))
      )
    )
    let backupURL = source.root.appendingPathComponent("snippet-write-failure.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: sourceSnippetLibrary,
      includeSecrets: true,
      password: "correct-password"
    )

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    let existingProfile = try await restoreStore.importLocalConfig(from: restore.localProfileURL)
    let settings = makeSettings(defaults: restore.defaults)
    settings.appTheme = .dark
    settings.overrides.mixedPort = 18_001
    let preview = ProxyPreviewStore(defaults: restore.defaults)
    preview.previewSelections = ["Elite": "Japan"]
    preview.saveSelections(for: existingProfile.id)
    let seedSnippetLibrary = await makeSnippetLibrary(paths: restore.paths)
    let localSnippet = RuntimeSnippet(
      name: "Local Runtime",
      payload: .dnsPatch(TunDNSSettings(respectRules: true))
    )
    try await seedSnippetLibrary.saveSnippet(localSnippet)
    let failingSnippetLibrary = RuntimeSnippetLibraryStore(
      paths: restore.paths,
      diskIO: FailingRuntimeSnippetLibraryDiskIO()
    )
    await failingSnippetLibrary.waitForLoad()

    let profileIDsBefore = restoreStore.profiles.map(\.id)
    let activeProfileIDBefore = restoreStore.activeProfileID
    let profileSourceBefore = try String(contentsOfFile: existingProfile.originalConfigPath, encoding: .utf8)
    let settingsBefore = settings.backupSnapshot()
    let selectionsBefore = preview.backupSelections()
    let previewSelectionsBefore = preview.previewSelections
    let snippetsBefore = failingSnippetLibrary.snippets

    await XCTAssertThrowsErrorAsync {
      try await service.restoreBackup(
        from: backupURL,
        password: "correct-password",
        profileStore: restoreStore,
        settings: settings,
        proxyPreview: preview,
        runtimeSnippetLibrary: failingSnippetLibrary
      )
    } handler: { _ in }

    XCTAssertEqual(restoreStore.profiles.map(\.id), profileIDsBefore)
    XCTAssertEqual(restoreStore.activeProfileID, activeProfileIDBefore)
    XCTAssertEqual(try String(contentsOfFile: existingProfile.originalConfigPath, encoding: .utf8), profileSourceBefore)
    XCTAssertEqual(settings.backupSnapshot(), settingsBefore)
    XCTAssertEqual(preview.backupSelections(), selectionsBefore)
    XCTAssertEqual(preview.previewSelections, previewSelectionsBefore)
    XCTAssertEqual(failingSnippetLibrary.snippets, snippetsBefore)

    let reloadedLibrary = RuntimeSnippetLibraryStore(paths: restore.paths)
    await reloadedLibrary.waitForLoad()
    XCTAssertEqual(reloadedLibrary.snippets, snippetsBefore)
  }

  private func makeSubscriptionStore(
    paths: RuntimePaths,
    secrets: InMemorySecretStore
  ) async throws -> (ProfileStore, Profile) {
    let store = ProfileStore(paths: paths, keychain: secrets)
    let recorder = URLProtocolRecorder(
      responseBody: """
      proxies:
        - { name: Japan, type: direct }
      proxy-groups:
        - { name: Elite, type: select, proxies: [Japan, DIRECT] }
      rules:
        - MATCH,Elite
      """
    )
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub.yaml")!,
      session: URLSession(configuration: recorder.configuration)
    )
    let header = SubscriptionRequestHeader(name: "Authorization", value: "Bearer provider-secret")
    let options = SubscriptionProviderOptions(
      runtimeMergeYAML: "rules:\n  - MATCH,DIRECT\n",
      requestHeaders: [header]
    )
    try await store.updateSubscriptionProviderOptions(profile, options: options)
    return (store, try XCTUnwrap(store.profiles.first))
  }

  private func exportLocalBackup(in fixture: BackupFixture) async throws -> ClashMaxBackupFile {
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    _ = try await store.importLocalConfig(from: fixture.localProfileURL)
    let backupURL = fixture.root.appendingPathComponent("valid-\(UUID().uuidString).clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: fixture.paths),
      includeSecrets: false,
      password: nil
    )
    return try readBackup(at: backupURL)
  }

  private func exportEncryptedSubscriptionBackup(
    in fixture: BackupFixture,
    password: String = "correct-password"
  ) async throws -> ClashMaxBackupFile {
    let secrets = InMemorySecretStore()
    let (store, _) = try await makeSubscriptionStore(paths: fixture.paths, secrets: secrets)
    let backupURL = fixture.root.appendingPathComponent("encrypted-\(UUID().uuidString).clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: store,
      settings: makeSettings(defaults: fixture.defaults),
      proxyPreview: ProxyPreviewStore(defaults: fixture.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: fixture.paths),
      includeSecrets: true,
      password: password
    )
    return try readBackup(at: backupURL)
  }

  private func makeSnippetLibrary(paths: RuntimePaths) async -> RuntimeSnippetLibraryStore {
    let store = RuntimeSnippetLibraryStore(paths: paths)
    await store.waitForLoad()
    return store
  }

  private func makeBackupProfile(
    id: Profile.ID,
    source: ProfileSource = .localFile(originalPath: nil),
    requestHeaders: [SubscriptionRequestHeader] = []
  ) -> Profile {
    Profile(
      id: id,
      name: "Backup",
      source: source,
      originalConfigPath: "Profiles/\(id.uuidString).yaml",
      subscriptionProviderOptions: SubscriptionProviderOptions(requestHeaders: requestHeaders),
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
  }

  private var validProfileSource: String {
    """
    proxies:
      - { name: Japan, type: direct }
    proxy-groups:
      - { name: Elite, type: select, proxies: [Japan, DIRECT] }
    rules:
      - MATCH,Elite
    """
  }

  private var credentialedProfileSource: String {
    """
    proxies:
      - name: Secret Node
        type: hysteria2
        server: proxy.example.com
        port: 443
        password: node-password
        uuid: 11111111-1111-1111-1111-111111111111
    proxy-providers:
      Remote:
        type: http
        url: https://provider.example.com/sub.yaml?token=source-token
        interval: 3600
    proxy-groups:
      - name: Elite
        type: select
        proxies:
          - Secret Node
          - DIRECT
    rules:
      - MATCH,Elite
    """
  }

  private func readBackup(at url: URL) throws -> ClashMaxBackupFile {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ClashMaxBackupFile.self, from: Data(contentsOf: url))
  }

  private func writeBackup(_ backup: ClashMaxBackupFile, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(backup).write(to: url, options: [.atomic])
  }

  private func assertInvalidBackup(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    guard case .invalidBackup = error as? BackupRestoreError else {
      return XCTFail("Expected invalid backup error, got \(error).", file: file, line: line)
    }
  }

  private func makeSettings(defaults: UserDefaults) -> PersistedSettingsStore {
    PersistedSettingsStore(loginItemService: BackupLoginItemService(), defaults: defaults)
  }
}

private struct BackupFixture {
  let root: URL
  let paths: RuntimePaths
  let defaults: UserDefaults
  let localProfileURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxBackupTests-\(UUID().uuidString)", isDirectory: true)
    paths = RuntimePaths(
      appSupport: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
      profiles: root.appendingPathComponent("ApplicationSupport/Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("ApplicationSupport/Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("ApplicationSupport/Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("ApplicationSupport/Logs", isDirectory: true)
    )
    try paths.prepareDirectories()
    defaults = UserDefaults(suiteName: "ClashMaxBackupTests-\(UUID().uuidString)")!
    localProfileURL = root.appendingPathComponent("local.yaml")
    try """
    proxies:
      - { name: Japan, type: direct }
    proxy-groups:
      - { name: Elite, type: select, proxies: [Japan, DIRECT] }
    rules:
      - MATCH,Elite
    """.write(to: localProfileURL, atomically: true, encoding: .utf8)
  }
}

private final class BackupLoginItemService: LoginItemManaging {
  var status: SMAppService.Status = .notRegistered

  func register() throws {
    status = .enabled
  }

  func unregister() async throws {
    status = .notRegistered
  }

  func openSystemSettingsLoginItems() {}
}

private struct FailingRuntimeSnippetLibraryDiskIO: RuntimeSnippetLibraryDiskIOProviding {
  private let base = RuntimeSnippetLibraryDiskIO()

  func load(from url: URL) async throws -> [RuntimeSnippet] {
    try await base.load(from: url)
  }

  func save(_ snippets: [RuntimeSnippet], to url: URL) async throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}
