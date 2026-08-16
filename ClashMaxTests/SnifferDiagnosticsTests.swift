@testable import ClashMax
import XCTest

/// One test per `SnifferDiagnosticsSnapshot.Cause`, plus the fix folding, so every branch of the
/// answer to "why does my DOMAIN-SUFFIX rule not fire?" is reachable without a running core
/// (roadmap A1c).
final class SnifferDiagnosticsTests: XCTestCase {
  // MARK: Helpers

  private let sniffingOn = SnifferSettings(
    enabled: true,
    overrideDestination: true,
    protocols: [
      SnifferProtocolSettings(networkProtocol: .tls, ports: ["443"]),
      SnifferProtocolSettings(networkProtocol: .http, ports: ["80"]),
    ]
  )

  private func makeInput(
    domainOrigin: ConnectionDomainOrigin = .none,
    domain: String? = nil,
    destinationIP: String? = "104.20.23.154",
    destinationPort: Int? = 443,
    sourceIP: String? = "192.168.1.20",
    network: String = "tcp",
    sniffer: SnifferSettings?,
    startedAt: Date? = nil,
    snifferChangedAt: Date? = nil,
    rules: [RuntimeRule] = []
  ) -> SnifferDiagnosticsInput {
    SnifferDiagnosticsInput(
      domainOrigin: domainOrigin,
      domain: domain,
      destinationIP: destinationIP,
      destinationPort: destinationPort,
      sourceIP: sourceIP,
      network: network,
      sniffer: sniffer,
      startedAt: startedAt,
      snifferChangedAt: snifferChangedAt,
      rules: rules
    )
  }

  // MARK: A domain is in play

