import XCTest
@testable import ClashMax

final class ClashXMigrationParserTests: XCTestCase {
  func testParserExtractsProviderURLsDuplicatesPortsBypassSystemProxyAndUnsupportedKeys() throws {
    let root = try makeTemporaryDirectory()
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try """
    mixed-port: 7890
    socks-port: "7891"
    allow-lan: true
    mode: global
    log-level: debug
    system-proxy: true
    cfw-bypass:
      - localhost
      - "*.local"
    shortcut:
      toggleProxy: cmd+shift+p
      restartCore: cmd+shift+r
      unknownAction: cmd+shift+u
    hotkeys:
      systemProxy: ctrl+option+s
    tray: true
    unknown-clashx-key: value
    proxy-providers:
      Main:
        type: http
        url: https://example.com/sub.yaml
        path: providers/main.yaml
      Backup:
        type: http
        url: https://example.com/sub.yaml
        path: providers/backup.yaml
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    try """
    proxy-providers:
      Main:
        type: http
        url: https://mirror.example.com/sub.yaml
    subscriptions:
      - name: Airport
        url: https://airport.example.com/api
    """.write(to: providers.appendingPathComponent("main.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(
      report.subscriptionURLs,
      [
        "https://example.com/sub.yaml",
        "https://mirror.example.com/sub.yaml",
        "https://airport.example.com/api"
      ]
    )
    XCTAssertEqual(report.duplicateSubscriptionURLs, ["https://example.com/sub.yaml"])
    XCTAssertEqual(report.ports["mixed-port"], 7890)
    XCTAssertEqual(report.ports["socks-port"], 7891)
    XCTAssertEqual(report.bypassDomains, ["localhost", "*.local"])
    XCTAssertEqual(report.allowLan, true)
    XCTAssertEqual(report.mode, "global")
    XCTAssertEqual(report.logLevel, "debug")
    XCTAssertEqual(report.systemProxyEnabled, true)
    XCTAssertFalse(report.unsupportedSettings.contains { $0.contains("shortcut") })
    XCTAssertEqual(
      report.shortcutBindings.map { "\($0.sourceKey):\($0.action.rawValue):\($0.shortcut.storageString)" },
      [
        "restartCore:restart:shift+command+r",
        "toggleProxy:startStop:shift+command+p",
        "systemProxy:toggleSystemProxy:control+option+s"
      ]
    )
    XCTAssertTrue(report.warnings.contains { $0.contains("unknownAction") })
    XCTAssertTrue(report.menuBarMigrationSuggested)
    XCTAssertTrue(report.unknownKeys.contains { $0.contains("unknown-clashx-key") })
    XCTAssertTrue(report.conflicts.contains { $0.contains("Provider Main uses multiple URLs") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("config.yaml") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("providers/main.yaml") })
  }

  func testParserDeduplicatesShortcutAliasesByCanonicalStorage() throws {
    let root = try makeTemporaryDirectory()
    try """
    shortcut:
      toggleProxy: cmd+shift+enter
    hotkeys:
      toggleProxyAgain: cmd+shift+return
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(report.shortcutBindings.count, 1)
    XCTAssertEqual(report.shortcutBindings.first?.action, .startStop)
    XCTAssertEqual(report.shortcutBindings.first?.shortcut.storageString, "shift+command+return")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxClashXMigrationParserTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}
