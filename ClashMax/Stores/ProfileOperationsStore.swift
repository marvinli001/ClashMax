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
  func importLocalProfile(from url: URL) throws -> Profile {
    let profile = try profileStore.importLocalConfig(from: url)
    message = "Imported profile \(profile.name)."
    return profile
  }

  @discardableResult
  func addSubscription(name: String = "", url: URL, session: URLSession = .shared) async throws -> Profile? {
    guard !isAddingSubscription else { return nil }
    isAddingSubscription = true
    message = nil
    defer { isAddingSubscription = false }

    let profile = try await profileStore.addSubscription(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      url: url,
      session: session
    )
    message = "Added subscription \(profile.name)."
    return profile
  }

  func updateActiveSubscription(session: URLSession = .shared) async throws -> Bool {
    guard let profile = profileStore.activeProfile else { return false }
    return try await updateSubscription(profile, session: session)
  }

  @discardableResult
  func updateSubscription(_ profile: Profile, session: URLSession = .shared) async throws -> Bool {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can be updated.")
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    message = nil
    defer { setProfile(profile.id, updating: false) }

    try await profileStore.updateSubscription(profile, session: session)
    let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
    message = "Updated subscription \(name)."
    return true
  }

  @discardableResult
  func updateSubscriptionSource(_ profile: Profile, url: URL, session: URLSession = .shared) async throws -> Bool {
    guard profile.isSubscription else {
      throw AppError.invalidProfileConfig("Only subscription profiles can update their source URL.")
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    message = nil
    defer { setProfile(profile.id, updating: false) }

    try await profileStore.updateSubscriptionSource(profile, url: url, session: session)
    let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
    message = "Updated subscription source for \(name)."
    return true
  }

  func renameActiveProfile(to name: String) throws {
    guard let profile = profileStore.activeProfile else { return }
    try renameProfile(profile, to: name)
  }

  func renameProfile(_ profile: Profile, to name: String) throws {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw AppError.invalidProfileConfig("Profile name cannot be empty.")
    }
    try profileStore.rename(profile, to: trimmedName)
    message = "Renamed profile to \(trimmedName)."
  }

  func resetSubscriptionName(_ profile: Profile) throws {
    try profileStore.resetSubscriptionName(profile)
    if let name = profileStore.profiles.first(where: { $0.id == profile.id })?.name {
      message = "Restored subscription name to \(name)."
    }
  }

  func deleteActiveProfile() throws {
    guard let profile = profileStore.activeProfile else { return }
    try deleteProfile(profile)
  }

  func deleteProfile(_ profile: Profile) throws {
    try profileStore.delete(profile)
    message = "Deleted profile \(profile.name)."
  }

  func selectProfile(_ profile: Profile) throws -> Bool {
    let isChangingProfile = profileStore.activeProfileID != profile.id
    guard isChangingProfile else { return false }
    try profileStore.select(profile)
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
