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

  func testLaunchDaemonAssociatesHelperWithMainAppForSMAppService() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let launchDaemonPlist = projectRoot
      .appendingPathComponent("Config/io.github.clashmax.ClashMax.Helper.plist")
    let plist = try String(contentsOf: launchDaemonPlist, encoding: .utf8)

    XCTAssertTrue(plist.contains("<key>BundleProgram</key>"))
    XCTAssertTrue(plist.contains("Contents/Library/LaunchServices/ClashMaxHelper"))
    XCTAssertTrue(plist.contains("<key>AssociatedBundleIdentifiers</key>"))
    XCTAssertTrue(plist.contains("<string>io.github.clashmax.ClashMax</string>"))
  }

  func testHelperInfoPlistUsesSMAppServiceDaemonIdentityWithoutLegacyBlessClientRules() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let helperInfoPlist = projectRoot.appendingPathComponent("Config/ClashMaxHelper-Info.plist")
    let plist = try String(contentsOf: helperInfoPlist, encoding: .utf8)

    XCTAssertTrue(plist.contains("<key>SMIsPrivilegedDaemon</key>"))
    XCTAssertFalse(plist.contains("SMAuthorizedClients"))
    XCTAssertFalse(plist.contains("SMPrivilegedExecutables"))
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
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi \(SystemProxySettings.defaultBypassDomains.joined(separator: " "))"))
  }

  func testApplySystemProxySkipsInactiveBridgeAndVPNServicesWhenActiveInterfacesAreKnown() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": """
      An asterisk (*) denotes that a network service is disabled.
      Ethernet
      Thunderbolt Bridge
      USB 10/100/1G/2.5G LAN
      Wi-Fi
      Tailscale
      """,
      "/usr/sbin/networksetup -listnetworkserviceorder": """
      An asterisk (*) denotes that a network service is disabled.
      (1) Ethernet
      (Hardware Port: Ethernet, Device: en0)

      (2) Thunderbolt Bridge
      (Hardware Port: Thunderbolt Bridge, Device: bridge0)

      (3) USB 10/100/1G/2.5G LAN
      (Hardware Port: USB 10/100/1G/2.5G LAN, Device: en8)

      (4) Wi-Fi
      (Hardware Port: Wi-Fi, Device: en1)

      (5) Tailscale
      (Hardware Port: io.tailscale.ipn.macsys, Device: )
      """,
      "/usr/sbin/scutil --nwi": """
      Network information

      IPv4 network interface information
           en0 : flags      : 0x5 (IPv4,DNS)
           en1 : flags      : 0x5 (IPv4,DNS)

      Network interfaces: en0 en1
      """
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890)

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Ethernet 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertFalse(runner.commands.contains { $0.contains("-setsecurewebproxy Thunderbolt Bridge") })
    XCTAssertFalse(runner.commands.contains { $0.contains("-setsecurewebproxy USB 10/100/1G/2.5G LAN") })
    XCTAssertFalse(runner.commands.contains { $0.contains("-setsecurewebproxy Tailscale") })
  }

  func testApplySystemProxyAcceptsCustomBypassDomains() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890, bypassDomains: ["localhost", "*.corp"])

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi localhost *.corp"))
  }

  func testProxyGuardRepairsServicesThatNoLongerMatchExpectedProxy() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: Yes\nServer: other.proxy\nPort: 8080\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "Exceptions List\nlocalhost\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.enableGuard(host: "127.0.0.1", port: 7890, bypassDomains: ["localhost"])
    let didRepair = try await controller.verifyGuardOnce()

    XCTAssertEqual(controller.guardState, .active)
    XCTAssertTrue(didRepair)
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 7890"))
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
