@testable import ClashMax
import CoreLocation
import XCTest

/// Issue #26: macOS 14+ withholds `CWInterface.ssid()` from apps without Location Services access,
/// so ClashMax reported a bare "No Wi-Fi SSID detected." while the Mac was plainly on Wi-Fi.
final class WiFiNetworkInfoTests: XCTestCase {
  private func reading(
    poweredOn: Bool = true,
    ssid: String? = nil,
    associated: Bool = true
  ) -> WiFiInterfaceReading {
    WiFiInterfaceReading(isPoweredOn: poweredOn, ssid: ssid, isAssociated: associated)
  }

  // MARK: - Classification

  func testJoinedNetworkReportsSSIDRegardlessOfAuthorization() {
    for authorization in WiFiLocationAuthorizationStatus.allCases {
      let snapshot = WiFiNetworkClassifier.snapshot(
        for: reading(ssid: "corpnet"),
        authorization: authorization
      )
      XCTAssertEqual(snapshot.ssid, "corpnet", "authorization: \(authorization)")
      XCTAssertNil(snapshot.unavailableReason)
      XCTAssertFalse(snapshot.isBlockedByLocationAuthorization)
      XCTAssertEqual(snapshot.recoveryAction, .none)
    }
  }

  func testBlankSSIDIsTreatedAsMissing() {
    let snapshot = WiFiNetworkClassifier.snapshot(
      for: reading(ssid: "   "),
      authorization: .authorized
    )
    XCTAssertNil(snapshot.ssid)
    XCTAssertEqual(snapshot.unavailableReason, .ssidWithheld)
  }

  func testMissingSSIDWithoutAuthorizationBlamesAuthorizationNotTheNetwork() {
    let cases: [(WiFiLocationAuthorizationStatus, WiFiSSIDUnavailableReason, WiFiSSIDRecoveryAction)] = [
      (.notDetermined, .locationAuthorizationNotDetermined, .requestLocationAuthorization),
      (.denied, .locationAuthorizationDenied, .openLocationSettings),
      (.restricted, .locationAuthorizationDenied, .openLocationSettings),
      (.servicesDisabled, .locationServicesDisabled, .openLocationSettings),
    ]

    for (authorization, expectedReason, expectedAction) in cases {
      // Associated, but macOS redacted the name: exactly the reporter's state.
      let snapshot = WiFiNetworkClassifier.snapshot(
        for: reading(ssid: nil, associated: true),
        authorization: authorization
      )
      XCTAssertEqual(snapshot.unavailableReason, expectedReason, "authorization: \(authorization)")
      XCTAssertTrue(snapshot.isBlockedByLocationAuthorization)
      XCTAssertEqual(snapshot.recoveryAction, expectedAction)
      XCTAssertEqual(snapshot.statusSymbolName, "location.slash")
    }
  }

  func testUnauthorizedNotAssociatedInterfaceStillBlamesAuthorization() {
    // An unauthorized "not associated" reading cannot be trusted, and granting access is the
    // actionable fix either way.
    let snapshot = WiFiNetworkClassifier.snapshot(
      for: reading(ssid: nil, associated: false),
      authorization: .notDetermined
    )
    XCTAssertEqual(snapshot.unavailableReason, .locationAuthorizationNotDetermined)
  }

  func testAuthorizedInterfaceDistinguishesNotAssociatedFromWithheld() {
    XCTAssertEqual(
      WiFiNetworkClassifier.snapshot(
        for: reading(ssid: nil, associated: false),
        authorization: .authorized
      ).unavailableReason,
      .notAssociated
    )
    XCTAssertEqual(
      WiFiNetworkClassifier.snapshot(
        for: reading(ssid: nil, associated: true),
        authorization: .authorized
      ).unavailableReason,
      .ssidWithheld
    )
  }

  func testPoweredOffAndMissingInterfaceOutrankAuthorization() {
    XCTAssertEqual(
      WiFiNetworkClassifier.snapshot(
        for: reading(poweredOn: false, ssid: nil),
        authorization: .notDetermined
      ).unavailableReason,
      .wiFiPoweredOff
    )
    XCTAssertEqual(
      WiFiNetworkClassifier.snapshot(for: nil, authorization: .notDetermined).unavailableReason,
      .noWiFiInterface
    )
  }

  func testHardwareReasonsOfferNoRecoveryActionAndUseWiFiSymbol() {
    for reason in [WiFiSSIDUnavailableReason.noWiFiInterface, .wiFiPoweredOff, .notAssociated, .ssidWithheld] {
      let snapshot = WiFiNetworkSnapshot.unavailable(reason)
      XCTAssertEqual(snapshot.recoveryAction, .none, "reason: \(reason)")
      XCTAssertFalse(snapshot.isBlockedByLocationAuthorization)
      XCTAssertEqual(snapshot.statusSymbolName, "wifi.slash")
      XCTAssertNil(NetworkPolicyStatusPresenter.recoveryActionTitle(for: snapshot))
    }
  }

  // MARK: - Provider

  func testCoreWLANProviderCombinesReadingAndAuthorization() {
    let provider = CoreWLANCurrentNetworkProvider(
      readingProvider: { WiFiInterfaceReading(isPoweredOn: true, ssid: nil, isAssociated: true) },
      authorizationStatus: { .denied }
    )
    XCTAssertNil(provider.currentSSID())
    XCTAssertEqual(provider.currentNetwork().unavailableReason, .locationAuthorizationDenied)
  }

