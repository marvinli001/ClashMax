import Foundation

@MainActor
final class ProxyPreviewStore: ObservableObject {
  @Published var profilePreviewGroups: [ProxyGroup] = []
  @Published var previewRuntimeActive = false
  @Published var previewSelections: [String: String] = [:]

  private let defaults: UserDefaults
  private let previewBuilder: ProfilePreviewBuilder
  private static let previewSelectionsDefaultsKey = "io.github.clashmax.previewSelections"

  init(
    defaults: UserDefaults = .standard,
    previewBuilder: ProfilePreviewBuilder = ProfilePreviewBuilder()
  ) {
    self.defaults = defaults
    self.previewBuilder = previewBuilder
  }

  func refreshPreview(for profile: Profile?) {
    guard let profile else {
      profilePreviewGroups = []
      return
    }

    do {
      let source = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
      profilePreviewGroups = try previewBuilder.groups(from: source, profileName: profile.name)
    } catch {
      profilePreviewGroups = []
    }
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
