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

  /// cp -R only adds files, so merging into the previous build's Core directory
  /// kept shipping whatever was already there: the Intel-only per-architecture core
  /// after an incremental build, and the placeholder core that
  /// `DashboardRuntimeStateTests` writes into the test host on a checkout without
  /// `Resources/Core/mihomo` — which then failed the next build's arm64 check.
  func testEmbedStepMirrorsTheSourceCoreDirectoryInsteadOfMergingIntoIt() throws {
    let projectYAML = try contents(of: "project.yml")

    XCTAssertTrue(projectYAML.contains(#"rm -rf "$core_resources""#))
    XCTAssertTrue(projectYAML.contains(#"cp -R "$SRCROOT/Resources/Core/." "$core_resources/""#))
  }

  func testBuildFailsWhenTheEmbeddedCoreHasNoARM64Slice() throws {
    let projectYAML = try contents(of: "project.yml")

    XCTAssertTrue(projectYAML.contains(#"core_archs="$(/usr/bin/lipo -archs "$core_binary" 2>/dev/null)""#))
    XCTAssertTrue(projectYAML.contains("embedded Mihomo core is missing the arm64 slice"))
    // lipo's own diagnostic for a non-Mach-O file reads as a toolchain fault.
    XCTAssertTrue(projectYAML.contains("embedded Mihomo core is not a Mach-O binary"))
  }

  func testInstallScriptMergesTheUpstreamAssetsIntoOneUniversalBinary() throws {
    let script = try contents(of: "script/install_mihomo_core.sh")

    XCTAssertTrue(script.contains(#"/usr/bin/lipo -create "${slices[@]}" -output "$TARGET""#))
    XCTAssertTrue(script.contains(#"rm -f "$CORE_DIR/mihomo-darwin-arm64" "$CORE_DIR/mihomo-darwin-amd64""#))
    XCTAssertTrue(script.contains("merged core is missing the arm64 slice"))
  }

  /// Skips on a working copy that has not fetched the core; fails on CI, which always fetches it.
  func testCheckedOutCoreIsUniversalAndRunsNativelyOnAppleSilicon() throws {
    guard let coreURL = try BundledCoreRequirement.coreURL() else { return }

    let architectures = try lipoArchitectures(of: coreURL)
    XCTAssertTrue(architectures.contains("arm64"), "core architectures were \(architectures)")
    XCTAssertTrue(architectures.contains("x86_64"), "core architectures were \(architectures)")
  }

  /// ROADMAP D2: the bundled-core matrix is only a regression gate if CI runs it. The core is
  /// gitignored, so CI has to install it before the tests and has to turn a missing core into a
  /// failure — otherwise every bundled-core test reports as skipped and a broken bump ships green.
  func testCIInstallsTheCoreBeforeTestsAndRequiresIt() throws {
    let workflow = try contents(of: ".github/workflows/ci.yml")
    let testJob = try XCTUnwrap(workflow.components(separatedBy: "\n  build:\n").first)

    let install = try XCTUnwrap(testJob.range(of: "script/install_mihomo_core.sh"))
    let runTests = try XCTUnwrap(testJob.range(of: "xcodebuild test"))
    XCTAssertLessThan(install.lowerBound, runTests.lowerBound)
    XCTAssertTrue(testJob.contains("TEST_RUNNER_\(BundledCoreRequirement.environmentKey): \"1\""))
  }

  func testInstallScriptRefusesAnAssetThatDoesNotMatchTheManifest() throws {
    let script = try contents(of: "script/install_mihomo_core.sh")

    XCTAssertTrue(script.contains(#"if [[ "$actual" != "$checksum" ]]; then"#))
    XCTAssertTrue(script.contains("checksum mismatch for"))
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
