@testable import ClashMax
import Foundation
import XCTest

@MainActor
final class RuntimeSnippetLibraryStoreTests: XCTestCase {
  func testSaveMoveToggleAndReloadPersistSnippets() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = RuntimeSnippetLibraryStore(paths: paths)
    await store.waitForLoad()
    let first = Self.ruleSnippet(name: "First", domain: "first.example")
    let second = Self.ruleSnippet(name: "Second", domain: "second.example")

    try await store.saveSnippet(first)
    try await store.saveSnippet(second)
    try await store.moveSnippet(fromOffsets: IndexSet(integer: 1), toOffset: 0)
    try await store.setSnippetEnabled(id: first.id, enabled: false)

    XCTAssertEqual(store.snippets.map(\.id), [second.id, first.id])
    XCTAssertEqual(store.snippets.first(where: { $0.id == first.id })?.enabled, false)
    XCTAssertEqual(try Self.posixPermissions(at: paths.runtimeSnippetLibraryURL), SecureFileIO.privateFilePermissions)

    let reloaded = RuntimeSnippetLibraryStore(paths: paths)
    await reloaded.waitForLoad()

    XCTAssertEqual(reloaded.snippets.map(\.id), [second.id, first.id])
    XCTAssertEqual(reloaded.snippets.first(where: { $0.id == first.id })?.enabled, false)
  }

  func testProfileBindingFilteringAndDeletedProfileCleanup() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = RuntimeSnippetLibraryStore(paths: paths)
    await store.waitForLoad()
    let activeID = UUID()
    let otherID = UUID()
    let deletedID = UUID()
    let bound = RuntimeSnippet(
      name: "Bound",
      binding: .profiles([activeID, otherID]),
      payload: .dnsPatch(TunDNSSettings(respectRules: true))
    )
    let deletedOnly = RuntimeSnippet(
      name: "Deleted Only",
      binding: .profiles([deletedID]),
      payload: .dnsPatch(TunDNSSettings(useSystemHosts: false))
    )

    try await store.saveSnippet(bound)
    try await store.saveSnippet(deletedOnly)

    XCTAssertEqual(store.snippets(applyingTo: activeID).map(\.id), [bound.id])
    XCTAssertTrue(store.snippets(applyingTo: deletedID).map(\.id).contains(deletedOnly.id))

    let didClean = try await store.removeMissingProfileBindings(validProfileIDs: [activeID])

    XCTAssertTrue(didClean)
    let cleanedBound = try XCTUnwrap(store.snippets.first { $0.id == bound.id })
    let cleanedDeletedOnly = try XCTUnwrap(store.snippets.first { $0.id == deletedOnly.id })
    XCTAssertEqual(cleanedBound.binding, .profiles([activeID]))
    XCTAssertEqual(cleanedDeletedOnly.binding, .profiles([]))
    XCTAssertFalse(cleanedDeletedOnly.enabled)
    XCTAssertEqual(store.snippets(applyingTo: activeID).map(\.id), [bound.id])
  }

  func testDeletedOnlyBindingMustBeReboundBeforeEnabling() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = RuntimeSnippetLibraryStore(paths: paths)
    await store.waitForLoad()
    let activeID = UUID()
    let deletedOnly = RuntimeSnippet(
      name: "Deleted Only",
      binding: .profiles([UUID()]),
      payload: .dnsPatch(TunDNSSettings(useSystemHosts: false))
    )

    try await store.saveSnippet(deletedOnly)
    try await store.removeMissingProfileBindings(validProfileIDs: [activeID])
    let cleanedDeletedOnly = try XCTUnwrap(store.snippets.first { $0.id == deletedOnly.id })
    XCTAssertEqual(cleanedDeletedOnly.binding, .profiles([]))
    XCTAssertFalse(cleanedDeletedOnly.enabled)

    await XCTAssertThrowsErrorAsync {
      try await store.setSnippetEnabled(id: deletedOnly.id, enabled: true)
    } handler: { error in
      XCTAssertTrue(String(describing: error).contains("Select at least one profile"))
    }

    XCTAssertEqual(store.snippets.first { $0.id == deletedOnly.id }?.binding, .profiles([]))
    XCTAssertEqual(store.snippets.first { $0.id == deletedOnly.id }?.enabled, false)

    var rebound = cleanedDeletedOnly
    rebound.binding = .profiles([activeID])
    try await store.saveSnippet(rebound)
    try await store.setSnippetEnabled(id: deletedOnly.id, enabled: true)

    let enabledSnippet = try XCTUnwrap(store.snippets.first { $0.id == deletedOnly.id })
    XCTAssertEqual(enabledSnippet.binding, .profiles([activeID]))
    XCTAssertTrue(enabledSnippet.enabled)
  }

  func testValidationRejectsInvalidSnippetWithoutPersisting() async throws {
    let paths = try Self.makeRuntimePaths()
    let store = RuntimeSnippetLibraryStore(paths: paths)
    await store.waitForLoad()
    let valid = Self.ruleSnippet(name: "Valid", domain: "valid.example")
    let invalid = RuntimeSnippet(
      name: " ",
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: "invalid.example", policy: "DIRECT"),
          ]
        )
      )
    )

    try await store.saveSnippet(valid)
    do {
      try await store.saveSnippet(invalid)
      XCTFail("Expected invalid snippet to be rejected.")
    } catch {
      XCTAssertTrue(String(describing: error).contains("Snippet name cannot be empty"))
    }

    XCTAssertEqual(store.snippets.map(\.id), [valid.id])
    let reloaded = RuntimeSnippetLibraryStore(paths: paths)
    await reloaded.waitForLoad()
    XCTAssertEqual(reloaded.snippets.map(\.id), [valid.id])
  }

  func testDefaultRuleSnippetShipsWithNoRulesAndNoRuntimeEffect() throws {
    let snippet = RuntimeSnippet.defaultRuleSnippet

    XCTAssertTrue(snippet.enabled)
    let settings = try XCTUnwrap(Self.rulesSettings(of: snippet))
    XCTAssertTrue(settings.prependRules.isEmpty)
    XCTAssertTrue(settings.appendRules.isEmpty)
    XCTAssertTrue(settings.disabledRuleMatchers.isEmpty)
    // Enabled but empty: the snippet contributes nothing until the user adds a rule to it.
    XCTAssertFalse(settings.hasRuntimeOverlay)
    XCTAssertFalse(snippet.hasRuntimeEffect)
    XCTAssertEqual(RuntimeSnippetApplication(snippets: [snippet]), .empty)
  }

  func testDecodingFoldsLegacyPayloadDisableIntoSnippetEnabled() throws {
    let id = UUID()
    let json = Data(
      """
      {
        "id": "\(id.uuidString)",
        "name": "Legacy",
        "enabled": true,
        "binding": { "kind": "allProfiles" },
        "payload": {
          "kind": "rules",
          "rules": {
            "enabled": false,
            "prependRules": [
              { "id": "\(UUID().uuidString)", "kind": "DOMAIN-SUFFIX", "value": "legacy.example", "policy": "DIRECT" }
            ],
            "appendRules": [],
            "disabledRuleMatchers": []
          }
        }
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(RuntimeSnippet.self, from: json)

    // The overlay-level switch is gone from the editor, so a snippet stored with it off has to keep
    // being off via the one switch that is still reachable.
    XCTAssertEqual(decoded.id, id)
    XCTAssertFalse(decoded.enabled)
    let settings = try XCTUnwrap(Self.rulesSettings(of: decoded))
    XCTAssertTrue(settings.enabled)
    XCTAssertEqual(settings.prependRules.map(\.value), ["legacy.example"])
    XCTAssertFalse(decoded.hasRuntimeEffect)
    XCTAssertEqual(RuntimeSnippetApplication(snippets: [decoded]), .empty)
  }

  func testDecodingLeavesAlreadyEnabledPayloadUntouched() throws {
    let snippet = Self.ruleSnippet(name: "Modern", domain: "modern.example")
    let encoded = try JSONEncoder().encode(snippet)

    let decoded = try JSONDecoder().decode(RuntimeSnippet.self, from: encoded)

    XCTAssertEqual(decoded, snippet)
    XCTAssertTrue(decoded.enabled)
    XCTAssertEqual(
      RuntimeSnippetApplication(snippets: [decoded]).ruleOverlay.prependRules.map(\.value),
      ["modern.example"]
    )
  }

  private static func rulesSettings(of snippet: RuntimeSnippet) -> RuleOverlaySettings? {
    guard case let .rules(settings) = snippet.payload else { return nil }
    return settings
  }

  private static func ruleSnippet(name: String, domain: String) -> RuntimeSnippet {
    RuntimeSnippet(
      name: name,
      payload: .rules(
        RuleOverlaySettings(
          enabled: true,
          prependRules: [
            ManagedRuleOverlayRule(kind: .domainSuffix, value: domain, policy: "DIRECT"),
          ]
        )
      )
    )
  }

  private static func makeRuntimePaths() throws -> RuntimePaths {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxSnippetStoreTests-\(UUID().uuidString)", isDirectory: true)
    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    try paths.prepareDirectories()
    return paths
  }

  private static func posixPermissions(at url: URL) throws -> Int {
    let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
  }
}
