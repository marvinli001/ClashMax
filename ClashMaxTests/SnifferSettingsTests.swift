@testable import ClashMax
import XCTest
import Yams

/// Roadmap A1b. The bundled core's own validation is thinner than it looks: `sniff: {}`, a missing
/// `sniff` key, `ports: ["9000-100"]` and `ports: ["70000"]` all pass `mihomo -t` (v1.19.29,
/// measured 2026-08-15) and then sniff nothing, which is indistinguishable from a working sniffer
/// from outside. These tests pin the checks that stand in for the ones the core does not do — and,
/// just as importantly, the one case that only *looks* broken: an entry with no ports at all.
final class SnifferSettingsTests: XCTestCase {
  // MARK: - Validation

  /// Measured against the bundled core on 2026-08-15: an entry with no ports is neither inert nor
  /// unlimited — `sniff: {TLS: {}}` sniffed 443 and ignored 8443/9443, `sniff: {HTTP: {}}` sniffed 80
  /// and ignored 8080. So it is valid, and everything downstream has to read the fallback, not `[]`.
  func testProtocolWithNoPortsIsValidAndFallsBackToTheCoreDefaultPort() throws {
    let settings = SnifferSettings(
      enabled: true,
      protocols: [SnifferProtocolSettings(networkProtocol: .tls, ports: [])]
    )
    let entry = try XCTUnwrap(settings.settings(for: .tls))

    XCTAssertNil(settings.validationError)
    XCTAssertEqual(entry.ports, [], "The written config still says nothing about ports")
    XCTAssertEqual(entry.effectivePorts, ["443"])
    XCTAssertTrue(entry.covers(port: 443))
    XCTAssertFalse(entry.covers(port: 8443), "The core left 8443 alone in the same measurement")
    XCTAssertEqual(SnifferProtocolSettings(networkProtocol: .http, ports: []).effectivePorts, ["80"])
  }

  func testPortCoverageReadsSinglePortsAndRanges() {
    let entry = SnifferProtocolSettings(networkProtocol: .http, ports: ["80", "8080-8880"])

    XCTAssertTrue(entry.covers(port: 80))
    XCTAssertTrue(entry.covers(port: 8080))
    XCTAssertTrue(entry.covers(port: 8443))
    XCTAssertTrue(entry.covers(port: 8880))
    XCTAssertFalse(entry.covers(port: 8881))
    XCTAssertFalse(entry.covers(port: 443))
  }

  /// The empty entry is written as `TLS: {}` rather than `TLS: {ports: []}` — the exact shape the
  /// fallback above was measured against.
  func testProtocolWithNoPortsWritesNoPortsKey() {
    let mapping = SnifferSettings(
      enabled: true,
      protocols: [SnifferProtocolSettings(networkProtocol: .tls, ports: [])]
    ).runtimeMapping(applyingTo: [:])
    let sniff = mapping["sniff"] as? [String: Any]
    let entry = sniff?["TLS"] as? [String: Any]

    XCTAssertNotNil(entry)
    XCTAssertNil(entry?["ports"])
  }

  func testInvertedAndOutOfRangePortsAreRejected() {
    XCTAssertFalse(SnifferSettings.isValidPortToken("9000-100"))
    XCTAssertFalse(SnifferSettings.isValidPortToken("70000"))
    XCTAssertFalse(SnifferSettings.isValidPortToken("0"))
    XCTAssertFalse(SnifferSettings.isValidPortToken("443,8443"))
    XCTAssertFalse(SnifferSettings.isValidPortToken("-1"))
    XCTAssertFalse(SnifferSettings.isValidPortToken("https"))
    XCTAssertTrue(SnifferSettings.isValidPortToken("443"))
    XCTAssertTrue(SnifferSettings.isValidPortToken("8000-9000"))
    XCTAssertTrue(SnifferSettings.isValidPortToken("443-443"))
  }

  func testProtocolListedTwiceIsCollapsedRatherThanWrittenTwice() {
    let settings = SnifferSettings(
      protocols: [
        SnifferProtocolSettings(networkProtocol: .tls, ports: ["443"]),
        SnifferProtocolSettings(networkProtocol: .tls, ports: ["8443"]),
      ]
    )

    // A YAML map cannot hold the key twice anyway; the initializer keeps the first entry so the
    // editor and the generated block agree on which one survives.
    XCTAssertEqual(settings.protocols.count, 1)
    XCTAssertEqual(settings.protocols.first?.ports, ["443"])
    XCTAssertNil(settings.validationError)
  }

