import AppKit
import Foundation

enum AppLocalization {
  static var currentLanguageDisplayName: String {
    let identifier = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first
      ?? "en"
    return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
  }

  static func openLanguageAndRegionSettings(workspace: NSWorkspace = .shared) {
    let languageRegionURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
    if let languageRegionURL, workspace.open(languageRegionURL) {
      return
    }

    if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings") {
      workspace.open(settingsURL)
    }
  }
}