  func testCoreWLANProviderReportsSSIDWhenAuthorized() {
    let provider = CoreWLANCurrentNetworkProvider(
      readingProvider: { WiFiInterfaceReading(isPoweredOn: true, ssid: "corpnet", isAssociated: true) },
      authorizationStatus: { .authorized }
    )
    XCTAssertEqual(provider.currentSSID(), "corpnet")
  }

  // MARK: - Authorization status mapping

  func testAuthorizationStatusMapping() {
    // macOS has no separate "when in use" state: requestWhenInUseAuthorization() lands on
    // .authorizedAlways, and .authorizedWhenInUse is unavailable on this platform.
    XCTAssertEqual(
      WiFiLocationAuthorization.status(for: .authorizedAlways, servicesEnabled: true),
      .authorized
    )
    XCTAssertEqual(WiFiLocationAuthorization.status(for: .denied, servicesEnabled: true), .denied)
    XCTAssertEqual(WiFiLocationAuthorization.status(for: .restricted, servicesEnabled: true), .restricted)
    XCTAssertEqual(
      WiFiLocationAuthorization.status(for: .notDetermined, servicesEnabled: true),
      .notDetermined
    )
  }

  func testServicesDisabledOutranksPromptableStatuses() {
    // The prompt cannot appear while the master switch is off, so "Allow" would be a dead button.
    XCTAssertEqual(
      WiFiLocationAuthorization.status(for: .notDetermined, servicesEnabled: false),
      .servicesDisabled
    )
    XCTAssertEqual(
      WiFiLocationAuthorization.status(for: .denied, servicesEnabled: false),
      .servicesDisabled
    )
    // An already-granted app keeps reading the SSID; only promptable states degrade.
    XCTAssertEqual(
      WiFiLocationAuthorization.status(for: .authorizedAlways, servicesEnabled: false),
      .authorized
    )
  }

  func testOnlyAuthorizedStatusCanReadSSID() {
    for status in WiFiLocationAuthorizationStatus.allCases {
      XCTAssertEqual(status.canReadSSID, status == .authorized, "status: \(status)")
      XCTAssertEqual(status.unavailableReason == nil, status == .authorized)
    }
  }

  func testAuthorizationMirrorPublishesAcrossIsolationDomains() async {
    let previous = WiFiLocationAuthorizationMirror.current
    defer { WiFiLocationAuthorizationMirror.publish(previous) }

    WiFiLocationAuthorizationMirror.publish(.authorized)
    let readOffMainActor = await Task.detached { WiFiLocationAuthorizationMirror.current }.value
    XCTAssertEqual(readOffMainActor, .authorized)
  }

  // MARK: - Presenter

  func testEveryUnavailableReasonHasItsOwnMessage() {
    let messages = WiFiSSIDUnavailableReason.allCases.map(NetworkPolicyStatusPresenter.unavailableMessage)
    XCTAssertEqual(Set(messages).count, WiFiSSIDUnavailableReason.allCases.count)
    XCTAssertFalse(messages.contains(NetworkPolicyStatusPresenter.unavailableMessage(nil)))
  }

  /// Assertions stay locale-agnostic: the test bundle runs localized, so only the relationships
  /// between the strings are stable, not their English wording.
  func testLocationMessagesNameTheFixInsteadOfDeadEnding() {
    let notDetermined = NetworkPolicyStatusPresenter.unavailableMessage(.locationAuthorizationNotDetermined)
    XCTAssertNotEqual(notDetermined, NetworkPolicyStatusPresenter.unavailableMessage(nil))
    XCTAssertFalse(notDetermined.isEmpty)

    let promptTitle = NetworkPolicyStatusPresenter.recoveryActionTitle(
      for: .unavailable(.locationAuthorizationNotDetermined)
    )
    let settingsTitle = NetworkPolicyStatusPresenter.recoveryActionTitle(
      for: .unavailable(.locationAuthorizationDenied)
    )
    XCTAssertNotNil(promptTitle)
    XCTAssertNotNil(settingsTitle)
    XCTAssertNotEqual(promptTitle, settingsTitle)
    // Denied and globally-disabled both need System Settings, so they share one button.
    XCTAssertEqual(
      NetworkPolicyStatusPresenter.recoveryActionTitle(for: .unavailable(.locationServicesDisabled)),
      settingsTitle
    )
  }

  func testMatchedAndUnmatchedMessagesNameTheNetwork() {
    let rule = NetworkPolicyRule(
      name: "Office",
      ssid: "corpnet",
      proxyRoutingMode: .systemProxy,
      enableSystemProxy: true,
      autoStartRuntime: false
    )
    let matched = NetworkPolicyStatusPresenter.message(for: .joined("corpnet"), matchedRule: rule)
    XCTAssertTrue(matched.contains("corpnet"))
    XCTAssertTrue(matched.contains("Office"))

    let unmatched = NetworkPolicyStatusPresenter.message(for: .joined("cafe"), matchedRule: nil)
    XCTAssertTrue(unmatched.contains("cafe"))
    XCTAssertFalse(unmatched.contains("Office"))
  }

  func testMessageFallsBackToTheUnavailableReasonWhenSSIDIsMissing() {
    XCTAssertEqual(
      NetworkPolicyStatusPresenter.message(
        for: .unavailable(.locationAuthorizationDenied),
        matchedRule: nil
      ),
      NetworkPolicyStatusPresenter.unavailableMessage(.locationAuthorizationDenied)
    )
  }
}
