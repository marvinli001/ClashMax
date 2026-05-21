import Foundation

struct ProfileManifest: Codable, Sendable {
  var profiles: [Profile]
  var activeProfileID: Profile.ID?
}

actor ProfileDiskIO {
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
