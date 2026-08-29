@testable import ClashMax
import XCTest

/// ROADMAP INV-2 promises any Mihomo key can be overridden by a user snippet. These cover the model
/// half of that promise: what a raw patch parses to, which keys it refuses, and which ClashMax
/// controls it quietly takes over.
final class RawYAMLPatchTests: XCTestCase {
  func testEmptyAndCommentOnlyYAMLAreNotAnOverlay() throws {
    XCTAssertFalse(RawYAMLPatchSettings.empty.hasRuntimeOverlay)
    XCTAssertEqual(try RawYAMLPatchSettings.empty.parsedMapping().count, 0)

    // A document of nothing but comments loads as nil, which is an empty patch and not an error.
    let commentOnly = RawYAMLPatchSettings(yaml: "# tcp-concurrent: true\n")
    XCTAssertTrue(commentOnly.hasRuntimeOverlay)
    XCTAssertEqual(try commentOnly.parsedMapping().count, 0)
    XCTAssertNil(commentOnly.validationError)
    XCTAssertEqual(commentOnly.summary, String(localized: "No YAML"))
  }

  func testParsesATopLevelMapping() throws {
    let settings = RawYAMLPatchSettings(yaml: """
    tcp-concurrent: true
    keep-alive-interval: 15
    ntp:
      enable: true
      server: time.apple.com
    """)
    let mapping = try settings.parsedMapping()

    XCTAssertEqual(mapping["tcp-concurrent"] as? Bool, true)
    XCTAssertEqual(mapping["keep-alive-interval"] as? Int, 15)
    XCTAssertEqual((mapping["ntp"] as? [String: Any])?["server"] as? String, "time.apple.com")
    XCTAssertEqual(settings.topLevelKeys, ["keep-alive-interval", "ntp", "tcp-concurrent"])
    XCTAssertNil(settings.validationError)
    XCTAssertTrue(settings.overriddenManagedKeyPaths.isEmpty)
  }

  func testRejectsMalformedYAMLAndNonMappingRoots() {
    let malformed = RawYAMLPatchSettings(yaml: "tcp-concurrent: [")
    XCTAssertNotNil(malformed.validationError)
    XCTAssertEqual(malformed.summary, String(localized: "Invalid YAML"))

    let list = RawYAMLPatchSettings(yaml: "- one\n- two\n")
    XCTAssertThrowsError(try list.parsedMapping()) { error in
      XCTAssertEqual(error as? RawYAMLPatchError, .rootIsNotMapping)
    }

    let scalar = RawYAMLPatchSettings(yaml: "just a string")
    XCTAssertThrowsError(try scalar.parsedMapping()) { error in
      XCTAssertEqual(error as? RawYAMLPatchError, .rootIsNotMapping)
    }
  }

  /// Not a ceiling: every reserved key already has an owning control in Settings. What they protect
  /// is the app's ability to apply, verify and roll back the very snippet that sets them.
  func testRefusesTheControlChannelAndTheInboundPort() {
    XCTAssertThrowsError(try RawYAMLPatchSettings(yaml: "mixed-port: 1080").parsedMapping()) { error in
      XCTAssertEqual(error as? RawYAMLPatchError, .reservedInboundPortKey)
    }
    XCTAssertThrowsError(try RawYAMLPatchSettings(yaml: "external-controller: 0.0.0.0:9090").parsedMapping()) { error in
      XCTAssertEqual(error as? RawYAMLPatchError, .reservedControlChannelKey("external-controller"))
    }
    XCTAssertThrowsError(try RawYAMLPatchSettings(yaml: "secret: hunter2").parsedMapping()) { error in
      XCTAssertEqual(error as? RawYAMLPatchError, .reservedControlChannelKey("secret"))
    }

    for key in RawYAMLPatchPolicy.reservedKeys {
      XCTAssertThrowsError(
        try RawYAMLPatchSettings(yaml: "\(key): value").parsedMapping(),
        "Expected \(key) to be reserved"
      )
      // Case and stray whitespace must not be a way around the check.
      XCTAssertThrowsError(
        try RawYAMLPatchSettings(yaml: "\(key.uppercased()) : value").parsedMapping(),
        "Expected \(key) to be reserved regardless of case"
      )
    }
  }

  func testEveryOtherAppManagedKeyIsAllowedButReported() throws {
    let settings = RawYAMLPatchSettings(yaml: """
    mode: global
    ipv6: true
    dns:
      enable: false
      nameserver: [1.1.1.1]
    tun:
      stack: gvisor
    """)

    XCTAssertNil(settings.validationError)
    XCTAssertEqual(try settings.parsedMapping()["mode"] as? String, "global")
    // `dns.nameserver` is the profile's key, not ClashMax's, so it is not reported here.
    XCTAssertEqual(settings.overriddenManagedKeyPaths, ["dns.enable", "ipv6", "mode", "tun.stack"])
  }

