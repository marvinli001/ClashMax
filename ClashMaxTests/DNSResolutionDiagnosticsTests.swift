@testable import ClashMax
import XCTest

/// One test per `DNSResolutionSnapshot.Cause`, plus the decoder that feeds it, so "what does the
/// core resolve this name to?" is answerable without a running core (roadmap A2).
///
/// The endpoint's replies are DoH-*shaped* rather than DoH, and the differences are exactly the
/// ones a hand-written decoder gets wrong: `TTL` is upper-case while `name`/`type`/`data` are not,
/// a `NOERROR` with nothing to say omits `Answer` instead of sending `[]`, and the negative answer
/// lives in `Authority`. Each of those is pinned below against a body copied from the bundled core.
final class DNSResolutionDiagnosticsTests: XCTestCase {
  // MARK: Helpers

  private func dnsFacts(
    enable: Bool? = true,
    enhancedMode: String? = nil,
    respectRules: Bool = false,
    fakeIPRange: String? = nil
  ) -> DNSRuntimeFacts {
    var values: [DNSOverrideField: String] = [:]
    if let enable { values[.enable] = enable ? "true" : "false" }
    if let enhancedMode { values[.enhancedMode] = enhancedMode }
    if respectRules { values[.respectRules] = "true" }
    if let fakeIPRange { values[.fakeIPRange] = fakeIPRange }
    return DNSRuntimeFacts(isPresent: true, values: values)
  }

  private func answer(
    name: String = "example.com.",
    type: String = "A",
    status: Int = 0,
    answers: [DNSQueryRecord] = [DNSQueryRecord(name: "example.com.", type: 1, ttl: 300, data: "93.184.216.34")],
    authorities: [DNSQueryRecord] = []
  ) -> DNSQueryResult {
    DNSQueryResult(
      name: name,
      queryType: type,
      status: status,
      answers: answers,
      authorities: authorities
    )
  }

  private func rules() -> [RuntimeRule] {
    [
      RuntimeRule(index: 1, type: "DOMAIN-SUFFIX", payload: "example.com", policy: "Proxy"),
      RuntimeRule(index: 2, type: "IP-CIDR", payload: "93.184.216.0/24", policy: "DIRECT"),
      RuntimeRule(index: 3, type: "MATCH", payload: "", policy: "Proxy"),
    ]
  }

  private func fact(_ key: DNSResolutionSnapshot.Fact.Key, in snapshot: DNSResolutionSnapshot) -> String? {
    snapshot.facts.first { $0.key == key }?.value
  }

  // MARK: Causes

