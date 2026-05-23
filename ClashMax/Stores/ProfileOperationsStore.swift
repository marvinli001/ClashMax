import AppKit
import Foundation

@MainActor
final class ProfileCoordinator: ObservableObject {
  @Published private(set) var isAddingSubscription = false
  @Published private(set) var updatingProfileIDs: Set<Profile.ID> = []
  @Published private(set) var message: String?

  private let profileStore: ProfileStore
  private let proxyPreview: ProxyPreviewStore
  private let subscriptionScheduler: SubscriptionAutoUpdateScheduler
  private var hooks = ProfileCoordinatorHooks()

  init(
    profileStore: ProfileStore,
    proxyPreview: ProxyPreviewStore,
    subscriptionAutoUpdateRetryDelay: TimeInterval = 15 * 60
  ) {
    self.profileStore = profileStore
    self.proxyPreview = proxyPreview
    self.subscriptionScheduler = SubscriptionAutoUpdateScheduler(retryDelay: subscriptionAutoUpdateRetryDelay)
  }

  func configureRuntimeHooks(
    automaticSubscriptionUpdatesEnabled: @escaping () -> Bool,
    subscriptionFetchOptions: @escaping (Profile?) -> SubscriptionFetchOptions,
    preflightValidator: @escaping () -> any SubscriptionProfilePreflightValidating,
    reloadActiveRuntimeConfigIfNeeded: @escaping (Profile.ID, String) async throws -> Void,
    appendAppLog: @escaping (String, String) -> Void,
    clearRuntimeProxyGroups: @escaping () -> Void,
    shouldRestartRuntimeAfterProfileSelection: @escaping () -> Bool,
    restartRuntime: @escaping () -> Void
  ) {
    hooks = ProfileCoordinatorHooks(
      automaticSubscriptionUpdatesEnabled: automaticSubscriptionUpdatesEnabled,
      subscriptionFetchOptions: subscriptionFetchOptions,
      preflightValidator: preflightValidator,
      reloadActiveRuntimeConfigIfNeeded: reloadActiveRuntimeConfigIfNeeded,
      appendAppLog: appendAppLog,
      clearRuntimeProxyGroups: clearRuntimeProxyGroups,
      shouldRestartRuntimeAfterProfileSelection: shouldRestartRuntimeAfterProfileSelection,
      restartRuntime: restartRuntime
    )
  }

  @discardableResult
  func importLocalProfile(from url: URL) async throws -> Profile {
    let profile = try await profileStore.importLocalConfig(from: url)
    message = "Imported profile \(profile.name)."
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    return profile
  }