  func testReplacingAWholeManagedBlockReportsTheBlock() {
    let settings = RawYAMLPatchSettings(yaml: "tun: null\n")
    XCTAssertEqual(settings.overriddenManagedKeyPaths, ["tun"])
  }

  func testSummaryNamesTheKeysAndTruncatesLongPatches() {
    let short = RawYAMLPatchSettings(yaml: "ntp: {}\ntcp-concurrent: true\n")
    XCTAssertEqual(short.summary, "ntp, tcp-concurrent")

    let long = RawYAMLPatchSettings(yaml: "a: 1\nb: 2\nc: 3\nd: 4\ne: 5\n")
    XCTAssertEqual(long.summary, "a, b, c, d…")
  }

  func testListStrategyDecodingToleratesAnUnknownValue() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(
      RawYAMLPatchSettings.self,
      from: Data(#"{"yaml":"ntp: {}"}"#.utf8)
    )
    XCTAssertEqual(legacy.listStrategy, .replace, "A payload written before the field existed still loads")

    // A strategy from a newer build must not take the whole snippet library down with it.
    let future = try decoder.decode(
      RawYAMLPatchSettings.self,
      from: Data(#"{"yaml":"ntp: {}","listStrategy":"interleave"}"#.utf8)
    )
    XCTAssertEqual(future.listStrategy, .replace)
    XCTAssertEqual(future.yaml, "ntp: {}")
  }

  func testRawYAMLSnippetRoundTripsThroughTheLibraryEncoding() throws {
    let snippet = RuntimeSnippet(
      name: "Advanced",
      payload: .rawYAML(RawYAMLPatchSettings(yaml: "tcp-concurrent: true", listStrategy: .append))
    )
    let data = try JSONEncoder().encode([snippet])
    let decoded = try JSONDecoder().decode([RuntimeSnippet].self, from: data)

    XCTAssertEqual(decoded, [snippet])
    XCTAssertEqual(decoded.first?.payload.kind, .rawYAML)
    XCTAssertTrue(decoded.first?.payload.hasRuntimeEffect ?? false)
  }

  func testAnEmptyRawSnippetHasNoRuntimeEffectAndIsNotCollected() {
    let empty = RuntimeSnippet(name: "Blank", payload: .rawYAML(.empty))
    XCTAssertFalse(empty.payload.hasRuntimeEffect)
    XCTAssertTrue(RuntimeSnippetApplication(snippets: [empty]).rawYAMLPatches.isEmpty)
  }

  func testOnlyEnabledApplicableSnippetsAreCollectedInOrder() {
    let first = RuntimeSnippet(name: "First", payload: .rawYAML(RawYAMLPatchSettings(yaml: "ntp: {}")))
    let disabled = RuntimeSnippet(
      name: "Disabled",
      enabled: false,
      payload: .rawYAML(RawYAMLPatchSettings(yaml: "tcp-concurrent: true"))
    )
    let second = RuntimeSnippet(
      name: "Second",
      payload: .rawYAML(RawYAMLPatchSettings(yaml: "keep-alive-interval: 15"))
    )

    let application = RuntimeSnippetApplication(snippets: [first, disabled, second])
    // Order is the contract: the later patch is merged last, so it is the one that wins a shared key.
    XCTAssertEqual(application.rawYAMLPatches.map(\.normalizedYAML), ["ntp: {}", "keep-alive-interval: 15"])
  }

  func testDefaultRawYAMLSnippetShipsEmpty() {
    let snippet = RuntimeSnippet.defaultRawYAMLSnippet
    XCTAssertEqual(snippet.payload.kind, .rawYAML)
    // An escape hatch that arrived with content would change the runtime before the user wrote
    // anything; the editor's placeholder carries the example instead.
    XCTAssertFalse(snippet.payload.hasRuntimeEffect)
    XCTAssertNil(snippet.validationError)
  }

  func testRawYAMLIsAHotReloadChange() {
    XCTAssertEqual(RuntimeChangeKind(RuntimeSnippetPayloadKind.rawYAML), .rawYAML)
    for owner in [RuntimeOwner.user, .tunnel, .networkExtension] {
      XCTAssertEqual(
        RuntimeChangeApplyMode.resolve(.rawYAML, in: RuntimeApplyContext(runtimeOwner: owner)),
        .hotReload,
        "A raw patch cannot move mixed-port or external-controller, so no owner needs a restart"
      )
    }
    XCTAssertEqual(RuntimeChangeApplyMode.resolve(.rawYAML, in: .stopped), .appliesOnNextStart)
  }
}
