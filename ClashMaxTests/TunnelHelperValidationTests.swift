import XCTest
@testable import ClashMax

final class TunnelHelperValidationTests: XCTestCase {
  func testBundledCoreRootUsesExecutableURLWhenLaunchDaemonProgramIsRelative() {
    let root = HelperBundleLocator.bundledCoreRoot(
      executableURL: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Library/LaunchServices/ClashMaxHelper"),
      commandPath: "Contents/Library/LaunchServices/ClashMaxHelper",
      currentDirectoryURL: URL(fileURLWithPath: "/Users/test/Developer/ClashMax", isDirectory: true)
    )

    XCTAssertEqual(root.path, "/Applications/ClashMax.app/Contents/Resources/Core")
  }

  func testHelperRejectsPathsOutsideAllowedRoots() {
    let validator = HelperPathValidator(
      appSupportRoot: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax"),
      bundledCoreRoot: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core")
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/runtime/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/runtime")
      )
    )
  }

  func testHelperAcceptsBundledCoreAndAppManagedConfig() throws {
    let validator = HelperPathValidator(
      appSupportRoot: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax"),
      bundledCoreRoot: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core")
    )

    XCTAssertNoThrow(
      try validator.validate(
        coreURL: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64"),
        configURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/runtime/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/runtime")
      )
    )
  }
}
