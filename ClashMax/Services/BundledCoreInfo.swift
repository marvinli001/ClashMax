import Foundation

struct BundledCoreInfo: Equatable {
  let versionSummary: String
  let statusMessage: String

  init(bundle: Bundle = .main) {
    self.init(manifestURL: Self.manifestURL(in: bundle))
  }

  init(manifestURL: URL?) {
    guard
      let manifestURL,
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(BundledCoreManifest.self, from: data)
    else {
      versionSummary = "Mihomo unavailable"
      statusMessage = "Bundled Mihomo core information is unavailable."
      return
    }

    versionSummary = "Mihomo \(manifest.version)"
    statusMessage = "Bundled with ClashMax. Updating ClashMax updates the bundled Mihomo core."
  }

  private static func manifestURL(in bundle: Bundle) -> URL? {
    if let bundleManifestURL = bundle.resourceURL?
      .appendingPathComponent("Core", isDirectory: true)
      .appendingPathComponent("mihomo-manifest.json") {
      return bundleManifestURL
    }

    return AppConstants.bundledCoreRoot.appendingPathComponent("mihomo-manifest.json")
  }
}

private struct BundledCoreManifest: Decodable {
  let version: String
}
