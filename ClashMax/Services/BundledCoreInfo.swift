import Foundation

struct BundledCoreInfo: Equatable {
  let versionSummary: String
  let statusMessage: String
  /// Machine-readable User-Agent the bundled Mihomo core would send for subscription
  /// requests (e.g. `mihomo/1.19.27`), or nil when the manifest is missing/unparseable.
  /// Used as a compatibility fallback when a panel rejects the user-configured UA.
  let subscriptionCompatibilityUserAgent: String?

  init(bundle: Bundle = .main) {
    self.init(manifestURL: Self.manifestURL(in: bundle))
  }

  init(manifestURL: URL?) {
    guard
      let manifestURL,
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(BundledCoreManifest.self, from: data)
    else {
      versionSummary = String(localized: "Mihomo unavailable")
      statusMessage = String(localized: "Bundled Mihomo core information is unavailable.")
      subscriptionCompatibilityUserAgent = nil
      return
    }

    versionSummary = "Mihomo \(manifest.version)"
    statusMessage = String(localized: "Bundled with ClashMax. Updating ClashMax updates the bundled Mihomo core.")
    subscriptionCompatibilityUserAgent = Self.compatibilityUserAgent(fromVersion: manifest.version)
  }

  /// Normalizes a manifest version string (e.g. `v1.19.27`) into a `mihomo/<version>`
  /// User-Agent, stripping a leading `v`. Returns nil when no version is present.
  static func compatibilityUserAgent(fromVersion version: String) -> String? {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalizedVersion = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
      ? String(trimmed.dropFirst())
      : trimmed
    let cleanedVersion = normalizedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedVersion.isEmpty else { return nil }
    return "mihomo/\(cleanedVersion)"
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