  func testReportedDomainPasses() {
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(domainOrigin: .reported, domain: "example.com", destinationIP: nil, sniffer: .off)
    )

    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertEqual(snapshot.cause, .domainReported)
    XCTAssertTrue(snapshot.canDomainRulesMatch)
    XCTAssertNil(snapshot.fix)
    XCTAssertTrue(snapshot.recoveryActions.isEmpty)
  }

  func testSniffedDomainPasses() {
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(domainOrigin: .sniffed, domain: "example.com", sniffer: sniffingOn)
    )

    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertEqual(snapshot.cause, .domainRecoveredBySniffing)
    XCTAssertTrue(snapshot.canDomainRulesMatch)
    XCTAssertNil(snapshot.fix)
  }

  /// `override-destination: false` still matches rules on the sniffed name — measured against the
  /// bundled v1.19.29 on 2026-08-15 — so this is worth reporting but is not a failure.
  func testSniffedWithoutDestinationOverrideIsInfoNotFailure() {
    var sniffer = sniffingOn
    sniffer.overrideDestination = false
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(domainOrigin: .sniffed, domain: "example.com", sniffer: sniffer)
    )

    XCTAssertEqual(snapshot.status, .info)
    XCTAssertEqual(snapshot.cause, .sniffedWithoutDestinationOverride)
    XCTAssertTrue(snapshot.canDomainRulesMatch)
    XCTAssertNil(snapshot.fix)
    XCTAssertFalse(snapshot.recoveryActions.isEmpty)
  }

  // MARK: No domain

  func testUnknownSnifferConfigurationIsReportedAsUnknownRatherThanOff() {
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: nil))

    XCTAssertEqual(snapshot.status, .info)
    XCTAssertEqual(snapshot.cause, .snifferConfigurationUnknown)
    XCTAssertFalse(snapshot.canDomainRulesMatch)
    XCTAssertNil(snapshot.fix)
    XCTAssertNotNil(snapshot.facts.first { $0.key == .sniffing })
  }

  func testSnifferDisabledWarnsAndOffersToTurnSniffingOn() throws {
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: .off))

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .domainlessSnifferDisabled)
    XCTAssertFalse(snapshot.canDomainRulesMatch)
    let fix = try XCTUnwrap(snapshot.fix)
    XCTAssertEqual(fix.patch.enabled, true)
    XCTAssertEqual(fix.patch.overrideDestination, true)
    // An empty protocol list would leave the core on its own defaults; the fix names the protocols
    // ClashMax manages so the user can see and edit them afterwards.
    XCTAssertEqual(
      fix.patch.protocols.map(\.networkProtocol),
      SnifferSettings.appManagedDefault.protocols.map(\.networkProtocol)
    )
  }

  /// The fix must not overwrite a protocol list the user already wrote.
  func testTurningSniffingOnKeepsAnExistingProtocolList() {
    var sniffer = sniffingOn
    sniffer.enabled = false
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: sniffer))

    XCTAssertEqual(snapshot.cause, .domainlessSnifferDisabled)
    XCTAssertEqual(snapshot.fix?.patch.protocols, [])
  }

  func testSettingsNewerThanTheConnectionAreNotUsedToJudgeIt() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(
        sniffer: sniffingOn,
        startedAt: started,
        snifferChangedAt: started.addingTimeInterval(30)
      )
    )

    XCTAssertEqual(snapshot.status, .info)
    XCTAssertEqual(snapshot.cause, .domainlessSnifferChangedAfterStart)
    XCTAssertNil(snapshot.fix)
  }

  func testSettingsOlderThanTheConnectionStillJudgeIt() {
    let changed = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(
        sniffer: sniffingOn,
        startedAt: changed.addingTimeInterval(30),
        snifferChangedAt: changed
      )
    )

    XCTAssertEqual(snapshot.cause, .domainlessNotSniffable)
  }

  func testSkippedDestinationAddressIsNamedWithTheListItMatched() {
    var sniffer = sniffingOn
    sniffer.skipDestinationAddress = ["104.20.0.0/16"]
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: sniffer))

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .domainlessSkippedByAddress)
    XCTAssertTrue(snapshot.reason.contains("104.20.0.0/16"))
    XCTAssertTrue(snapshot.reason.contains("skip-dst-address"))
    XCTAssertNil(snapshot.fix)
  }

  func testSkippedSourceAddressIsNamedWithTheListItMatched() {
    var sniffer = sniffingOn
    sniffer.skipSourceAddress = ["192.168.1.0/24"]
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: sniffer))

    XCTAssertEqual(snapshot.cause, .domainlessSkippedByAddress)
    XCTAssertTrue(snapshot.reason.contains("skip-src-address"))
  }

  /// The port list is a real gate, measured on 2026-08-15: a TLS entry listing only 443 ignored the
  /// same handshake on 9443.
  func testPortOutsideEveryProtocolEntryWarnsAndOffersToAddIt() throws {
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(destinationPort: 9443, sniffer: sniffingOn)
    )

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .domainlessProtocolNotCovered)
    let fix = try XCTUnwrap(snapshot.fix)
    let tls = fix.patch.protocols.first { $0.networkProtocol == .tls }
    XCTAssertEqual(tls?.ports, ["443", "9443"])
    // The rest of the map has to survive the patch, which replaces the sniff map wholesale.
    XCTAssertEqual(
      fix.patch.protocols.first { $0.networkProtocol == .http }?.ports,
      ["80"]
    )
  }

  /// An entry running on the core's fallback port has to have that port written out before the new
  /// one is added, or the fix would silently drop it.
  func testAddingAPortToAnImplicitFallbackKeepsTheFallbackPort() {
    let sniffer = SnifferSettings(
      enabled: true,
      protocols: [SnifferProtocolSettings(networkProtocol: .tls, ports: [])]
    )
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(destinationPort: 8443, sniffer: sniffer))

    XCTAssertEqual(snapshot.cause, .domainlessProtocolNotCovered)
    XCTAssertEqual(
      snapshot.fix?.patch.protocols.first { $0.networkProtocol == .tls }?.ports,
      ["443", "8443"]
    )
  }

  func testUDPWithoutQUICSniffingOffersAQUICEntry() {
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(destinationPort: 443, network: "udp", sniffer: sniffingOn)
    )

    XCTAssertEqual(snapshot.cause, .domainlessProtocolNotCovered)
    // The connection's own port is already QUIC's default, and the port list is deduplicated, so
    // the fix adds one entry rather than repeating 443.
    let quic = snapshot.fix?.patch.protocols.first { $0.networkProtocol == .quic }
    XCTAssertEqual(quic?.ports, ["443"])
    XCTAssertEqual(quic?.covers(port: 443), true)
  }

  func testCoveredButUnsniffableTrafficIsAnAnswerNotAFix() {
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: sniffingOn))

    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertEqual(snapshot.cause, .domainlessNotSniffable)
    XCTAssertFalse(snapshot.canDomainRulesMatch)
    XCTAssertNil(snapshot.fix)
    XCTAssertFalse(snapshot.recoveryActions.isEmpty)
  }

  // MARK: Facts and report

  func testFactsReportBothTheDomainAndDomainlessRuleMatch() {
    let rules = [
      RuntimeRule(index: 1, type: "DOMAIN-SUFFIX", payload: "example.com", policy: "Proxy"),
      RuntimeRule(index: 2, type: "IP-CIDR", payload: "104.20.0.0/16", policy: "DIRECT"),
      RuntimeRule(index: 3, type: "MATCH", payload: "", policy: "Fallback"),
    ]
    let snapshot = SnifferDiagnosticsBuilder.build(
      makeInput(domainOrigin: .sniffed, domain: "example.com", sniffer: sniffingOn, rules: rules)
    )

    XCTAssertEqual(snapshot.facts.first { $0.key == .matchOnDomain }?.value, "DOMAIN-SUFFIX,example.com,Proxy")
    XCTAssertEqual(snapshot.facts.first { $0.key == .matchWithoutDomain }?.value, "IP-CIDR,104.20.0.0/16,DIRECT")
  }

  func testFactsOmitRuleMatchesWhenNoRulesAreLoaded() {
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: sniffingOn))

    XCTAssertEqual(snapshot.facts.map(\.key), [.domain, .destination, .sniffing])
    XCTAssertEqual(snapshot.facts.first { $0.key == .destination }?.value, "104.20.23.154:443 (TCP)")
  }

  func testPlainTextLinesNameTheCauseAndRecovery() {
    let snapshot = SnifferDiagnosticsBuilder.build(makeInput(sniffer: .off))

    XCTAssertEqual(snapshot.plainTextLines.first, "Sniffer: Warn (domainlessSnifferDisabled)")
    XCTAssertTrue(snapshot.plainTextLines.contains("Recovery Actions:"))
  }

  func testInputReadsTheConnectionSnapshot() {
    let connection = ConnectionSnapshot(
      id: "c1",
      network: "tcp",
      host: "",
      destinationIP: "1.1.1.1",
      destinationPort: 443,
      upload: 0,
      download: 0,
      chain: ["DIRECT"],
      rule: "MATCH",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let input = SnifferDiagnosticsInput(connection: connection, sniffer: .off)

    XCTAssertEqual(input.domainOrigin, .none)
    XCTAssertNil(input.domain)
    XCTAssertEqual(input.destinationIP, "1.1.1.1")
    XCTAssertEqual(input.destinationPort, 443)
    XCTAssertEqual(input.startedAt, connection.startedAt)
  }

  // MARK: Fix library

  func testFixLibraryCreatesOneEnabledSnippetBoundToTheActiveProfile() {
    let profileID = UUID()
    let snippet = SnifferFixLibrary.targetSnippet(in: [], activeProfileID: profileID)

    XCTAssertEqual(snippet.id, SnifferFixLibrary.snippetID)
    XCTAssertTrue(snippet.enabled)
    XCTAssertTrue(snippet.binding.applies(to: profileID))
    guard case .sniffer = snippet.payload else {
      return XCTFail("Expected a sniffer payload")
    }
  }

  func testFixLibraryReusesItsOwnSnippetAndFoldsFixesTogether() {
    let profileID = UUID()
    let first = SnifferFixLibrary.adding(
      SnifferDiagnosticsFix(title: "on", patch: SnifferSettings(enabled: true)),
      to: SnifferFixLibrary.targetSnippet(in: [], activeProfileID: profileID)
    )
    let second = SnifferFixLibrary.adding(
      SnifferDiagnosticsFix(
        title: "port",
        patch: SnifferSettings(protocols: [SnifferProtocolSettings(networkProtocol: .tls, ports: ["443", "8443"])])
      ),
      to: SnifferFixLibrary.targetSnippet(in: [first], activeProfileID: profileID)
    )

    XCTAssertEqual(second.id, first.id)
    guard case let .sniffer(settings) = second.payload else {
      return XCTFail("Expected a sniffer payload")
    }
    XCTAssertEqual(settings.enabled, true)
    XCTAssertEqual(settings.protocols.first?.ports, ["443", "8443"])
  }

  /// A snippet squatting on the fixed id with another payload kind is left alone rather than
  /// converted, so a restored backup never loses user data.
  func testFixLibraryDoesNotConvertAForeignSnippetOnTheSameID() {
    let squatter = RuntimeSnippet(
      id: SnifferFixLibrary.snippetID,
      name: "Not mine",
      payload: .dnsPatch(TunDNSSettings())
    )
    let snippet = SnifferFixLibrary.targetSnippet(in: [squatter], activeProfileID: nil)

    XCTAssertNotEqual(snippet.id, SnifferFixLibrary.snippetID)
    guard case .sniffer = snippet.payload else {
      return XCTFail("Expected a sniffer payload")
    }
  }
}
