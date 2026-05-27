import Foundation

struct RuntimeConfigMaterializationRequest: Sendable {
  var profileName: String
  var sourcePath: String
  var runtimeConfigURL: URL
  var providerContentURL: URL
  var overrides: RuntimeOverrides
  var selectionOverrides: [String: String]
  var options: RuntimeConfigOptions = .default
  var protectedArtifactURLs: [URL] = []
  var retainedGenerationCount: Int = 2
}

struct RuntimeConfigMaterializationResult: Sendable, Equatable {
  var runtimeConfigURL: URL
  var providerContentURL: URL?

  var artifactURLs: [URL] {
    [runtimeConfigURL] + [providerContentURL].compactMap { $0 }
  }
}

struct RuntimeConfigMaterializer: Sendable {
  func materialize(_ request: RuntimeConfigMaterializationRequest) async throws -> URL {
    try await materializeResult(request).runtimeConfigURL
  }

  func materializeResult(_ request: RuntimeConfigMaterializationRequest) async throws -> RuntimeConfigMaterializationResult {
    let task = Task.detached(priority: .userInitiated) {
      try Self.materializeOnDisk(request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func materializeOnDisk(_ request: RuntimeConfigMaterializationRequest) throws -> RuntimeConfigMaterializationResult {
    let runtimeConfigURL = uniquedSiblingURL(for: request.runtimeConfigURL)
    let providerContentURL = uniquedSiblingURL(for: request.providerContentURL)
    var writtenURLs: [URL] = []
    var materializedProviderContentURL: URL?

    do {
      try Task.checkCancellation()
      let source = try String(contentsOfFile: request.sourcePath, encoding: .utf8)
      try Task.checkCancellation()

      let providerContentPath: String?
      if try ProfileConfigInspector.format(of: source) == .proxyProviderContent {
        try SecureFileIO.writePrivateString(source, to: providerContentURL)
        writtenURLs.append(providerContentURL)
        materializedProviderContentURL = providerContentURL
        providerContentPath = providerContentURL.path
      } else {
        providerContentPath = nil
      }
      try Task.checkCancellation()

      let output = try ConfigNormalizer().runtimeConfig(
        from: source,
        providerContentPath: providerContentPath,
        profileName: request.profileName,
        overrides: request.overrides,
        options: request.options,
        selectionOverrides: request.selectionOverrides
      )
      try Task.checkCancellation()
      try SecureFileIO.writePrivateString(output, to: runtimeConfigURL)
      writtenURLs.append(runtimeConfigURL)
      try Task.checkCancellation()
      let result = RuntimeConfigMaterializationResult(
        runtimeConfigURL: runtimeConfigURL,
        providerContentURL: materializedProviderContentURL
      )
      cleanUpRetainedArtifacts(
        for: request,
        materialization: result
      )
      return result
    } catch {
      for url in writtenURLs {
        try? FileManager.default.removeItem(at: url)
      }
      throw error
    }
  }

  private static func uniquedSiblingURL(for url: URL) -> URL {
    let directory = url.deletingLastPathComponent()
    let fileExtension = url.pathExtension
    let baseName = fileExtension.isEmpty
      ? url.lastPathComponent
      : url.deletingPathExtension().lastPathComponent
    let uniqueName = fileExtension.isEmpty
      ? "\(baseName).\(UUID().uuidString)"
      : "\(baseName).\(UUID().uuidString).\(fileExtension)"
    return directory.appendingPathComponent(uniqueName)
  }

  private static func cleanUpRetainedArtifacts(
    for request: RuntimeConfigMaterializationRequest,
    materialization: RuntimeConfigMaterializationResult,
    fileManager: FileManager = .default
  ) {
    let protectedPaths = Set(request.protectedArtifactURLs.map(canonicalPath))
    cleanUpRetainedArtifacts(
      for: request.runtimeConfigURL,
      writtenURL: materialization.runtimeConfigURL,
      protectedPaths: protectedPaths,
      retainedGenerationCount: request.retainedGenerationCount,
      fileManager: fileManager
    )
    cleanUpRetainedArtifacts(
      for: request.providerContentURL,
      writtenURL: materialization.providerContentURL,
      protectedPaths: protectedPaths,
      retainedGenerationCount: request.retainedGenerationCount,
      fileManager: fileManager
    )
  }

  private static func cleanUpRetainedArtifacts(
    for baseURL: URL,
    writtenURL: URL?,
    protectedPaths: Set<String>,
    retainedGenerationCount: Int,
    fileManager: FileManager
  ) {
    let retainedGenerationCount = max(retainedGenerationCount, 0)
    let directory = baseURL.deletingLastPathComponent()
    let candidates: [ManagedArtifactCandidate]
    do {
      candidates = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      ).compactMap { managedArtifactCandidate(for: $0, baseURL: baseURL) }
    } catch {
      return
    }

    guard !candidates.isEmpty else { return }

    var keptPaths = protectedPaths
    let writtenPath = writtenURL.map(canonicalPath)
    if let writtenPath, candidates.contains(where: { canonicalPath($0.url) == writtenPath }) {
      keptPaths.insert(writtenPath)
    }

    var retainedNonProtectedCount = writtenPath == nil ? 0 : 1
    let sortedCandidates = candidates.sorted { lhs, rhs in
      if lhs.modifiedAt == rhs.modifiedAt {
        return lhs.url.lastPathComponent > rhs.url.lastPathComponent
      }
      return lhs.modifiedAt > rhs.modifiedAt
    }
    for candidate in sortedCandidates {
      let path = canonicalPath(candidate.url)
      guard !keptPaths.contains(path) else { continue }
      guard retainedNonProtectedCount < retainedGenerationCount else { continue }
      keptPaths.insert(path)
      retainedNonProtectedCount += 1
    }

    for candidate in candidates {
      let path = canonicalPath(candidate.url)
      guard !keptPaths.contains(path) else { continue }
      try? fileManager.removeItem(at: candidate.url)
    }
  }

  private static func managedArtifactCandidate(for url: URL, baseURL: URL) -> ManagedArtifactCandidate? {
    let fileExtension = baseURL.pathExtension
    let baseName = fileExtension.isEmpty
      ? baseURL.lastPathComponent
      : baseURL.deletingPathExtension().lastPathComponent
    let name = url.lastPathComponent
    let prefix = "\(baseName)."
    guard name.hasPrefix(prefix) else { return nil }

    let uuidCandidate: String
    if fileExtension.isEmpty {
      uuidCandidate = String(name.dropFirst(prefix.count))
    } else {
      let suffix = ".\(fileExtension)"
      guard name.hasSuffix(suffix) else { return nil }
      uuidCandidate = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }
    guard UUID(uuidString: uuidCandidate) != nil else { return nil }

    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
    guard values?.isRegularFile == true else { return nil }
    let modifiedAt = values?.contentModificationDate ?? Date.distantPast
    return ManagedArtifactCandidate(url: url, modifiedAt: modifiedAt)
  }

  private static func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.path
  }

  private struct ManagedArtifactCandidate {
    var url: URL
    var modifiedAt: Date
  }
}

struct ProfilePreviewMaterializer: Sendable {
  func groups(from sourcePath: String, profileName: String) async throws -> [ProxyGroup] {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
      try Task.checkCancellation()
      return try ProfilePreviewBuilder().groups(from: source, profileName: profileName)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
