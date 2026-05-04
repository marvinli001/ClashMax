import Foundation

@MainActor
final class ProfileStore: ObservableObject {
  @Published private(set) var profiles: [Profile] = []
  @Published var activeProfileID: Profile.ID?

  private let paths: RuntimePaths
  private let keychain: SecretStoring
  private let fileManager: FileManager
  private static let subscriptionUserAgent = "clash.meta"

  init(paths: RuntimePaths, keychain: SecretStoring = KeychainStore(), fileManager: FileManager = .default) {
    self.paths = paths
    self.keychain = keychain
    self.fileManager = fileManager
    loadManifest()
  }

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  @discardableResult
  func importLocalConfig(from sourceURL: URL) throws -> Profile {
    let id = UUID()
    let name = sourceURL.deletingPathExtension().lastPathComponent
    let destination = paths.profiles.appendingPathComponent("\(id.uuidString).yaml")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    try ProfileConfigValidator.validate(source)
    try source.write(to: destination, atomically: true, encoding: .utf8)
    let profile = Profile(
      id: id,
      name: name,
      source: .localFile(originalPath: sourceURL.path),
      originalConfigPath: destination.path
    )
    profiles.append(profile)
    activeProfileID = profile.id
    try saveManifest()
    return profile
  }

  @discardableResult
  func addSubscription(name: String, url: URL, session: URLSession = .shared) async throws -> Profile {
    let (data, response) = try await session.data(for: subscriptionRequest(url: url))
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AppError.invalidSubscriptionResponse
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw AppError.invalidSubscriptionResponse
    }
    try ProfileConfigValidator.validateProfileSource(source)

    let id = UUID()
    let destination = paths.profiles.appendingPathComponent("\(id.uuidString).yaml")
    try source.write(to: destination, atomically: true, encoding: .utf8)
    try keychain.save(url.absoluteString, account: subscriptionAccount(for: id))

    let profile = Profile(
      id: id,
      name: name.isEmpty ? url.host(percentEncoded: false) ?? "Subscription" : name,
      source: .subscription(id: id),
      originalConfigPath: destination.path
    )
    profiles.append(profile)
    activeProfileID = profile.id
    try saveManifest()
    return profile
  }

  func updateSubscription(_ profile: Profile, session: URLSession = .shared) async throws {
    guard case let .subscription(id) = profile.source,
          let rawURL = try keychain.load(account: subscriptionAccount(for: id)),
          let url = URL(string: rawURL)
    else { return }

    let (data, response) = try await session.data(for: subscriptionRequest(url: url))
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AppError.invalidSubscriptionResponse
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw AppError.invalidSubscriptionResponse
    }
    try ProfileConfigValidator.validateProfileSource(source)
    try source.write(to: URL(fileURLWithPath: profile.originalConfigPath), atomically: true, encoding: .utf8)
    touch(profile.id)
    try saveManifest()
  }

  func rename(_ profile: Profile, to name: String) throws {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    profiles[index].name = name
    profiles[index].updatedAt = Date()
    try saveManifest()
  }

  func delete(_ profile: Profile) throws {
    profiles.removeAll { $0.id == profile.id }
    try? fileManager.removeItem(atPath: profile.originalConfigPath)
    if case let .subscription(id) = profile.source {
      try? keychain.delete(account: subscriptionAccount(for: id))
    }
    if activeProfileID == profile.id {
      activeProfileID = profiles.first?.id
    }
    try saveManifest()
  }

  func select(_ profile: Profile) throws {
    guard activeProfileID != profile.id else { return }
    activeProfileID = profile.id
    try saveManifest()
  }

  private func touch(_ id: UUID) {
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      profiles[index].updatedAt = Date()
    }
  }

  private func subscriptionAccount(for id: UUID) -> String {
    "subscription.\(id.uuidString)"
  }

  private func subscriptionRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(Self.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/yaml, application/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
    return request
  }

  private func loadManifest() {
    guard let data = try? Data(contentsOf: paths.manifestURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(ProfileManifest.self, from: data) else { return }
    profiles = manifest.profiles
    activeProfileID = manifest.activeProfileID
  }

  private func saveManifest() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(ProfileManifest(profiles: profiles, activeProfileID: activeProfileID))
    try data.write(to: paths.manifestURL, options: [.atomic])
  }
}

private struct ProfileManifest: Codable {
  var profiles: [Profile]
  var activeProfileID: Profile.ID?
}

private enum ProfileConfigValidator {
  static func validate(_ source: String) throws {
    try validateProfileSource(source, allowProviderContent: false)
  }

  static func validateProfileSource(_ source: String, allowProviderContent: Bool = true) throws {
    do {
      let format = try ProfileConfigInspector.format(of: source)
      if !allowProviderContent, format == .proxyProviderContent {
        throw AppError.invalidProfileConfig("Local imports must be Clash/Mihomo YAML. Add URI/base64 node lists as a subscription.")
      }
    } catch let error as ProfileConfigFormatError {
      throw AppError.invalidProfileConfig(String(describing: error))
    }
  }
}