  func testSkipAddressListsRejectNonCIDREntries() {
    let settings = SnifferSettings(skipSourceAddress: ["not-an-ip"])

    XCTAssertNotNil(settings.validationError)
    XCTAssertNil(SnifferSettings(skipSourceAddress: ["192.168.0.0/16"]).validationError)
  }

  func testDomainListsAreNotValidatedAsDomains() {
    // `Mijia Cloud` is the canonical skip-domain entry and is not a domain at all.
    XCTAssertNil(SnifferSettings(skipDomain: ["Mijia Cloud", "+.push.apple.com"]).validationError)
  }

  func testSniffingOnWithNoProtocolIsOnlyRejectedOnceMerged() {
    let patch = SnifferSettings(enabled: true)

    // Sparse patches are legal: this one inherits the protocol map from the layer underneath.
    XCTAssertNil(patch.validationError)
    // Merged, it would be an inert sniffer, which is the failure this whole item is about.
    XCTAssertNotNil(patch.effectiveValidationError)
    XCTAssertNil(SnifferSettings.appManagedDefault.patched(with: patch).effectiveValidationError)
  }

  // MARK: - Merging

  func testPatchOverridesScalarsMergesListsAndReplacesTheProtocolMap() {
    let base = SnifferSettings(
      enabled: true,
      overrideDestination: true,
      protocols: [
        SnifferProtocolSettings(networkProtocol: .tls),
        SnifferProtocolSettings(networkProtocol: .http),
      ],
      skipDomain: ["Mijia Cloud"]
    )
    let patch = SnifferSettings(
      overrideDestination: false,
      protocols: [SnifferProtocolSettings(networkProtocol: .quic, ports: ["443"])],
      skipDomain: ["+.internal.example"]
    )

    let merged = base.patched(with: patch)

    XCTAssertEqual(merged.enabled, true, "An unset scalar leaves what is underneath alone")
    XCTAssertEqual(merged.overrideDestination, false)
    XCTAssertEqual(merged.protocols.map(\.networkProtocol), [.quic], "A non-empty sniff map replaces, never merges")
    XCTAssertEqual(merged.skipDomain, ["Mijia Cloud", "+.internal.example"], "Exception lists merge")
  }

  func testCombinedFoldsSnippetsInOrder() {
    let combined = SnifferSettings.combined([
      SnifferSettings(enabled: true, skipDomain: ["a.example"]),
      SnifferSettings(enabled: false, skipDomain: ["b.example"]),
    ])

    XCTAssertEqual(combined.enabled, false, "The later snippet wins on scalars")
    XCTAssertEqual(combined.skipDomain, ["a.example", "b.example"])
  }

  // MARK: - YAML round trip

  func testRuntimeMappingRoundTripsThroughTheTypedView() throws {
    let settings = SnifferSettings(
      enabled: true,
      overrideDestination: true,
      forceDNSMapping: true,
      parsePureIP: false,
      protocols: [
        SnifferProtocolSettings(networkProtocol: .tls, ports: ["443", "8443"]),
        SnifferProtocolSettings(networkProtocol: .http, ports: ["80"], overrideDestination: false),
      ],
      forceDomain: ["+.v2ex.com"],
      skipDomain: ["Mijia Cloud"],
      skipSourceAddress: ["192.168.0.0/16"],
      skipDestinationAddress: ["10.0.0.0/8"]
    )

    let mapping = settings.runtimeMapping(applyingTo: [:])
    let yaml = try Yams.dump(object: ["sniffer": mapping])
    let reloaded = try XCTUnwrap((Yams.load(yaml: yaml) as? [String: Any])?["sniffer"] as? [String: Any])

    XCTAssertEqual(SnifferSettings(runtimeMapping: reloaded), settings)
  }

  func testReadingAProfileMappingToleratesLowercaseKeysAndIntegerPorts() {
    let settings = SnifferSettings(runtimeMapping: [
      "enable": true,
      "sniff": [
        "tls": ["ports": [443, "8443"]],
        "http": ["ports": 80],
      ],
      "skip-domain": ["Mijia Cloud"],
    ])

    XCTAssertEqual(settings.enabled, true)
    XCTAssertEqual(settings.settings(for: .tls)?.ports, ["443", "8443"])
    XCTAssertEqual(settings.settings(for: .http)?.ports, ["80"])
    XCTAssertEqual(settings.skipDomain, ["Mijia Cloud"])
  }

