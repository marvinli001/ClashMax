import Foundation

struct OutboundProxyEndpointManifest: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var endpoints: [OutboundProxyEndpoint]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case endpoints
  }

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    endpoints: [OutboundProxyEndpoint] = []
  ) {
    self.schemaVersion = schemaVersion
    self.endpoints = endpoints
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    endpoints = try container.decode([OutboundProxyEndpoint].self, forKey: .endpoints)
  }
}

protocol OutboundProxyEndpointManifestStoring: Sendable {
  func loadManifest(from url: URL) async throws -> OutboundProxyEndpointManifest?
  func saveManifest(_ manifest: OutboundProxyEndpointManifest, to url: URL) async throws
}

actor OutboundProxyEndpointDiskIO: OutboundProxyEndpointManifestStoring {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func loadManifest(from url: URL) throws -> OutboundProxyEndpointManifest? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(OutboundProxyEndpointManifest.self, from: data)
  }

  func saveManifest(_ manifest: OutboundProxyEndpointManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try SecureFileIO.writePrivateData(data, to: url, fileManager: fileManager)
  }
}

enum OutboundProxyEndpointStoreError: Error, Equatable {
  case nameRequired
  case hostRequired
  case invalidPort(Int)
  case usernameRequired
  case passwordRequired
  case duplicateName(String)
  case duplicateIdentifier(UUID)
  case endpointNotFound(UUID)
  case unsupportedSchema(Int)
  case invalidBackup(String)
  case rollbackFailed
}

extension OutboundProxyEndpointStoreError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .nameRequired:
      return "Proxy endpoint name is required."
    case .hostRequired:
      return "Proxy endpoint host is required."
    case let .invalidPort(port):
      return "Proxy endpoint port \(port) is outside the valid range 1...65535."
    case .usernameRequired:
      return "A username is required when proxy authentication is enabled."
    case .passwordRequired:
      return "A password is required when proxy authentication is enabled."
    case let .duplicateName(name):
      return "A proxy endpoint named \(name) already exists."
    case let .duplicateIdentifier(id):
      return "A proxy endpoint with identifier \(id.uuidString) already exists."
    case let .endpointNotFound(id):
      return "Proxy endpoint \(id.uuidString) was not found."
    case let .unsupportedSchema(version):
      return "Unsupported proxy endpoint manifest schema version \(version)."
    case let .invalidBackup(message):
      return "Invalid proxy endpoint backup: \(message)"
    case .rollbackFailed:
      return "The proxy endpoint transaction failed and its previous state could not be fully restored."
    }
  }
}

