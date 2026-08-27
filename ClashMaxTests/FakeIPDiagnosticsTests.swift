@testable import ClashMax
import XCTest

/// One test per `FakeIPDiagnosticsSnapshot.Cause`, so the answer to "are my fake-ip mappings still
/// trustworthy?" is reachable without a running core (roadmap A3).
///
/// `POST /cache/fakeip/flush` answers 204 whether or not the core is even in fake-ip mode, so the
/// status code can never tell the user whether flushing would achieve anything. That judgement is
/// made entirely here, which is why every branch is worth pinning.
final class FakeIPDiagnosticsTests: XCTestCase {
  // MARK: Helpers

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func minutesAgo(_ minutes: Double) -> Date {
    now.addingTimeInterval(-minutes * 60)
  }

  private func dnsFacts(
    enable: Bool? = true,
    enhancedMode: String? = "fake-ip",
    fakeIPRange: String? = "198.18.0.1/16"
  ) -> DNSRuntimeFacts {
    var values: [DNSOverrideField: String] = [:]
    if let enable { values[.enable] = enable ? "true" : "false" }
    if let enhancedMode { values[.enhancedMode] = enhancedMode }
    if let fakeIPRange { values[.fakeIPRange] = fakeIPRange }
    return DNSRuntimeFacts(isPresent: true, values: values)
  }

  // MARK: Causes

  func testStoppedCoreHoldsNoTableToFlush() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(isCoreRunning: false, dnsFacts: dnsFacts()),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .coreNotRunning)
    XCTAssertEqual(snapshot.status, .info)
    XCTAssertFalse(snapshot.canFlush)
  }

  /// An unread runtime config is reported as unknown rather than collapsed into "not fake-ip",
  /// which would be a guess dressed up as an answer.
  func testUnreadRuntimeConfigIsUnknownRatherThanAssumedOff() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: nil),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .configurationUnknown)
    XCTAssertFalse(snapshot.canFlush)
    XCTAssertEqual(snapshot.recoveryActions.count, 1)
  }

  /// `dns.enable` defaults to false in Mihomo, so an absent key means DNS is off — the same reading
  /// issue #16's "inert override" verdict uses.
  func testAbsentDNSEnableKeyReadsAsDNSOff() {
    let absent = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(enable: nil)),
      now: now
    )
    let explicit = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(enable: false)),
      now: now
    )

    XCTAssertEqual(absent.cause, .dnsDisabled)
    XCTAssertEqual(explicit.cause, .dnsDisabled)
    XCTAssertFalse(absent.canFlush)
  }

  func testRedirHostModeNamesTheModeItActuallyFound() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(enhancedMode: "redir-host")),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .notFakeIPMode)
    XCTAssertFalse(snapshot.canFlush)
    XCTAssertTrue(snapshot.reason.contains("redir-host"))
    XCTAssertEqual(snapshot.facts.first { $0.key == .enhancedMode }?.value, "redir-host")
  }

  /// An absent `enhanced-mode` is the core's `normal` default, and the fact has to say so rather
  /// than render an empty value.
  func testAbsentEnhancedModeIsReportedAsNormal() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(enhancedMode: nil)),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .notFakeIPMode)
    XCTAssertEqual(snapshot.facts.first { $0.key == .enhancedMode }?.value, "normal")
  }

  func testFakeIPWithNothingInvalidatingItIsFresh() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(
        dnsFacts: dnsFacts(),
        runtimeAppliedAt: minutesAgo(5),
        networkChangedAt: minutesAgo(30),
        profileUpdatedAt: minutesAgo(90)
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertTrue(snapshot.canFlush)
    XCTAssertEqual(snapshot.facts.first { $0.key == .fakeIPRange }?.value, "198.18.0.1/16")
  }

  func testNetworkChangeAfterTheLastKnownGoodMomentIsAWarning() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(
        dnsFacts: dnsFacts(),
        runtimeAppliedAt: minutesAgo(60),
        networkChangedAt: minutesAgo(2)
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .networkChanged)
    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertTrue(snapshot.canFlush)
    XCTAssertNotNil(snapshot.facts.first { $0.key == .lastInvalidation })
  }

  func testProfileUpdateWinsOverAnOlderNetworkChange() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(
        dnsFacts: dnsFacts(),
        runtimeAppliedAt: minutesAgo(60),
        networkChangedAt: minutesAgo(10),
        profileUpdatedAt: minutesAgo(2)
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .profileReloaded)
    XCTAssertEqual(snapshot.facts.filter { $0.key == .lastInvalidation }.count, 1)
  }

  /// Flushing is what makes the table known-good again, so the warning has to clear afterwards or
  /// the button would never stop nagging.
  func testFlushingClearsAnEarlierInvalidation() {
    let input = FakeIPDiagnosticsInput(
      dnsFacts: dnsFacts(),
      runtimeAppliedAt: minutesAgo(60),
      lastFlushAt: minutesAgo(1),
      networkChangedAt: minutesAgo(5),
      profileUpdatedAt: minutesAgo(4)
    )

    let snapshot = FakeIPDiagnosticsBuilder.snapshot(for: input, now: now)

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertNotNil(snapshot.facts.first { $0.key == .lastFlush })
  }

  /// A core that hot-reloaded a config started from an empty table, so a *later* restart also
  /// clears an earlier network change without anybody pressing the button.
  func testRuntimeReapplyAfterANetworkChangeIsAlreadyKnownGood() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(
        dnsFacts: dnsFacts(),
        runtimeAppliedAt: minutesAgo(1),
        networkChangedAt: minutesAgo(3)
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
  }

  /// Nothing is known to have emptied the table yet, so an invalidating event with no baseline has
  /// to count rather than be silently dropped.
  func testInvalidationWithNoKnownGoodMomentStillWarns() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(), networkChangedAt: minutesAgo(3)),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .networkChanged)
  }

  func testMissingFakeIPRangeSimplyOmitsTheFact() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(dnsFacts: dnsFacts(fakeIPRange: nil), runtimeAppliedAt: minutesAgo(5)),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertNil(snapshot.facts.first { $0.key == .fakeIPRange })
  }

  // MARK: Report

  func testPlainTextLinesCarryTheCauseFactsAndActions() {
    let snapshot = FakeIPDiagnosticsBuilder.snapshot(
      for: FakeIPDiagnosticsInput(
        dnsFacts: dnsFacts(),
        runtimeAppliedAt: minutesAgo(60),
        networkChangedAt: minutesAgo(2)
      ),
      now: now
    )

    let lines = snapshot.plainTextLines

    XCTAssertEqual(lines.first, "Fake IP: Warn (networkChanged)")
    XCTAssertTrue(lines.contains { $0.hasPrefix("Reason: ") })
    XCTAssertTrue(lines.contains("Recovery Actions:"))
  }

  func testStatusLabelsStayEnglishForTheCopyableReport() {
    XCTAssertEqual(
      FakeIPDiagnosticsBuilder.snapshot(for: FakeIPDiagnosticsInput(isCoreRunning: false), now: now).statusLabel,
      "Info"
    )
  }
}
