import Foundation

struct RuntimeConfigMaterializationRequest: Sendable {
  var profileName: String
  var sourcePath: String
  var runtimeConfigURL: URL
  var providerContentURL: URL
  var overrides: RuntimeOverrides
  var selectionOverrides: [String: String]
}

struct RuntimeConfigMaterializer: Sendable {
  func materialize(_ request: RuntimeConfigMaterializationRequest) async throws -> URL {
    let task = Task.detached(priority: .userInitiated) {
      try Self.materializeOnDisk(request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func materializeOnDisk(_ request: RuntimeConfigMaterializationRequest) throws -> URL {
    let runtimeConfigURL = uniquedSiblingURL(for: request.runtimeConfigURL)
    let providerContentURL = uniquedSiblingURL(for: request.providerContentURL)
    var writtenURLs: [URL] = []

    do {
      try Task.checkCancellation()
      let source = try String(contentsOfFile: request.sourcePath, encoding: .utf8)
      try Task.checkCancellation()

      let providerContentPath: String?
      if try ProfileConfigInspector.format(of: source) == .proxyProviderContent {
        try source.write(to: providerContentURL, atomically: true, encoding: .utf8)
        writtenURLs.append(providerContentURL)
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
        selectionOverrides: request.selectionOverrides
      )
      try Task.checkCancellation()
      try output.write(to: runtimeConfigURL, atomically: true, encoding: .utf8)
      writtenURLs.append(runtimeConfigURL)
      try Task.checkCancellation()
      return runtimeConfigURL
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