private actor OutboundProxyEndpointTransactionGate {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var isLocked = false
  private var waiters: [Waiter] = []

  func acquire() async throws {
    guard isLocked else {
      isLocked = true
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append(Waiter(id: waiterID, continuation: continuation))
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      isLocked = false
      return
    }
    waiters.removeFirst().continuation.resume()
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

actor OutboundProxyEndpointStore {
  private let manifestURL: URL
  private let secretStore: any SecretStoring
  private let diskIO: any OutboundProxyEndpointManifestStoring
  private let transactionGate = OutboundProxyEndpointTransactionGate()

  init(
    manifestURL: URL,
    secretStore: any SecretStoring = KeychainStore(),
    diskIO: any OutboundProxyEndpointManifestStoring = OutboundProxyEndpointDiskIO()
  ) {
    self.manifestURL = manifestURL
    self.secretStore = secretStore
    self.diskIO = diskIO
  }

  static func passwordAccount(for endpointID: UUID) -> String {
    "outbound-proxy.\(endpointID.uuidString).password"
  }

  func endpoints() async throws -> [OutboundProxyEndpoint] {
    try await withTransactionLock {
      try await loadManifest().endpoints
    }
  }

  @discardableResult
  func add(
    _ endpoint: OutboundProxyEndpoint,
    password: String?
  ) async throws -> OutboundProxyEndpoint {
    try await withTransactionLock {
      try await addTransaction(endpoint, password: password)
    }
  }

  @discardableResult
  func update(
    _ endpoint: OutboundProxyEndpoint,
    password suppliedPassword: String? = nil
  ) async throws -> OutboundProxyEndpoint {
    try await withTransactionLock {
      try await updateTransaction(endpoint, password: suppliedPassword)
    }
  }

  func resolve(id: UUID) async throws -> ResolvedOutboundProxyEndpoint {
    try await withTransactionLock {
      try await resolveTransaction(id: id)
    }
  }

  func delete(id: UUID) async throws {
    try await withTransactionLock {
      try await deleteTransaction(id: id)
    }
  }

  func backupExport(
    includeSecrets: Bool = false
  ) async throws -> BackupOutboundProxyEndpointExport {
    try await withTransactionLock {
      let manifest = try await loadManifest()
      var passwords: [BackupOutboundProxyEndpointPassword] = []
      var omittedPasswordCount = 0

      for endpoint in manifest.endpoints where endpoint.authentication != nil {
        guard
          let password = try secretStore.load(account: Self.passwordAccount(for: endpoint.id)),
          !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          continue
        }

        if includeSecrets {
          passwords.append(
            BackupOutboundProxyEndpointPassword(
              endpointID: endpoint.id,
              password: password
            )
          )
        } else {
          omittedPasswordCount += 1
        }
      }

      return BackupOutboundProxyEndpointExport(
        manifest: manifest,
        passwords: passwords,
        omittedPasswordCount: omittedPasswordCount
      )
    }
  }

  func rollbackSnapshot(
    additionalAffectedEndpointIDs: [UUID] = []
  ) async throws -> OutboundProxyEndpointStoreRollbackSnapshot {
    try await withTransactionLock {
      let manifest = try await loadManifest()
      return OutboundProxyEndpointStoreRollbackSnapshot(
        manifest: manifest,
        passwords: try passwordSnapshots(
          for: manifest.endpoints.map(\.id) + additionalAffectedEndpointIDs
        )
      )
    }
  }

  func restoreRollbackSnapshot(
    _ snapshot: OutboundProxyEndpointStoreRollbackSnapshot
  ) async throws {
    try await withTransactionLock {
      try Self.validateSupportedSchema(snapshot.manifest)
      let currentManifest = try await loadManifest()
      let snapshotPasswords = try Self.passwordSnapshotIndex(snapshot.passwords)
      let affectedIDs = Set(currentManifest.endpoints.map(\.id))
        .union(snapshot.manifest.endpoints.map(\.id))
        .union(snapshotPasswords.keys)
        .sorted { $0.uuidString < $1.uuidString }
      let previousPasswords = try passwordSnapshots(for: affectedIDs)
      var didAttemptManifestSave = false

      do {
        for endpointID in affectedIDs {
          try replaceSecret(
            snapshotPasswords[endpointID]?.password,
            account: Self.passwordAccount(for: endpointID)
          )
        }
        didAttemptManifestSave = true
        try await diskIO.saveManifest(snapshot.manifest, to: manifestURL)
      } catch {
        let operationError = error
        try await restoreTransactionState(
          passwords: previousPasswords,
          manifest: currentManifest,
          restoreManifest: didAttemptManifestSave
        )
        throw operationError
      }
    }
  }

  func mergeRestoreBackup(
    manifest backupManifest: OutboundProxyEndpointManifest,
    passwords: [BackupOutboundProxyEndpointPassword]
  ) async throws -> BackupOutboundProxyEndpointRestoreResult {
    try await withTransactionLock {
      let backupEndpoints = try validatedBackupEndpoints(in: backupManifest)
      let passwordByEndpointID = try Self.backupPasswordIndex(
        passwords,
        endpoints: backupEndpoints
      )
      let currentManifest = try await loadManifest()
      var usedIDs = Set(currentManifest.endpoints.map(\.id))
      var usedNames = Set(currentManifest.endpoints.map { Self.canonicalName($0.name) })
      var idMap: [UUID: UUID] = [:]
      var restoredEndpoints: [(originalID: UUID, endpoint: OutboundProxyEndpoint)] = []

      for backupEndpoint in backupEndpoints {
        var restoredEndpoint = backupEndpoint
        let originalID = backupEndpoint.id
        restoredEndpoint.id = Self.restoredID(for: originalID, usedIDs: &usedIDs)
        restoredEndpoint.name = Self.restoredName(
          for: backupEndpoint.name,
          usedNames: &usedNames
        )
        idMap[originalID] = restoredEndpoint.id
        restoredEndpoints.append((originalID: originalID, endpoint: restoredEndpoint))
      }

      let rollbackSnapshot = OutboundProxyEndpointStoreRollbackSnapshot(
        manifest: currentManifest,
        passwords: try passwordSnapshots(
          for: currentManifest.endpoints.map(\.id) + restoredEndpoints.map(\.endpoint.id)
        )
      )
      var nextManifest = currentManifest
      nextManifest.endpoints.append(contentsOf: restoredEndpoints.map(\.endpoint))
      var didAttemptManifestSave = false

      do {
        for restoredEndpoint in restoredEndpoints {
          try replaceSecret(
            passwordByEndpointID[restoredEndpoint.originalID],
            account: Self.passwordAccount(for: restoredEndpoint.endpoint.id)
          )
        }
        didAttemptManifestSave = true
        try await diskIO.saveManifest(nextManifest, to: manifestURL)
      } catch {
        let operationError = error
        try await restoreTransactionState(
          passwords: rollbackSnapshot.passwords,
          manifest: currentManifest,
          restoreManifest: didAttemptManifestSave
        )
        throw operationError
      }

      return BackupOutboundProxyEndpointRestoreResult(
        importedEndpointCount: restoredEndpoints.count,
        idMap: idMap,
        restoredSecretCount: passwordByEndpointID.count,
        rollbackSnapshot: rollbackSnapshot
      )
    }
  }

  private func resolveTransaction(id: UUID) async throws -> ResolvedOutboundProxyEndpoint {
    let manifest = try await loadManifest()
    guard let endpoint = manifest.endpoints.first(where: { $0.id == id }) else {
      throw OutboundProxyEndpointStoreError.endpointNotFound(id)
    }
    let password: String?
    if endpoint.authentication == nil {
      password = nil
    } else {
      password = try secretStore.load(account: Self.passwordAccount(for: id))
    }
    return ResolvedOutboundProxyEndpoint(endpoint: endpoint, password: password)
  }

  private func addTransaction(
    _ endpoint: OutboundProxyEndpoint,
    password: String?
  ) async throws -> OutboundProxyEndpoint {
    let endpoint = try normalized(endpoint)
    var manifest = try await loadManifest()
    guard !manifest.endpoints.contains(where: { $0.id == endpoint.id }) else {
      throw OutboundProxyEndpointStoreError.duplicateIdentifier(endpoint.id)
    }
    try ensureUniqueName(endpoint.name, excluding: nil, in: manifest.endpoints)

    let password = try requiredPassword(
      for: endpoint,
      suppliedPassword: password,
      existingPassword: nil
    )
    let account = Self.passwordAccount(for: endpoint.id)
    let previousPassword = try secretStore.load(account: account)
    if let password {
      try secretStore.save(password, account: account)
    } else {
      try secretStore.delete(account: account)
    }

    let previousManifest = manifest
    manifest.endpoints.append(endpoint)
    do {
      try await diskIO.saveManifest(manifest, to: manifestURL)
    } catch {
      let operationError = error
      try await restoreTransactionState(
        passwords: [
          OutboundProxyEndpointPasswordSnapshot(
            endpointID: endpoint.id,
            password: previousPassword
          )
        ],
        manifest: previousManifest,
        restoreManifest: true
      )
      throw operationError
    }
    return endpoint
  }

  private func updateTransaction(
    _ endpoint: OutboundProxyEndpoint,
    password suppliedPassword: String?
  ) async throws -> OutboundProxyEndpoint {
    let endpoint = try normalized(endpoint)
    var manifest = try await loadManifest()
    guard let index = manifest.endpoints.firstIndex(where: { $0.id == endpoint.id }) else {
      throw OutboundProxyEndpointStoreError.endpointNotFound(endpoint.id)
    }
    try ensureUniqueName(endpoint.name, excluding: endpoint.id, in: manifest.endpoints)

    let account = Self.passwordAccount(for: endpoint.id)
    let oldPassword = try secretStore.load(account: account)
    let password = try requiredPassword(
      for: endpoint,
      suppliedPassword: suppliedPassword,
      existingPassword: oldPassword
    )
    try replaceSecret(password, account: account)

    let previousManifest = manifest
    manifest.endpoints[index] = endpoint
    do {
      try await diskIO.saveManifest(manifest, to: manifestURL)
    } catch {
      let operationError = error
      try await restoreTransactionState(
        passwords: [
          OutboundProxyEndpointPasswordSnapshot(
            endpointID: endpoint.id,
            password: oldPassword
          )
        ],
        manifest: previousManifest,
        restoreManifest: true
      )
      throw operationError
    }
    return endpoint
  }

  private func deleteTransaction(id: UUID) async throws {
    var manifest = try await loadManifest()
    guard let index = manifest.endpoints.firstIndex(where: { $0.id == id }) else {
      throw OutboundProxyEndpointStoreError.endpointNotFound(id)
    }

    let account = Self.passwordAccount(for: id)
    let oldPassword = try secretStore.load(account: account)
    try secretStore.delete(account: account)
    let previousManifest = manifest
    manifest.endpoints.remove(at: index)
    do {
      try await diskIO.saveManifest(manifest, to: manifestURL)
    } catch {
      let operationError = error
      try await restoreTransactionState(
        passwords: [
          OutboundProxyEndpointPasswordSnapshot(
            endpointID: id,
            password: oldPassword
          )
        ],
        manifest: previousManifest,
        restoreManifest: true
      )
      throw operationError
    }
  }

  private func withTransactionLock<T>(_ operation: () async throws -> T) async throws -> T {
    try await transactionGate.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await transactionGate.release()
      return result
    } catch {
      await transactionGate.release()
      throw error
    }
  }

  private func loadManifest() async throws -> OutboundProxyEndpointManifest {
    let manifest = try await diskIO.loadManifest(from: manifestURL)
      ?? OutboundProxyEndpointManifest()
    try Self.validateSupportedSchema(manifest)
    return manifest
  }

  private func normalized(_ endpoint: OutboundProxyEndpoint) throws -> OutboundProxyEndpoint {
    var endpoint = endpoint
    endpoint.name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !endpoint.name.isEmpty else {
      throw OutboundProxyEndpointStoreError.nameRequired
    }

    endpoint.host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !endpoint.host.isEmpty else {
      throw OutboundProxyEndpointStoreError.hostRequired
    }
    guard (1...65_535).contains(endpoint.port) else {
      throw OutboundProxyEndpointStoreError.invalidPort(endpoint.port)
    }

    if var authentication = endpoint.authentication {
      authentication.username = authentication.username.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !authentication.username.isEmpty else {
        throw OutboundProxyEndpointStoreError.usernameRequired
      }
      endpoint.authentication = authentication
    }

    endpoint.httpOptions.serverName = endpoint.httpOptions.serverName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if endpoint.httpOptions.serverName?.isEmpty == true {
      endpoint.httpOptions.serverName = nil
    }
    return endpoint
  }

  private func requiredPassword(
    for endpoint: OutboundProxyEndpoint,
    suppliedPassword: String?,
    existingPassword: String?
  ) throws -> String? {
    guard endpoint.authentication != nil else { return nil }
    guard
      let password = suppliedPassword ?? existingPassword,
      !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw OutboundProxyEndpointStoreError.passwordRequired
    }
    return password
  }

  private func ensureUniqueName(
    _ name: String,
    excluding endpointID: UUID?,
    in endpoints: [OutboundProxyEndpoint]
  ) throws {
    let canonicalName = Self.canonicalName(name)
    guard !endpoints.contains(where: {
      $0.id != endpointID && Self.canonicalName($0.name) == canonicalName
    }) else {
      throw OutboundProxyEndpointStoreError.duplicateName(canonicalName)
    }
  }

  private static func canonicalName(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private func validatedBackupEndpoints(
    in manifest: OutboundProxyEndpointManifest
  ) throws -> [OutboundProxyEndpoint] {
    try Self.validateSupportedSchema(manifest)
    var usedIDs = Set<UUID>()
    var usedNames = Set<String>()
    var endpoints: [OutboundProxyEndpoint] = []

    for endpoint in manifest.endpoints {
      guard usedIDs.insert(endpoint.id).inserted else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint manifest contains duplicate endpoint IDs."
        )
      }

      let endpoint = try normalized(endpoint)
      guard usedNames.insert(Self.canonicalName(endpoint.name)).inserted else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint manifest contains duplicate endpoint names."
        )
      }
      endpoints.append(endpoint)
    }
    return endpoints
  }

  private static func validateSupportedSchema(
    _ manifest: OutboundProxyEndpointManifest
  ) throws {
    guard manifest.schemaVersion == OutboundProxyEndpointManifest.currentSchemaVersion else {
      throw OutboundProxyEndpointStoreError.unsupportedSchema(manifest.schemaVersion)
    }
  }

  private static func backupPasswordIndex(
    _ passwords: [BackupOutboundProxyEndpointPassword],
    endpoints: [OutboundProxyEndpoint]
  ) throws -> [UUID: String] {
    let endpointByID = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.id, $0) })
    var passwordByEndpointID: [UUID: String] = [:]

    for password in passwords {
      guard passwordByEndpointID[password.endpointID] == nil else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint passwords contain duplicate endpoint IDs."
        )
      }
      guard endpointByID[password.endpointID]?.authentication != nil else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint password does not reference an authenticated endpoint."
        )
      }
      guard !password.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint password records cannot contain a blank password."
        )
      }
      passwordByEndpointID[password.endpointID] = password.password
    }
    return passwordByEndpointID
  }

  private static func passwordSnapshotIndex(
    _ passwords: [OutboundProxyEndpointPasswordSnapshot]
  ) throws -> [UUID: OutboundProxyEndpointPasswordSnapshot] {
    var passwordByEndpointID: [UUID: OutboundProxyEndpointPasswordSnapshot] = [:]
    for password in passwords {
      guard passwordByEndpointID[password.endpointID] == nil else {
        throw OutboundProxyEndpointStoreError.invalidBackup(
          "Endpoint rollback snapshot contains duplicate endpoint IDs."
        )
      }
      passwordByEndpointID[password.endpointID] = password
    }
    return passwordByEndpointID
  }

  private static func restoredID(
    for originalID: UUID,
    usedIDs: inout Set<UUID>
  ) -> UUID {
    guard !usedIDs.contains(originalID) else {
      var candidate = UUID()
      while usedIDs.contains(candidate) {
        candidate = UUID()
      }
      usedIDs.insert(candidate)
      return candidate
    }
    usedIDs.insert(originalID)
    return originalID
  }

  private static func restoredName(
    for originalName: String,
    usedNames: inout Set<String>
  ) -> String {
    guard !usedNames.contains(canonicalName(originalName)) else {
      var suffix = 1
      while true {
        let candidate = suffix == 1
          ? "\(originalName) (Restored)"
          : "\(originalName) (Restored \(suffix))"
        if usedNames.insert(canonicalName(candidate)).inserted {
          return candidate
        }
        suffix += 1
      }
    }
    usedNames.insert(canonicalName(originalName))
    return originalName
  }

  private func passwordSnapshots<S: Sequence>(
    for endpointIDs: S
  ) throws -> [OutboundProxyEndpointPasswordSnapshot] where S.Element == UUID {
    var seen = Set<UUID>()
    var snapshots: [OutboundProxyEndpointPasswordSnapshot] = []
    for endpointID in endpointIDs where seen.insert(endpointID).inserted {
      snapshots.append(
        OutboundProxyEndpointPasswordSnapshot(
          endpointID: endpointID,
          password: try secretStore.load(account: Self.passwordAccount(for: endpointID))
        )
      )
    }
    return snapshots
  }

  private func restoreTransactionState(
    passwords: [OutboundProxyEndpointPasswordSnapshot],
    manifest: OutboundProxyEndpointManifest,
    restoreManifest: Bool
  ) async throws {
    var rollbackFailed = false
    for password in passwords {
      do {
        try replaceSecret(
          password.password,
          account: Self.passwordAccount(for: password.endpointID)
        )
      } catch {
        rollbackFailed = true
      }
    }
    if restoreManifest {
      do {
        try await diskIO.saveManifest(manifest, to: manifestURL)
      } catch {
        rollbackFailed = true
      }
    }
    if rollbackFailed {
      throw OutboundProxyEndpointStoreError.rollbackFailed
    }
  }

  private func replaceSecret(_ password: String?, account: String) throws {
    if let password {
      try secretStore.save(password, account: account)
    } else {
      try secretStore.delete(account: account)
    }
  }
}

