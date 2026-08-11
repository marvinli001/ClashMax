import Foundation
import XCTest

/// macOS 26.4 and later tell users that an app "includes a component that isn't
/// compatible with future versions of macOS" whenever its bundle holds a Mach-O
/// without an arm64 slice — even one that never runs. ClashMax used to embed a
/// separate Intel-only Mihomo core, which is exactly what triggered it. These
/// tests guard the packaging rules that keep it out.
final class BundledCoreArchitectureTests: XCTestCase {
  func testProjectEmbedsOnlyTheUniversalCore() throws {
    let projectYAML = try contents(of: "project.yml")

    XCTAssertTrue(projectYAML.contains("$(SRCROOT)/Resources/Core/mihomo\""))
    XCTAssertFalse(projectYAML.contains("$(SRCROOT)/Resources/Core/mihomo-darwin-amd64"))
    XCTAssertFalse(projectYAML.contains("$(SRCROOT)/Resources/Core/mihomo-darwin-arm64"))
    XCTAssertFalse(
      projectYAML.contains("$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Core/mihomo-darwin-amd64")
    )
  }

  func testEmbedStepPurgesPerArchitectureCoresFromStaleBuildDirectories() throws {
    let projectYAML = try contents(of: "project.yml")

    // cp -R only adds files, so without this an incremental build over an older
    // build directory keeps shipping the Intel-only core.
    XCTAssertTrue(projectYAML.contains(#"rm -f "$core_resources"/mihomo-darwin-*"#))
  }

  func testBuildFailsWhenTheEmbeddedCoreHasNoARM64Slice() throws {
    let projectYAML = try contents(of: "project.yml")

    XCTAssertTrue(projectYAML.contains(#"core_archs="$(/usr/bin/lipo -archs "$core_binary")""#))
    XCTAssertTrue(projectYAML.contains("embedded Mihomo core is missing the arm64 slice"))
  }

  func testInstallScriptMergesTheUpstreamAssetsIntoOneUniversalBinary() throws {
    let script = try contents(of: "script/install_mihomo_core.sh")

    XCTAssertTrue(script.contains(#"/usr/bin/lipo -create "${slices[@]}" -output "$TARGET""#))
    XCTAssertTrue(script.contains(#"rm -f "$CORE_DIR/mihomo-darwin-arm64" "$CORE_DIR/mihomo-darwin-amd64""#))
    XCTAssertTrue(script.contains("merged core is missing the arm64 slice"))
  }

  /// Only runs on a working copy that has actually fetched the core.
  func testCheckedOutCoreIsUniversalAndRunsNativelyOnAppleSilicon() throws {
    let coreURL = try repositoryRoot()
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("Core", isDirectory: true)
      .appendingPathComponent("mihomo")
    try XCTSkipUnless(
      FileManager.default.isExecutableFile(atPath: coreURL.path),
      "Resources/Core/mihomo is absent; run script/install_mihomo_core.sh"
    )

    let architectures = try lipoArchitectures(of: coreURL)
    XCTAssertTrue(architectures.contains("arm64"), "core architectures were \(architectures)")
  }

  func testNoIntelOnlyCoreIsLeftInTheWorkingCopy() throws {
    let coreRoot = try repositoryRoot()
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("Core", isDirectory: true)

    for name in ["mihomo-darwin-amd64", "mihomo-darwin-arm64"] {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: coreRoot.appendingPathComponent(name).path),
        "\(name) is superseded by the universal mihomo binary and would be re-embedded by the build"
      )
    }
  }

  private func repositoryRoot() throws -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func contents(of relativePath: String) throws -> String {
    try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
  }

  private func lipoArchitectures(of url: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
    process.arguments = ["-archs", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ")
      .map(String.init)
  }
}
