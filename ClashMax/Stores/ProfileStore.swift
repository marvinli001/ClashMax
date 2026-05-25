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
protocol SubscriptionProfilePreflightValidating {
  func validate(
    subscriptionSource: String,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws
}

extension SubscriptionProfilePreflightValidating {
  func validate(subscriptionSource: String, profileName: String) async throws {
    try await validate(
      subscriptionSource: subscriptionSource,
      profileName: profileName,
      providerOptions: .default
    )
  }
}

struct NoopSubscriptionProfilePreflightValidator: SubscriptionProfilePreflightValidating {
  func validate(
    subscriptionSource: String,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {}
}

struct MihomoSubscriptionProfilePreflightValidator: SubscriptionProfilePreflightValidating {
  var paths: RuntimePaths
  var overrides: RuntimeOverrides
  var coreURLProvider: @MainActor () throws -> URL
  var runtimeConfigValidator: any RuntimeConfigValidating
  var materializer: RuntimeConfigMaterializer

  init(
    paths: RuntimePaths,
    overrides: RuntimeOverrides,
    coreURLProvider: @escaping @MainActor () throws -> URL,
    runtimeConfigValidator: any RuntimeConfigValidating = MihomoRuntimeConfigValidator(),
    materializer: RuntimeConfigMaterializer = RuntimeConfigMaterializer()
  ) {
    self.paths = paths
    self.overrides = overrides
    self.coreURLProvider = coreURLProvider
    self.runtimeConfigValidator = runtimeConfigValidator
    self.materializer = materializer
  }