struct ProfileManifest: Codable, Equatable, Sendable {
  var profiles: [Profile]
  var activeProfileID: Profile.ID?
}

protocol ProfileDiskStoring: Sendable {
  func loadManifest(from url: URL) async throws -> ProfileManifest?
  func saveManifest(_ manifest: ProfileManifest, to url: URL) async throws
  func importLocalConfig(from sourceURL: URL, to destinationURL: URL) async throws -> String
  func readProfileSource(atPath path: String) async throws -> String
  func writeProfileSource(_ source: String, to url: URL) async throws
  func removeProfileConfig(atPath path: String) async throws
}

actor ProfileDiskIO: ProfileDiskStoring {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func loadManifest(from url: URL) throws -> ProfileManifest? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProfileManifest.self, from: data)
  }

  func saveManifest(_ manifest: ProfileManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(manifest)
    try SecureFileIO.writePrivateData(data, to: url, fileManager: fileManager)
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

actor ProfileSecretIO {
  private let store: any SecretStoring

  init(store: any SecretStoring) {
    self.store = store
  }

  func save(_ value: String, account: String) throws {
    try store.save(value, account: account)
  }

  func load(account: String) throws -> String? {
    try store.load(account: account)
  }

  func delete(account: String) throws {
    try store.delete(account: account)
  }

  func loadSubscriptionURLs(for ids: [UUID], account: @Sendable (UUID) -> String) -> [UUID: String] {
    ids.reduce(into: [UUID: String]()) { result, id in
      if let value = try? store.load(account: account(id)) {
        result[id] = value
      }
    }
  }
}
