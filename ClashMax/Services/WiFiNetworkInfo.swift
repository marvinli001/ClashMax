import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Synchronization

/// Why ClashMax could not read the SSID of the current Wi-Fi network.
///
/// macOS 14 and later gate `CWInterface.ssid()` behind Location Services: an app that has not been
/// granted "When In Use" location access always reads `nil`, even while the Mac is associated with a
/// network. Reporting *why* the name is missing lets Settings offer the matching recovery action
/// instead of the dead-end "No Wi-Fi SSID detected." message (issue #26).
enum WiFiSSIDUnavailableReason: String, Equatable, Sendable, CaseIterable {
  /// The Mac exposes no Wi-Fi interface at all (Ethernet-only hardware, or the interface is gone).
  case noWiFiInterface
  /// A Wi-Fi interface exists but its radio is powered off.
  case wiFiPoweredOff
  /// Wi-Fi is on but the interface is not associated with any network.
  case notAssociated
  /// Location Services is switched off for the whole Mac, so no app can resolve an SSID.
  case locationServicesDisabled
  /// ClashMax has never asked for location access, so macOS withholds the SSID.
  case locationAuthorizationNotDetermined
  /// Location access was denied by the user, or restricted by device management.
  case locationAuthorizationDenied
  /// Authorized and associated, yet CoreWLAN still withheld the name (hidden network, or a
  /// transient state right after joining).
  case ssidWithheld
}

/// What the user can do to make the SSID readable.
enum WiFiSSIDRecoveryAction: Equatable, Sendable {
  /// Show the macOS location prompt. Only ever useful while the status is `notDetermined`.
  case requestLocationAuthorization
  /// Deep-link into Privacy & Security → Location Services.
  case openLocationSettings
  /// Nothing ClashMax can offer; the fix is on the network itself.
  case none
}

/// The Wi-Fi network ClashMax believes the Mac is on, or the reason it cannot tell.
///
/// `ssid` and `unavailableReason` are mutually exclusive. Both `nil` means "not checked yet".
struct WiFiNetworkSnapshot: Equatable, Sendable {
  var ssid: String?
  var unavailableReason: WiFiSSIDUnavailableReason?

  init(ssid: String? = nil, unavailableReason: WiFiSSIDUnavailableReason? = nil) {
    self.ssid = ssid
    self.unavailableReason = unavailableReason
  }

  static let notChecked = WiFiNetworkSnapshot()

  static func joined(_ ssid: String) -> WiFiNetworkSnapshot {
    WiFiNetworkSnapshot(ssid: ssid)
  }

  static func unavailable(_ reason: WiFiSSIDUnavailableReason) -> WiFiNetworkSnapshot {
    WiFiNetworkSnapshot(unavailableReason: reason)
  }

  /// True when the SSID is unknown *only* because macOS is withholding it from ClashMax.
  ///
  /// Auto-apply treats this differently from "not on Wi-Fi": a permission gap means the network is
  /// unknown, not that the user left the network, so reverting routing would be wrong.
  var isBlockedByLocationAuthorization: Bool {
    switch unavailableReason {
    case .locationServicesDisabled,
         .locationAuthorizationNotDetermined,
         .locationAuthorizationDenied:
      return true
    default:
      return false
    }
  }

  var recoveryAction: WiFiSSIDRecoveryAction {
    switch unavailableReason {
    case .locationAuthorizationNotDetermined:
      return .requestLocationAuthorization
    case .locationServicesDisabled, .locationAuthorizationDenied:
      return .openLocationSettings
    default:
      return .none
    }
  }

  var statusSymbolName: String {
    if ssid != nil { return "wifi" }
    switch unavailableReason {
    case .locationServicesDisabled,
         .locationAuthorizationNotDetermined,
         .locationAuthorizationDenied:
      return "location.slash"
    case .noWiFiInterface, .wiFiPoweredOff, .notAssociated, .ssidWithheld:
      return "wifi.slash"
    case nil:
      return "wifi"
    }
  }
}

/// ClashMax's Location Services standing, as far as reading an SSID is concerned.
enum WiFiLocationAuthorizationStatus: String, Equatable, Sendable, CaseIterable {
  case notDetermined
  case denied
  case restricted
  case authorized
  /// Location Services is off for the entire Mac; prompting cannot succeed.
  case servicesDisabled