  func validate(
    subscriptionSource: String,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {
    let format = try ProfileConfigInspector.format(of: subscriptionSource)
    guard format == .proxyProviderContent || providerOptions.requiresRuntimeConfigPreflight else {
      return
    }

    let preflightDirectory = paths.runtime.appendingPathComponent(
      "subscription-preflight-\(UUID().uuidString)",
      isDirectory: true
    )
    try SecureFileIO.createPrivateDirectory(at: preflightDirectory)
    defer {
      try? FileManager.default.removeItem(at: preflightDirectory)
    }

    let sourceURL = preflightDirectory.appendingPathComponent("subscription.txt")
    let runtimeConfigDestinationURL = preflightDirectory.appendingPathComponent("runtime.yaml")
    let providerContentURL = preflightDirectory.appendingPathComponent("provider.txt")
    try SecureFileIO.writePrivateString(subscriptionSource, to: sourceURL)

    var preflightOverrides = overrides
    preflightOverrides.tunEnabled = false
    var preflightOptions = RuntimeConfigOptions.default
    preflightOptions.subscriptionProviderOptions = providerOptions
    let runtimeConfigURL = try await materializer.materialize(
      RuntimeConfigMaterializationRequest(
        profileName: profileName,
        sourcePath: sourceURL.path,
        runtimeConfigURL: runtimeConfigDestinationURL,
        providerContentURL: providerContentURL,
        overrides: preflightOverrides,
        selectionOverrides: [:],
        options: preflightOptions
      )
    )
    try await runtimeConfigValidator.validate(
      coreURL: try coreURLProvider(),
      configURL: runtimeConfigURL,
      workDirectory: preflightDirectory
    )
  }
}

@MainActor
final class ProfileStore: ObservableObject {
  private struct ProviderOptionSecretSnapshot: Sendable {
    var headers: [UUID: String?]
    var runtimeMergeYAML: String?
  }

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
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Profile {
    await waitForManifestLoad()
    return try await withMutationLock {
      let resolution = try Self.resolvedSubscriptionURL(from: url, displayNameHint: displayNameHint)
      let result = Self.fetchResult(
        try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
        displayNameHint: resolution.displayNameHint
      )
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let suggestedName = await Self.subscriptionDisplayNameAsync(
        metadata: result.metadata,
        source: result.source,
        url: resolution.url
      )
      let profileName = trimmedName.isEmpty ? suggestedName : trimmedName
      try await preflightValidator.validate(
        subscriptionSource: result.source,
        profileName: profileName,
        providerOptions: .default
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
        name: profileName,
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

  func updateSubscription(
    _ profile: Profile,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws {
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
        try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
        displayNameHint: resolution.displayNameHint
      )
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      let preflightName = nextProfiles.first { $0.id == profile.id }?.name ?? profile.name
      try await preflightValidator.validate(
        subscriptionSource: result.source,
        profileName: preflightName,
        providerOptions: nextProfiles.first { $0.id == profile.id }?.subscriptionProviderOptions ?? .default
      )
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
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
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
        try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
        displayNameHint: resolution.displayNameHint
      )
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      let preflightName = nextProfiles.first { $0.id == profile.id }?.name ?? profile.name
      try await preflightValidator.validate(
        subscriptionSource: result.source,
        profileName: preflightName,
        providerOptions: nextProfiles.first { $0.id == profile.id }?.subscriptionProviderOptions ?? .default
      )
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

  func updateSubscriptionSourceAndProviderOptions(
    _ profile: Profile,
    url: URL,
    displayNameHint: String? = nil,
    options: SubscriptionProviderOptions,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
            case let .subscription(id) = profiles[index].source
      else { return }
      let currentProfile = profiles[index]
      let resolution = try Self.resolvedSubscriptionURL(from: url, displayNameHint: displayNameHint)
      let account = Self.subscriptionAccount(for: id)
      let previousSource = try? await diskIO.readProfileSource(atPath: currentProfile.originalConfigPath)
      let previousURL = try await storedSubscriptionURL(for: id)
      let result = Self.fetchResult(
        try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
        displayNameHint: resolution.displayNameHint
      )
      var nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      guard let nextIndex = nextProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
      nextProfiles[nextIndex].subscriptionProviderOptions = options
      nextProfiles[nextIndex].updatedAt = Date()
      let nextProfile = nextProfiles[nextIndex]
      try await preflightValidator.validate(
        subscriptionSource: result.source,
        profileName: nextProfile.name,
        providerOptions: options
      )
      let secretSnapshot = await providerOptionSecretSnapshot(replacing: currentProfile, with: nextProfile)
      do {
        try await diskIO.writeProfileSource(result.source, to: URL(fileURLWithPath: currentProfile.originalConfigPath))
        try await secretIO.save(resolution.url.absoluteString, account: account)
        try await saveProviderOptionSecrets(for: nextProfile, replacing: currentProfile)
        try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      } catch {
        if let previousSource {
          try? await diskIO.writeProfileSource(previousSource, to: URL(fileURLWithPath: currentProfile.originalConfigPath))
        }
        if let previousURL {
          try? await secretIO.save(previousURL, account: account)
        } else {
          try? await secretIO.delete(account: account)
        }
        await restoreProviderOptionSecrets(secretSnapshot, for: currentProfile)
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

  func updateSubscriptionProviderOptions(
    _ profile: Profile,
    options: SubscriptionProviderOptions,
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
            profiles[index].isSubscription
      else { return }
      let currentProfile = profiles[index]
      let source = try await diskIO.readProfileSource(atPath: currentProfile.originalConfigPath)
      try await preflightValidator.validate(
        subscriptionSource: source,
        profileName: currentProfile.name,
        providerOptions: options
      )
      var nextProfiles = profiles
      nextProfiles[index].subscriptionProviderOptions = options
      nextProfiles[index].updatedAt = Date()
      let secretSnapshot = await providerOptionSecretSnapshot(replacing: currentProfile, with: nextProfiles[index])
      do {
        try await saveProviderOptionSecrets(for: nextProfiles[index], replacing: currentProfile)
        try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      } catch {
        await restoreProviderOptionSecrets(secretSnapshot, for: currentProfile)
        throw error
      }
      profiles = nextProfiles
    }
  }

  func updateSubscriptionUpdatePolicy(_ profile: Profile, policy: SubscriptionUpdatePolicy) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
            profiles[index].isSubscription
      else { return }
      var nextProfiles = profiles
      nextProfiles[index].subscriptionUpdatePolicy = policy
      nextProfiles[index].updatedAt = Date()
      try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      profiles = nextProfiles
    }
  }

  func markSubscriptionUpdateStarted(profileID: Profile.ID, at date: Date) async throws {
    try await updateSubscriptionUpdateStatus(profileID: profileID) { status in
      status.started(at: date)
    }
  }

  func markSubscriptionUpdateSucceeded(profileID: Profile.ID, at date: Date, nextUpdateAt: Date?) async throws {
    try await updateSubscriptionUpdateStatus(profileID: profileID) { status in
      status.succeeded(at: date, nextUpdateAt: nextUpdateAt)
    }
  }

  func markSubscriptionUpdateFailed(
    profileID: Profile.ID,
    message: String,
    at date: Date,
    backoffUntil: Date?,
    nextUpdateAt: Date?
  ) async throws {
    try await updateSubscriptionUpdateStatus(profileID: profileID) { status in
      status.failed(message: message, at: date, backoffUntil: backoffUntil, nextUpdateAt: nextUpdateAt)
    }
  }

  func updateSubscriptionNextUpdateDates(_ nextUpdateDates: [Profile.ID: Date?]) async {
    await waitForManifestLoad()
    do {
      try await withMutationLock {
        var nextProfiles = profiles
        var changed = false
        for index in nextProfiles.indices where nextProfiles[index].isSubscription {
          guard nextUpdateDates.keys.contains(nextProfiles[index].id) else { continue }
          let nextUpdateAt = nextUpdateDates[nextProfiles[index].id] ?? nil
          if nextProfiles[index].subscriptionUpdateStatus.nextUpdateAt != nextUpdateAt {
            nextProfiles[index].subscriptionUpdateStatus = nextProfiles[index].subscriptionUpdateStatus
              .scheduled(nextUpdateAt: nextUpdateAt)
            changed = true
          }
        }
        guard changed else { return }
        try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
        profiles = nextProfiles
      }
    } catch {
      // Scheduling metadata should never block the app from running.
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
        await deleteProviderOptionSecrets(for: current)
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

  private func updateSubscriptionUpdateStatus(
    profileID: Profile.ID,
    transform: (SubscriptionUpdateStatus) -> SubscriptionUpdateStatus
  ) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profileID }),
            profiles[index].isSubscription
      else { return }
      var nextProfiles = profiles
      nextProfiles[index].subscriptionUpdateStatus = transform(nextProfiles[index].subscriptionUpdateStatus)
      try await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
      profiles = nextProfiles
    }
  }