  func testStoppedCoreHasNoResolverToAsk() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(isCoreRunning: false, dnsFacts: dnsFacts(), query: "example.com")
    )

    XCTAssertEqual(snapshot.cause, .coreNotRunning)
    XCTAssertEqual(snapshot.status, .info)
    XCTAssertFalse(snapshot.canQuery)
  }

  /// `dns.enable: false` answers 500 `DNS section is disabled`. Refusing here says the same thing
  /// earlier and with the fix attached, so the user is not sent to read an HTTP status.
  func testDisabledDNSRefusesBeforeAsking() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(enable: false), query: "example.com")
    )

    XCTAssertEqual(snapshot.cause, .dnsDisabled)
    XCTAssertFalse(snapshot.canQuery)
  }

  /// An absent `dns.enable` key is Mihomo's `false`, so the same refusal applies to a config that
  /// simply never mentioned it.
  func testAbsentEnableKeyReadsAsDisabled() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(enable: nil), query: "example.com")
    )

    XCTAssertEqual(snapshot.cause, .dnsDisabled)
  }

  /// Not having read the config back is not evidence DNS is off. Guessing "off" would refuse a
  /// query the core would have answered, so the query stays available and says why.
  func testUnreadConfigurationStillAllowsAQuery() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: nil, query: "example.com")
    )

    XCTAssertEqual(snapshot.cause, .configurationUnknown)
    XCTAssertTrue(snapshot.canQuery)
  }

  func testReadyStateOffersTheQuery() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(), query: "example.com")
    )

    XCTAssertEqual(snapshot.cause, .ready)
    XCTAssertTrue(snapshot.canQuery)
  }

  func testInFlightQueryBlocksASecondOne() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(), query: "example.com", outcome: .querying)
    )

    XCTAssertEqual(snapshot.cause, .querying)
    XCTAssertFalse(snapshot.canQuery)
  }

  func testResolvedNameReportsItsAddresses() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(), query: "example.com", outcome: .answered(answer()))
    )

    XCTAssertEqual(snapshot.cause, .resolved)
    XCTAssertEqual(snapshot.status, .pass)
    XCTAssertEqual(fact(.addresses, in: snapshot), "93.184.216.34")
    XCTAssertEqual(fact(.response, in: snapshot), "NOERROR")
    XCTAssertEqual(snapshot.records.count, 1)
  }

  /// A `NOERROR` with no records is the shape a name with only IPv4 answers AAAA with. It is not a
  /// failure, and calling it one would send the user looking for a broken resolver.
  func testEmptyAnswerIsAWarningNotAFailure() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "example.com",
        queryType: .aaaa,
        outcome: .answered(answer(type: "AAAA", answers: []))
      )
    )

    XCTAssertEqual(snapshot.cause, .emptyAnswer)
    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertTrue(snapshot.canQuery)
  }

  func testNXDOMAINSurfacesTheDenyingZone() {
    let soa = DNSQueryRecord(
      name: "com.",
      type: DNSRecordType.soa,
      ttl: 900,
      data: "a.gtld-servers.net. nstld.verisign-grs.com. 1 1800 900 604800 86400"
    )
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "no-such-name.example.com",
        outcome: .answered(answer(status: DNSResponseCode.nameError, answers: [], authorities: [soa]))
      )
    )

    XCTAssertEqual(snapshot.cause, .nameNotFound)
    XCTAssertEqual(snapshot.status, .fail)
    XCTAssertEqual(fact(.response, in: snapshot), "NXDOMAIN")
    XCTAssertEqual(fact(.authority, in: snapshot)?.hasPrefix("com. SOA"), true)
    XCTAssertEqual(snapshot.records, [soa])
  }

  func testServerFailureBlamesTheUpstream() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "example.com",
        outcome: .answered(answer(status: DNSResponseCode.serverFailure, answers: []))
      )
    )

    XCTAssertEqual(snapshot.cause, .serverFailure)
    XCTAssertEqual(snapshot.status, .fail)
  }

  func testUnnamedResponseCodeStillReportsItsNumber() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "example.com",
        outcome: .answered(answer(status: 9, answers: []))
      )
    )

    XCTAssertEqual(snapshot.cause, .responseError)
    XCTAssertEqual(fact(.response, in: snapshot), "RCODE9")
  }

  /// The core's own message is the only text that names the fix (`invalid query type`), so it is
  /// shown verbatim rather than replaced with a paraphrase.
  func testTransportFailureRepeatsTheCoreMessage() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "example.com",
        outcome: .failed("invalid query type")
      )
    )

    XCTAssertEqual(snapshot.cause, .queryFailed)
    XCTAssertEqual(snapshot.reason, "invalid query type")
    XCTAssertTrue(snapshot.canQuery)
  }

  // MARK: Honesty facts

  /// Roadmap A2 originally asked which nameserver answered. The reply has no such field, so the
  /// panel says so out loud — a blank row would be read as "the default one".
  func testResolverAttributionIsReportedAsUnavailable() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(), query: "example.com", outcome: .answered(answer()))
    )

    XCTAssertNotNil(fact(.resolver, in: snapshot))
  }

  /// In fake-ip mode an app resolving the same name gets a placeholder from the fake-ip range while
  /// this endpoint answers from upstream. Both are right about different things, so the difference
  /// is stated instead of left for the user to trip over.
  func testFakeIPModeExplainsWhichAnswerThisIs() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(enhancedMode: "fake-ip", fakeIPRange: "198.18.0.1/16"),
        query: "example.com",
        outcome: .answered(answer())
      )
    )

    XCTAssertEqual(fact(.fakeIP, in: snapshot)?.contains("198.18.0.1/16"), true)
  }

  func testRedirectedNameReportsItsCanonicalTarget() {
    let chain = [
      DNSQueryRecord(name: "www.example.com.", type: DNSRecordType.cname, ttl: 300, data: "example.com."),
      DNSQueryRecord(name: "example.com.", type: DNSRecordType.a, ttl: 60, data: "93.184.216.34"),
    ]
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "www.example.com",
        outcome: .answered(answer(name: "www.example.com.", answers: chain))
      )
    )

    XCTAssertEqual(fact(.canonicalName, in: snapshot), "example.com.")
    // The shortest TTL in the chain is the one that decides when the answer stops being true.
    XCTAssertEqual(fact(.ttl, in: snapshot)?.hasPrefix("60"), true)
  }

  // MARK: Routing

  /// The half of A2 worth having: the name and the address it resolves to can match different
  /// rules, and that gap is what a "why did this go DIRECT?" question is actually about.
  func testNameAndAddressAreMatchedSeparately() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(
        dnsFacts: dnsFacts(),
        query: "example.com",
        outcome: .answered(answer()),
        rules: rules()
      )
    )

    XCTAssertEqual(fact(.matchedPolicy, in: snapshot), "Proxy")
    XCTAssertNotNil(fact(.matchedRule, in: snapshot))
    XCTAssertEqual(fact(.matchOnAddress, in: snapshot)?.hasPrefix("93.184.216.34 →"), true)
  }

  func testNoRulesMeansNoRoutingClaims() {
    let snapshot = DNSResolutionDiagnosticsBuilder.snapshot(
      for: DNSResolutionInput(dnsFacts: dnsFacts(), query: "example.com", outcome: .answered(answer()))
    )

    XCTAssertNil(fact(.matchedRule, in: snapshot))
    XCTAssertNil(fact(.matchOnAddress, in: snapshot))
  }

  // MARK: Input

  /// A blank `name` makes the core resolve the root zone and answer 200, which would read as an
  /// answer about whatever was last typed. The query is refused before it is sent.
  func testBlankQueryIsNotAQuery() {
    XCTAssertFalse(DNSResolutionInput(query: "   ").hasQuery)
    XCTAssertEqual(DNSResolutionInput(query: "  example.com \n").trimmedQuery, "example.com")
  }

  // MARK: Decoding

  private func decode(_ json: String, type: String = "A", fallbackName: String = "example.com") -> DNSQueryResult {
    let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    return DNSQueryResult.decode(object, queryType: type, fallbackName: fallbackName)
  }

  /// Body copied from the bundled core (v1.19.30). `TTL` is upper-case while its siblings are not,
  /// which is the single most likely thing for a decoder to get wrong and the reason it is pinned.
  func testDecodesACoreAnswer() {
    let result = decode(#"""
    {"Status":0,"TC":false,"RD":true,"RA":true,"AD":false,"CD":false,
     "Question":[{"Name":"example.com.","Qtype":1,"Qclass":1}],
     "Answer":[{"name":"example.com.","type":1,"TTL":274,"data":"23.192.228.84"}]}
    """#)

    XCTAssertEqual(result.name, "example.com.")
    XCTAssertEqual(result.displayName, "example.com")
    XCTAssertTrue(result.isSuccess)
    XCTAssertTrue(result.isRecursionAvailable)
    XCTAssertEqual(result.answers, [
      DNSQueryRecord(name: "example.com.", type: 1, ttl: 274, data: "23.192.228.84"),
    ])
    XCTAssertEqual(result.addresses, ["23.192.228.84"])
  }

  /// A `NOERROR` with nothing to say omits `Answer` entirely rather than sending `[]`, so the
  /// decoder must not require the key.
  func testDecodesAnAnswerlessSuccess() {
    let result = decode(#"{"Status":0,"Question":[{"Name":"example.com.","Qtype":28}]}"#, type: "AAAA")

    XCTAssertTrue(result.isSuccess)
    XCTAssertTrue(result.answers.isEmpty)
    XCTAssertEqual(result.queryType, "AAAA")
  }

  func testDecodesNXDOMAINAuthority() {
    let result = decode(#"""
    {"Status":3,"Question":[{"Name":"nope.example.com.","Qtype":1}],
     "Authority":[{"name":"example.com.","type":6,"TTL":3600,"data":"ns.icann.org. noc.dns.icann.org. 2024 7200 3600 1209600 3600"}]}
    """#)

    XCTAssertEqual(result.status, DNSResponseCode.nameError)
    XCTAssertEqual(result.statusName, "NXDOMAIN")
    XCTAssertEqual(result.authorities.count, 1)
    XCTAssertEqual(result.authorities.first?.typeName, "SOA")
  }

  /// The question name is where the fully-qualified form comes from; without it the panel would
  /// show whatever the user typed and quietly disagree with the records below it.
  func testFallsBackToTheRequestedNameWhenTheQuestionIsMissing() {
    let result = decode(#"{"Status":0}"#, fallbackName: "typed.example")

    XCTAssertEqual(result.name, "typed.example")
  }

  /// An unassigned type is rendered the way `dig` renders it, so an unexpected record is still
  /// legible rather than showing a bare integer.
  func testUnknownRecordTypeIsNamedLikeDig() {
    XCTAssertEqual(DNSRecordType.name(for: 65), "HTTPS")
    XCTAssertEqual(DNSRecordType.name(for: 99), "TYPE99")
    XCTAssertEqual(DNSResponseCode.name(for: 42), "RCODE42")
  }

  /// Records without `data` carry nothing to show, so they are dropped rather than rendered as a
  /// blank row.
  func testRecordsWithoutDataAreDropped() {
    let result = decode(#"""
    {"Status":0,"Answer":[{"name":"example.com.","type":1,"TTL":5},{"name":"example.com.","type":1,"TTL":5,"data":"1.2.3.4"}]}
    """#)

    XCTAssertEqual(result.answers.count, 1)
  }
}