  var canReadSSID: Bool {
    self == .authorized
  }

  var unavailableReason: WiFiSSIDUnavailableReason? {
    switch self {
    case .authorized:
      return nil
    case .notDetermined:
      return .locationAuthorizationNotDetermined
    case .denied, .restricted:
      return .locationAuthorizationDenied
    case .servicesDisabled:
      return .locationServicesDisabled
    }
  }
}

/// Thread-safe mirror of the current authorization status.
///
/// `CWInterface` is polled from `NetworkEnvironmentMonitor`'s background queue, but
/// `CLLocationManager` is main-thread bound. `WiFiLocationAuthorization` publishes every status
/// change here so the provider can classify a `nil` SSID from any isolation domain.
enum WiFiLocationAuthorizationMirror {
  private static let storage = Mutex<WiFiLocationAuthorizationStatus>(.notDetermined)

  static var current: WiFiLocationAuthorizationStatus {
    storage.withLock { $0 }
  }

  static func publish(_ status: WiFiLocationAuthorizationStatus) {
    storage.withLock { $0 = status }
  }
}

/// What CoreWLAN reported about the Wi-Fi interface, lifted out of `CWInterface` so the
/// classification below stays a pure function.
struct WiFiInterfaceReading: Equatable, Sendable {
  var isPoweredOn: Bool
  var ssid: String?
  var isAssociated: Bool

  init(isPoweredOn: Bool, ssid: String?, isAssociated: Bool) {
    self.isPoweredOn = isPoweredOn
    self.ssid = ssid?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
    self.isAssociated = isAssociated
  }

  init(interface: CWInterface) {
    self.init(
      isPoweredOn: interface.powerOn(),
      ssid: interface.ssid(),
      isAssociated: interface.interfaceMode() != CWInterfaceMode.none
    )
  }
}

enum WiFiNetworkClassifier {
  /// Decides what ClashMax can honestly say about the current network.
  ///
  /// A `nil` SSID is attributed to authorization *before* the association state: macOS redacts
  /// network identity from unauthorized apps, so an unauthorized reading of "not associated" cannot
  /// be trusted, and granting access is the actionable fix either way.
  static func snapshot(
    for reading: WiFiInterfaceReading?,
    authorization: WiFiLocationAuthorizationStatus
  ) -> WiFiNetworkSnapshot {
    guard let reading else {
      return .unavailable(.noWiFiInterface)
    }
    guard reading.isPoweredOn else {
      return .unavailable(.wiFiPoweredOff)
    }
    if let ssid = reading.ssid {
      return .joined(ssid)
    }
    if let reason = authorization.unavailableReason {
      return .unavailable(reason)
    }
    return .unavailable(reading.isAssociated ? .ssidWithheld : .notAssociated)
  }
}

protocol CurrentNetworkProviding: Sendable {
  func currentNetwork() -> WiFiNetworkSnapshot
}

extension CurrentNetworkProviding {
  func currentSSID() -> String? {
    currentNetwork().ssid
  }
}

struct CoreWLANCurrentNetworkProvider: CurrentNetworkProviding {
  private let readingProvider: @Sendable () -> WiFiInterfaceReading?
  private let authorizationStatus: @Sendable () -> WiFiLocationAuthorizationStatus

  init(
    readingProvider: @escaping @Sendable () -> WiFiInterfaceReading? = {
      CWWiFiClient.shared().interface().map(WiFiInterfaceReading.init(interface:))
    },
    authorizationStatus: @escaping @Sendable () -> WiFiLocationAuthorizationStatus = {
      WiFiLocationAuthorizationMirror.current
    }
  ) {
    self.readingProvider = readingProvider
    self.authorizationStatus = authorizationStatus
  }

  func currentNetwork() -> WiFiNetworkSnapshot {
    WiFiNetworkClassifier.snapshot(for: readingProvider(), authorization: authorizationStatus())
  }
}

extension String {
  var nonEmptyString: String? {
    isEmpty ? nil : self
  }
}

