import Foundation
import ServiceManagement
import XCTest
@testable import ClashMax

@MainActor
final class BackupRestoreServiceTests: XCTestCase {
  private let service = BackupRestoreService()

  func testSchema2ExportWritesEndpointManifestAndSchema1WithoutItStillRestores() async throws {
    let source = try BackupFixture()
    let sourceStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    await sourceStore.waitForManifestLoad()
    let backupURL = source.root.appendingPathComponent("schema-2.clashmax-backup")

    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      includeSecrets: false,
      password: nil
    )

    let encodedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
    )
    XCTAssertEqual(encodedObject["schemaVersion"] as? Int, 2)
    XCTAssertNotNil(encodedObject["outboundProxyManifest"])

    var schema1Object = encodedObject
    schema1Object["schemaVersion"] = 1
    schema1Object.removeValue(forKey: "outboundProxyManifest")
    if var omittedSummary = schema1Object["omittedSecretSummary"] as? [String: Any] {
      omittedSummary.removeValue(forKey: "outboundProxyPasswordCount")
      schema1Object["omittedSecretSummary"] = omittedSummary
    }
    let schema1URL = source.root.appendingPathComponent("schema-1.clashmax-backup")
    try JSONSerialization.data(
      withJSONObject: schema1Object,
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: schema1URL, options: [.atomic])

    let preview = try service.previewBackup(at: schema1URL)
    XCTAssertEqual(preview.profileCount, 0)

    let restore = try BackupFixture()
    let restoreStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreStore.waitForManifestLoad()
    let summary = try await service.restoreBackup(
      from: schema1URL,
      password: nil,
      profileStore: restoreStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths)
    )

    XCTAssertEqual(summary.importedProfileCount, 0)
    XCTAssertTrue(restoreStore.profiles.isEmpty)

    var futureSchemaObject = encodedObject
    futureSchemaObject["schemaVersion"] = 3
    let futureSchemaURL = source.root.appendingPathComponent("schema-3.clashmax-backup")
    try JSONSerialization.data(
      withJSONObject: futureSchemaObject,
      options: [.prettyPrinted, .sortedKeys]
    ).write(to: futureSchemaURL, options: [.atomic])
    XCTAssertThrowsError(try service.previewBackup(at: futureSchemaURL)) { error in
      XCTAssertEqual(error as? BackupRestoreError, .unsupportedSchema(3))
    }
  }

  func testLegacySecretJSONDefaultsEndpointPasswordFieldsToEmpty() throws {
    let summary = try JSONDecoder().decode(
      BackupSecretSummary.self,
      from: Data(
        """
        {
          "subscriptionURLCount": 1,
          "requestHeaderValueCount": 2,
          "runtimeMergeYAMLCount": 3,
          "profileSourceCredentialCount": 4,
          "runtimeSnippetCount": 5
        }
        """.utf8
      )
    )
    let secrets = try JSONDecoder().decode(
      BackupSecretsBundle.self,
      from: Data(#"{"subscriptions":[]}"#.utf8)
    )

    XCTAssertEqual(summary.outboundProxyPasswordCount, 0)
    XCTAssertEqual(summary.totalCount, 15)
    XCTAssertEqual(secrets.outboundProxyPasswords, [])
  }

  func testPasswordlessEndpointExportIsRedactedCountedAndRestoresMissingSecret() async throws {
    let source = try BackupFixture()
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    await sourceProfileStore.waitForManifestLoad()
    let sourceEndpointSecrets = InMemorySecretStore()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: sourceEndpointSecrets
    )
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
      name: "Authenticated Endpoint",
      kind: .http,
      host: "auth.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    _ = try await sourceEndpointStore.add(endpoint, password: "endpoint-password")
    let backupURL = source.root.appendingPathComponent("endpoint-redacted.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: false,
      password: nil
    )

    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    let backup = try readBackup(at: backupURL)
    let preview = try service.previewBackup(at: backupURL)
    XCTAssertFalse(backupText.contains("endpoint-password"))
    XCTAssertEqual(backup.outboundProxyManifest.endpoints, [endpoint])
    XCTAssertNil(backup.encryptedSecrets)
    XCTAssertEqual(backup.omittedSecretSummary.outboundProxyPasswordCount, 1)
    XCTAssertEqual(backup.omittedSecretSummary.totalCount, 1)
    XCTAssertEqual(exportSummary.importedEndpointCount, 1)
    XCTAssertEqual(exportSummary.skippedSecretCount, 1)
    XCTAssertEqual(preview.endpointCount, 1)

    let restore = try BackupFixture()
    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreProfileStore.waitForManifestLoad()
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let restoreSummary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreProfileStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths),
      outboundProxyStore: restoreEndpointStore
    )

    let resolved = try await restoreEndpointStore.resolve(id: endpoint.id)
    XCTAssertEqual(restoreSummary.importedEndpointCount, 1)
    XCTAssertEqual(restoreSummary.restoredSecretCount, 0)
    XCTAssertEqual(restoreSummary.skippedSecretCount, 1)
    XCTAssertNil(resolved.password)
    XCTAssertEqual(resolved.secretState, .missingSecret)
  }

  func testPasswordEndpointExportEncryptsPasswordAndRestoresIt() async throws {
    let source = try BackupFixture()
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    await sourceProfileStore.waitForManifestLoad()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!,
      name: "Encrypted Endpoint",
      kind: .socks5,
      host: "encrypted.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "bob")
    )
    _ = try await sourceEndpointStore.add(endpoint, password: "encrypted-endpoint-password")
    let backupURL = source.root.appendingPathComponent("endpoint-encrypted.clashmax-backup")

    let exportSummary = try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: true,
      password: "correct-password"
    )

    let backupText = try String(contentsOf: backupURL, encoding: .utf8)
    let backup = try readBackup(at: backupURL)
    XCTAssertFalse(backupText.contains("encrypted-endpoint-password"))
    XCTAssertEqual(backup.encryptedSecrets?.secretCount, 1)
    XCTAssertEqual(backup.omittedSecretSummary.outboundProxyPasswordCount, 0)
    XCTAssertEqual(exportSummary.importedEndpointCount, 1)
    XCTAssertEqual(exportSummary.restoredSecretCount, 1)

    let restore = try BackupFixture()
    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreProfileStore.waitForManifestLoad()
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let restoreSummary = try await service.restoreBackup(
      from: backupURL,
      password: "correct-password",
      profileStore: restoreProfileStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths),
      outboundProxyStore: restoreEndpointStore
    )

    let resolved = try await restoreEndpointStore.resolve(id: endpoint.id)
    XCTAssertEqual(restoreSummary.importedEndpointCount, 1)
    XCTAssertEqual(restoreSummary.restoredSecretCount, 1)
    XCTAssertEqual(resolved.password, "encrypted-endpoint-password")
    XCTAssertEqual(resolved.secretState, .ready)

    let skippedRestore = try BackupFixture()
    let skippedProfileStore = ProfileStore(
      paths: skippedRestore.paths,
      keychain: InMemorySecretStore()
    )
    await skippedProfileStore.waitForManifestLoad()
    let skippedEndpointStore = OutboundProxyEndpointStore(
      manifestURL: skippedRestore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let skippedSummary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: skippedProfileStore,
      settings: makeSettings(defaults: skippedRestore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: skippedRestore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: skippedRestore.paths),
      outboundProxyStore: skippedEndpointStore
    )
    let skippedResolved = try await skippedEndpointStore.resolve(id: endpoint.id)
    XCTAssertEqual(skippedSummary.restoredSecretCount, 0)
    XCTAssertEqual(skippedSummary.skippedSecretCount, 1)
    XCTAssertNil(skippedResolved.password)
    XCTAssertEqual(skippedResolved.secretState, .missingSecret)
  }

  func testRestoreRemapsEndpointAndProfileCollisionsBeforeRewritingManualAndUpstreamReferences() async throws {
    let manualEndpointID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
    let upstreamEndpointID = UUID(uuidString: "83000000-0000-0000-0000-000000000002")!
    let source = try BackupFixture()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    _ = try await sourceEndpointStore.add(
      OutboundProxyEndpoint(
        id: manualEndpointID,
        name: "Source Manual Endpoint",
        kind: .http,
        host: "manual.source.example",
        port: 8080
      ),
      password: nil
    )
    _ = try await sourceEndpointStore.add(
      OutboundProxyEndpoint(
        id: upstreamEndpointID,
        name: "Source Upstream Endpoint",
        kind: .socks5,
        host: "upstream.source.example",
        port: 1080
      ),
      password: nil
    )
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceProfileStore.addManualProxyProfile(
      name: "Manual Source",
      endpointID: manualEndpointID
    )
    let sourceUpstreamProfile = try await sourceProfileStore.importLocalConfig(from: source.localProfileURL)
    try await sourceProfileStore.updateUpstreamEndpoint(
      for: sourceUpstreamProfile,
      endpointID: upstreamEndpointID
    )
    let backupURL = source.root.appendingPathComponent("two-level-remap.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: false,
      password: nil
    )

    let restore = try BackupFixture()
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    _ = try await restoreEndpointStore.add(
      OutboundProxyEndpoint(
        id: manualEndpointID,
        name: "Existing Manual ID",
        kind: .http,
        host: "manual.existing.example",
        port: 8081
      ),
      password: nil
    )
    _ = try await restoreEndpointStore.add(
      OutboundProxyEndpoint(
        id: upstreamEndpointID,
        name: "Existing Upstream ID",
        kind: .socks5,
        host: "upstream.existing.example",
        port: 1081
      ),
      password: nil
    )
    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    let existingProfile = try await restoreProfileStore.importLocalConfig(from: restore.localProfileURL)

    var collidingBackup = try readBackup(at: backupURL)
    let manualIndex = try XCTUnwrap(
      collidingBackup.profilesManifest.profiles.firstIndex(where: {
        if case .manualProxy = $0.source { return true }
        return false
      })
    )
    let originalManualProfileID = collidingBackup.profilesManifest.profiles[manualIndex].id
    collidingBackup.profilesManifest.profiles[manualIndex].id = existingProfile.id
    let manualSourceIndex = try XCTUnwrap(
      collidingBackup.profileSources.firstIndex(where: { $0.profileID == originalManualProfileID })
    )
    collidingBackup.profileSources[manualSourceIndex].profileID = existingProfile.id
    if collidingBackup.profilesManifest.activeProfileID == originalManualProfileID {
      collidingBackup.profilesManifest.activeProfileID = existingProfile.id
    }
    try writeBackup(collidingBackup, to: backupURL)

    let summary = try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreProfileStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths),
      outboundProxyStore: restoreEndpointStore
    )

    let endpoints = try await restoreEndpointStore.endpoints()
    let restoredManualEndpoint = try XCTUnwrap(
      endpoints.first(where: { $0.host == "manual.source.example" })
    )
    let restoredUpstreamEndpoint = try XCTUnwrap(
      endpoints.first(where: { $0.host == "upstream.source.example" })
    )
    let restoredManualProfile = try XCTUnwrap(
      restoreProfileStore.profiles.first(where: {
        if case .manualProxy = $0.source { return true }
        return false
      })
    )
    let restoredUpstreamProfile = try XCTUnwrap(
      restoreProfileStore.profiles.first(where: {
        $0.id != existingProfile.id && $0.upstreamEndpointID != nil
      })
    )

    XCTAssertEqual(summary.importedEndpointCount, 2)
    XCTAssertEqual(summary.importedProfileCount, 2)
    XCTAssertNotEqual(restoredManualEndpoint.id, manualEndpointID)
    XCTAssertNotEqual(restoredUpstreamEndpoint.id, upstreamEndpointID)
    XCTAssertNotEqual(restoredManualProfile.id, existingProfile.id)
    XCTAssertEqual(
      restoredManualProfile.source,
      .manualProxy(endpointID: restoredManualEndpoint.id)
    )
    XCTAssertEqual(restoredUpstreamProfile.upstreamEndpointID, restoredUpstreamEndpoint.id)
  }

  func testManualProfileExportNeverReadsTamperedPayloadAndRestoreAlwaysWritesCanonicalMarker() async throws {
    let endpointID = UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
    let source = try BackupFixture()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    _ = try await sourceEndpointStore.add(
      OutboundProxyEndpoint(
        id: endpointID,
        name: "Manual Endpoint",
        kind: .http,
        host: "manual.example",
        port: 8080
      ),
      password: nil
    )
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    let manualProfile = try await sourceProfileStore.addManualProxyProfile(
      name: "Manual",
      endpointID: endpointID
    )
    try "password: tampered-manual-file-secret\n".write(
      toFile: manualProfile.originalConfigPath,
      atomically: true,
      encoding: .utf8
    )
    let backupURL = source.root.appendingPathComponent("manual-marker.clashmax-backup")

    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: false,
      password: nil
    )

    var backup = try readBackup(at: backupURL)
    let manualSourceIndex = try XCTUnwrap(
      backup.profileSources.firstIndex(where: { $0.profileID == manualProfile.id })
    )
    XCTAssertFalse(
      try String(contentsOf: backupURL, encoding: .utf8)
        .contains("tampered-manual-file-secret")
    )
    XCTAssertEqual(backup.profileSources[manualSourceIndex].source, canonicalManualProxyMarker)

    backup.profileSources[manualSourceIndex].source = "password: malicious-backup-payload\n"
    try writeBackup(backup, to: backupURL)

    let restore = try BackupFixture()
    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreProfileStore.waitForManifestLoad()
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    try await service.restoreBackup(
      from: backupURL,
      password: nil,
      profileStore: restoreProfileStore,
      settings: makeSettings(defaults: restore.defaults),
      proxyPreview: ProxyPreviewStore(defaults: restore.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: restore.paths),
      outboundProxyStore: restoreEndpointStore
    )

    let restoredManualProfile = try XCTUnwrap(restoreProfileStore.profiles.first)
    XCTAssertEqual(
      try String(contentsOfFile: restoredManualProfile.originalConfigPath, encoding: .utf8),
      canonicalManualProxyMarker
    )
    XCTAssertFalse(
      try String(contentsOfFile: restoredManualProfile.originalConfigPath, encoding: .utf8)
        .contains("malicious-backup-payload")
    )
  }

  func testInvalidEndpointMetadataDuplicateIDsAndUnicodeNamesAreRejectedBeforeMutation() async throws {
    let source = try BackupFixture()
    let validBackup = try await exportLocalBackup(in: source)
    let duplicateID = UUID(uuidString: "85000000-0000-0000-0000-000000000001")!
    let cases: [(String, [OutboundProxyEndpoint])] = [
      (
        "invalid-port",
        [
          OutboundProxyEndpoint(
            name: "Invalid Port",
            kind: .http,
            host: "invalid.example",
            port: 0
          )
        ]
      ),
      (
        "duplicate-id",
        [
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
      ),
      (
        "unicode-name",
        [
          OutboundProxyEndpoint(
            name: "straße",
            kind: .http,
            host: "one.example",
            port: 8080
          ),
          OutboundProxyEndpoint(
            name: "STRASSE",
            kind: .socks5,
            host: "two.example",
            port: 1080
          )
        ]
      )
    ]

    for (name, endpoints) in cases {
      var malformed = validBackup
      malformed.outboundProxyManifest = OutboundProxyEndpointManifest(endpoints: endpoints)
      try await assertRestoreRejectsBeforeMutation(
        malformed,
        password: nil,
        fileName: "\(name).clashmax-backup"
      )
    }
  }

  func testUnknownManualAndUpstreamEndpointReferencesAreRejectedBeforeMutation() async throws {
    let source = try BackupFixture()
    let validBackup = try await exportLocalBackup(in: source)
    let unknownEndpointID = UUID(uuidString: "86000000-0000-0000-0000-000000000001")!

    for kind in ["manual", "upstream"] {
      var malformed = validBackup
      if kind == "manual" {
        malformed.profilesManifest.profiles[0].source = .manualProxy(
          endpointID: unknownEndpointID
        )
      } else {
        malformed.profilesManifest.profiles[0].upstreamEndpointID = unknownEndpointID
      }
      try await assertRestoreRejectsBeforeMutation(
        malformed,
        password: nil,
        fileName: "unknown-\(kind)-endpoint.clashmax-backup"
      )
    }
  }

  func testEncryptedEndpointPasswordReferenceIsRejectedBeforeMutation() async throws {
    let source = try BackupFixture()
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    await sourceProfileStore.waitForManifestLoad()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "87000000-0000-0000-0000-000000000001")!,
      name: "Password Reference",
      kind: .http,
      host: "password-ref.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "alice")
    )
    _ = try await sourceEndpointStore.add(endpoint, password: "hidden-endpoint-secret")
    let backupURL = source.root.appendingPathComponent("password-ref-source.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: await makeSnippetLibrary(paths: source.paths),
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: true,
      password: "correct-password"
    )

    var malformed = try readBackup(at: backupURL)
    malformed.outboundProxyManifest.endpoints[0].id = UUID(
      uuidString: "87000000-0000-0000-0000-000000000002"
    )!
    try await assertRestoreRejectsBeforeMutation(
      malformed,
      password: "correct-password",
      fileName: "unknown-password-reference.clashmax-backup"
    )
  }

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

  func testRuntimeSnippetPostWriteFailureRollsBackEndpointsOrphanSecretAndAllRestoreState() async throws {
    let importedEndpointID = UUID(uuidString: "88000000-0000-0000-0000-000000000001")!
    let source = try BackupFixture()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    _ = try await sourceEndpointStore.add(
      OutboundProxyEndpoint(
        id: importedEndpointID,
        name: "Imported Endpoint",
        kind: .http,
        host: "imported.example",
        port: 8080,
        authentication: OutboundProxyAuthentication(username: "source")
      ),
      password: "source-endpoint-secret"
    )
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    let sourceProfile = try await sourceProfileStore.addManualProxyProfile(
      name: "Imported Manual",
      endpointID: importedEndpointID
    )
    let sourceSettings = makeSettings(defaults: source.defaults)
    sourceSettings.appTheme = .light
    sourceSettings.overrides.mixedPort = 17_701
    let sourcePreview = ProxyPreviewStore(defaults: source.defaults)
    sourcePreview.previewSelections = ["Proxy": "Imported"]
    sourcePreview.saveSelections(for: sourceProfile.id)
    let sourceSnippetLibrary = await makeSnippetLibrary(paths: source.paths)
    try await sourceSnippetLibrary.saveSnippet(
      RuntimeSnippet(
        name: "Imported Runtime",
        payload: .dnsPatch(TunDNSSettings(respectRules: true))
      )
    )
    let backupURL = source.root.appendingPathComponent("endpoint-rollback.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: sourceSettings,
      proxyPreview: sourcePreview,
      runtimeSnippetLibrary: sourceSnippetLibrary,
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: true,
      password: "correct-password"
    )

    let restore = try BackupFixture()
    let endpointSecrets = InMemorySecretStore()
    try endpointSecrets.save(
      "orphan-before-restore",
      account: OutboundProxyEndpointStore.passwordAccount(for: importedEndpointID)
    )
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: endpointSecrets
    )
    let existingEndpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "88000000-0000-0000-0000-000000000002")!,
      name: "Existing Endpoint",
      kind: .socks5,
      host: "existing.example",
      port: 1080,
      authentication: OutboundProxyAuthentication(username: "existing")
    )
    _ = try await restoreEndpointStore.add(existingEndpoint, password: "existing-endpoint-secret")

    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    let existingProfile = try await restoreProfileStore.importLocalConfig(from: restore.localProfileURL)
    let restoreSettings = makeSettings(defaults: restore.defaults)
    restoreSettings.appTheme = .dark
    restoreSettings.overrides.mixedPort = 18_801
    let restorePreview = ProxyPreviewStore(defaults: restore.defaults)
    restorePreview.previewSelections = ["Elite": "Existing"]
    restorePreview.saveSelections(for: existingProfile.id)
    let seedSnippetLibrary = await makeSnippetLibrary(paths: restore.paths)
    let existingSnippet = RuntimeSnippet(
      name: "Existing Runtime",
      payload: .rules(RuleOverlaySettings(enabled: true))
    )
    try await seedSnippetLibrary.saveSnippet(existingSnippet)
    let failingSnippetLibrary = RuntimeSnippetLibraryStore(
      paths: restore.paths,
      diskIO: FailOnceAfterStoringRuntimeSnippetLibraryDiskIO()
    )
    await failingSnippetLibrary.waitForLoad()

    let endpointsBefore = try await restoreEndpointStore.endpoints()
    let endpointSecretsBefore = endpointSecrets.storedValues
    let profilesBefore = restoreProfileStore.profiles
    let activeProfileIDBefore = restoreProfileStore.activeProfileID
    let existingSourceBefore = try String(
      contentsOfFile: existingProfile.originalConfigPath,
      encoding: .utf8
    )
    let settingsBefore = restoreSettings.backupSnapshot()
    let selectionsBefore = restorePreview.backupSelections()
    let previewSelectionsBefore = restorePreview.previewSelections
    let snippetsBefore = failingSnippetLibrary.snippets

    await XCTAssertThrowsErrorAsync {
      try await self.service.restoreBackup(
        from: backupURL,
        password: "correct-password",
        profileStore: restoreProfileStore,
        settings: restoreSettings,
        proxyPreview: restorePreview,
        runtimeSnippetLibrary: failingSnippetLibrary,
        outboundProxyStore: restoreEndpointStore
      )
    } handler: { _ in }

    let endpointsAfter = try await restoreEndpointStore.endpoints()
    XCTAssertEqual(endpointsAfter, endpointsBefore)
    XCTAssertEqual(endpointSecrets.storedValues, endpointSecretsBefore)
    XCTAssertEqual(
      try endpointSecrets.load(
        account: OutboundProxyEndpointStore.passwordAccount(for: importedEndpointID)
      ),
      "orphan-before-restore"
    )
    XCTAssertEqual(restoreProfileStore.profiles, profilesBefore)
    XCTAssertEqual(restoreProfileStore.activeProfileID, activeProfileIDBefore)
    XCTAssertEqual(
      try String(contentsOfFile: existingProfile.originalConfigPath, encoding: .utf8),
      existingSourceBefore
    )
    XCTAssertEqual(restoreSettings.backupSnapshot(), settingsBefore)
    XCTAssertEqual(restorePreview.backupSelections(), selectionsBefore)
    XCTAssertEqual(restorePreview.previewSelections, previewSelectionsBefore)
    XCTAssertEqual(failingSnippetLibrary.snippets, snippetsBefore)

    let reloadedSnippetLibrary = RuntimeSnippetLibraryStore(paths: restore.paths)
    await reloadedSnippetLibrary.waitForLoad()
    XCTAssertEqual(reloadedSnippetLibrary.snippets, snippetsBefore)
  }

  func testEndpointRollbackFailureIsReportedAfterOtherRestoreStateRollbacks() async throws {
    let source = try BackupFixture()
    let sourceEndpointStore = OutboundProxyEndpointStore(
      manifestURL: source.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore()
    )
    let endpoint = OutboundProxyEndpoint(
      id: UUID(uuidString: "89000000-0000-0000-0000-000000000001")!,
      name: "Rollback Failure Endpoint",
      kind: .http,
      host: "rollback-failure.example",
      port: 8080
    )
    _ = try await sourceEndpointStore.add(endpoint, password: nil)
    let sourceProfileStore = ProfileStore(paths: source.paths, keychain: InMemorySecretStore())
    _ = try await sourceProfileStore.addManualProxyProfile(
      name: "Rollback Failure Manual",
      endpointID: endpoint.id
    )
    let sourceSnippets = await makeSnippetLibrary(paths: source.paths)
    try await sourceSnippets.saveSnippet(
      RuntimeSnippet(
        name: "Triggers Later Failure",
        payload: .rules(RuleOverlaySettings(enabled: true))
      )
    )
    let backupURL = source.root.appendingPathComponent("endpoint-rollback-failure.clashmax-backup")
    try await service.exportBackup(
      to: backupURL,
      profileStore: sourceProfileStore,
      settings: makeSettings(defaults: source.defaults),
      proxyPreview: ProxyPreviewStore(defaults: source.defaults),
      runtimeSnippetLibrary: sourceSnippets,
      outboundProxyStore: sourceEndpointStore,
      includeSecrets: true,
      password: "correct-password"
    )

    let restore = try BackupFixture()
    let restoreProfileStore = ProfileStore(paths: restore.paths, keychain: InMemorySecretStore())
    await restoreProfileStore.waitForManifestLoad()
    let restoreSettings = makeSettings(defaults: restore.defaults)
    restoreSettings.appTheme = .dark
    let settingsBefore = restoreSettings.backupSnapshot()
    let restorePreview = ProxyPreviewStore(defaults: restore.defaults)
    let restoreSnippets = RuntimeSnippetLibraryStore(
      paths: restore.paths,
      diskIO: FailOnceAfterStoringRuntimeSnippetLibraryDiskIO()
    )
    await restoreSnippets.waitForLoad()
    let restoreEndpointStore = OutboundProxyEndpointStore(
      manifestURL: restore.paths.outboundProxyEndpointManifestURL,
      secretStore: InMemorySecretStore(),
      diskIO: FailOnSecondOutboundProxyEndpointManifestSave()
    )

    await XCTAssertThrowsErrorAsync {
      try await self.service.restoreBackup(
        from: backupURL,
        password: "correct-password",
        profileStore: restoreProfileStore,
        settings: restoreSettings,
        proxyPreview: restorePreview,
        runtimeSnippetLibrary: restoreSnippets,
        outboundProxyStore: restoreEndpointStore
      )
    } handler: { error in
      XCTAssertEqual(error as? BackupRestoreError, .rollbackFailed)
    }

    XCTAssertTrue(restoreProfileStore.profiles.isEmpty)
    XCTAssertNil(restoreProfileStore.activeProfileID)
    XCTAssertEqual(restoreSettings.backupSnapshot(), settingsBefore)
    XCTAssertTrue(restorePreview.backupSelections().isEmpty)
    XCTAssertTrue(restorePreview.previewSelections.isEmpty)
    XCTAssertTrue(restoreSnippets.snippets.isEmpty)
    let reloadedSnippets = RuntimeSnippetLibraryStore(paths: restore.paths)
    await reloadedSnippets.waitForLoad()
    XCTAssertTrue(reloadedSnippets.snippets.isEmpty)
  }

  private func assertRestoreRejectsBeforeMutation(
    _ backup: ClashMaxBackupFile,
    password: String?,
    fileName: String
  ) async throws {
    let fixture = try BackupFixture()
    let backupURL = fixture.root.appendingPathComponent(fileName)
    try writeBackup(backup, to: backupURL)

    let endpointSecrets = InMemorySecretStore()
    let endpointStore = OutboundProxyEndpointStore(
      manifestURL: fixture.paths.outboundProxyEndpointManifestURL,
      secretStore: endpointSecrets
    )
    let existingEndpoint = OutboundProxyEndpoint(
      name: "Existing Endpoint",
      kind: .http,
      host: "existing.example",
      port: 8080,
      authentication: OutboundProxyAuthentication(username: "existing")
    )
    _ = try await endpointStore.add(existingEndpoint, password: "existing-endpoint-secret")

    let profileStore = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let existingProfile = try await profileStore.importLocalConfig(from: fixture.localProfileURL)
    let settings = makeSettings(defaults: fixture.defaults)
    settings.appTheme = .dark
    settings.overrides.mixedPort = 18_700
    let preview = ProxyPreviewStore(defaults: fixture.defaults)
    preview.previewSelections = ["Elite": "Existing"]
    preview.saveSelections(for: existingProfile.id)
    let snippetLibrary = await makeSnippetLibrary(paths: fixture.paths)
    let existingSnippet = RuntimeSnippet(
      name: "Existing Snippet",
      payload: .dnsPatch(TunDNSSettings(respectRules: true))
    )
    try await snippetLibrary.saveSnippet(existingSnippet)

    let endpointsBefore = try await endpointStore.endpoints()
    let endpointSecretsBefore = endpointSecrets.storedValues
    let profilesBefore = profileStore.profiles
    let activeProfileIDBefore = profileStore.activeProfileID
    let profileSourceBefore = try String(
      contentsOfFile: existingProfile.originalConfigPath,
      encoding: .utf8
    )
    let settingsBefore = settings.backupSnapshot()
    let selectionsBefore = preview.backupSelections()
    let previewSelectionsBefore = preview.previewSelections
    let snippetsBefore = snippetLibrary.snippets

    await XCTAssertThrowsErrorAsync {
      try await self.service.restoreBackup(
        from: backupURL,
        password: password,
        profileStore: profileStore,
        settings: settings,
        proxyPreview: preview,
        runtimeSnippetLibrary: snippetLibrary,
        outboundProxyStore: endpointStore
      )
    } handler: { error in
      self.assertInvalidBackup(error)
    }

    let endpointsAfter = try await endpointStore.endpoints()
    XCTAssertEqual(endpointsAfter, endpointsBefore, file: #filePath, line: #line)
    XCTAssertEqual(endpointSecrets.storedValues, endpointSecretsBefore, file: #filePath, line: #line)
    XCTAssertEqual(profileStore.profiles, profilesBefore, file: #filePath, line: #line)
    XCTAssertEqual(profileStore.activeProfileID, activeProfileIDBefore, file: #filePath, line: #line)
    XCTAssertEqual(
      try String(contentsOfFile: existingProfile.originalConfigPath, encoding: .utf8),
      profileSourceBefore,
      file: #filePath,
      line: #line
    )
    XCTAssertEqual(settings.backupSnapshot(), settingsBefore, file: #filePath, line: #line)
    XCTAssertEqual(preview.backupSelections(), selectionsBefore, file: #filePath, line: #line)
    XCTAssertEqual(preview.previewSelections, previewSelectionsBefore, file: #filePath, line: #line)
    XCTAssertEqual(snippetLibrary.snippets, snippetsBefore, file: #filePath, line: #line)
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

  private var canonicalManualProxyMarker: String {
    """
    # ClashMax managed manual proxy profile
    mode: rule
    proxies:
      - name: ClashMax Managed Block
        type: reject
    proxy-groups:
      - name: Proxy
        type: select
        proxies:
          - ClashMax Managed Block
    rules:
      - MATCH,REJECT
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

private actor FailOnceAfterStoringRuntimeSnippetLibraryDiskIO: RuntimeSnippetLibraryDiskIOProviding {
  private let base = RuntimeSnippetLibraryDiskIO()
  private var shouldFailNextSave = true

  func load(from url: URL) async throws -> [RuntimeSnippet] {
    try await base.load(from: url)
  }

  func save(_ snippets: [RuntimeSnippet], to url: URL) async throws {
    try await base.save(snippets, to: url)
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw CocoaError(.fileWriteNoPermission)
    }
  }
}

private actor FailOnSecondOutboundProxyEndpointManifestSave:
  OutboundProxyEndpointManifestStoring {
  private let base = OutboundProxyEndpointDiskIO()
  private var saveCount = 0

  func loadManifest(from url: URL) async throws -> OutboundProxyEndpointManifest? {
    try await base.loadManifest(from: url)
  }

  func saveManifest(
    _ manifest: OutboundProxyEndpointManifest,
    to url: URL
  ) async throws {
    saveCount += 1
    if saveCount == 2 {
      throw CocoaError(.fileWriteNoPermission)
    }
    try await base.saveManifest(manifest, to: url)
  }
}