  @discardableResult
  func addSubscription(
    name: String = "",
    url: URL,
    displayNameHint: String? = nil,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Profile? {
    guard !isAddingSubscription else { return nil }
    isAddingSubscription = true
    message = nil
    defer { isAddingSubscription = false }

    let profile = try await profileStore.addSubscription(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      url: url,
      displayNameHint: displayNameHint,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
    message = "Added subscription \(profile.name)."
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    rescheduleSubscriptionAutoUpdates()
    return profile
  }

  func updateActiveSubscription(
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Bool {
    guard let profile = profileStore.activeProfile else { return false }
    return try await updateSubscription(
      profile,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
  }

  @discardableResult
  func updateSubscription(
    _ profile: Profile,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Bool {
    let updated = try await updateSubscriptionWithoutPostActions(
      profile,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
    await refreshPreviewAndWait()
    rescheduleSubscriptionAutoUpdates()
    return updated
  }

  @discardableResult
  func updateSubscriptionSource(
    _ profile: Profile,
    url: URL,
    displayNameHint: String? = nil,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Bool {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can update their source URL.")
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    message = nil
    defer { setProfile(profile.id, updating: false) }

    try await profileStore.updateSubscriptionSource(
      profile,
      url: url,
      displayNameHint: displayNameHint,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
    let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
    message = "Updated subscription source for \(name)."
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    try await hooks.reloadActiveRuntimeConfigIfNeeded(
      profile.id,
      "Subscription source updated: Mihomo reloaded"
    )
    rescheduleSubscriptionAutoUpdates()
    return true
  }

  @discardableResult
  func updateSubscriptionSourceAndProviderOptions(
    _ profile: Profile,
    url: URL,
    displayNameHint: String? = nil,
    options: SubscriptionProviderOptions,
    session: URLSession = .shared,
    fetchOptions: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws -> Bool {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can update their source URL.")
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    message = nil
    defer { setProfile(profile.id, updating: false) }

    try await profileStore.updateSubscriptionSourceAndProviderOptions(
      profile,
      url: url,
      displayNameHint: displayNameHint,
      options: options,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
    let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
    message = "Updated subscription source and provider options for \(name)."
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    try await hooks.reloadActiveRuntimeConfigIfNeeded(
      profile.id,
      "Subscription source and provider options updated: Mihomo reloaded"
    )
    rescheduleSubscriptionAutoUpdates()
    return true
  }

  func renameActiveProfile(to name: String) async throws {
    guard let profile = profileStore.activeProfile else { return }
    try await renameProfile(profile, to: name)
  }

  func renameProfile(_ profile: Profile, to name: String) async throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw AppError.invalidProfileConfig("Profile name cannot be empty.")
    }
    try await profileStore.rename(profile, to: trimmedName)
    message = "Renamed profile to \(trimmedName)."
    await refreshPreviewAndWait()
  }

  func resetSubscriptionName(_ profile: Profile) async throws {
    try await profileStore.resetSubscriptionName(profile)
    if let name = profileStore.profiles.first(where: { $0.id == profile.id })?.name {
      message = "Restored subscription name to \(name)."
    }
    await refreshPreviewAndWait()
  }

  func updateSubscriptionProviderOptions(
    _ profile: Profile,
    options: SubscriptionProviderOptions,
    preflightValidator: any SubscriptionProfilePreflightValidating = NoopSubscriptionProfilePreflightValidator()
  ) async throws {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can update provider options.")
    }
    try await profileStore.updateSubscriptionProviderOptions(
      profile,
      options: options,
      preflightValidator: preflightValidator
    )
    message = "Updated provider options for \(profile.name)."
    if profile.id == profileStore.activeProfileID {
      await refreshPreviewAndWait()
      try await hooks.reloadActiveRuntimeConfigIfNeeded(
        profile.id,
        "Subscription provider options updated: Mihomo reloaded"
      )
    }
    rescheduleSubscriptionAutoUpdates()
  }

  func deleteActiveProfile() async throws {
    let deletedID = profileStore.activeProfileID
    guard let profile = profileStore.activeProfile else { return }
    try await deleteProfile(profile, deletedSelectionID: deletedID)
  }

  func deleteProfile(_ profile: Profile) async throws {
    try await deleteProfile(profile, deletedSelectionID: profile.id)
  }

  private func deleteProfile(_ profile: Profile, deletedSelectionID: Profile.ID?) async throws {
    try await profileStore.delete(profile)
    message = "Deleted profile \(profile.name)."
    proxyPreview.previewSelections = [:]
    proxyPreview.saveSelections(for: deletedSelectionID)
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    rescheduleSubscriptionAutoUpdates()
  }

  func selectProfile(_ profile: Profile) async throws -> Bool {
    let isChangingProfile = profileStore.activeProfileID != profile.id
    guard isChangingProfile else { return false }
    let shouldRestart = hooks.shouldRestartRuntimeAfterProfileSelection()
    try await profileStore.select(profile)
    hooks.clearRuntimeProxyGroups()
    await refreshPreviewAndWait()
    loadSelectionsForActiveProfile()
    if shouldRestart {
      hooks.restartRuntime()
    }
    return true
  }

  func clearMessage() {
    message = nil
  }

  private func setProfile(_ id: Profile.ID, updating isUpdating: Bool) {
    var ids = updatingProfileIDs
    if isUpdating {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    updatingProfileIDs = ids
  }

  func refreshPreview() -> Task<Void, Never>? {
    proxyPreview.refreshPreview(for: profileStore.activeProfile)
  }

  func refreshPreviewAndWait() async {
    await refreshPreview()?.value
  }

  func waitForPreviewRefresh() async {
    await proxyPreview.waitForRefresh()
  }

  func loadSelectionsForActiveProfile() {
    proxyPreview.loadSelections(for: profileStore.activeProfileID)
  }

  func saveCurrentSelections(forProfileID overrideID: Profile.ID? = nil) {
    proxyPreview.saveSelections(for: overrideID ?? profileStore.activeProfileID)
  }

  func rescheduleSubscriptionAutoUpdates(now: Date = Date()) {
    subscriptionScheduler.reschedule(
      now: now,
      profiles: profileStore.profiles,
      automaticUpdatesEnabled: hooks.automaticSubscriptionUpdatesEnabled(),
      runDueUpdates: { [weak self] in
        await self?.runDueSubscriptionAutoUpdates()
      }
    )
  }

  func cancelSubscriptionAutoUpdates() {
    subscriptionScheduler.cancel()
  }

  @discardableResult
  private func updateSubscriptionWithoutPostActions(
    _ profile: Profile,
    session: URLSession,
    fetchOptions: SubscriptionFetchOptions,
    preflightValidator: any SubscriptionProfilePreflightValidating
  ) async throws -> Bool {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can be updated.")
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    message = nil
    defer { setProfile(profile.id, updating: false) }

    try await profileStore.updateSubscription(
      profile,
      session: session,
      fetchOptions: fetchOptions,
      preflightValidator: preflightValidator
    )
    let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
    message = "Updated subscription \(name)."
    return true
  }

  private func runDueSubscriptionAutoUpdates() async {
    subscriptionScheduler.clearScheduledTask()
    guard hooks.automaticSubscriptionUpdatesEnabled() else { return }

    let now = Date()
    let dueProfiles = subscriptionScheduler.dueProfiles(from: profileStore.profiles, now: now)
    guard !dueProfiles.isEmpty else {
      rescheduleSubscriptionAutoUpdates(now: now)
      return
    }

    var shouldRefreshPreview = false
    for profile in dueProfiles {
      do {
        let updated = try await updateSubscriptionWithoutPostActions(
          profile,
          session: .shared,
          fetchOptions: hooks.subscriptionFetchOptions(profile),
          preflightValidator: hooks.preflightValidator()
        )
        if updated {
          subscriptionScheduler.clearBackoff(for: profile.id)
          hooks.appendAppLog("info", "Auto-updated subscription \(profile.name).")
          shouldRefreshPreview = shouldRefreshPreview || profile.id == profileStore.activeProfileID
        } else {
          subscriptionScheduler.deferBriefly(profile.id, now: now)
        }
      } catch {
        subscriptionScheduler.deferAfterFailure(profile.id, now: Date())
        hooks.appendAppLog(
          "warn",
          "Could not auto-update subscription \(profile.name): \(UserFacingError.message(for: error))"
        )
      }
    }

    if shouldRefreshPreview {
      await refreshPreviewAndWait()
      loadSelectionsForActiveProfile()
    }
    rescheduleSubscriptionAutoUpdates()
  }
}

typealias ProfileOperationsStore = ProfileCoordinator

private struct ProfileCoordinatorHooks {
  var automaticSubscriptionUpdatesEnabled: () -> Bool = { false }
  var subscriptionFetchOptions: (Profile?) -> SubscriptionFetchOptions = { _ in SubscriptionFetchOptions() }
  var preflightValidator: () -> any SubscriptionProfilePreflightValidating = {
    NoopSubscriptionProfilePreflightValidator()
  }
  var reloadActiveRuntimeConfigIfNeeded: (Profile.ID, String) async throws -> Void = { _, _ in }
  var appendAppLog: (String, String) -> Void = { _, _ in }
  var clearRuntimeProxyGroups: () -> Void = {}
  var shouldRestartRuntimeAfterProfileSelection: () -> Bool = { false }
  var restartRuntime: () -> Void = {}
}

@MainActor
private final class SubscriptionAutoUpdateScheduler {
  private let retryDelay: TimeInterval
  private var task: Task<Void, Never>?
  private var backoffUntil: [Profile.ID: Date] = [:]

  init(retryDelay: TimeInterval) {
    self.retryDelay = retryDelay
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  func clearScheduledTask() {
    task = nil
  }

  func reschedule(
    now: Date,
    profiles: [Profile],
    automaticUpdatesEnabled: Bool,
    runDueUpdates: @escaping () async -> Void
  ) {
    cancel()
    guard automaticUpdatesEnabled,
          let nextUpdateAt = nextUpdateDate(in: profiles, now: now)
    else {
      return
    }

    let delay = max(1, nextUpdateAt.timeIntervalSince(now))
    task = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await runDueUpdates()
    }
  }

  func dueProfiles(from profiles: [Profile], now: Date) -> [Profile] {
    profiles.filter { profile in
      guard let updateAt = updateDate(for: profile, now: now) else { return false }
      return updateAt <= now
    }
  }

  func clearBackoff(for profileID: Profile.ID) {
    backoffUntil[profileID] = nil
  }

  func deferBriefly(_ profileID: Profile.ID, now: Date) {
    backoffUntil[profileID] = now.addingTimeInterval(60)
  }

  func deferAfterFailure(_ profileID: Profile.ID, now: Date) {
    backoffUntil[profileID] = now.addingTimeInterval(retryDelay)
  }

  private func nextUpdateDate(in profiles: [Profile], now: Date) -> Date? {
    profiles
      .compactMap { updateDate(for: $0, now: now) }
      .min()
  }

  private func updateDate(for profile: Profile, now: Date) -> Date? {
    guard profile.isSubscription,
          let metadata = profile.subscriptionMetadata,
          let intervalMinutes = metadata.updateIntervalMinutes,
          intervalMinutes > 0
    else {
      return nil
    }

    let baseDate = (metadata.lastFetchedAt ?? profile.updatedAt)
      .addingTimeInterval(TimeInterval(intervalMinutes * 60))
    if baseDate <= now,
       let backoffDate = backoffUntil[profile.id],
       backoffDate > now {
      return backoffDate
    }
    return baseDate
  }

  private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
  }
}
