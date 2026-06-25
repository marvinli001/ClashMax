import XCTest
@testable import ClashMax

final class ProxyEffectDiagnosticsTests: XCTestCase {

  // MARK: Helpers

  private func makeInfo(
    countryCode: String?,
    countryName: String? = nil,
    sourceHost: String? = "api.ip.sb"
  ) -> PublicIPInfo {
    PublicIPInfo(
      ipAddress: "203.0.113.7",
      countryCode: countryCode,
      countryName: countryName,
      sourceName: "test",
      sourceHost: sourceHost,
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  // MARK: Waiting

  func testNotRunningReturnsWaitingWithoutFalseSuccess() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "US"),
        isCoreRunning: false
      )
    )

    XCTAssertEqual(snapshot.status, .waiting)
    XCTAssertEqual(snapshot.cause, .notRunning)
    XCTAssertNotEqual(snapshot.status, .pass)
  }

  func testRunningWithoutPublicIPReturnsWaiting() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: nil,
        isCoreRunning: true,
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentNodeName: "JP-01",
        currentNodeType: "vless"
      )
    )

    XCTAssertEqual(snapshot.status, .waiting)
    XCTAssertEqual(snapshot.cause, .waitingForPublicIP)
  }

  // MARK: Capture path not enabled

  func testSystemProxyModeWithoutSystemProxyReturnsFail() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN"),
        routingMode: .systemProxy,
        systemProxyEnabled: false
      )
    )

    XCTAssertEqual(snapshot.status, .fail)
    XCTAssertEqual(snapshot.cause, .systemProxyDisabled)
    XCTAssertEqual(
      snapshot.reason,
      String(localized: "System Proxy is not enabled for this runtime mode.")
    )
    // Recovery should suggest enabling system proxy or switching to TUN.
    XCTAssertFalse(snapshot.recoveryActions.isEmpty)
  }

  func testTunModeWithoutTunReturnsFail() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        routingMode: .tun,
        systemProxyEnabled: false,
        tunEnabled: false
      )
    )

    XCTAssertEqual(snapshot.status, .fail)
    XCTAssertEqual(snapshot.cause, .tunInactive)
    XCTAssertFalse(snapshot.recoveryActions.isEmpty)
  }

  func testTunModeWithDiagnosticIssueReturnsWarnAndSurfacesIssue() {
    let tun = TunDiagnosticsSnapshot(
      checks: [
        TunDiagnosticCheck(
          id: "route",
          title: "Default route",
          status: .fail,
          message: "No utun default route present"
        )
      ],
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      externalProbeIncluded: true
    )

    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        routingMode: .tun,
        systemProxyEnabled: false,
        tunEnabled: true,
        tunDiagnostics: tun
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .tunDegraded)
    // The concrete TUN issue must be shown (reason or facts), not a vague message.
    let mentionsIssue = snapshot.reason.contains("No utun default route present")
      || snapshot.facts.contains { $0.value.contains("No utun default route present") }
    XCTAssertTrue(mentionsIssue)
  }

  func testNetworkExtensionModeWithoutNEReturnsFail() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        routingMode: .neProxy,
        systemProxyEnabled: false,
        networkExtensionEnabled: false
      )
    )

    XCTAssertEqual(snapshot.status, .fail)
    XCTAssertEqual(snapshot.cause, .networkExtensionInactive)
  }

  // MARK: Run mode / node / rule direct

  func testDirectRunModeIsReportedEvenWhenCaptureEnabled() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "US"),
        routingMode: .systemProxy,
        runMode: .direct,
        systemProxyEnabled: true,
        currentNodeName: "JP-01",
        currentNodeType: "vless"
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .directRunMode)
    XCTAssertTrue(snapshot.reason.localizedCaseInsensitiveContains("Direct"))
  }

  func testCurrentNodeNamedDirectIsReported() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "DIRECT",
        currentNodeType: "Selector"
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .currentNodeDirect)
    XCTAssertEqual(snapshot.reason, String(localized: "Current node is DIRECT."))
  }

  func testCurrentNodeTypedDirectIsReportedCaseInsensitively() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "US"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "Built-in Direct",
        currentNodeType: "direct"
      )
    )

    XCTAssertEqual(snapshot.cause, .currentNodeDirect)
  }

  func testMissingSelectionIsReportedAsWarn() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: nil,
        hasMissingSelection: true
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .selectionUnavailable)
  }

  func testProbeHostMatchingDirectRuleIsReportedWithRuleAndPolicy() {
    let rules = [
      RuntimeRule(index: 1, type: "DOMAIN-SUFFIX", payload: "ip.sb", policy: "DIRECT")
    ]

    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "JP-01",
        currentNodeType: "vless",
        runtimeRules: rules,
        probeHost: "api.ip.sb"
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .ruleTargetDirect)
    XCTAssertEqual(snapshot.reason, String(localized: "IP check target matched a DIRECT rule."))
    XCTAssertEqual(snapshot.probePolicy, "DIRECT")
    // The matched rule must be surfaced for the user.
    XCTAssertTrue(snapshot.ruleProbeSummary.contains("DOMAIN-SUFFIX"))
    XCTAssertTrue(snapshot.facts.contains { $0.value == "DIRECT" })
  }

  // MARK: Public IP outcome

  func testStillChinaWhenPathLooksProxiedReturnsWarn() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN", countryName: "China"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "JP-01",
        currentNodeType: "vless",
        runtimeRules: [],
        probeHost: "api.ip.sb"
      )
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .publicIPChina)
    XCTAssertEqual(
      snapshot.reason,
      String(localized: "Public IP is still China; if you selected a non-China node, proxy capture is not confirmed.")
    )
  }

  func testNonChinaPublicIPWithProxiedPathReturnsPass() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "US", countryName: "United States"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "US-01",
        currentNodeType: "vless",
        runtimeRules: [],
        probeHost: "api.ip.sb"
      )
    )

    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertEqual(snapshot.cause, .proxyConfirmed)
    XCTAssertTrue(snapshot.recoveryActions.isEmpty)
  }

  // MARK: Plain text export

  func testPlainTextLinesIncludeProxyEffectProbeHostAndCurrentNode() {
    let snapshot = ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: makeInfo(countryCode: "CN"),
        routingMode: .systemProxy,
        runMode: .rule,
        systemProxyEnabled: true,
        currentGroupName: "Proxies",
        currentNodeName: "DIRECT",
        currentNodeType: "Selector",
        probeHost: "api.ip.sb"
      )
    )

    let text = snapshot.plainTextLines.joined(separator: "\n")
    XCTAssertTrue(text.contains("Proxy Effect:"))
    XCTAssertTrue(text.contains("Probe Host: api.ip.sb"))
    XCTAssertTrue(text.contains("Current Node:"))
  }
}
