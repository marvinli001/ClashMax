import Foundation

private struct RuntimeSnippetLibraryManifest: Codable, Sendable {
  var version: Int
  var snippets: [RuntimeSnippet]

  init(version: Int = 1, snippets: [RuntimeSnippet]) {
    self.version = version
    self.snippets = snippets
  }
}

protocol RuntimeSnippetLibraryDiskIOProviding: Sendable {
  func load(from url: URL) async throws -> [RuntimeSnippet]
  func save(_ snippets: [RuntimeSnippet], to url: URL) async throws
}

struct RuntimeSnippetLibraryDiskIO: RuntimeSnippetLibraryDiskIOProviding {
  func load(from url: URL) async throws -> [RuntimeSnippet] {
    try await Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: url.path) else {
        return []
      }
      let data = try Data(contentsOf: url)
      let manifest = try JSONDecoder().decode(RuntimeSnippetLibraryManifest.self, from: data)
      return manifest.snippets
    }.value
  }

  func save(_ snippets: [RuntimeSnippet], to url: URL) async throws {
    let manifest = RuntimeSnippetLibraryManifest(snippets: snippets)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try await Task.detached(priority: .utility) {
      try SecureFileIO.writePrivateData(data, to: url)
    }.value
  }
}

@MainActor
final class RuntimeSnippetLibraryStore: ObservableObject {
  @Published private(set) var snippets: [RuntimeSnippet] = []
  @Published private(set) var loadError: String?

  private let libraryURL: URL
  private let diskIO: any RuntimeSnippetLibraryDiskIOProviding
  private var loadTask: Task<Void, Never>?

  init(
    paths: RuntimePaths,
    diskIO: any RuntimeSnippetLibraryDiskIOProviding = RuntimeSnippetLibraryDiskIO()
  ) {
    self.libraryURL = paths.runtimeSnippetLibraryURL
    self.diskIO = diskIO
    loadTask = Task { [weak self] in
      await self?.loadFromDisk()
    }
  }

  deinit {
    loadTask?.cancel()
  }

  func waitForLoad() async {
    await loadTask?.value
  }

  func snippets(applyingTo profileID: Profile.ID) -> [RuntimeSnippet] {
    snippets.filter { $0.enabled && $0.applies(to: profileID) }
  }

  func backupSnapshot() async -> [RuntimeSnippet] {
    await waitForLoad()
    return snippets
  }

  func applyBackupSnapshot(_ backupSnippets: [RuntimeSnippet], idMap: [Profile.ID: Profile.ID]) async throws {
    await waitForLoad()
    let validRestoredProfileIDs = Set(idMap.values)
    let restoredSnippets = backupSnippets.map { snippet in
      Self.restoredBackupSnippet(
        snippet,
        idMap: idMap,
        validRestoredProfileIDs: validRestoredProfileIDs
      )
    }
    try await persist(restoredSnippets)
  }

  func replaceSnippets(_ nextSnippets: [RuntimeSnippet]) async throws {
    await waitForLoad()
    try await persist(nextSnippets)
  }

  func saveSnippet(_ snippet: RuntimeSnippet) async throws {
    try validate(snippet)
    var nextSnippets = snippets
    if let index = nextSnippets.firstIndex(where: { $0.id == snippet.id }) {
      nextSnippets[index] = snippet
    } else {
      nextSnippets.append(snippet)
    }
    try await persist(nextSnippets)
  }

  func deleteSnippet(id: RuntimeSnippet.ID) async throws {
    let nextSnippets = snippets.filter { $0.id != id }
    try await persist(nextSnippets)
  }

  func setSnippetEnabled(id: RuntimeSnippet.ID, enabled: Bool) async throws {
    var nextSnippets = snippets
    guard let index = nextSnippets.firstIndex(where: { $0.id == id }) else { return }
    nextSnippets[index].enabled = enabled
    try validate(nextSnippets[index])
    try await persist(nextSnippets)
  }

  func moveSnippet(fromOffsets source: IndexSet, toOffset destination: Int) async throws {
    var nextSnippets = snippets
    nextSnippets.moveElements(fromOffsets: source, toOffset: destination)
    try await persist(nextSnippets)
  }

  @discardableResult
  func removeMissingProfileBindings(validProfileIDs: Set<Profile.ID>) async throws -> Bool {
    let nextSnippets = snippets.map {
      $0.removingMissingProfileBindings(validProfileIDs: validProfileIDs)
    }
    guard nextSnippets != snippets else { return false }
    try await persist(nextSnippets)
    return true
  }

  private func loadFromDisk() async {
    do {
      snippets = try await diskIO.load(from: libraryURL)
      loadError = nil
    } catch {
      snippets = []
      loadError = UserFacingError.message(for: error)
    }
  }

  private func validate(_ snippet: RuntimeSnippet) throws {
    if let validationError = snippet.validationError {
      throw AppError.invalidProfileConfig(validationError)
    }
  }

  private func persist(_ nextSnippets: [RuntimeSnippet]) async throws {
    for snippet in nextSnippets {
      try validate(snippet)
    }
    try await diskIO.save(nextSnippets, to: libraryURL)
    snippets = nextSnippets
    loadError = nil
  }

  private static func restoredBackupSnippet(
    _ snippet: RuntimeSnippet,
    idMap: [Profile.ID: Profile.ID],
    validRestoredProfileIDs: Set<Profile.ID>
  ) -> RuntimeSnippet {
    var restored = snippet
    if case let .profiles(profileIDs) = restored.binding {
      restored.binding = .profiles(profileIDs.compactMap { idMap[$0] })
    }
    return restored.removingMissingProfileBindings(validProfileIDs: validRestoredProfileIDs)
  }
}

private extension Array {
  mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
    let movingIndexes = source.sorted()
    guard !movingIndexes.isEmpty else { return }
    let movingElements = movingIndexes.map { self[$0] }
    for index in movingIndexes.sorted(by: >) {
      remove(at: index)
    }
    let removedBeforeDestination = movingIndexes.filter { $0 < destination }.count
    let insertionIndex = Swift.max(0, Swift.min(count, destination - removedBeforeDestination))
    insert(contentsOf: movingElements, at: insertionIndex)
  }
}