/// Owns the `CLLocationManager` whose authorization unlocks `CWInterface.ssid()`.
///
/// ClashMax never asks for a location fix -- the authorization itself is the whole point. The
/// prompt is only raised when the user asks for it (or when network policies need the SSID to do
/// their job), never unconditionally at launch.
@MainActor
@Observable
final class WiFiLocationAuthorization {
  private(set) var status: WiFiLocationAuthorizationStatus

  /// Invoked on every authorization transition so callers can re-read the SSID.
  @ObservationIgnored var onStatusChange: (@MainActor (WiFiLocationAuthorizationStatus) -> Void)?

  @ObservationIgnored private let manager: CLLocationManager
  @ObservationIgnored private let delegate = AuthorizationDelegate()
  @ObservationIgnored private var servicesEnabled = true
  @ObservationIgnored private var hasRequestedAuthorization = false

  init(manager: CLLocationManager = CLLocationManager()) {
    self.manager = manager
    status = Self.status(for: manager.authorizationStatus, servicesEnabled: true)
    WiFiLocationAuthorizationMirror.publish(status)
    delegate.onChange = { [weak self] status in
      self?.handleAuthorizationChange(status)
    }
    manager.delegate = delegate
    refreshServicesEnabled()
  }

  /// Raises the macOS location prompt when it can still succeed.
  ///
  /// Returns `false` when the prompt cannot appear -- already answered, or Location Services is off
  /// system-wide -- so the caller can send the user to System Settings instead.
  @discardableResult
  func requestAuthorizationIfPossible() -> Bool {
    refreshServicesEnabled()
    guard status == .notDetermined else { return false }
    hasRequestedAuthorization = true
    manager.requestWhenInUseAuthorization()
    return true
  }

  func openLocationSettings() {
    let candidates = [
      URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"),
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"),
      URL(fileURLWithPath: "/System/Applications/System Settings.app"),
    ].compactMap(\.self)

    for url in candidates where NSWorkspace.shared.open(url) {
      return
    }
  }

  /// Re-reads the current status, e.g. after returning from System Settings.
  func refresh() {
    refreshServicesEnabled()
    applyStatus(Self.status(for: manager.authorizationStatus, servicesEnabled: servicesEnabled))
  }

  private func handleAuthorizationChange(_ authorization: CLAuthorizationStatus) {
    applyStatus(Self.status(for: authorization, servicesEnabled: servicesEnabled))
    refreshServicesEnabled()
  }

  private func applyStatus(_ next: WiFiLocationAuthorizationStatus) {
    WiFiLocationAuthorizationMirror.publish(next)
    guard next != status else { return }
    status = next
    onStatusChange?(next)
  }

  /// `CLLocationManager.locationServicesEnabled()` can block, so it is never read on the main actor.
  private func refreshServicesEnabled() {
    Task.detached(priority: .utility) { [weak self] in
      let enabled = CLLocationManager.locationServicesEnabled()
      await MainActor.run {
        guard let self else { return }
        self.servicesEnabled = enabled
        self.applyStatus(Self.status(for: self.manager.authorizationStatus, servicesEnabled: enabled))
      }
    }
  }

  /// macOS has no "when in use" authorization state: `requestWhenInUseAuthorization()` resolves to
  /// `.authorizedAlways`, and `CLAuthorizationStatus.authorizedWhenInUse` is unavailable here.
  nonisolated static func status(
    for authorization: CLAuthorizationStatus,
    servicesEnabled: Bool
  ) -> WiFiLocationAuthorizationStatus {
    switch authorization {
    case .authorizedAlways:
      return .authorized
    case .denied:
      return servicesEnabled ? .denied : .servicesDisabled
    case .restricted:
      return .restricted
    case .notDetermined:
      // A never-prompted app cannot be prompted while the master switch is off: the request call
      // returns silently, so surfacing "turn Location Services on" is the only honest advice.
      return servicesEnabled ? .notDetermined : .servicesDisabled
    @unknown default:
      return .notDetermined
    }
  }
}

private final class AuthorizationDelegate: NSObject, CLLocationManagerDelegate {
  var onChange: (@MainActor (CLAuthorizationStatus) -> Void)?

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor [onChange] in
      onChange?(status)
    }
  }
}
