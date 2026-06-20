import Foundation
import XCTest
@testable import ClashMax

final class BundledCoreInfoTests: XCTestCase {
  func testReadsBundledCoreVersionFromManifest() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxBundledCoreInfoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifestURL = directory.appendingPathComponent("mihomo-manifest.json")
    try #"{"version":"v9.9.9"}"#.write(to: manifestURL, atomically: true, encoding: .utf8)

    let info = BundledCoreInfo(manifestURL: manifestURL)

    XCTAssertEqual(info.versionSummary, "Mihomo v9.9.9")
    XCTAssertEqual(
      info.statusMessage,
      String(localized: "Bundled with ClashMax. Updating ClashMax updates the bundled Mihomo core.")
    )
  }

  func testMissingManifestShowsBundledCoreUnavailableWithoutCheckUpdateLanguage() {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-mihomo-manifest-\(UUID().uuidString).json")

    let info = BundledCoreInfo(manifestURL: manifestURL)

    XCTAssertEqual(info.versionSummary, String(localized: "Mihomo unavailable"))
    XCTAssertEqual(info.statusMessage, String(localized: "Bundled Mihomo core information is unavailable."))
    XCTAssertFalse(info.statusMessage.localizedCaseInsensitiveContains("check"))
  }

  func testDerivesSubscriptionCompatibilityUserAgentFromManifestVersion() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxBundledCoreInfoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manifestURL = directory.appendingPathComponent("mihomo-manifest.json")
    try #"{"version":"v1.19.27"}"#.write(to: manifestURL, atomically: true, encoding: .utf8)

    let info = BundledCoreInfo(manifestURL: manifestURL)

    XCTAssertEqual(info.subscriptionCompatibilityUserAgent, "mihomo/1.19.27")
  }

  func testMissingManifestHasNoSubscriptionCompatibilityUserAgent() {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-mihomo-manifest-\(UUID().uuidString).json")

    let info = BundledCoreInfo(manifestURL: manifestURL)

    XCTAssertNil(info.subscriptionCompatibilityUserAgent)
  }
}
