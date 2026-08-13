import CommonCrypto
import CryptoKit
import Foundation
import Security
import Yams

struct BackupRestoreService: Sendable {
  private static let secretAlgorithm = "AES-GCM-256"
  private static let keyDerivation = "PBKDF2-HMAC-SHA256"
  private static let keyByteCount = 32
  private static let saltByteCount = 16
  private static let keyDerivationIterations = 210_000
  private static let maximumKeyDerivationIterations = 1_000_000
  private static let minimumSealedPayloadByteCount = 28
  private static let maximumSealedPayloadByteCount = 10 * 1024 * 1024

  @MainActor
  func exportBackup(
    to url: URL,
    profileStore: ProfileStore,
    settings: PersistedSettingsStore,
    proxyPreview: ProxyPreviewStore,
    runtimeSnippetLibrary: RuntimeSnippetLibraryStore,
    outboundProxyStore: OutboundProxyEndpointStore? = nil,
    includeSecrets: Bool,
    password: String?
  ) async throws -> BackupRestoreSummary {
    let profileExport = try await profileStore.backupExport(includeSecrets: includeSecrets)
    let endpointExport = try await outboundProxyStore?.backupExport(includeSecrets: includeSecrets)
      ?? BackupOutboundProxyEndpointExport(
        manifest: OutboundProxyEndpointManifest(),
        passwords: [],
        omittedPasswordCount: 0
      )
    var backupSecrets = profileExport.secrets
    backupSecrets.outboundProxyPasswords = endpointExport.passwords
    try Self.validateEndpointManifest(endpointExport.manifest)
    try Self.validate(
      backupSecrets,
      against: profileExport.manifest,
      endpointManifest: endpointExport.manifest
    )
    let sourceRedaction = try BackupProfileSourceRedactor.redactedProfileSources(from: profileExport.profileSources)
    let runtimeSnippetSnapshot = await runtimeSnippetLibrary.backupSnapshot()
    let encryptedSecrets: BackupEncryptedSecrets?
    let encryptedProfileSources: BackupEncryptedProfileSources?
    let encryptedRuntimeSnippets: BackupEncryptedRuntimeSnippets?
    let omittedSecretSummary: BackupSecretSummary

    if includeSecrets {
      guard let password, !password.isEmpty else {
        throw BackupRestoreError.passwordRequired
      }
      encryptedSecrets = try encryptSecrets(backupSecrets, password: password)
      encryptedProfileSources = try encryptProfileSources(
        profileExport.profileSources,
        redactedCredentialCount: sourceRedaction.redactedCredentialCount,
        password: password
      )
      encryptedRuntimeSnippets = try encryptRuntimeSnippets(runtimeSnippetSnapshot, password: password)
      omittedSecretSummary = BackupSecretSummary()
    } else {
      encryptedSecrets = nil
      encryptedProfileSources = nil
      encryptedRuntimeSnippets = nil
      var summary = profileExport.omittedSecretSummary
      summary.profileSourceCredentialCount += sourceRedaction.redactedCredentialCount
      summary.runtimeSnippetCount += runtimeSnippetSnapshot.count
      summary.outboundProxyPasswordCount += endpointExport.omittedPasswordCount
      omittedSecretSummary = summary
    }

    let backup = ClashMaxBackupFile(
      appMetadata: .current(),
      profilesManifest: profileExport.manifest,
      outboundProxyManifest: endpointExport.manifest,
      profileSources: sourceRedaction.profileSources,
      settings: settings.backupSnapshot(),
      proxySelections: proxyPreview.backupSelections(),
      runtimeSnippets: nil,
      omittedSecretSummary: omittedSecretSummary,
      encryptedSecrets: encryptedSecrets,
      encryptedProfileSources: encryptedProfileSources,
      encryptedRuntimeSnippets: encryptedRuntimeSnippets
    )

    try Self.validate(backup)
    let data = try Self.makeEncoder().encode(backup)
    try writeBackupData(data, to: url)
    return BackupRestoreSummary(
      importedProfileCount: backup.profilesManifest.profiles.count,
      importedEndpointCount: backup.outboundProxyManifest.endpoints.count,
      restoredSecretCount: includeSecrets ? backupSecrets.secretCount + runtimeSnippetSnapshot.count : 0,
      skippedSecretCount: omittedSecretSummary.totalCount
    )
  }

