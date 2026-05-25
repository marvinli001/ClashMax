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
    XCTAssertTrue(report.unsupportedSettings.contains { $0.contains("shortcut") })
    XCTAssertTrue(report.unknownKeys.contains { $0.contains("unknown-clashx-key") })
    XCTAssertTrue(report.conflicts.contains { $0.contains("Provider Main uses multiple URLs") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("config.yaml") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("providers/main.yaml") })
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
