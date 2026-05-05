import XCTest
@testable import ClashMax

final class SystemProxyControllerTests: XCTestCase {
  func testRunScriptAllowsCodesigningForHelperRegistration() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let scriptURL = projectRoot.appendingPathComponent("script/build_and_run.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertFalse(script.contains("CODE_SIGNING_ALLOWED=NO"))
    XCTAssertTrue(script.contains("CLASHMAX_DERIVED_DATA"))
    XCTAssertTrue(script.contains("Library/Developer/Xcode/DerivedData/ClashMaxLocal"))
    XCTAssertTrue(script.contains("security find-identity -v -p codesigning"))
    XCTAssertTrue(script.contains("CLASHMAX_CODESIGN_IDENTITY"))
    XCTAssertTrue(script.contains("Config/ClashMaxHelper.entitlements"))
    XCTAssertTrue(script.contains("Config/ClashMax.entitlements"))
    XCTAssertTrue(script.contains("TUN helper registration will not work with ad-hoc signing"))
  }

  func testAppBundleExtendedAttributesAreClearedBeforeSigning() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let projectFile = projectRoot.appendingPathComponent("ClashMax.xcodeproj/project.pbxproj")
    let project = try String(contentsOf: projectFile, encoding: .utf8)

    XCTAssertTrue(project.contains("Clean Bundle Extended Attributes"))
    XCTAssertTrue(project.contains("xattr -cr \\\"$TARGET_BUILD_DIR/$WRAPPER_NAME\\\""))
    XCTAssertTrue(project.contains("ENABLE_USER_SCRIPT_SANDBOXING = NO;"))
  }

  func testHelperEmbedsInfoPlistForPrivilegedServiceIdentity() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let projectFile = projectRoot.appendingPathComponent("ClashMax.xcodeproj/project.pbxproj")
    let project = try String(contentsOf: projectFile, encoding: .utf8)

    XCTAssertTrue(project.contains("CREATE_INFOPLIST_SECTION_IN_BINARY = YES;"))
  }

  func testProjectDoesNotReferenceUnusedRiveRuntimeArtifact() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let projectFile = projectRoot.appendingPathComponent("ClashMax.xcodeproj/project.pbxproj")
    let projectSpecFile = projectRoot.appendingPathComponent("project.yml")
    let project = try String(contentsOf: projectFile, encoding: .utf8)
    let projectSpec = try String(contentsOf: projectSpecFile, encoding: .utf8)

    XCTAssertFalse(project.contains("rive-ios"))
    XCTAssertFalse(project.contains("RiveRuntime"))
    XCTAssertFalse(projectSpec.contains("rive-ios"))
    XCTAssertFalse(projectSpec.contains("RiveRuntime"))
  }

  func testArchiveSignsNestedCoreBinariesWithHardenedRuntime() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let projectFile = projectRoot.appendingPathComponent("ClashMax.xcodeproj/project.pbxproj")
    let projectSpecFile = projectRoot.appendingPathComponent("project.yml")
    let project = try String(contentsOf: projectFile, encoding: .utf8)
    let projectSpec = try String(contentsOf: projectSpecFile, encoding: .utf8)

    for content in [project, projectSpec] {
      XCTAssertTrue(content.contains("Sign Nested Core Binaries"))
      XCTAssertTrue(content.contains("mihomo-darwin-*"))
      XCTAssertTrue(content.contains("EXPANDED_CODE_SIGN_IDENTITY"))
      XCTAssertTrue(content.contains("--options runtime"))
      XCTAssertTrue(content.contains("--timestamp"))
      XCTAssertTrue(content.contains("codesign --verify --strict"))
    }
  }

  func testProcessCommandRunnerTimesOutHangingCommands() async throws {
    let runner = ProcessCommandRunner(timeout: 0.1)
    let startedAt = Date()

    do {
      _ = try await runner.run("/bin/sleep", ["2"])
      XCTFail("Expected timeout error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
  }

  func testApplySystemProxyTargetsAllActiveServices() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nThunderbolt Bridge\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890)

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi localhost 127.0.0.1 ::1 *.local 169.254/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"))
  }

  func testRestoreTurnsProxyStatesOff() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.restore()

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxystate Wi-Fi off"))
  }

  func testRestoreReturnsServicesToOriginalProxySettings() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": """
      Enabled: Yes
      Server: corp.proxy
      Port: 8080
      Authenticated Proxy Enabled: 0
      """,
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": """
      Enabled: No
      Server:
      Port: 0
      Authenticated Proxy Enabled: 0
      """,
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": """
      Enabled: No
      Server:
      Port: 0
      Authenticated Proxy Enabled: 0
      """,
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": """
      Exceptions List
      corp.internal
      *.corp
      """
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890)
    try await controller.restore()

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi corp.proxy 8080"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi on"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi corp.internal *.corp"))
  }

  func testRestoreClearsBypassDomainsWhenNoSnapshotExists() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.restore()

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi Empty"))
  }
}