  func previewBackup(at url: URL) throws -> BackupRestorePreview {
    let backup = try decodeBackup(at: url)
    try Self.validate(backup)
    return BackupRestorePreview(
      url: url,
      fileName: url.lastPathComponent,
      profileCount: backup.profilesManifest.profiles.count,
      endpointCount: backup.outboundProxyManifest.endpoints.count,
      hasSettings: true,
      proxySelectionProfileCount: backup.proxySelections.count,
      hasEncryptedSecrets: backup.encryptedSecrets != nil
        || backup.encryptedProfileSources != nil
        || backup.encryptedRuntimeSnippets != nil,
      omittedSecretSummary: backup.omittedSecretSummary
    )
  }

  @MainActor
  func restoreBackup(
    from url: URL,
    password: String?,
    profileStore: ProfileStore,
    settings: PersistedSettingsStore,
    proxyPreview: ProxyPreviewStore,
    runtimeSnippetLibrary: RuntimeSnippetLibraryStore,
    outboundProxyStore: OutboundProxyEndpointStore? = nil
  ) async throws -> BackupRestoreSummary {
    let backup = try decodeBackup(at: url)
    try Self.validate(backup)
    if outboundProxyStore == nil, !backup.outboundProxyManifest.endpoints.isEmpty {
      throw BackupRestoreError.invalidBackup(
        "Backup contains outbound proxy endpoints, but no endpoint store is available."
      )
    }

    let passwordForEncryptedPayloads = password?.trimmingCharacters(in: .whitespacesAndNewlines)
    let secrets: BackupSecretsBundle?
    if let encryptedSecrets = backup.encryptedSecrets {
      if let passwordForEncryptedPayloads, !passwordForEncryptedPayloads.isEmpty {
        let decryptedSecrets = try decryptSecrets(encryptedSecrets, password: passwordForEncryptedPayloads)
        try Self.validate(
          decryptedSecrets,
          against: backup.profilesManifest,
          endpointManifest: backup.outboundProxyManifest
        )
        secrets = decryptedSecrets
      } else {
        secrets = nil
      }
    } else {
      secrets = nil
    }
    let profileSources: [BackupProfileSource]
    if let encryptedProfileSources = backup.encryptedProfileSources,
       let passwordForEncryptedPayloads,
       !passwordForEncryptedPayloads.isEmpty
    {
      profileSources = try decryptProfileSources(encryptedProfileSources, password: passwordForEncryptedPayloads)
      try Self.validateProfileSources(profileSources, against: backup.profilesManifest)
    } else {
      profileSources = backup.profileSources
    }
    let runtimeSnippets: [RuntimeSnippet]?
    if let encryptedRuntimeSnippets = backup.encryptedRuntimeSnippets {
      if let passwordForEncryptedPayloads, !passwordForEncryptedPayloads.isEmpty {
        runtimeSnippets = try decryptRuntimeSnippets(encryptedRuntimeSnippets, password: passwordForEncryptedPayloads)
      } else {
        runtimeSnippets = nil
      }
    } else {
      runtimeSnippets = backup.runtimeSnippets
    }

    let profileSnapshot = try await profileStore.rollbackSnapshot()
    let settingsSnapshot = settings.backupSnapshot()
    let proxyPreviewSnapshot = proxyPreview.rollbackSnapshot()
    let runtimeSnippetSnapshot = await runtimeSnippetLibrary.backupSnapshot()

    var endpointResult: BackupOutboundProxyEndpointRestoreResult?
    let profileResult: BackupProfileRestoreResult
    do {
      if let outboundProxyStore, !backup.outboundProxyManifest.endpoints.isEmpty {
        endpointResult = try await outboundProxyStore.mergeRestoreBackup(
          manifest: backup.outboundProxyManifest,
          passwords: secrets?.outboundProxyPasswords ?? []
        )
      }
      let restoredProfileManifest = try Self.remapEndpointReferences(
        in: backup.profilesManifest,
        endpointIDMap: endpointResult?.idMap ?? [:]
      )
      profileResult = try await profileStore.mergeRestoreBackup(
        manifest: restoredProfileManifest,
        profileSources: profileSources,
        secrets: secrets
      )
      settings.applyBackupSnapshot(backup.settings)
      proxyPreview.mergeBackupSelections(
        backup.proxySelections,
        idMap: profileResult.idMap,
        activeProfileID: profileResult.activeProfileID
      )
      if let runtimeSnippets {
        try await runtimeSnippetLibrary.applyBackupSnapshot(runtimeSnippets, idMap: profileResult.idMap)
      }
    } catch {
      let operationError = error
      try? await runtimeSnippetLibrary.replaceSnippets(runtimeSnippetSnapshot)
      try? await profileStore.restoreRollbackSnapshot(profileSnapshot)
      settings.applyBackupSnapshot(settingsSnapshot)
      proxyPreview.restoreRollbackSnapshot(proxyPreviewSnapshot)
      var endpointRollbackFailed = false
      if let outboundProxyStore, let endpointResult {
        do {
          try await outboundProxyStore.restoreRollbackSnapshot(endpointResult.rollbackSnapshot)
        } catch {
          endpointRollbackFailed = true
        }
      }
      if endpointRollbackFailed {
        throw BackupRestoreError.rollbackFailed
      }
      throw operationError
    }

    let encryptedSecretCount = backup.encryptedSecrets?.secretCount ?? 0
    let encryptedProfileSourceSecretCount = backup.encryptedProfileSources?.redactedCredentialCount ?? 0
    let encryptedRuntimeSnippetCount = backup.encryptedRuntimeSnippets?.snippetCount ?? 0
    let skippedSecretCount = (secrets == nil ? encryptedSecretCount : 0)
      + (profileSources == backup.profileSources ? encryptedProfileSourceSecretCount : 0)
      + (runtimeSnippets == nil ? encryptedRuntimeSnippetCount : 0)
      + backup.omittedSecretSummary.totalCount

    return BackupRestoreSummary(
      importedProfileCount: profileResult.importedProfileCount,
      importedEndpointCount: endpointResult?.importedEndpointCount ?? 0,
      restoredSecretCount: profileResult.restoredSecretCount
        + (endpointResult?.restoredSecretCount ?? 0)
        + (backup.encryptedRuntimeSnippets == nil || runtimeSnippets == nil ? 0 : encryptedRuntimeSnippetCount),
      skippedSecretCount: skippedSecretCount
    )
  }

