import Foundation
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var statusMessage = String(localized: "Checking for updates is not configured for this build.")

  private let updaterController: SPUStandardUpdaterController?
  private var canCheckObservation: NSKeyValueObservation?

  override init() {
    if Self.hasConfiguredPublicKey {
      let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
      updaterController = controller
      super.init()
      statusMessage = String(localized: "Sparkle is configured for automatic app updates.")
      canCheckForUpdates = controller.updater.canCheckForUpdates
      canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
        Task { @MainActor in
          self?.canCheckForUpdates = updater.canCheckForUpdates
        }
      }
    } else {
      updaterController = nil
      super.init()
      statusMessage = String(localized: "Generate a Sparkle EdDSA key and replace SUPublicEDKey before publishing updates.")
    }
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
