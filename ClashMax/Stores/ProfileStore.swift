import Foundation
import Yams

@MainActor
final class ProfileStore: ObservableObject {
  @Published private(set) var profiles: [Profile] = []
  @Published var activeProfileID: Profile.ID?

  private let paths: RuntimePaths
  private let keychain: SecretStoring
  private let fileManager: FileManager
  private let subscriptionFetcher = SubscriptionFetcher()

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
      nameIsUserCustomized: true,
      source: .localFile(originalPath: sourceURL.path),
      originalConfigPath: destination.path
    )
    profiles.append(profile)
    activeProfileID = profile.id
    try saveManifest()
    return profile
  }

  @discardableResult
  func addSubscription(name: String = "", url: URL, session: URLSession = .shared) async throws -> Profile {
    let result = try await fetchSubscription(url: url, session: session)
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let suggestedName = subscriptionDisplayName(metadata: result.metadata, source: result.source, url: url)

    let id = UUID()
    let destination = paths.profiles.appendingPathComponent("\(id.uuidString).yaml")
    try result.source.write(to: destination, atomically: true, encoding: .utf8)
    try keychain.save(url.absoluteString, account: subscriptionAccount(for: id))

    let profile = Profile(
      id: id,
      name: trimmedName.isEmpty ? suggestedName : trimmedName,
      nameIsUserCustomized: !trimmedName.isEmpty,
      source: .subscription(id: id),
      originalConfigPath: destination.path,
      subscriptionMetadata: result.metadata
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

    let result = try await fetchSubscription(url: url, session: session)
    try result.source.write(to: URL(fileURLWithPath: profile.originalConfigPath), atomically: true, encoding: .utf8)
    updateSubscriptionDetails(result, sourceURL: url, for: profile.id)
    try saveManifest()
  }

  func updateSubscriptionSource(_ profile: Profile, url: URL, session: URLSession = .shared) async throws {
    guard case let .subscription(id) = profile.source else { return }
    let result = try await fetchSubscription(url: url, session: session)
    try result.source.write(to: URL(fileURLWithPath: profile.originalConfigPath), atomically: true, encoding: .utf8)
    try keychain.save(url.absoluteString, account: subscriptionAccount(for: id))
    updateSubscriptionDetails(result, sourceURL: url, for: profile.id)
    try saveManifest()
  }

  func rename(_ profile: Profile, to name: String) throws {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    profiles[index].name = name
    profiles[index].nameIsUserCustomized = true
    profiles[index].updatedAt = Date()
    try saveManifest()
  }

  func resetSubscriptionName(_ profile: Profile) throws {
    guard case let .subscription(id) = profile.source,
          let index = profiles.firstIndex(where: { $0.id == profile.id }),
          let rawURL = try keychain.load(account: subscriptionAccount(for: id)),
          let url = URL(string: rawURL)
    else { return }
    let source = (try? String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)) ?? ""
    let metadata = profiles[index].subscriptionMetadata ?? SubscriptionMetadata()
    profiles[index].name = subscriptionDisplayName(metadata: metadata, source: source, url: url)
    profiles[index].nameIsUserCustomized = false
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

  private func updateMetadata(_ metadata: SubscriptionMetadata, for id: UUID) {
    if let index = profiles.firstIndex(where: { $0.id == id }) {
      profiles[index].subscriptionMetadata = metadata
      profiles[index].updatedAt = Date()
    }
  }

  private func updateSubscriptionDetails(_ result: SubscriptionFetchResult, sourceURL: URL, for id: UUID) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
    profiles[index].subscriptionMetadata = result.metadata
    if !profiles[index].nameIsUserCustomized {
      profiles[index].name = subscriptionDisplayName(metadata: result.metadata, source: result.source, url: sourceURL)
    }
    profiles[index].updatedAt = Date()
  }

  func subscriptionURLString(for profile: Profile) -> String? {
    guard case let .subscription(id) = profile.source else { return nil }
    return try? keychain.load(account: subscriptionAccount(for: id))
  }

  private func subscriptionAccount(for id: UUID) -> String {
    "subscription.\(id.uuidString)"
  }

  private func fetchSubscription(url: URL, session: URLSession) async throws -> SubscriptionFetchResult {
    guard session !== URLSession.shared else {
      return try await subscriptionFetcher.fetch(url: url)
    }
    return try await subscriptionFetcher.fetch(url: url) { _ in
      try await session.data(for: subscriptionFetcher.request(url: url))
    }
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

  private func subscriptionDisplayName(metadata: SubscriptionMetadata, source: String, url: URL) -> String {
    if let remoteName = metadata.remoteFileName.map(Self.normalizedRemoteProfileName), !remoteName.isEmpty {
      return remoteName
    }
    if let profileName = Self.profileName(from: source), !profileName.isEmpty {
      return profileName
    }
    if let host = url.host(percentEncoded: false), !host.isEmpty {
      return host
    }
    return "Subscription"
  }

  private static func normalizedRemoteProfileName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(fileURLWithPath: trimmed)
    let withoutExtension = ["yaml", "yml", "txt"].contains(url.pathExtension.lowercased())
      ? url.deletingPathExtension().lastPathComponent
      : trimmed
    return withoutExtension.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func profileName(from source: String) -> String? {
    guard let root = try? Yams.load(yaml: source) as? [String: Any] else { return nil }
    if let groups = root["proxy-groups"] as? [[String: Any]] {
      for group in groups {
        guard let name = group["name"] as? String else { continue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    if let providers = root["proxy-providers"] as? [String: Any],
       let name = providers.keys.sorted().first {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }
}

private struct ProfileManifest: Codable {
  var profiles: [Profile]
  var activeProfileID: Profile.ID?
}

enum ProfileConfigValidator {
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