  private func decodeBackup(at url: URL) throws -> ClashMaxBackupFile {
    let data = try Data(contentsOf: url)
    return try Self.makeDecoder().decode(ClashMaxBackupFile.self, from: data)
  }

  private func encryptSecrets(_ secrets: BackupSecretsBundle, password: String) throws -> BackupEncryptedSecrets {
    let salt = try Self.randomData(byteCount: Self.saltByteCount)
    let key = try Self.deriveKey(password: password, salt: salt)
    let nonce = AES.GCM.Nonce()
    let plaintext = try Self.makeEncoder().encode(secrets)
    let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    guard let combined = sealedBox.combined else {
      throw BackupRestoreError.invalidBackup("Could not seal encrypted secrets.")
    }
    return BackupEncryptedSecrets(
      algorithm: Self.secretAlgorithm,
      keyDerivation: Self.keyDerivation,
      iterations: Self.keyDerivationIterations,
      salt: salt,
      nonce: Data(nonce),
      sealedPayload: combined,
      secretCount: secrets.secretCount
    )
  }

  private func encryptProfileSources(
    _ profileSources: [BackupProfileSource],
    redactedCredentialCount: Int,
    password: String
  ) throws -> BackupEncryptedProfileSources {
    let salt = try Self.randomData(byteCount: Self.saltByteCount)
    let key = try Self.deriveKey(password: password, salt: salt)
    let nonce = AES.GCM.Nonce()
    let plaintext = try Self.makeEncoder().encode(profileSources)
    let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    guard let combined = sealedBox.combined else {
      throw BackupRestoreError.invalidBackup("Could not seal encrypted profile sources.")
    }
    return BackupEncryptedProfileSources(
      algorithm: Self.secretAlgorithm,
      keyDerivation: Self.keyDerivation,
      iterations: Self.keyDerivationIterations,
      salt: salt,
      nonce: Data(nonce),
      sealedPayload: combined,
      profileSourceCount: profileSources.count,
      redactedCredentialCount: redactedCredentialCount
    )
  }

