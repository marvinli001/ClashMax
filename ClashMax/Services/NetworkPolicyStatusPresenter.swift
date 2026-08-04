import Foundation

/// Turns a `WiFiNetworkSnapshot` into the copy shown in Settings → Network Policies.
///
/// Kept pure and separate from `AppModel` so every branch -- including the Location Services
/// recovery paths added for issue #26 -- is directly testable.
enum NetworkPolicyStatusPresenter {
  static func message(for snapshot: WiFiNetworkSnapshot, matchedRule: NetworkPolicyRule?) -> String {
    guard let ssid = snapshot.ssid else {
      return unavailableMessage(snapshot.unavailableReason)
    }
    if let matchedRule {
      return String(
        format: String(localized: "Current network %@ matches %@."),
        ssid,
        matchedRule.name
      )
    }
    return String(format: String(localized: "No saved policy matches %@."), ssid)
  }

  static func unavailableMessage(_ reason: WiFiSSIDUnavailableReason?) -> String {
    switch reason {
    case .noWiFiInterface:
      return String(localized: "This Mac has no Wi-Fi interface.")
    case .wiFiPoweredOff:
      return String(localized: "Wi-Fi is turned off.")
    case .notAssociated:
      return String(localized: "Not connected to a Wi-Fi network.")
    case .locationServicesDisabled:
      return String(localized: "macOS hides Wi-Fi network names until Location Services is turned on.")
    case .locationAuthorizationNotDetermined:
      return String(localized: "Allow ClashMax to use Location Services to read the Wi-Fi network name.")
    case .locationAuthorizationDenied:
      return String(localized: "Location access is denied, so macOS hides the Wi-Fi network name from ClashMax.")
    case .ssidWithheld:
      return String(localized: "macOS did not report a Wi-Fi network name.")
    case nil:
      return String(localized: "No Wi-Fi SSID detected.")
    }
  }

  /// Short button title for the snapshot's recovery action, or `nil` when there is nothing to offer.
  static func recoveryActionTitle(for snapshot: WiFiNetworkSnapshot) -> String? {
    switch snapshot.recoveryAction {
    case .requestLocationAuthorization:
      return String(localized: "Allow Location Access")
    case .openLocationSettings:
      return String(localized: "Open Location Settings")
    case .none:
      return nil
    }
  }
}
