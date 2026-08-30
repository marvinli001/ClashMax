@testable import ClashMax
import XCTest
import Yams

/// Roadmap C3's decision made testable: `listeners:` is supported at L3 through the Raw YAML
/// snippet (INV-2 — no bespoke toggle for a key the generic override already reaches), on the
/// condition that the exposure it creates is never silent.
///
/// Three measured facts make that condition load-bearing (bundled core v1.19.30, 2026-08-30):
/// `GET /configs` carries no `listeners` key, `allow-lan: false` does **not** close these inbounds,
/// and an entry with no `listen:` binds every interface. Together they mean a listener a user
/// pasted — or a subscription supplied — is an open door nothing else in the app would mention.
final class ListenerExposureTests: XCTestCase {
  // MARK: Helpers

  private func facts(_ yaml: String) -> ListenerRuntimeFacts {
    // Parsed the way the reader does, so the tests exercise the same path as the app.
    let root = try! Yams.load(yaml: yaml) as! [String: Any]
    return ListenerRuntimeFacts.facts(from: root)
  }

  private func fact(_ key: ListenerExposureSnapshot.Fact.Key, in snapshot: ListenerExposureSnapshot) -> String? {
    snapshot.facts.first { $0.key == key }?.value
  }

  private func listener(
    name: String = "lan-mixed",
    type: String = "mixed",
    listen: String = "0.0.0.0",
    port: String = "7890",
    proxy: String? = nil
  ) -> RuntimeListener {
    RuntimeListener(name: name, type: type, listen: listen, port: port, proxy: proxy)
  }

  // MARK: Bind address reading

  func testLoopbackBindsAreNotExposed() {
    XCTAssertFalse(listener(listen: "127.0.0.1").isLANExposed)
    XCTAssertFalse(listener(listen: "localhost").isLANExposed)
    XCTAssertFalse(listener(listen: "::1").isLANExposed)
    XCTAssertFalse(listener(listen: "[::1]:1080").isLANExposed)
  }

  func testRoutableBindsAreExposed() {
    XCTAssertTrue(listener(listen: "0.0.0.0").isLANExposed)
    XCTAssertTrue(listener(listen: "192.168.1.20").isLANExposed)
    XCTAssertTrue(listener(listen: "::").isLANExposed)
  }

  /// The default is the exposed one: with no `listen`, the core binds `*:port`. Reporting an absent
  /// key as loopback would be the single mistake that matters in this file.
  func testAbsentListenKeyCountsAsExposed() {
    XCTAssertTrue(listener(listen: "").isLANExposed)
    XCTAssertEqual(listener(listen: "", port: "7890").summary.contains("7890"), true)
  }

  func testHostPortFormIsSplitBeforeJudging() {
    XCTAssertFalse(listener(listen: "127.0.0.1:7890").isLANExposed)
    XCTAssertTrue(listener(listen: "0.0.0.0:7890").isLANExposed)
    // A bare IPv6 literal has more than one colon and no port to strip.
    XCTAssertEqual(listener(listen: "fe80::1").listenHost, "fe80::1")
  }

  // MARK: Parsing

  func testParsesAListenersBlock() {
    let parsed = facts("""
    listeners:
      - name: lan-mixed
        type: mixed
        port: 7890
        listen: 0.0.0.0
        proxy: 🇯🇵 Tokyo
      - name: local-socks
        type: socks
        port: 1080
        listen: 127.0.0.1
    """)

    XCTAssertEqual(parsed.listeners.count, 2)
    XCTAssertEqual(parsed.listeners.first?.port, "7890")
    XCTAssertEqual(parsed.listeners.first?.proxy, "🇯🇵 Tokyo")
    XCTAssertEqual(parsed.exposedListeners.map(\.name), ["lan-mixed"])
    XCTAssertFalse(parsed.hasInboundAuthentication)
  }

  /// The global `authentication:` list gates `listeners:` entries too — measured, not assumed: the
  /// same LAN request answered 407 without credentials and 200 with them.
  func testParsesTheGlobalAuthenticationList() {
    let parsed = facts("""
    authentication:
      - "user:password"
    listeners:
      - name: lan-mixed
        type: mixed
        port: 7890
    """)

    XCTAssertTrue(parsed.hasInboundAuthentication)
  }

  func testEmptyAuthenticationListIsNoAuthentication() {
    let parsed = facts("""
    authentication: []
    listeners:
      - {name: a, type: mixed, port: 1}
    """)

    XCTAssertFalse(parsed.hasInboundAuthentication)
  }

  /// Some listener types take a `ports:` range instead of a single `port:`.
  func testRangePortsAreRead() {
    let parsed = facts("""
    listeners:
      - name: range
        type: tuic
        ports: 20000-20100
        listen: 127.0.0.1
    """)

    XCTAssertEqual(parsed.listeners.first?.port, "20000-20100")
  }