  private func encryptRuntimeSnippets(_ snippets: [RuntimeSnippet], password: String) throws -> BackupEncryptedRuntimeSnippets {
    let salt = try Self.randomData(byteCount: Self.saltByteCount)
    let key = try Self.deriveKey(password: password, salt: salt)
    let nonce = AES.GCM.Nonce()
    let plaintext = try Self.makeEncoder().encode(snippets)
    let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    guard let combined = sealedBox.combined else {
      throw BackupRestoreError.invalidBackup("Could not seal encrypted runtime snippets.")
    }
    return BackupEncryptedRuntimeSnippets(
      algorithm: Self.secretAlgorithm,
      keyDerivation: Self.keyDerivation,
      iterations: Self.keyDerivationIterations,
      salt: salt,
      nonce: Data(nonce),
      sealedPayload: combined,
      snippetCount: snippets.count
    )
  }

  private func decryptSecrets(_ encryptedSecrets: BackupEncryptedSecrets, password: String) throws -> BackupSecretsBundle {
    try Self.validate(encryptedSecrets)
    guard !password.isEmpty else {
      throw BackupRestoreError.passwordRequired
    }
    do {
      let key = try Self.deriveKey(
        password: password,
        salt: encryptedSecrets.salt,
        iterations: encryptedSecrets.iterations
      )
      let sealedBox = try AES.GCM.SealedBox(combined: encryptedSecrets.sealedPayload)
      let data = try AES.GCM.open(sealedBox, using: key)
      let secrets = try Self.makeDecoder().decode(BackupSecretsBundle.self, from: data)
      guard secrets.secretCount == encryptedSecrets.secretCount else {
        throw BackupRestoreError.invalidBackup(
          "Encrypted secret count does not match its payload."
        )
      }
      return secrets
    } catch let error as BackupRestoreError {
      throw error
    } catch {
      throw BackupRestoreError.invalidPassword
    }
  }

  private func decryptProfileSources(
    _ encryptedProfileSources: BackupEncryptedProfileSources,
    password: String
  ) throws -> [BackupProfileSource] {
    try Self.validate(encryptedProfileSources)
    guard !password.isEmpty else {
      throw BackupRestoreError.passwordRequired
    }
    do {
      let key = try Self.deriveKey(
        password: password,
        salt: encryptedProfileSources.salt,
        iterations: encryptedProfileSources.iterations
      )
      let sealedBox = try AES.GCM.SealedBox(combined: encryptedProfileSources.sealedPayload)
      let data = try AES.GCM.open(sealedBox, using: key)
      let profileSources = try Self.makeDecoder().decode([BackupProfileSource].self, from: data)
      guard profileSources.count == encryptedProfileSources.profileSourceCount else {
        throw BackupRestoreError.invalidBackup("Encrypted profile source count does not match its payload.")
      }
      return profileSources
    } catch let error as BackupRestoreError {
      throw error
    } catch {
      throw BackupRestoreError.invalidPassword
    }
  }

  private func decryptRuntimeSnippets(
    _ encryptedRuntimeSnippets: BackupEncryptedRuntimeSnippets,
    password: String
  ) throws -> [RuntimeSnippet] {
    try Self.validate(encryptedRuntimeSnippets)
    guard !password.isEmpty else {
      throw BackupRestoreError.passwordRequired
    }
    do {
      let key = try Self.deriveKey(
        password: password,
        salt: encryptedRuntimeSnippets.salt,
        iterations: encryptedRuntimeSnippets.iterations
      )
      let sealedBox = try AES.GCM.SealedBox(combined: encryptedRuntimeSnippets.sealedPayload)
      let data = try AES.GCM.open(sealedBox, using: key)
      let snippets = try Self.makeDecoder().decode([RuntimeSnippet].self, from: data)
      guard snippets.count == encryptedRuntimeSnippets.snippetCount else {
        throw BackupRestoreError.invalidBackup("Encrypted runtime snippet count does not match its payload.")
      }
      if let snippetError = snippets.compactMap(\.validationError).first {
        throw BackupRestoreError.invalidBackup(snippetError)
      }
      return snippets
    } catch let error as BackupRestoreError {
      throw error
    } catch {
      throw BackupRestoreError.invalidPassword
    }
  }