  nonisolated private static func subscriptionAccount(for id: UUID) -> String {
    "subscription.\(id.uuidString)"
  }

  nonisolated private static func subscriptionHeaderAccount(subscriptionID: UUID, headerID: UUID) -> String {
    "subscription.\(subscriptionID.uuidString).header.\(headerID.uuidString)"
  }

  nonisolated private static func subscriptionRuntimeMergeAccount(subscriptionID: UUID) -> String {
    "subscription.\(subscriptionID.uuidString).runtimeMergeYAML"
  }

  private func fetchSubscription(
    url: URL,
    session: URLSession,
    options: SubscriptionFetchOptions
  ) async throws -> SubscriptionFetchResult {
    guard session !== URLSession.shared else {
      return try await subscriptionFetcher.fetch(url: url, options: options)
    }
    return try await subscriptionFetcher.fetch(url: url, options: options) { _ in
      try await session.data(for: subscriptionFetcher.request(url: url, options: options))
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
      let hydrated = await profilesByHydratingHeaderSecrets(manifest.profiles)
      profiles = hydrated.profiles
      activeProfileID = manifest.activeProfileID
      subscriptionURLCache = loadedSubscriptionURLs
      if hydrated.shouldRewriteManifest {
        try await saveManifest(profiles: hydrated.profiles, activeProfileID: manifest.activeProfileID)
      }
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

  private func profilesByHydratingHeaderSecrets(_ loadedProfiles: [Profile]) async -> (
    profiles: [Profile],
    shouldRewriteManifest: Bool
  ) {
    var hydratedProfiles = loadedProfiles
    var shouldRewriteManifest = false

    for profileIndex in hydratedProfiles.indices {
      guard case let .subscription(subscriptionID) = hydratedProfiles[profileIndex].source else {
        continue
      }
      var providerOptions = hydratedProfiles[profileIndex].subscriptionProviderOptions
      var headers = providerOptions.requestHeaders
      for headerIndex in headers.indices {
        let headerID = headers[headerIndex].id
        let legacyValue = headers[headerIndex].value
        let account = Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: headerID)
        if let storedValue = try? await secretIO.load(account: account) {
          headers[headerIndex].value = storedValue
          if !legacyValue.isEmpty {
            shouldRewriteManifest = true
          }
        } else if !legacyValue.isEmpty {
          do {
            try await secretIO.save(legacyValue, account: account)
            headers[headerIndex].value = legacyValue
            shouldRewriteManifest = true
          } catch {
            headers[headerIndex].value = ""
          }
        }
      }
      providerOptions.requestHeaders = headers

      let legacyRuntimeMergeYAML = providerOptions.runtimeMergeYAML
      let runtimeMergeAccount = Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID)
      if let storedRuntimeMergeYAML = try? await secretIO.load(account: runtimeMergeAccount) {
        providerOptions.runtimeMergeYAML = storedRuntimeMergeYAML
        if !legacyRuntimeMergeYAML.isEmpty {
          shouldRewriteManifest = true
        }
      } else if !legacyRuntimeMergeYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        do {
          try await secretIO.save(legacyRuntimeMergeYAML, account: runtimeMergeAccount)
          providerOptions.runtimeMergeYAML = legacyRuntimeMergeYAML
          shouldRewriteManifest = true
        } catch {
          providerOptions.runtimeMergeYAML = ""
        }
      }

      hydratedProfiles[profileIndex].subscriptionProviderOptions = providerOptions
    }

