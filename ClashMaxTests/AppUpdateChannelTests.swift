@testable import ClashMax
import Foundation
import XCTest

/// Sparkle filters appcast items by minimum system version only. An
/// Apple-silicon-only build therefore has to be published under a channel that
/// Intel clients never ask for, or those clients will download an app they
/// cannot launch.
@MainActor
final class AppUpdateChannelTests: XCTestCase {
  func testAppleSiliconClientsAllowTheAppleSiliconChannel() throws {
    #if !arch(arm64)
      throw XCTSkip("Only meaningful when the running slice is arm64.")
    #else
      XCTAssertEqual(
        AppUpdateController.allowedUpdateChannels,
        [AppUpdateController.appleSiliconUpdateChannel]
      )
    #endif
  }

  func testIntelClientsSeeOnlyTheDefaultChannel() throws {
    #if arch(arm64)
      throw XCTSkip("Only meaningful when the running slice is x86_64.")
    #else
      // Sparkle treats the empty set as "default channel only".
      XCTAssertTrue(AppUpdateController.allowedUpdateChannels.isEmpty)
    #endif
  }

  func testChannelNameUsesCharactersSparkleAccepts() {
    let allowed = CharacterSet.alphanumerics
      .union(CharacterSet(charactersIn: "-_."))
    XCTAssertTrue(
      AppUpdateController.appleSiliconUpdateChannel.unicodeScalars.allSatisfy(allowed.contains),
      "Sparkle channel names allow only letters, numbers, dashes, underscores and periods"
    )
  }

  /// Universal builds must stay in the default channel so clients that predate
  /// the channel delegate keep receiving them.
  func testShippedAppcastPublishesEveryCurrentItemInTheDefaultChannel() throws {
    let appcast = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("docs/appcast.xml")
    let xml = try String(contentsOf: appcast, encoding: .utf8)

    XCTAssertFalse(
      xml.contains("<sparkle:channel>"),
      "docs/appcast.xml still advertises only universal builds; none of them may be channel-gated"
    )
  }
}