  private func writeBackupData(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: SecureFileIO.privateFilePermissions],
      ofItemAtPath: url.path
    )
  }

  private static func validate(_ backup: ClashMaxBackupFile) throws {
    guard backup.schemaVersion == 1
      || backup.schemaVersion == ClashMaxBackupFile.currentSchemaVersion
    else {
      throw BackupRestoreError.unsupportedSchema(backup.schemaVersion)
    }
    if backup.schemaVersion == 1, !backup.outboundProxyManifest.endpoints.isEmpty {
      throw BackupRestoreError.invalidBackup(
        "Schema 1 backups cannot contain outbound proxy endpoints."
      )
    }
    try validateEndpointManifest(backup.outboundProxyManifest)
    let manifestIDs = try uniqueIDs(
      backup.profilesManifest.profiles.map(\.id),
      duplicateMessage: "Profile manifest contains duplicate profile IDs."
    )
    let sourceIDs = try uniqueIDs(
      backup.profileSources.map(\.profileID),
      duplicateMessage: "Profile sources contain duplicate profile IDs."
    )
    guard manifestIDs == sourceIDs else {
      throw BackupRestoreError.invalidBackup("Profile manifest and profile source IDs do not match.")
    }
    try validateEndpointReferences(
      in: backup.profilesManifest,
      endpointManifest: backup.outboundProxyManifest
    )
    if let settingsError = backup.settings.validationError {
      throw BackupRestoreError.invalidBackup(settingsError)
    }
    if let snippetError = backup.runtimeSnippets?.compactMap(\.validationError).first {
      throw BackupRestoreError.invalidBackup(snippetError)
    }
    if let encryptedSecrets = backup.encryptedSecrets {
      try validate(encryptedSecrets)
    }
    if let encryptedProfileSources = backup.encryptedProfileSources {
      try validate(encryptedProfileSources)
    }
    if let encryptedRuntimeSnippets = backup.encryptedRuntimeSnippets {
      try validate(encryptedRuntimeSnippets)
    }
  }

  private static func validate(_ encryptedSecrets: BackupEncryptedSecrets) throws {
    guard encryptedSecrets.algorithm == secretAlgorithm,
          encryptedSecrets.keyDerivation == keyDerivation
    else {
      throw BackupRestoreError.invalidBackup("Unsupported secret encryption format.")
    }
    guard (1...maximumKeyDerivationIterations).contains(encryptedSecrets.iterations) else {
      throw BackupRestoreError.invalidBackup("Encrypted secret key derivation iterations are invalid.")
    }
    guard encryptedSecrets.salt.count == saltByteCount else {
      throw BackupRestoreError.invalidBackup("Encrypted secret salt length is invalid.")
    }
    guard (minimumSealedPayloadByteCount...maximumSealedPayloadByteCount).contains(encryptedSecrets.sealedPayload.count) else {
      throw BackupRestoreError.invalidBackup("Encrypted secret payload length is invalid.")
    }
    guard encryptedSecrets.secretCount >= 0 else {
      throw BackupRestoreError.invalidBackup("Encrypted secret count is invalid.")
    }
  }

  private static func validate(_ encryptedRuntimeSnippets: BackupEncryptedRuntimeSnippets) throws {
    guard encryptedRuntimeSnippets.algorithm == secretAlgorithm,
          encryptedRuntimeSnippets.keyDerivation == keyDerivation
    else {
      throw BackupRestoreError.invalidBackup("Unsupported runtime snippet encryption format.")
    }
    guard (1...maximumKeyDerivationIterations).contains(encryptedRuntimeSnippets.iterations) else {
      throw BackupRestoreError.invalidBackup("Encrypted runtime snippet key derivation iterations are invalid.")
    }
    guard encryptedRuntimeSnippets.salt.count == saltByteCount else {
      throw BackupRestoreError.invalidBackup("Encrypted runtime snippet salt length is invalid.")
    }
    guard (minimumSealedPayloadByteCount...maximumSealedPayloadByteCount)
      .contains(encryptedRuntimeSnippets.sealedPayload.count)
    else {
      throw BackupRestoreError.invalidBackup("Encrypted runtime snippet payload length is invalid.")
    }
    guard encryptedRuntimeSnippets.snippetCount >= 0 else {
      throw BackupRestoreError.invalidBackup("Encrypted runtime snippet count is invalid.")
    }
  }

  private static func validate(_ encryptedProfileSources: BackupEncryptedProfileSources) throws {
    guard encryptedProfileSources.algorithm == secretAlgorithm,
          encryptedProfileSources.keyDerivation == keyDerivation
    else {
      throw BackupRestoreError.invalidBackup("Unsupported profile source encryption format.")
    }
    guard (1...maximumKeyDerivationIterations).contains(encryptedProfileSources.iterations) else {
      throw BackupRestoreError.invalidBackup("Encrypted profile source key derivation iterations are invalid.")
    }
    guard encryptedProfileSources.salt.count == saltByteCount else {
      throw BackupRestoreError.invalidBackup("Encrypted profile source salt length is invalid.")
    }
    guard (minimumSealedPayloadByteCount...maximumSealedPayloadByteCount)
      .contains(encryptedProfileSources.sealedPayload.count)
    else {
      throw BackupRestoreError.invalidBackup("Encrypted profile source payload length is invalid.")
    }
    guard encryptedProfileSources.profileSourceCount >= 0,
          encryptedProfileSources.redactedCredentialCount >= 0
    else {
      throw BackupRestoreError.invalidBackup("Encrypted profile source counts are invalid.")
    }
  }

  private static func validate(
    _ secrets: BackupSecretsBundle,
    against manifest: ProfileManifest,
    endpointManifest: OutboundProxyEndpointManifest
  ) throws {
    let subscriptionProfilesByID = manifest.profiles.reduce(into: [Profile.ID: Profile]()) { result, profile in
      guard profile.isSubscription else { return }
      result[profile.id] = profile
    }
    var seenProfileIDs = Set<Profile.ID>()
    for subscription in secrets.subscriptions {
      guard seenProfileIDs.insert(subscription.profileID).inserted else {
        throw BackupRestoreError.invalidBackup("Subscription secrets contain duplicate profile IDs.")
      }
      guard let profile = subscriptionProfilesByID[subscription.profileID] else {
        throw BackupRestoreError.invalidBackup("Subscription secrets reference an unknown subscription profile.")
      }
      let requestHeaderIDs = try uniqueIDs(
        subscription.requestHeaders.map(\.headerID),
        duplicateMessage: "Subscription secrets contain duplicate request header IDs."
      )
      let profileHeaderIDs = Set(profile.subscriptionProviderOptions.requestHeaders.map(\.id))
      guard requestHeaderIDs.isSubset(of: profileHeaderIDs) else {
        throw BackupRestoreError.invalidBackup("Subscription secrets reference an unknown request header.")
      }
    }

    let endpointByID = Dictionary(
      uniqueKeysWithValues: endpointManifest.endpoints.map { ($0.id, $0) }
    )
    var seenEndpointIDs = Set<UUID>()
    for password in secrets.outboundProxyPasswords {
      guard seenEndpointIDs.insert(password.endpointID).inserted else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy passwords contain duplicate endpoint IDs."
        )
      }
      guard endpointByID[password.endpointID]?.authentication != nil else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy password references an unknown or unauthenticated endpoint."
        )
      }
      guard !password.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy password records cannot contain a blank password."
        )
      }
    }
  }

  private static func validateEndpointManifest(
    _ manifest: OutboundProxyEndpointManifest
  ) throws {
    guard manifest.schemaVersion == OutboundProxyEndpointManifest.currentSchemaVersion else {
      throw BackupRestoreError.invalidBackup(
        "Unsupported outbound proxy endpoint schema version \(manifest.schemaVersion)."
      )
    }

    var endpointIDs = Set<UUID>()
    var endpointNames = Set<String>()
    for endpoint in manifest.endpoints {
      guard endpointIDs.insert(endpoint.id).inserted else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy endpoint manifest contains duplicate endpoint IDs."
        )
      }

      let name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw BackupRestoreError.invalidBackup("Outbound proxy endpoint name is required.")
      }
      let canonicalName = canonicalEndpointName(name)
      guard endpointNames.insert(canonicalName).inserted else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy endpoint manifest contains duplicate endpoint names."
        )
      }
      guard !endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BackupRestoreError.invalidBackup("Outbound proxy endpoint host is required.")
      }
      guard (1...65_535).contains(endpoint.port) else {
        throw BackupRestoreError.invalidBackup(
          "Outbound proxy endpoint port is outside the valid range 1...65535."
        )
      }
      if let authentication = endpoint.authentication {
        guard !authentication.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw BackupRestoreError.invalidBackup(
            "Outbound proxy endpoint username is required when authentication is enabled."
          )
        }
      }
    }
  }

  private static func validateEndpointReferences(
    in manifest: ProfileManifest,
    endpointManifest: OutboundProxyEndpointManifest
  ) throws {
    let endpointIDs = Set(endpointManifest.endpoints.map(\.id))
    for profile in manifest.profiles {
      if case let .manualProxy(endpointID) = profile.source {
        guard endpointIDs.contains(endpointID) else {
          throw BackupRestoreError.invalidBackup(
            "Manual proxy profile references an unknown outbound proxy endpoint."
          )
        }
        if profile.upstreamEndpointID == endpointID {
          throw BackupRestoreError.invalidBackup(
            "Manual proxy profile cannot use its own endpoint as an upstream."
          )
        }
      }
      if let upstreamEndpointID = profile.upstreamEndpointID,
         !endpointIDs.contains(upstreamEndpointID)
      {
        throw BackupRestoreError.invalidBackup(
          "Profile upstream references an unknown outbound proxy endpoint."
        )
      }
    }
  }

  private static func canonicalEndpointName(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private static func remapEndpointReferences(
    in manifest: ProfileManifest,
    endpointIDMap: [UUID: UUID]
  ) throws -> ProfileManifest {
    var restoredManifest = manifest
    for index in restoredManifest.profiles.indices {
      if case let .manualProxy(endpointID) = restoredManifest.profiles[index].source {
        guard let restoredEndpointID = endpointIDMap[endpointID] else {
          throw BackupRestoreError.invalidBackup(
            "Manual proxy profile endpoint could not be remapped."
          )
        }
        restoredManifest.profiles[index].source = .manualProxy(
          endpointID: restoredEndpointID
        )
      }
      if let upstreamEndpointID = restoredManifest.profiles[index].upstreamEndpointID {
        guard let restoredEndpointID = endpointIDMap[upstreamEndpointID] else {
          throw BackupRestoreError.invalidBackup(
            "Profile upstream endpoint could not be remapped."
          )
        }
        restoredManifest.profiles[index].upstreamEndpointID = restoredEndpointID
      }
    }
    return restoredManifest
  }

  private static func validateProfileSources(
    _ profileSources: [BackupProfileSource],
    against manifest: ProfileManifest
  ) throws {
    let manifestIDs = try uniqueIDs(
      manifest.profiles.map(\.id),
      duplicateMessage: "Profile manifest contains duplicate profile IDs."
    )
    let sourceIDs = try uniqueIDs(
      profileSources.map(\.profileID),
      duplicateMessage: "Profile sources contain duplicate profile IDs."
    )
    guard manifestIDs == sourceIDs else {
      throw BackupRestoreError.invalidBackup("Profile manifest and profile source IDs do not match.")
    }
  }

  private static func uniqueIDs<ID: Hashable>(_ ids: [ID], duplicateMessage: String) throws -> Set<ID> {
    var seen = Set<ID>()
    for id in ids {
      guard seen.insert(id).inserted else {
        throw BackupRestoreError.invalidBackup(duplicateMessage)
      }
    }
    return seen
  }

  private static func deriveKey(
    password: String,
    salt: Data,
    iterations: Int = keyDerivationIterations
  ) throws -> SymmetricKey {
    guard salt.count == saltByteCount else {
      throw BackupRestoreError.invalidBackup("Encrypted secret salt length is invalid.")
    }
    guard (1...maximumKeyDerivationIterations).contains(iterations),
          let iterationCount = UInt32(exactly: iterations)
    else {
      throw BackupRestoreError.invalidBackup("Encrypted secret key derivation iterations are invalid.")
    }
    let passwordData = Data(password.utf8)
    var derived = Data(count: keyByteCount)
    let status = derived.withUnsafeMutableBytes { derivedBytes in
      salt.withUnsafeBytes { saltBytes in
        passwordData.withUnsafeBytes { passwordBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.bindMemory(to: Int8.self).baseAddress,
            passwordData.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterationCount,
            derivedBytes.bindMemory(to: UInt8.self).baseAddress,
            keyByteCount
          )
        }
      }
    }
    guard status == kCCSuccess else {
      throw BackupRestoreError.invalidBackup("Could not derive backup encryption key.")
    }
    return SymmetricKey(data: derived)
  }

  private static func randomData(byteCount: Int) throws -> Data {
    var data = Data(count: byteCount)
    let status = data.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.bindMemory(to: UInt8.self).baseAddress!)
    }
    guard status == errSecSuccess else {
      throw BackupRestoreError.invalidBackup("Could not generate secure random bytes.")
    }
    return data
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private extension BackupSecretsBundle {
  var secretCount: Int {
    subscriptions.reduce(0) { partialResult, subscription in
      partialResult
        + (subscription.subscriptionURL == nil ? 0 : 1)
        + subscription.requestHeaders.count
        + (subscription.runtimeMergeYAML == nil ? 0 : 1)
    } + outboundProxyPasswords.count
  }
}