    return (hydratedProfiles, shouldRewriteManifest)
  }

  private func providerOptionSecretSnapshot(
    replacing currentProfile: Profile,
    with nextProfile: Profile
  ) async -> ProviderOptionSecretSnapshot {
    ProviderOptionSecretSnapshot(
      headers: await headerSecretSnapshot(replacing: currentProfile, with: nextProfile),
      runtimeMergeYAML: await runtimeMergeSecretSnapshot(for: currentProfile)
    )
  }

  private func headerSecretSnapshot(replacing currentProfile: Profile, with nextProfile: Profile) async -> [UUID: String?] {
    guard case let .subscription(subscriptionID) = currentProfile.source else { return [:] }
    let currentIDs = currentProfile.subscriptionProviderOptions.requestHeaders.map(\.id)
    let nextIDs = nextProfile.subscriptionProviderOptions.requestHeaders.map(\.id)
    let headerIDs = Set(currentIDs + nextIDs)
    var snapshot: [UUID: String?] = [:]
    for headerID in headerIDs {
      snapshot[headerID] = try? await secretIO.load(
        account: Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: headerID)
      )
    }
    return snapshot
  }

  private func runtimeMergeSecretSnapshot(for profile: Profile) async -> String? {
    guard case let .subscription(subscriptionID) = profile.source else { return nil }
    return try? await secretIO.load(account: Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID))
  }

  private func saveProviderOptionSecrets(for profile: Profile, replacing previousProfile: Profile?) async throws {
    try await saveHeaderSecrets(for: profile, replacing: previousProfile)
    try await saveRuntimeMergeSecret(for: profile)
  }

  private func saveHeaderSecrets(for profile: Profile, replacing previousProfile: Profile?) async throws {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    let nextHeaders = profile.subscriptionProviderOptions.requestHeaders
    let nextHeaderIDs = Set(nextHeaders.map(\.id))

    for header in nextHeaders {
      try await secretIO.save(
        header.value,
        account: Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: header.id)
      )
    }

    let previousHeaderIDs = Set(previousProfile?.subscriptionProviderOptions.requestHeaders.map(\.id) ?? [])
    for removedHeaderID in previousHeaderIDs.subtracting(nextHeaderIDs) {
      try await secretIO.delete(
        account: Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: removedHeaderID)
      )
    }
  }

  private func saveRuntimeMergeSecret(for profile: Profile) async throws {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    let account = Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID)
    let runtimeMergeYAML = profile.subscriptionProviderOptions.runtimeMergeYAML
    if runtimeMergeYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try await secretIO.delete(account: account)
    } else {
      try await secretIO.save(runtimeMergeYAML, account: account)
    }
  }

  private func restoreProviderOptionSecrets(_ snapshot: ProviderOptionSecretSnapshot, for profile: Profile) async {
    await restoreHeaderSecrets(snapshot.headers, for: profile)
    await restoreRuntimeMergeSecret(snapshot.runtimeMergeYAML, for: profile)
  }

  private func restoreHeaderSecrets(_ snapshot: [UUID: String?], for profile: Profile) async {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    for (headerID, value) in snapshot {
      let account = Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: headerID)
      if let value {
        try? await secretIO.save(value, account: account)
      } else {
        try? await secretIO.delete(account: account)
      }
    }
  }

  private func restoreRuntimeMergeSecret(_ value: String?, for profile: Profile) async {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    let account = Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID)
    if let value {
      try? await secretIO.save(value, account: account)
    } else {
      try? await secretIO.delete(account: account)
    }
  }

  private func deleteProviderOptionSecrets(for profile: Profile) async {
    await deleteHeaderSecrets(for: profile)
    await deleteRuntimeMergeSecret(for: profile)
  }

  private func deleteHeaderSecrets(for profile: Profile) async {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    for header in profile.subscriptionProviderOptions.requestHeaders {
      try? await secretIO.delete(
        account: Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: header.id)
      )
    }
  }

  private func deleteRuntimeMergeSecret(for profile: Profile) async {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    try? await secretIO.delete(account: Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID))
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
