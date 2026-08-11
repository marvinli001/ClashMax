import Foundation
import Sparkle

@MainActor
@Observable
final class AppUpdateController: NSObject {
  private(set) var canCheckForUpdates = false
  private(set) var statusMessage = String(localized: "Checking for updates is not configured for this build.")

  @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
  @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

  /// Sparkle only filters appcast items by minimum system version, so an
  /// Apple-silicon-only build would otherwise be offered to Intel Macs that
  /// cannot launch it. Publishing such a build under this channel keeps it
  /// invisible to Intel clients; universal builds stay in the default channel so
  /// every client, including ones predating this delegate, still sees them.
  static let appleSiliconUpdateChannel = "apple-silicon"

  override init() {
    super.init()
    if Self.hasConfiguredPublicKey {
      let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
      )
      updaterController = controller
      statusMessage = String(localized: "Sparkle is configured for automatic app updates.")
      canCheckForUpdates = controller.updater.canCheckForUpdates
      canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
        Task { @MainActor in
          self?.canCheckForUpdates = updater.canCheckForUpdates
        }
      }
    } else {
      updaterController = nil
      statusMessage = String(localized: "Generate a Sparkle EdDSA key and replace SUPublicEDKey before publishing updates.")
    }
  }

  /// Resolved from the running slice rather than `uname`, so a universal build
  /// translated by Rosetta correctly identifies itself as an Intel client.
  static var allowedUpdateChannels: Set<String> {
    #if arch(arm64)
      [appleSiliconUpdateChannel]
    #else
      []
    #endif
  }

  var feedURLString: String {
    (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String) ?? AppConstants.appcastURL.absoluteString
  }

  var versionSummary: String {
    let displayVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    return displayVersion
  }

  func checkForUpdates() {
    updaterController?.checkForUpdates(nil)
  }

  private static var hasConfiguredPublicKey: Bool {
    guard let rawKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
      return false
    }
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key != AppConstants.sparklePublicEDKeyPlaceholder else {
      return false
    }
    return Data(base64Encoded: key)?.count == 32
  }
}

extension AppUpdateController: SPUUpdaterDelegate {
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    Self.allowedUpdateChannels
  }
}