private struct BackupProfileSourceRedaction {
  var profileSources: [BackupProfileSource]
  var redactedCredentialCount: Int
}

private enum BackupProfileSourceRedactor {
  private static let redactedValue = "<redacted>"

  static func redactedProfileSources(from profileSources: [BackupProfileSource]) throws -> BackupProfileSourceRedaction {
    var redactedSources: [BackupProfileSource] = []
    var redactedCredentialCount = 0

    for profileSource in profileSources {
      let redaction = try redactedSource(profileSource.source)
      redactedSources.append(
        BackupProfileSource(
          profileID: profileSource.profileID,
          fileName: profileSource.fileName,
          source: redaction.source
        )
      )
      redactedCredentialCount += redaction.credentialCount
    }

    return BackupProfileSourceRedaction(
      profileSources: redactedSources,
      redactedCredentialCount: redactedCredentialCount
    )
  }

  private static func redactedSource(_ source: String) throws -> (source: String, credentialCount: Int) {
    if ProfileConfigInspector.isProxyProviderContent(source) {
      return (placeholderClashConfig(), max(providerContentCredentialCount(source), 1))
    }

    guard let root = try Yams.load(yaml: source) as? [String: Any] else {
      return (source, 0)
    }

    var credentialCount = 0
    let redactedRoot = redact(root, path: [], credentialCount: &credentialCount)
    guard credentialCount > 0 else {
      return (source, 0)
    }
    return try (Yams.dump(object: redactedRoot, sortKeys: false), credentialCount)
  }