  /// An entry the core could not start is not something to report as running.
  func testUnnamedUntypedEntriesAreDropped() {
    let parsed = facts("""
    listeners:
      - port: 7890
      - name: real
        type: mixed
        port: 7891
    """)

    XCTAssertEqual(parsed.listeners.map(\.name), ["real"])
  }

  /// An entry with only a type is still a listener; it is named after the type so the fact row is
  /// not blank.
  func testTypeOnlyEntryIsNamedAfterItsType() {
    let parsed = facts("listeners:\n  - {type: mixed, port: 7890, listen: 127.0.0.1}")

    XCTAssertEqual(parsed.listeners.first?.name, "mixed")
  }

  func testConfigWithoutListenersParsesToNone() {
    XCTAssertEqual(facts("mode: rule"), .empty)
  }

  // MARK: Snapshot causes

  func testStoppedCoreIsListeningToNothing() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(isCoreRunning: false, facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: false))
    )

    XCTAssertEqual(snapshot.cause, .coreNotRunning)
    XCTAssertEqual(snapshot.status, .info)
    XCTAssertTrue(snapshot.exposedListeners.isEmpty)
  }

  func testUnreadConfigurationSaysSoRatherThanClaimingSafety() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(for: ListenerExposureInput(facts: nil))

    XCTAssertEqual(snapshot.cause, .configurationUnknown)
    XCTAssertEqual(snapshot.status, .info)
  }

  func testNoListenersBlockIsNothingToReport() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(for: ListenerExposureInput(facts: ListenerRuntimeFacts.empty))

    XCTAssertEqual(snapshot.cause, .noListeners)
    XCTAssertEqual(snapshot.status, .info)
  }

  func testLoopbackOnlyListenersPass() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(
          listeners: [listener(name: "local", listen: "127.0.0.1")],
          hasInboundAuthentication: false
        )
      )
    )

    XCTAssertEqual(snapshot.cause, .loopbackOnly)
    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertTrue(snapshot.exposedListeners.isEmpty)
    XCTAssertEqual(snapshot.facts.filter { $0.key == .listener }.count, 1)
  }

  /// Exposed *and* unauthenticated is the one that deserves the loudest word the file has: anyone
  /// who can reach the Mac can route traffic through the user's paid proxy.
  func testExposedAndUnauthenticatedIsAnOpenProxy() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: false)
      )
    )

    XCTAssertEqual(snapshot.cause, .openProxy)
    XCTAssertEqual(snapshot.status, .fail)
    XCTAssertEqual(snapshot.exposedListeners.map(\.name), ["lan-mixed"])
    XCTAssertEqual(fact(.exposure, in: snapshot)?.contains("lan-mixed"), true)
    XCTAssertFalse(snapshot.recoveryActions.isEmpty)
  }

  func testExposedWithAuthenticationIsAWarning() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: true)
      )
    )

    XCTAssertEqual(snapshot.cause, .lanExposed)
    XCTAssertEqual(snapshot.status, .warn)
  }

  /// `allow-lan` governs the default inbounds only. Saying nothing about it would let a user read
  /// "Allow LAN: Off" elsewhere in the app and conclude the port is closed.
  func testAllowLanIsReportedForWhatItDoesNotCover() {
    let off = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: true),
        allowLan: false
      )
    )
    let on = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: true),
        allowLan: true
      )
    )

    XCTAssertNotNil(fact(.allowLan, in: off))
    XCTAssertNotNil(fact(.allowLan, in: on))
    XCTAssertNotEqual(fact(.allowLan, in: off), fact(.allowLan, in: on))
    // Both statuses are the same: the setting does not change the exposure.
    XCTAssertEqual(off.status, on.status)
  }

  func testOneExposedEntryAmongLocalOnesStillReportsExposure() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(
          listeners: [listener(name: "local", listen: "127.0.0.1"), listener(name: "open", listen: "")],
          hasInboundAuthentication: false
        )
      )
    )

    XCTAssertEqual(snapshot.cause, .openProxy)
    XCTAssertEqual(snapshot.exposedListeners.map(\.name), ["open"])
    XCTAssertEqual(snapshot.facts.filter { $0.key == .listener }.count, 2)
  }

  // MARK: Report

  func testPlainTextLinesCarryTheVerdictAndTheFix() {
    let snapshot = ListenerExposureDiagnosticsBuilder.snapshot(
      for: ListenerExposureInput(
        facts: ListenerRuntimeFacts(listeners: [listener()], hasInboundAuthentication: false)
      )
    )
    let text = snapshot.plainTextLines.joined(separator: "\n")

    XCTAssertTrue(text.hasPrefix("Inbound Listeners: Fail (openProxy)"))
    XCTAssertTrue(text.contains("Recovery Actions:"))
  }
}