  func testWritingAPatchKeepsKeysClashMaxDoesNotModel() throws {
    let base: [String: Any] = [
      "enable": true,
      "sniffing": ["tls"],
      "sniff": ["TLS": ["ports": ["443"]]],
    ]

    let mapping = SnifferSettings(overrideDestination: false).runtimeMapping(applyingTo: base)

    XCTAssertEqual(mapping["override-destination"] as? Bool, false)
    XCTAssertEqual(mapping["enable"] as? Bool, true)
    XCTAssertEqual(mapping["sniffing"] as? [String], ["tls"], "An unmodeled key survives untouched")
    let sniff = try XCTUnwrap(mapping["sniff"] as? [String: Any])
    XCTAssertNotNil(sniff["TLS"], "An untouched sniff map is not regenerated")
  }

  // MARK: - Plan

  func testProfileWithNoSnifferGetsTheAppManagedDefault() {
    let plan = SnifferPlanBuilder.plan(profileMapping: nil, patch: .empty)

    XCTAssertEqual(plan.source, .appManaged)
    XCTAssertTrue(plan.isSniffing)
    XCTAssertEqual(plan.settings.protocols.map(\.networkProtocol), [.tls, .http])
    XCTAssertEqual(plan.settings.overrideDestination, true)
    XCTAssertEqual(plan.patchedKeyNames, [])
  }

  func testProfileSnifferIsKeptVerbatimWhenNoSnippetTouchesIt() {
    let plan = SnifferPlanBuilder.plan(
      profileMapping: ["enable": true, "sniff": ["QUIC": ["ports": ["443"]]]],
      patch: .empty
    )

    XCTAssertEqual(plan.source, .profileKept)
    XCTAssertEqual(plan.settings.protocols.map(\.networkProtocol), [.quic])
    XCTAssertNil(plan.settings.overrideDestination, "The app default is not folded into a profile block")
  }

  func testProfileSnifferIsPatchedRatherThanReplaced() {
    let plan = SnifferPlanBuilder.plan(
      profileMapping: ["enable": true, "sniff": ["QUIC": ["ports": ["443"]]], "skip-domain": ["Mijia Cloud"]],
      patch: SnifferSettings(overrideDestination: false, skipDomain: ["+.internal.example"])
    )

    XCTAssertEqual(plan.source, .profilePatched)
    XCTAssertEqual(plan.settings.protocols.map(\.networkProtocol), [.quic], "The profile's own map survives")
    XCTAssertEqual(plan.settings.overrideDestination, false)
    XCTAssertEqual(plan.settings.skipDomain, ["Mijia Cloud", "+.internal.example"])
    XCTAssertEqual(plan.patchedKeyNames, ["override-destination", "skip-domain"])
  }

  func testTurningSniffingOffIsReportedAsOffRatherThanAsNoSniffer() {
    let plan = SnifferPlanBuilder.plan(profileMapping: nil, patch: SnifferSettings(enabled: false))

    XCTAssertEqual(plan.source, .appManagedPatched)
    XCTAssertFalse(plan.isSniffing)
    XCTAssertEqual(plan.summary, String(localized: "Sniffing off"))
  }

  func testObservedPlanReportsTheGeneratedBlockRatherThanTheAppsIntent() {
    // What matters is the block Mihomo will read, the same way the DNS layer reports the merged
    // result instead of the intent (issue #16).
    let plan = SnifferPlan.observed(
      finalSettings: SnifferSettings(enabled: true, protocols: [SnifferProtocolSettings(networkProtocol: .quic)]),
      profileDeclaresSniffer: true,
      patch: SnifferSettings(enabled: true)
    )

    XCTAssertEqual(plan.source, .profilePatched)
    XCTAssertEqual(plan.settings.protocols.map(\.networkProtocol), [.quic])
    XCTAssertEqual(plan.patchedKeyNames, ["enable"])
    XCTAssertTrue(plan.plainTextLines.contains { $0.contains("QUIC") })
  }

  func testDefaultSnifferSnippetCarriesTheManagedDefault() {
    guard case let .sniffer(settings) = RuntimeSnippet.defaultSnifferSnippet.payload else {
      return XCTFail("Expected a sniffer payload")
    }

    XCTAssertEqual(settings, .appManagedDefault)
    XCTAssertTrue(RuntimeSnippet.defaultSnifferSnippet.payload.hasRuntimeEffect)
    XCTAssertNil(RuntimeSnippet.defaultSnifferSnippet.validationError)
  }
}
