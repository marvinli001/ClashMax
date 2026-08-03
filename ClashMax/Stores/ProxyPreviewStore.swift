import Foundation

@MainActor
@Observable
final class ProxyPreviewStore {
  /// Fired after `profilePreviewGroups` changes. Assigned by `AppModel.init`.
  @ObservationIgnored var onProfilePreviewGroupsChange: (([ProxyGroup]) -> Void)?

  var profilePreviewGroups: [ProxyGroup] = [] {
    didSet {
      onProfilePreviewGroupsChange?(profilePreviewGroups)
    }
  }
  var previewRuntimeActive = false
  var previewSelections: [String: String] = [:]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let previewMaterializer: ProfilePreviewMaterializer
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshGeneration = 0
  private static let previewSelectionsDefaultsKey = "io.github.clashmax.previewSelections"

  init(
    defaults: UserDefaults = .standard,
    previewMaterializer: ProfilePreviewMaterializer = ProfilePreviewMaterializer()
  ) {
    self.defaults = defaults
    self.previewMaterializer = previewMaterializer
  }

  deinit {
    refreshTask?.cancel()
  }

  @discardableResult
  func refreshPreview(for profile: Profile?) -> Task<Void, Never>? {
    refreshTask?.cancel()
    refreshGeneration += 1

    guard let profile else {
      profilePreviewGroups = []
      refreshTask = nil
      return nil
    }

    let generation = refreshGeneration
    let sourcePath = profile.originalConfigPath
    let profileName = profile.name
    let task = Task { [weak self, previewMaterializer] in
      let groups: [ProxyGroup]
      do {
        groups = try await previewMaterializer.groups(from: sourcePath, profileName: profileName)
      } catch {
        groups = []
      }
      guard !Task.isCancelled else { return }
      guard let self, self.refreshGeneration == generation else { return }
      self.profilePreviewGroups = groups
    }
    refreshTask = task
    return task
  }

  func waitForRefresh() async {
    await refreshTask?.value
  }

  func loadSelections(for profileID: Profile.ID?) {
    guard let profileID else {
      previewSelections = [:]
      return
    }
    let store = defaults.dictionary(forKey: Self.previewSelectionsDefaultsKey) as? [String: [String: String]] ?? [:]
    previewSelections = store[profileID.uuidString] ?? [:]
  }

  func saveSelections(for profileID: Profile.ID?) {
    guard let profileID else { return }
    var store = defaults.dictionary(forKey: Self.previewSelectionsDefaultsKey) as? [String: [String: String]] ?? [:]
    if previewSelections.isEmpty {
      store.removeValue(forKey: profileID.uuidString)
    } else {
      store[profileID.uuidString] = previewSelections
    }
    defaults.set(store, forKey: Self.previewSelectionsDefaultsKey)
  }

  func backupSelections() -> [String: [String: String]] {
    defaults.dictionary(forKey: Self.previewSelectionsDefaultsKey) as? [String: [String: String]] ?? [:]
  }

  func rollbackSnapshot() -> ProxyPreviewRollbackSnapshot {
    ProxyPreviewRollbackSnapshot(
      storedSelections: backupSelections(),
      previewSelections: previewSelections
    )
  }

  func restoreRollbackSnapshot(_ snapshot: ProxyPreviewRollbackSnapshot) {
    defaults.set(snapshot.storedSelections, forKey: Self.previewSelectionsDefaultsKey)
    previewSelections = snapshot.previewSelections
  }

  func mergeBackupSelections(
    _ selections: [String: [String: String]],
    idMap: [Profile.ID: Profile.ID],
    activeProfileID: Profile.ID?
  ) {
    var store = backupSelections()
    for (profileIDString, groupSelections) in selections {
      guard let profileID = UUID(uuidString: profileIDString),
            let restoredID = idMap[profileID]
      else { continue }
      if groupSelections.isEmpty {
        store.removeValue(forKey: restoredID.uuidString)
      } else {
        store[restoredID.uuidString] = groupSelections
      }
    }
    defaults.set(store, forKey: Self.previewSelectionsDefaultsKey)
    loadSelections(for: activeProfileID)
  }

  func mergedPreviewSelections(into groups: [ProxyGroup]) -> [ProxyGroup] {
    guard !previewSelections.isEmpty else { return groups }
    return groups.map { group in
      var group = group
      if let chosen = previewSelections[group.name],
         group.nodes.contains(where: { $0.name == chosen }) {
        group.selected = chosen
      }
      return group
    }
  }
}
