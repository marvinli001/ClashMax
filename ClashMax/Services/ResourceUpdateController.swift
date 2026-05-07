import Foundation

@MainActor
final class ResourceUpdateController: ObservableObject {
  @Published private(set) var statusMessage: String

  let coreVersionSummary: String
  private let manifest: CoreResourceManifest?

  init(bundle: Bundle = .main) {
    manifest = Self.loadManifest(bundle: bundle)
    if let manifest {
      coreVersionSummary = "Mihomo \(manifest.version)"
      statusMessage = "Resource updates use a separate channel from app updates."
    } else {
      coreVersionSummary = "Mihomo unavailable"
      statusMessage = "Bundled resource manifest was not found."
    }
  }

  func checkForUpdates() {
    if let manifest {
      statusMessage = "Resource update channel is not implemented in this build. Current bundled core is Mihomo \(manifest.version)."
    } else {
      statusMessage = "Cannot check resource updates because the bundled Mihomo manifest is missing."
    }
  }

  private static func loadManifest(bundle: Bundle) -> CoreResourceManifest? {
    let manifestURL = bundle.resourceURL?
      .appendingPathComponent("Core", isDirectory: true)
      .appendingPathComponent("mihomo-manifest.json")
      ?? AppConstants.bundledCoreRoot.appendingPathComponent("mihomo-manifest.json")
    guard let data = try? Data(contentsOf: manifestURL) else {
      return nil
    }
    return try? JSONDecoder().decode(CoreResourceManifest.self, from: data)
  }
}

private struct CoreResourceManifest: Decodable {
  let version: String
}
