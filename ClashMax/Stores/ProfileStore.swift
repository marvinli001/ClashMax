import Foundation
import Yams

private actor ProfileMutationGate {
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

@MainActor
final class ProfileStore: ObservableObject {
  @Published private(set) var profiles: [Profile] = []
  @Published private(set) var activeProfileID: Profile.ID?
  @Published private(set) var subscriptionURLCache: [Profile.ID: String] = [:]

  private let paths: RuntimePaths
  private let diskIO: ProfileDiskIO
  private let secretIO: ProfileSecretIO
  private let subscriptionFetcher = SubscriptionFetcher()
  private let mutationGate = ProfileMutationGate()
  private var manifestLoadTask: Task<Void, Never>?

  init(
    paths: RuntimePaths,
    keychain: any SecretStoring = KeychainStore(),
    diskIO: ProfileDiskIO = ProfileDiskIO()
  ) {
    self.paths = paths
    self.diskIO = diskIO
    self.secretIO = ProfileSecretIO(store: keychain)
    manifestLoadTask = Task { @MainActor [weak self] in
      await self?.loadManifestFromDisk()
    }
  }

  deinit {
    manifestLoadTask?.cancel()
  }

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  func waitForManifestLoad() async {
    await manifestLoadTask?.value
  }

  @discardableResult
  func importLocalConfig(from sourceURL: URL) async throws -> Profile {
    await waitForManifestLoad()
    return try await withMutationLock {
      let id = UUID()
      let name = sourceURL.deletingPathExtension().lastPathComponent
      let destination = paths.profiles.appendingPathComponent("\(id.uuidString).yaml")
      _ = try await diskIO.importLocalConfig(from: sourceURL, to: destination)
      let profile = Profile(
        id: id,
        name: name,
        nameIsUserCustomized: true,
        source: .localFile(originalPath: sourceURL.path),
        originalConfigPath: destination.path
      )
      let nextProfiles = profiles + [profile]
      do {
        try await saveManifest(profiles: nextProfiles, activeProfileID: profile.id)
      } catch {
        try? await diskIO.removeProfileConfig(atPath: destination.path)
        throw error
      }
      profiles = nextProfiles
      activeProfileID = profile.id
      return profile
    }
  }

  @discardableResult
  func addSubscription(
    name: String = "",
    url: URL,
    displayNameHint: String? = nil,
    session: URLSession = .shared
  ) async throws -> Profile {
    await waitForManifestLoad()
    return try await withMutationLock {
      let resolution = try Self.resolvedSubscriptionURL(from: url, displayNameHint: displayNameHint)
      let result = Self.fetchResult(
        try await fetchSubscription(url: resolution.url, session: session),
        displayNameHint: resolution.displayNameHint
      )
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let suggestedName = await Self.subscriptionDisplayNameAsync(
        metadata: result.metadata,
        source: result.source,
        url: resolution.url
      )

      let id = UUID()
      let destination = paths.profiles.appendingPathComponent("\(id.uuidString).yaml")
      try await diskIO.writeProfileSource(result.source, to: destination)
      do {
        try await secretIO.save(resolution.url.absoluteString, account: Self.subscriptionAccount(for: id))
      } catch {
        try? await diskIO.removeProfileConfig(atPath: destination.path)
        throw error
      }

      let profile = Profile(
        id: id,
        name: trimmedName.isEmpty ? suggestedName : trimmedName,
        nameIsUserCustomized: !trimmedName.isEmpty,
        source: .subscription(id: id),
        originalConfigPath: destination.path,
        subscriptionMetadata: result.metadata
      )
      let nextProfiles = profiles + [profile]
      do {
        try await saveManifest(profiles: nextProfiles, activeProfileID: profile.id)
      } catch {
        try? await diskIO.removeProfileConfig(atPath: destination.path)
        try? await secretIO.delete(account: Self.subscriptionAccount(for: id))
        throw error
      }
      profiles = nextProfiles
      activeProfileID = profile.id
      subscriptionURLCache[id] = resolution.url.absoluteString
      return profile
    }
  }

  func updateSubscription(_ profile: Profile, session: URLSession = .shared) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard profiles.contains(where: { $0.id == profile.id }),
            case let .subscription(id) = profile.source,
            let rawURL = try await storedSubscriptionURL(for: id),
            let url = URL(string: rawURL)
      else { return }

      let resolution = try Self.resolvedSubscriptionURL(
        from: url,
        displayNameHint: profile.subscriptionMetadata?.displayNameHint
      )
      let previousSource = try? await diskIO.readProfileSource(atPath: profile.originalConfigPath)
      let result = Self.fetchResult(
        try await fetchSubscription(url: resolution.url, session: session),
        displayNameHint: resolution.displayNameHint
      )
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      do {
        try await diskIO.writeProfileSource(result.source, to: URL(fileURLWithPath: profile.originalConfigPath))
        if rawURL != resolution.url.absoluteString {
          try await secretIO.save(resolution.url.absoluteString, account: Self.subscriptionAccount(for: id))
        }
        try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      } catch {
        if let previousSource {
          try? await diskIO.writeProfileSource(previousSource, to: URL(fileURLWithPath: profile.originalConfigPath))
        }
        throw error
      }
      profiles = nextProfiles
      subscriptionURLCache[id] = resolution.url.absoluteString
    }
  }

  func updateSubscriptionSource(
    _ profile: Profile,
    url: URL,
    displayNameHint: String? = nil,
    session: URLSession = .shared
  ) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard profiles.contains(where: { $0.id == profile.id }),
            case let .subscription(id) = profile.source
      else { return }
      let resolution = try Self.resolvedSubscriptionURL(from: url, displayNameHint: displayNameHint)
      let account = Self.subscriptionAccount(for: id)
      let previousSource = try? await diskIO.readProfileSource(atPath: profile.originalConfigPath)
      let previousURL = try await storedSubscriptionURL(for: id)
      let result = Self.fetchResult(
        try await fetchSubscription(url: resolution.url, session: session),
        displayNameHint: resolution.displayNameHint
      )
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      do {
        try await diskIO.writeProfileSource(result.source, to: URL(fileURLWithPath: profile.originalConfigPath))
        try await secretIO.save(resolution.url.absoluteString, account: account)
        try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      } catch {
        if let previousSource {
          try? await diskIO.writeProfileSource(previousSource, to: URL(fileURLWithPath: profile.originalConfigPath))
        }
        if let previousURL {
          try? await secretIO.save(previousURL, account: account)
        } else {
          try? await secretIO.delete(account: account)
        }
        throw error
      }
      profiles = nextProfiles
      subscriptionURLCache[id] = resolution.url.absoluteString
    }
  }

  func rename(_ profile: Profile, to name: String) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
      var nextProfiles = profiles
      nextProfiles[index].name = name
      nextProfiles[index].nameIsUserCustomized = true
      nextProfiles[index].updatedAt = Date()
      try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      profiles = nextProfiles
    }
  }

  func resetSubscriptionName(_ profile: Profile) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard case let .subscription(id) = profile.source,
            let index = profiles.firstIndex(where: { $0.id == profile.id }),
            let rawURL = try await storedSubscriptionURL(for: id),
            let url = URL(string: rawURL),
            let resolution = SubscriptionURLResolver.resolve(url: url)
      else { return }
      let source = (try? await diskIO.readProfileSource(atPath: profile.originalConfigPath)) ?? ""
      let metadata = profiles[index].subscriptionMetadata ?? SubscriptionMetadata()
      let displayName = await Self.subscriptionDisplayNameAsync(metadata: metadata, source: source, url: resolution.url)
      var nextProfiles = profiles
      nextProfiles[index].name = displayName
      nextProfiles[index].nameIsUserCustomized = false
      nextProfiles[index].updatedAt = Date()
      try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      profiles = nextProfiles
      subscriptionURLCache[id] = resolution.url.absoluteString
    }
  }

  func delete(_ profile: Profile) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let current = profiles.first(where: { $0.id == profile.id }) else { return }
      var nextProfiles = profiles
      nextProfiles.removeAll { $0.id == current.id }
      let nextActiveProfileID = activeProfileID == current.id ? nextProfiles.first?.id : activeProfileID
      try await saveManifest(profiles: nextProfiles, activeProfileID: nextActiveProfileID)
      profiles = nextProfiles
      activeProfileID = nextActiveProfileID
      try? await diskIO.removeProfileConfig(atPath: current.originalConfigPath)
      if case let .subscription(id) = current.source {
        subscriptionURLCache.removeValue(forKey: id)
        try? await secretIO.delete(account: Self.subscriptionAccount(for: id))
      }
    }
  }

  func select(_ profile: Profile) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard activeProfileID != profile.id else { return }
      guard profiles.contains(where: { $0.id == profile.id }) else { return }
      try await saveManifest(profiles: profiles, activeProfileID: profile.id)
      activeProfileID = profile.id
    }
  }

  func subscriptionURLString(for profile: Profile) -> String? {
    guard case let .subscription(id) = profile.source else { return nil }
    return subscriptionURLCache[id]
  }

  nonisolated private static func subscriptionAccount(for id: UUID) -> String {
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

  nonisolated private static func resolvedSubscriptionURL(
    from url: URL,
    displayNameHint: String? = nil
  ) throws -> SubscriptionURLResolution {
    guard var resolution = SubscriptionURLResolver.resolve(url: url) else {
      throw AppError.invalidProfileConfig("Invalid subscription URL.")
    }
    if let explicitHint = SubscriptionURLResolver.normalizedDisplayName(displayNameHint) {
      resolution.displayNameHint = explicitHint
    }
    return resolution
  }

  nonisolated private static func fetchResult(
    _ result: SubscriptionFetchResult,
    displayNameHint: String?
  ) -> SubscriptionFetchResult {
    guard let displayNameHint = SubscriptionURLResolver.normalizedDisplayName(displayNameHint) else {
      return result
    }
    var metadata = result.metadata
    metadata.displayNameHint = displayNameHint
    return SubscriptionFetchResult(source: result.source, metadata: metadata)
  }

  private func loadManifestFromDisk() async {
    do {
      guard let manifest = try await diskIO.loadManifest(from: paths.manifestURL) else { return }
      let loadedSubscriptionURLs = await secretIO.loadSubscriptionURLs(
        for: Self.subscriptionIDs(in: manifest.profiles),
        account: Self.subscriptionAccount(for:)
      )
      profiles = manifest.profiles
      activeProfileID = manifest.activeProfileID
      subscriptionURLCache = loadedSubscriptionURLs
    } catch {
      return
    }
  }

  private func saveManifest(profiles: [Profile], activeProfileID: Profile.ID?) async throws {
    try await diskIO.saveManifest(
      ProfileManifest(profiles: profiles, activeProfileID: activeProfileID),
      to: paths.manifestURL
    )
  }

  private func withMutationLock<T>(_ operation: () async throws -> T) async throws -> T {
    try await mutationGate.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await mutationGate.release()
      return result
    } catch {
      await mutationGate.release()
      throw error
    }
  }

  private func storedSubscriptionURL(for id: UUID) async throws -> String? {
    if let cached = subscriptionURLCache[id] {
      return cached
    }
    guard let loaded = try await secretIO.load(account: Self.subscriptionAccount(for: id)) else {
      return nil
    }
    subscriptionURLCache[id] = loaded
    return loaded
  }

  private func profilesByApplyingSubscriptionDetails(
    _ result: SubscriptionFetchResult,
    sourceURL: URL,
    for id: UUID
  ) async -> [Profile] {
    var nextProfiles = profiles
    guard let index = nextProfiles.firstIndex(where: { $0.id == id }) else { return nextProfiles }
    nextProfiles[index].subscriptionMetadata = result.metadata
    if !nextProfiles[index].nameIsUserCustomized {
      nextProfiles[index].name = await Self.subscriptionDisplayNameAsync(
        metadata: result.metadata,
        source: result.source,
        url: sourceURL
      )
    }
    nextProfiles[index].updatedAt = Date()
    return nextProfiles
  }

  private static func subscriptionIDs(in profiles: [Profile]) -> [UUID] {
    profiles.compactMap { profile in
      if case let .subscription(id) = profile.source {
        return id
      }
      return nil
    }
  }

  nonisolated private static func subscriptionDisplayNameAsync(
    metadata: SubscriptionMetadata,
    source: String,
    url: URL
  ) async -> String {
    await Task.detached(priority: .userInitiated) {
      Self.subscriptionDisplayName(metadata: metadata, source: source, url: url)
    }.value
  }

  nonisolated private static func subscriptionDisplayName(metadata: SubscriptionMetadata, source: String, url: URL) -> String {
    if let remoteName = metadata.remoteFileName.map(Self.normalizedRemoteProfileName), !remoteName.isEmpty {
      return remoteName
    }
    if let displayNameHint = metadata.displayNameHint, !displayNameHint.isEmpty {
      return displayNameHint
    }
    if let profileName = Self.profileName(from: source), !profileName.isEmpty {
      return profileName
    }
    if let pathName = Self.profileName(fromURLPath: url), !pathName.isEmpty {
      return pathName
    }
    if let host = url.host(percentEncoded: false), !host.isEmpty {
      return host
    }
    return "Subscription"
  }

  nonisolated private static func normalizedRemoteProfileName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(fileURLWithPath: trimmed)
    let withoutExtension = ["yaml", "yml", "txt"].contains(url.pathExtension.lowercased())
      ? url.deletingPathExtension().lastPathComponent
      : trimmed
    return withoutExtension.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func profileName(fromURLPath url: URL) -> String? {
    let segments = url.path(percentEncoded: false)
      .split(separator: "/")
      .map(String.init)
    guard let lastSegment = segments.last else { return nil }
    let normalized = normalizedRemoteProfileName(lastSegment)
    return normalized.isEmpty ? nil : normalized
  }

  nonisolated private static func profileName(from source: String) -> String? {
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