  private static func redact(
    _ value: Any,
    path: [String],
    credentialCount: inout Int
  ) -> Any {
    if let map = value as? [String: Any] {
      return map.reduce(into: [String: Any]()) { result, entry in
        let key = entry.key
        let nextPath = path + [key]
        if shouldRedactValue(forKey: key, path: path) {
          let count = credentialValueCount(entry.value)
          if count > 0 {
            credentialCount += count
            result[key] = redactedValue
          } else {
            result[key] = entry.value
          }
        } else {
          result[key] = redact(entry.value, path: nextPath, credentialCount: &credentialCount)
        }
      }
    }

    if let list = value as? [Any] {
      return list.map { redact($0, path: path, credentialCount: &credentialCount) }
    }

    return value
  }

  private static func shouldRedactValue(forKey key: String, path: [String]) -> Bool {
    let normalized = key
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    if normalized == "url", path.contains("proxy-providers") {
      return true
    }
    if normalized.contains("password")
      || normalized.contains("token")
      || normalized.contains("secret")
    {
      return true
    }
    return [
      "uuid",
      "private-key",
      "auth",
      "auth-str",
      "authorization",
      "proxy-authorization",
      "credential",
      "credentials",
      "psk",
    ].contains(normalized)
  }

  private static func credentialValueCount(_ value: Any) -> Int {
    if let string = value as? String {
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
    }
    if let list = value as? [Any] {
      let nestedCount = list.reduce(0) { $0 + credentialValueCount($1) }
      return nestedCount == 0 && !list.isEmpty ? 1 : nestedCount
    }
    if let map = value as? [String: Any] {
      let nestedCount = map.values.reduce(0) { $0 + credentialValueCount($1) }
      return nestedCount == 0 && !map.isEmpty ? 1 : nestedCount
    }
    return 1
  }

  private static func providerContentCredentialCount(_ source: String) -> Int {
    let content = ProfileConfigInspector.decodedBase64ProviderContent(from: source) ?? source
    return max(nonEmptyLines(in: content).count, 1)
  }

  private static func nonEmptyLines(in source: String) -> [String] {
    source
      .components(separatedBy: .newlines)
      .compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
  }

  private static func placeholderClashConfig() -> String {
    """
    proxies:
      - name: Redacted Backup Placeholder
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies:
          - Redacted Backup Placeholder
          - DIRECT
    rules:
      - MATCH,Proxy
    """
  }
}
