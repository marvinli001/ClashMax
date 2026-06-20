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

  func validate(
    subscriptionSource: String,
    profileID: Profile.ID?,
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

  func validate(
    subscriptionSource: String,
    profileID: Profile.ID?,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {
    try await validate(
      subscriptionSource: subscriptionSource,
      profileName: profileName,
      providerOptions: providerOptions
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

struct SubscriptionPreflightValidationError: Error, LocalizedError, CustomStringConvertible {
  var message: String
  var fullMessage: String?
  var diagnostics: SubscriptionPreflightDiagnostics

  init(error: Error, diagnostics: SubscriptionPreflightDiagnostics) {
    // Prefer the extracted short summary (the actual Mihomo failure line) over the
    // raw error text, which UserFacingError truncates to its first ~217 chars and
    // would surface only the benign log head (see issue #7).
    self.message = diagnostics.localizedMessage ?? UserFacingError.message(for: error)
    self.fullMessage = diagnostics.fullMessage
    self.diagnostics = diagnostics
  }

  var errorDescription: String? { message }
  var description: String { message }
}

struct MihomoSubscriptionProfilePreflightValidator: SubscriptionProfilePreflightValidating {
  var paths: RuntimePaths
  var overrides: RuntimeOverrides
  var coreURLProvider: @MainActor () throws -> URL
  var runtimeConfigValidator: any RuntimeConfigValidating
  var materializer: RuntimeConfigMaterializer
  var runtimeSnippetsProvider: @MainActor (Profile.ID?) async -> [RuntimeSnippet]

  init(
    paths: RuntimePaths,
    overrides: RuntimeOverrides,
    coreURLProvider: @escaping @MainActor () throws -> URL,
    runtimeConfigValidator: any RuntimeConfigValidating = MihomoRuntimeConfigValidator(),
    materializer: RuntimeConfigMaterializer = RuntimeConfigMaterializer(),
    runtimeSnippetsProvider: @escaping @MainActor (Profile.ID?) async -> [RuntimeSnippet] = { _ in [] }
  ) {
    self.paths = paths
    self.overrides = overrides
    self.coreURLProvider = coreURLProvider
    self.runtimeConfigValidator = runtimeConfigValidator
    self.materializer = materializer
    self.runtimeSnippetsProvider = runtimeSnippetsProvider
  }

  func validate(
    subscriptionSource: String,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {
    try await validate(
      subscriptionSource: subscriptionSource,
      profileID: nil,
      profileName: profileName,
      providerOptions: providerOptions
    )
  }

  func validate(
    subscriptionSource: String,
    profileID: Profile.ID?,
    profileName: String,
    providerOptions: SubscriptionProviderOptions
  ) async throws {
    _ = try ProfileConfigInspector.format(of: subscriptionSource)

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

    let preflightOverrides = overrides
    var preflightOptions = RuntimeConfigOptions.default
    preflightOptions.subscriptionProviderOptions = providerOptions
    preflightOptions.runtimeSnippets = await runtimeSnippetsProvider(profileID)
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
    providerOptions: SubscriptionProviderOptions = .default,
    updatePolicy: SubscriptionUpdatePolicy = .default,
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
      let preflightDiagnostics = try await validateSubscriptionPreflight(
        subscriptionSource: result.source,
        profileID: nil,
        profileName: profileName,
        providerOptions: providerOptions,
        preflightValidator: preflightValidator
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

      var diagnostics = SubscriptionDiagnostics(
        latestFetch: result.diagnostics,
        latestPreflight: preflightDiagnostics
      )
      diagnostics.appendHistory(
        SubscriptionUpdateHistoryEntry(
          trigger: .importProfile,
          result: .succeeded,
          fetchStrategy: result.diagnostics.successfulStrategy,
          httpStatusCode: result.diagnostics.httpStatusCode
        )
      )
      let profile = Profile(
        id: id,
        name: profileName,
        nameIsUserCustomized: !trimmedName.isEmpty,
        source: .subscription(id: id),
        originalConfigPath: destination.path,
        subscriptionMetadata: result.metadata,
        subscriptionProviderOptions: providerOptions,
        subscriptionUpdatePolicy: updatePolicy,
        subscriptionDiagnostics: diagnostics
      )
      do {
        try await saveProviderOptionSecrets(for: profile, replacing: nil)
      } catch {
        try? await diskIO.removeProfileConfig(atPath: destination.path)
        try? await secretIO.delete(account: Self.subscriptionAccount(for: id))
        await deleteProviderOptionSecrets(for: profile)
        throw error
      }
      let nextProfiles = profiles + [profile]
      do {
        try await saveManifest(profiles: nextProfiles, activeProfileID: profile.id)
      } catch {
        try? await diskIO.removeProfileConfig(atPath: destination.path)
        try? await secretIO.delete(account: Self.subscriptionAccount(for: id))
        await deleteProviderOptionSecrets(for: profile)
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
      let result: SubscriptionFetchResult
      do {
        result = Self.fetchResult(
          try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
          displayNameHint: resolution.displayNameHint
        )
      } catch {
        if let diagnostics = fetchDiagnostics(from: error) {
          let nextProfiles = profilesByRecordingFetchDiagnostics(diagnostics, for: profile.id)
          try? await saveManifest(profiles: nextProfiles, activeProfileID: activeProfileID)
          profiles = nextProfiles
        }
        throw error
      }
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      let preflightName = nextProfiles.first { $0.id == profile.id }?.name ?? profile.name
      let preflightDiagnostics: SubscriptionPreflightDiagnostics
      do {
        preflightDiagnostics = try await validateSubscriptionPreflight(
          subscriptionSource: result.source,
          profileID: profile.id,
          profileName: preflightName,
          providerOptions: nextProfiles.first { $0.id == profile.id }?.subscriptionProviderOptions ?? .default,
          preflightValidator: preflightValidator
        )
      } catch let error as SubscriptionPreflightValidationError {
        var failedProfiles = profilesByRecordingFetchDiagnostics(result.diagnostics, for: profile.id)
        failedProfiles = profilesByRecordingPreflightDiagnostics(error.diagnostics, for: profile.id, in: failedProfiles)
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      let validatedProfiles = profilesByRecordingPreflightDiagnostics(
        preflightDiagnostics,
        for: profile.id,
        in: nextProfiles
      )
      do {
        try await diskIO.writeProfileSource(result.source, to: URL(fileURLWithPath: profile.originalConfigPath))
        if rawURL != resolution.url.absoluteString {
          try await secretIO.save(resolution.url.absoluteString, account: Self.subscriptionAccount(for: id))
        }
        try await saveManifest(profiles: validatedProfiles, activeProfileID: activeProfileID)
      } catch {
        if let previousSource {
          try? await diskIO.writeProfileSource(previousSource, to: URL(fileURLWithPath: profile.originalConfigPath))
        }
        throw error
      }
      profiles = validatedProfiles
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
      let result: SubscriptionFetchResult
      do {
        result = Self.fetchResult(
          try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
          displayNameHint: resolution.displayNameHint
        )
      } catch {
        var failedProfiles = profiles
        if let diagnostics = fetchDiagnostics(from: error) {
          failedProfiles = profilesByRecordingFetchDiagnostics(diagnostics, for: profile.id)
        }
        failedProfiles = profilesByAppendingSubscriptionHistory(
          trigger: .sourceEdit,
          result: .failed,
          failureKind: SubscriptionUpdateFailureKind.classify(error),
          message: UserFacingError.message(for: error),
          for: profile.id,
          in: failedProfiles
        )
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      let nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      let preflightName = nextProfiles.first { $0.id == profile.id }?.name ?? profile.name
      let preflightDiagnostics: SubscriptionPreflightDiagnostics
      do {
        preflightDiagnostics = try await validateSubscriptionPreflight(
          subscriptionSource: result.source,
          profileID: profile.id,
          profileName: preflightName,
          providerOptions: nextProfiles.first { $0.id == profile.id }?.subscriptionProviderOptions ?? .default,
          preflightValidator: preflightValidator
        )
      } catch let error as SubscriptionPreflightValidationError {
        var failedProfiles = profilesByRecordingFetchDiagnostics(result.diagnostics, for: profile.id)
        failedProfiles = profilesByRecordingPreflightDiagnostics(error.diagnostics, for: profile.id, in: failedProfiles)
        failedProfiles = profilesByAppendingSubscriptionHistory(
          trigger: .sourceEdit,
          result: .failed,
          failureKind: .preflight,
          message: error.message,
          for: profile.id,
          in: failedProfiles
        )
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      var validatedProfiles = profilesByRecordingPreflightDiagnostics(
        preflightDiagnostics,
        for: profile.id,
        in: nextProfiles
      )
      validatedProfiles = profilesByAppendingSubscriptionHistory(
        trigger: .sourceEdit,
        result: .succeeded,
        for: profile.id,
        in: validatedProfiles
      )
      do {
        try await diskIO.writeProfileSource(result.source, to: URL(fileURLWithPath: profile.originalConfigPath))
        try await secretIO.save(resolution.url.absoluteString, account: account)
        try await saveManifest(profiles: validatedProfiles, activeProfileID: activeProfileID)
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
      profiles = validatedProfiles
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
      let result: SubscriptionFetchResult
      do {
        result = Self.fetchResult(
          try await fetchSubscription(url: resolution.url, session: session, options: fetchOptions),
          displayNameHint: resolution.displayNameHint
        )
      } catch {
        var failedProfiles = profiles
        if let diagnostics = fetchDiagnostics(from: error) {
          failedProfiles = profilesByRecordingFetchDiagnostics(diagnostics, for: profile.id)
        }
        failedProfiles = profilesByAppendingSubscriptionHistory(
          trigger: .sourceAndProviderOptionsEdit,
          result: .failed,
          failureKind: SubscriptionUpdateFailureKind.classify(error),
          message: UserFacingError.message(for: error),
          for: profile.id,
          in: failedProfiles
        )
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      var nextProfiles = await profilesByApplyingSubscriptionDetails(result, sourceURL: resolution.url, for: profile.id)
      guard let nextIndex = nextProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
      nextProfiles[nextIndex].subscriptionProviderOptions = options
      nextProfiles[nextIndex].updatedAt = Date()
      let nextProfile = nextProfiles[nextIndex]
      let preflightDiagnostics: SubscriptionPreflightDiagnostics
      do {
        preflightDiagnostics = try await validateSubscriptionPreflight(
          subscriptionSource: result.source,
          profileID: profile.id,
          profileName: nextProfile.name,
          providerOptions: options,
          preflightValidator: preflightValidator
        )
      } catch let error as SubscriptionPreflightValidationError {
        var failedProfiles = profilesByRecordingFetchDiagnostics(result.diagnostics, for: profile.id)
        failedProfiles = profilesByRecordingPreflightDiagnostics(error.diagnostics, for: profile.id, in: failedProfiles)
        failedProfiles = profilesByAppendingSubscriptionHistory(
          trigger: .sourceAndProviderOptionsEdit,
          result: .failed,
          failureKind: .preflight,
          message: error.message,
          for: profile.id,
          in: failedProfiles
        )
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      nextProfiles = profilesByRecordingPreflightDiagnostics(
        preflightDiagnostics,
        for: profile.id,
        in: nextProfiles
      )
      nextProfiles = profilesByAppendingSubscriptionHistory(
        trigger: .sourceAndProviderOptionsEdit,
        result: .succeeded,
        for: profile.id,
        in: nextProfiles
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
      let preflightDiagnostics: SubscriptionPreflightDiagnostics
      do {
        preflightDiagnostics = try await validateSubscriptionPreflight(
          subscriptionSource: source,
          profileID: profile.id,
          profileName: currentProfile.name,
          providerOptions: options,
          preflightValidator: preflightValidator
        )
      } catch let error as SubscriptionPreflightValidationError {
        var failedProfiles = profilesByRecordingPreflightDiagnostics(error.diagnostics, for: profile.id, in: profiles)
        failedProfiles = profilesByAppendingSubscriptionHistory(
          trigger: .providerOptionsEdit,
          result: .failed,
          failureKind: .preflight,
          message: error.message,
          for: profile.id,
          in: failedProfiles
        )
        try? await saveManifest(profiles: failedProfiles, activeProfileID: activeProfileID)
        profiles = failedProfiles
        throw error
      }
      var nextProfiles = profiles
      nextProfiles[index].subscriptionProviderOptions = options
      nextProfiles[index].subscriptionDiagnostics.recordPreflight(preflightDiagnostics)
      nextProfiles[index].subscriptionDiagnostics.appendHistory(
        Self.subscriptionHistoryEntry(
          profile: nextProfiles[index],
          trigger: .providerOptionsEdit,
          result: .succeeded,
          at: Date()
        )
      )
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
    try await updateSubscriptionUpdateStatus(profileID: profileID) { profile in
      profile.subscriptionUpdateStatus = profile.subscriptionUpdateStatus.started(at: date)
    }
  }

  func markSubscriptionUpdateSucceeded(
    profileID: Profile.ID,
    trigger: SubscriptionUpdateTrigger,
    at date: Date,
    nextUpdateAt: Date?
  ) async throws {
    try await updateSubscriptionUpdateStatus(profileID: profileID) { profile in
      profile.subscriptionUpdateStatus = profile.subscriptionUpdateStatus.succeeded(
        at: date,
        nextUpdateAt: nextUpdateAt
      )
      profile.subscriptionDiagnostics.appendHistory(
        Self.subscriptionHistoryEntry(
          profile: profile,
          trigger: trigger,
          result: .succeeded,
          at: date
        )
      )
    }
  }

  func markSubscriptionUpdateFailed(
    profileID: Profile.ID,
    trigger: SubscriptionUpdateTrigger,
    message: String,
    failureKind: SubscriptionUpdateFailureKind,
    at date: Date,
    backoffUntil: Date?,
    nextUpdateAt: Date?,
    fetchDiagnostics: SubscriptionFetchDiagnostics? = nil
  ) async throws {
    try await updateSubscriptionUpdateStatus(profileID: profileID) { profile in
      if let fetchDiagnostics {
        profile.subscriptionDiagnostics.recordFetch(fetchDiagnostics)
      }
      profile.subscriptionUpdateStatus = profile.subscriptionUpdateStatus.failed(
        message: message,
        at: date,
        backoffUntil: backoffUntil,
        nextUpdateAt: nextUpdateAt
      )
      profile.subscriptionDiagnostics.appendHistory(
        Self.subscriptionHistoryEntry(
          profile: profile,
          trigger: trigger,
          result: .failed,
          failureKind: failureKind,
          message: message,
          at: date
        )
      )
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

  func backupExport(includeSecrets: Bool) async throws -> BackupProfileExport {
    await waitForManifestLoad()
    var backupProfiles: [Profile] = []
    var profileSources: [BackupProfileSource] = []
    var subscriptionSecrets: [BackupSubscriptionSecrets] = []
    var omittedSummary = BackupSecretSummary()

    for profile in profiles {
      let source = try await diskIO.readProfileSource(atPath: profile.originalConfigPath)
      try ProfileConfigValidator.validateProfileSource(source, allowProviderContent: profile.isSubscription)
      profileSources.append(
        BackupProfileSource(
          profileID: profile.id,
          fileName: "\(profile.id.uuidString).yaml",
          source: source
        )
      )

      let secretSnapshot = try await backupSecrets(for: profile)
      omittedSummary.subscriptionURLCount += secretSnapshot.subscriptionURL == nil ? 0 : 1
      omittedSummary.requestHeaderValueCount += secretSnapshot.requestHeaders.count
      omittedSummary.runtimeMergeYAMLCount += secretSnapshot.runtimeMergeYAML == nil ? 0 : 1
      if includeSecrets, secretSnapshot.hasSecrets {
        subscriptionSecrets.append(secretSnapshot)
      }

      backupProfiles.append(Self.sanitizedBackupProfile(profile))
    }

    return BackupProfileExport(
      manifest: ProfileManifest(profiles: backupProfiles, activeProfileID: activeProfileID),
      profileSources: profileSources,
      secrets: BackupSecretsBundle(subscriptions: subscriptionSecrets),
      omittedSecretSummary: omittedSummary
    )
  }

  func rollbackSnapshot() async throws -> ProfileStoreRollbackSnapshot {
    await waitForManifestLoad()
    return try await withMutationLock {
      var sourceByProfileID: [Profile.ID: String] = [:]
      var secretsByProfileID: [Profile.ID: BackupSubscriptionSecrets] = [:]

      for profile in profiles {
        sourceByProfileID[profile.id] = try await diskIO.readProfileSource(atPath: profile.originalConfigPath)
        guard profile.isSubscription else { continue }
        secretsByProfileID[profile.id] = try await backupSecrets(for: profile)
      }

      return ProfileStoreRollbackSnapshot(
        manifest: ProfileManifest(profiles: profiles, activeProfileID: activeProfileID),
        profileSources: sourceByProfileID,
        subscriptionSecrets: secretsByProfileID,
        subscriptionURLCache: subscriptionURLCache
      )
    }
  }

  func restoreRollbackSnapshot(_ snapshot: ProfileStoreRollbackSnapshot) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      let snapshotProfileIDs = Set(snapshot.manifest.profiles.map(\.id))
      for profile in profiles where !snapshotProfileIDs.contains(profile.id) {
        try? await diskIO.removeProfileConfig(atPath: profile.originalConfigPath)
        await deleteStoredSubscriptionSecrets(for: profile)
      }

      for profile in snapshot.manifest.profiles {
        guard let source = snapshot.profileSources[profile.id] else { continue }
        try await diskIO.writeProfileSource(source, to: URL(fileURLWithPath: profile.originalConfigPath))
      }

      subscriptionURLCache = snapshot.subscriptionURLCache
      for profile in snapshot.manifest.profiles {
        try await restoreStoredSubscriptionSecrets(snapshot.subscriptionSecrets[profile.id], for: profile)
      }

      try await saveManifest(
        profiles: snapshot.manifest.profiles,
        activeProfileID: snapshot.manifest.activeProfileID
      )
      profiles = snapshot.manifest.profiles
      activeProfileID = snapshot.manifest.activeProfileID
    }
  }

  func mergeRestoreBackup(
    manifest: ProfileManifest,
    profileSources: [BackupProfileSource],
    secrets: BackupSecretsBundle?
  ) async throws -> BackupProfileRestoreResult {
    await waitForManifestLoad()
    return try await withMutationLock {
      try Self.validateUniqueBackupProfileIDs(manifest.profiles.map(\.id))
      let sourceByProfileID = try Self.backupProfileSourceIndex(profileSources)
      let secretsByProfileID = try Self.backupSecretsIndex(secrets?.subscriptions ?? [])
      var usedIDs = Set(profiles.map(\.id))
      var idMap: [Profile.ID: Profile.ID] = [:]
      var restoredProfiles: [Profile] = []
      var writtenProfileURLs: [URL] = []
      var writtenSecretAccounts: [String] = []
      var restoredSecretCount = 0
      var restoredSubscriptionURLCache: [Profile.ID: String] = [:]

      do {
        for backupProfile in manifest.profiles {
          guard let sourceEntry = sourceByProfileID[backupProfile.id] else {
            throw BackupRestoreError.missingProfileSource(backupProfile.id)
          }
          try ProfileConfigValidator.validateProfileSource(
            sourceEntry.source,
            allowProviderContent: backupProfile.isSubscription
          )

          let restoredID = Self.restoredID(for: backupProfile.id, usedIDs: &usedIDs)
          idMap[backupProfile.id] = restoredID
          let destination = paths.profiles.appendingPathComponent("\(restoredID.uuidString).yaml")
          try await diskIO.writeProfileSource(sourceEntry.source, to: destination)
          writtenProfileURLs.append(destination)

          var restoredProfile = Self.restoredBackupProfile(
            backupProfile,
            restoredID: restoredID,
            destination: destination
          )
          if let subscriptionSecrets = secretsByProfileID[backupProfile.id] {
            restoredSecretCount += try await applyBackupSecrets(
              subscriptionSecrets,
              to: &restoredProfile,
              restoredID: restoredID,
              writtenAccounts: &writtenSecretAccounts,
              subscriptionURLCache: &restoredSubscriptionURLCache
            )
          }
          restoredProfiles.append(restoredProfile)
        }

        let nextProfiles = profiles + restoredProfiles
        let restoredActiveProfileID = manifest.activeProfileID.flatMap { idMap[$0] }
          ?? activeProfileID
          ?? nextProfiles.first?.id
        try await saveManifest(profiles: nextProfiles, activeProfileID: restoredActiveProfileID)
        profiles = nextProfiles
        activeProfileID = restoredActiveProfileID
        for (id, url) in restoredSubscriptionURLCache {
          subscriptionURLCache[id] = url
        }

        return BackupProfileRestoreResult(
          importedProfileCount: restoredProfiles.count,
          activeProfileID: restoredActiveProfileID,
          idMap: idMap,
          restoredSecretCount: restoredSecretCount
        )
      } catch {
        for url in writtenProfileURLs {
          try? await diskIO.removeProfileConfig(atPath: url.path)
        }
        for account in writtenSecretAccounts {
          try? await secretIO.delete(account: account)
        }
        throw error
      }
    }
  }

  private static func validateUniqueBackupProfileIDs(_ ids: [Profile.ID]) throws {
    var seen = Set<Profile.ID>()
    for id in ids {
      guard seen.insert(id).inserted else {
        throw BackupRestoreError.invalidBackup("Profile manifest contains duplicate profile IDs.")
      }
    }
  }

  private static func backupProfileSourceIndex(
    _ profileSources: [BackupProfileSource]
  ) throws -> [Profile.ID: BackupProfileSource] {
    var index: [Profile.ID: BackupProfileSource] = [:]
    for profileSource in profileSources {
      guard index[profileSource.profileID] == nil else {
        throw BackupRestoreError.invalidBackup("Profile sources contain duplicate profile IDs.")
      }
      index[profileSource.profileID] = profileSource
    }
    return index
  }

  private static func backupSecretsIndex(
    _ subscriptions: [BackupSubscriptionSecrets]
  ) throws -> [Profile.ID: BackupSubscriptionSecrets] {
    var index: [Profile.ID: BackupSubscriptionSecrets] = [:]
    for subscription in subscriptions {
      guard index[subscription.profileID] == nil else {
        throw BackupRestoreError.invalidBackup("Subscription secrets contain duplicate profile IDs.")
      }
      index[subscription.profileID] = subscription
    }
    return index
  }

  private func updateSubscriptionUpdateStatus(
    profileID: Profile.ID,
    transform: (inout Profile) -> Void
  ) async throws {
    await waitForManifestLoad()
    try await withMutationLock {
      guard let index = profiles.firstIndex(where: { $0.id == profileID }),
            profiles[index].isSubscription
      else { return }
      var nextProfiles = profiles
      transform(&nextProfiles[index])
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

  private func backupSecrets(for profile: Profile) async throws -> BackupSubscriptionSecrets {
    guard case let .subscription(subscriptionID) = profile.source else {
      return BackupSubscriptionSecrets(
        profileID: profile.id,
        subscriptionURL: nil,
        requestHeaders: [],
        runtimeMergeYAML: nil
      )
    }

    let subscriptionURL = try await storedSubscriptionURL(for: subscriptionID)
    let requestHeaders = profile.subscriptionProviderOptions.requestHeaders.compactMap { header in
      let value = header.normalizedValue
      return value.isEmpty ? nil : BackupRequestHeaderSecret(headerID: header.id, value: value)
    }
    let runtimeMergeYAML = profile.subscriptionProviderOptions.runtimeMergeYAML
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
      ? nil
      : profile.subscriptionProviderOptions.runtimeMergeYAML
    return BackupSubscriptionSecrets(
      profileID: profile.id,
      subscriptionURL: subscriptionURL,
      requestHeaders: requestHeaders,
      runtimeMergeYAML: runtimeMergeYAML
    )
  }

  private static func sanitizedBackupProfile(_ profile: Profile) -> Profile {
    var sanitized = profile
    sanitized.originalConfigPath = "Profiles/\(profile.id.uuidString).yaml"
    if case .localFile = sanitized.source {
      sanitized.source = .localFile(originalPath: nil)
    }
    sanitized.subscriptionProviderOptions = sanitizedProviderOptions(sanitized.subscriptionProviderOptions)
    return sanitized
  }

  private static func restoredBackupProfile(
    _ profile: Profile,
    restoredID: Profile.ID,
    destination: URL
  ) -> Profile {
    var restored = profile
    restored.id = restoredID
    restored.originalConfigPath = destination.path
    switch restored.source {
    case .localFile:
      restored.source = .localFile(originalPath: nil)
    case .subscription:
      restored.source = .subscription(id: restoredID)
    }
    restored.subscriptionProviderOptions = sanitizedProviderOptions(restored.subscriptionProviderOptions)
    return restored
  }

  private static func sanitizedProviderOptions(_ options: SubscriptionProviderOptions) -> SubscriptionProviderOptions {
    var sanitized = options
    sanitized.runtimeMergeYAML = ""
    sanitized.requestHeaders = sanitized.requestHeaders.map { header in
      SubscriptionRequestHeader(id: header.id, name: header.name, value: "")
    }
    return sanitized
  }

  private static func restoredID(for id: Profile.ID, usedIDs: inout Set<Profile.ID>) -> Profile.ID {
    if !usedIDs.contains(id) {
      usedIDs.insert(id)
      return id
    }
    var replacement = UUID()
    while usedIDs.contains(replacement) {
      replacement = UUID()
    }
    usedIDs.insert(replacement)
    return replacement
  }

  private func applyBackupSecrets(
    _ secrets: BackupSubscriptionSecrets,
    to profile: inout Profile,
    restoredID: Profile.ID,
    writtenAccounts: inout [String],
    subscriptionURLCache: inout [Profile.ID: String]
  ) async throws -> Int {
    guard profile.isSubscription else { return 0 }
    var restoredCount = 0

    if let subscriptionURL = secrets.subscriptionURL {
      let account = Self.subscriptionAccount(for: restoredID)
      try await secretIO.save(subscriptionURL, account: account)
      writtenAccounts.append(account)
      subscriptionURLCache[restoredID] = subscriptionURL
      restoredCount += 1
    }

    if !secrets.requestHeaders.isEmpty {
      let profileHeaderIDs = Set(profile.subscriptionProviderOptions.requestHeaders.map(\.id))
      var headerValues: [SubscriptionRequestHeader.ID: String] = [:]
      for header in secrets.requestHeaders {
        guard headerValues[header.headerID] == nil else {
          throw BackupRestoreError.invalidBackup("Subscription secrets contain duplicate request header IDs.")
        }
        guard profileHeaderIDs.contains(header.headerID) else {
          throw BackupRestoreError.invalidBackup("Subscription secrets reference an unknown request header.")
        }
        headerValues[header.headerID] = header.value
      }
      profile.subscriptionProviderOptions.requestHeaders = profile.subscriptionProviderOptions.requestHeaders.map { header in
        guard let value = headerValues[header.id] else { return header }
        return SubscriptionRequestHeader(id: header.id, name: header.name, value: value)
      }
      for header in profile.subscriptionProviderOptions.requestHeaders {
        guard let value = headerValues[header.id] else { continue }
        let account = Self.subscriptionHeaderAccount(subscriptionID: restoredID, headerID: header.id)
        try await secretIO.save(value, account: account)
        writtenAccounts.append(account)
        restoredCount += 1
      }
    }

    if let runtimeMergeYAML = secrets.runtimeMergeYAML {
      let account = Self.subscriptionRuntimeMergeAccount(subscriptionID: restoredID)
      profile.subscriptionProviderOptions.runtimeMergeYAML = runtimeMergeYAML
      try await secretIO.save(runtimeMergeYAML, account: account)
      writtenAccounts.append(account)
      restoredCount += 1
    }

    return restoredCount
  }

  private func deleteStoredSubscriptionSecrets(for profile: Profile) async {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    try? await secretIO.delete(account: Self.subscriptionAccount(for: subscriptionID))
    for header in profile.subscriptionProviderOptions.requestHeaders {
      try? await secretIO.delete(
        account: Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: header.id)
      )
    }
    try? await secretIO.delete(account: Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID))
    subscriptionURLCache.removeValue(forKey: subscriptionID)
  }

  private func restoreStoredSubscriptionSecrets(
    _ secrets: BackupSubscriptionSecrets?,
    for profile: Profile
  ) async throws {
    guard case let .subscription(subscriptionID) = profile.source else { return }
    guard let secrets else {
      await deleteStoredSubscriptionSecrets(for: profile)
      return
    }

    if let subscriptionURL = secrets.subscriptionURL {
      try await secretIO.save(subscriptionURL, account: Self.subscriptionAccount(for: subscriptionID))
      subscriptionURLCache[subscriptionID] = subscriptionURL
    } else {
      try? await secretIO.delete(account: Self.subscriptionAccount(for: subscriptionID))
      subscriptionURLCache.removeValue(forKey: subscriptionID)
    }

    let headerValues = secrets.requestHeaders.reduce(into: [SubscriptionRequestHeader.ID: String]()) { result, header in
      result[header.headerID] = header.value
    }
    for header in profile.subscriptionProviderOptions.requestHeaders {
      let account = Self.subscriptionHeaderAccount(subscriptionID: subscriptionID, headerID: header.id)
      if let value = headerValues[header.id] {
        try await secretIO.save(value, account: account)
      } else {
        try? await secretIO.delete(account: account)
      }
    }

    let runtimeMergeAccount = Self.subscriptionRuntimeMergeAccount(subscriptionID: subscriptionID)
    if let runtimeMergeYAML = secrets.runtimeMergeYAML {
      try await secretIO.save(runtimeMergeYAML, account: runtimeMergeAccount)
    } else {
      try? await secretIO.delete(account: runtimeMergeAccount)
    }
  }

  private func fetchSubscription(
    url: URL,
    session: URLSession,
    options: SubscriptionFetchOptions
  ) async throws -> SubscriptionFetchResult {
    guard session !== URLSession.shared else {
      return try await subscriptionFetcher.fetch(url: url, options: options)
    }
    return try await subscriptionFetcher.fetch(url: url, options: options) { _, userAgent in
      try await session.data(for: subscriptionFetcher.request(url: url, options: options, userAgent: userAgent))
    }
  }

  private func validateSubscriptionPreflight(
    subscriptionSource: String,
    profileID: Profile.ID?,
    profileName: String,
    providerOptions: SubscriptionProviderOptions,
    preflightValidator: any SubscriptionProfilePreflightValidating
  ) async throws -> SubscriptionPreflightDiagnostics {
    guard Self.requiresSubscriptionPreflight(subscriptionSource: subscriptionSource, providerOptions: providerOptions) else {
      return SubscriptionPreflightDiagnostics(
        result: .skipped,
        messageKind: .notRequired
      )
    }

    do {
      try await preflightValidator.validate(
        subscriptionSource: subscriptionSource,
        profileID: profileID,
        profileName: profileName,
        providerOptions: providerOptions
      )
      return SubscriptionPreflightDiagnostics(
        result: .succeeded,
        messageKind: .mihomoAccepted
      )
    } catch {
      let fullDiagnostic = Self.fullPreflightDiagnostic(from: error)
      let summary = fullDiagnostic.flatMap(SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage:))
        ?? UserFacingError.message(for: error)
      let diagnostics = SubscriptionPreflightDiagnostics(
        result: .failed,
        message: summary,
        fullMessage: fullDiagnostic
      )
      throw SubscriptionPreflightValidationError(error: error, diagnostics: diagnostics)
    }
  }

  nonisolated private static func fullPreflightDiagnostic(from error: Error) -> String? {
    if case let AppError.configValidationFailed(payload) = error {
      return SubscriptionPreflightDiagnosticFormatter.fullDiagnostic(fromFullMessage: payload)
    }
    let nsError = error as NSError
    let described = String(describing: error)
    let localized = nsError.localizedDescription
    let candidates = [described, localized].filter { !$0.isEmpty }
    for candidate in candidates {
      if candidate.contains("\n") || candidate.count > SubscriptionPreflightDiagnosticFormatter.summaryCharacterLimit {
        return SubscriptionPreflightDiagnosticFormatter.fullDiagnostic(fromFullMessage: candidate)
      }
    }
    return nil
  }

  nonisolated private static func requiresSubscriptionPreflight(
    subscriptionSource: String,
    providerOptions: SubscriptionProviderOptions
  ) -> Bool {
    if providerOptions.requiresRuntimeConfigPreflight {
      return true
    }
    return (try? ProfileConfigInspector.format(of: subscriptionSource)) != nil
  }

  nonisolated private static func subscriptionHistoryEntry(
    profile: Profile,
    trigger: SubscriptionUpdateTrigger,
    result: SubscriptionUpdateResult,
    failureKind: SubscriptionUpdateFailureKind? = nil,
    message: String? = nil,
    at date: Date
  ) -> SubscriptionUpdateHistoryEntry {
    let fetch = profile.subscriptionDiagnostics.latestFetch
    return SubscriptionUpdateHistoryEntry(
      date: date,
      trigger: trigger,
      result: result,
      failureKind: failureKind,
      message: message,
      fetchStrategy: fetch?.successfulStrategy ?? fetch?.attemptedStrategies.last,
      httpStatusCode: fetch?.httpStatusCode
    )
  }

  private func fetchDiagnostics(from error: Error) -> SubscriptionFetchDiagnostics? {
    (error as? SubscriptionFetchError)?.diagnostics
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
    return SubscriptionFetchResult(source: result.source, metadata: metadata, diagnostics: result.diagnostics)
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
    nextProfiles[index].subscriptionDiagnostics.recordFetch(result.diagnostics)
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

  private func profilesByRecordingFetchDiagnostics(
    _ diagnostics: SubscriptionFetchDiagnostics,
    for id: UUID
  ) -> [Profile] {
    var nextProfiles = profiles
    guard let index = nextProfiles.firstIndex(where: { $0.id == id }) else { return nextProfiles }
    nextProfiles[index].subscriptionDiagnostics.recordFetch(diagnostics)
    return nextProfiles
  }

  private func profilesByRecordingPreflightDiagnostics(
    _ diagnostics: SubscriptionPreflightDiagnostics,
    for id: UUID,
    in profiles: [Profile]
  ) -> [Profile] {
    var nextProfiles = profiles
    guard let index = nextProfiles.firstIndex(where: { $0.id == id }) else { return nextProfiles }
    nextProfiles[index].subscriptionDiagnostics.recordPreflight(diagnostics)
    return nextProfiles
  }

  private func profilesByAppendingSubscriptionHistory(
    trigger: SubscriptionUpdateTrigger,
    result: SubscriptionUpdateResult,
    failureKind: SubscriptionUpdateFailureKind? = nil,
    message: String? = nil,
    at date: Date = Date(),
    for id: UUID,
    in profiles: [Profile]
  ) -> [Profile] {
    var nextProfiles = profiles
    guard let index = nextProfiles.firstIndex(where: { $0.id == id }) else { return nextProfiles }
    nextProfiles[index].subscriptionDiagnostics.appendHistory(
      Self.subscriptionHistoryEntry(
        profile: nextProfiles[index],
        trigger: trigger,
        result: result,
        failureKind: failureKind,
        message: message,
        at: date
      )
    )
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
