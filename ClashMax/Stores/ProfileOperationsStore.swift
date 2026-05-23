import AppKit
import Foundation

@MainActor
final class ProfileOperationsStore: ObservableObject {
  @Published private(set) var isAddingSubscription = false
  @Published private(set) var updatingProfileIDs: Set<Profile.ID> = []
  @Published private(set) var message: String?

  private let profileStore: ProfileStore

  init(profileStore: ProfileStore) {
    self.profileStore = profileStore
  }

  @discardableResult
  func importLocalProfile(from url: URL) async throws -> Profile {
    let profile = try await profileStore.importLocalConfig(from: url)
    message = "Imported profile \(profile.name)."
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
  }

  func resetSubscriptionName(_ profile: Profile) async throws {
    try await profileStore.resetSubscriptionName(profile)
    if let name = profileStore.profiles.first(where: { $0.id == profile.id })?.name {
      message = "Restored subscription name to \(name)."
    }
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
  }

  func deleteActiveProfile() async throws {
    guard let profile = profileStore.activeProfile else { return }
    try await deleteProfile(profile)
  }

  func deleteProfile(_ profile: Profile) async throws {
    try await profileStore.delete(profile)
    message = "Deleted profile \(profile.name)."
  }

  func selectProfile(_ profile: Profile) async throws -> Bool {
    let isChangingProfile = profileStore.activeProfileID != profile.id
    guard isChangingProfile else { return false }
    try await profileStore.select(profile)
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
}
