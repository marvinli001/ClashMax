import XCTest
@testable import ClashMax

final class SystemProxyControllerTests: XCTestCase {
  func testRunScriptUsesXcodeManagedSigningAndVerifyOnlyChecks() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let scriptURL = projectRoot.appendingPathComponent("script/build_and_run.sh")
    let script = try String(contentsOf: scriptURL, encoding: .utf8)

    XCTAssertFalse(script.contains("CODE_SIGNING_ALLOWED=NO"))
    XCTAssertTrue(script.contains("CLASHMAX_DERIVED_DATA"))
    XCTAssertTrue(script.contains("Library/Developer/Xcode/DerivedData/ClashMaxLocal"))
    XCTAssertTrue(script.contains("verify_signatures"))
    XCTAssertTrue(script.contains(#"codesign --verify --strict --verbose=2 "$APP_BUNDLE""#))
    XCTAssertTrue(script.contains(#"codesign --verify --strict --verbose=2 "$SYSTEM_EXTENSION""#))
    XCTAssertFalse(script.contains("security find-identity -v -p codesigning"))
    XCTAssertFalse(script.contains("CLASHMAX_CODESIGN_IDENTITY"))
    XCTAssertFalse(script.contains("Developer ID Application"))
    XCTAssertFalse(script.contains("Apple Development"))
    XCTAssertFalse(script.contains("Config/ClashMaxHelper.entitlements"))
    XCTAssertFalse(script.contains("Config/ClashMax.entitlements"))
    XCTAssertFalse(script.contains("codesign --force"))
  }

  func testTunSmokeRunbookAndScriptCoverReadOnlyInstalledBundleGate() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let runbook = try String(
      contentsOf: projectRoot.appendingPathComponent("docs/TUN_SMOKE_TEST.md"),
      encoding: .utf8
    )
    let script = try String(
      contentsOf: projectRoot.appendingPathComponent("script/tun_smoke_check.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(runbook.contains("/Applications/ClashMax.app"))
    XCTAssertTrue(runbook.contains("sleep"))
    XCTAssertTrue(runbook.contains("network"))
    XCTAssertTrue(runbook.contains("UDP"))
    XCTAssertTrue(runbook.contains("DNS leak"))
    XCTAssertTrue(runbook.contains("real installed-bundle TUN smoke remains manual"))
    XCTAssertTrue(script.contains("launchctl print"))
    XCTAssertTrue(script.contains("scutil --dns"))
    XCTAssertTrue(script.contains("netstat -rn"))
    XCTAssertTrue(script.contains("This script is read-only"))
    XCTAssertFalse(script.contains("sudo "))
    XCTAssertFalse(script.contains("launchctl bootstrap"))
    XCTAssertFalse(script.contains("launchctl bootout"))
    XCTAssertFalse(script.contains("networksetup -set"))
  }

  func testReleaseSmokeScriptCoversTwoLayerGateWithoutMutatingSigningState() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(
      contentsOf: projectRoot.appendingPathComponent("script/release_smoke_check.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(script.contains("set -euo pipefail"))
    XCTAssertTrue(script.contains(#"DEFAULT_REPORT_DIR="dist/release-smoke""#))
    XCTAssertTrue(script.contains("DEFAULT_SOAK_MINUTES=60"))
    XCTAssertTrue(script.contains("--preflight-only"))
    XCTAssertTrue(script.contains("--live"))
    XCTAssertTrue(script.contains("--soak-minutes"))
    XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2"))
    XCTAssertTrue(script.contains("spctl --assess --type execute --verbose"))
    XCTAssertTrue(script.contains("hdiutil verify"))
    XCTAssertTrue(script.contains("sparkle:shortVersionString"))
    XCTAssertTrue(script.contains("REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"))
    XCTAssertTrue(script.contains("security find-generic-password"))
    XCTAssertTrue(script.contains("io.github.clashmax.ClashMax"))
    XCTAssertTrue(script.contains("subscription."))
    XCTAssertTrue(script.contains("profiles.json"))
    XCTAssertTrue(script.contains("sanitize_url"))
    XCTAssertTrue(script.contains("<redacted>"))
    XCTAssertFalse(script.contains("xcodegen generate"))
    XCTAssertFalse(script.contains("codesign --force"))
    XCTAssertFalse(script.contains("sudo "))
    XCTAssertFalse(script.contains("Config/ClashMax.entitlements"))
    XCTAssertFalse(script.contains("Config/ClashMaxNetworkExtension.entitlements"))
  }

  func testReleaseSmokeDocumentationUsesScriptedGateAsReleaseEntryPoint() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let appUpdates = try String(
      contentsOf: projectRoot.appendingPathComponent("docs/APP_UPDATES.md"),
      encoding: .utf8
    )
    let development = try String(
      contentsOf: projectRoot.appendingPathComponent("docs/DEVELOPMENT.md"),
      encoding: .utf8
    )
    let tunRunbook = try String(
      contentsOf: projectRoot.appendingPathComponent("docs/TUN_SMOKE_TEST.md"),
      encoding: .utf8
    )

    XCTAssertTrue(appUpdates.contains("script/release_smoke_check.sh"))
    XCTAssertTrue(appUpdates.contains("--preflight-only"))
    XCTAssertTrue(appUpdates.contains("--live --soak-minutes 60"))
    XCTAssertTrue(appUpdates.contains("dist/release-smoke"))
    XCTAssertTrue(development.contains("script/release_smoke_check.sh"))
    XCTAssertTrue(tunRunbook.contains("script/release_smoke_check.sh"))
    XCTAssertFalse(appUpdates.contains("发布前检查导出的 app 和生成的更新源："))
  }

  func testReleaseSmokeFailurePathWritesMachineReadableSummary() throws {
    let projectRoot = Self.projectRoot()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxReleaseSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let homeDirectory = directory.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    let reportDirectory = directory.appendingPathComponent("reports", isDirectory: true)
    let missingApp = directory.appendingPathComponent("Missing.app")
    let missingAppcast = directory.appendingPathComponent("missing-appcast.xml")
    let missingDmg = directory.appendingPathComponent("missing.dmg")

    let result = try Self.runProcess(
      executable: projectRoot.appendingPathComponent("script/release_smoke_check.sh").path,
      arguments: [
        "--app", missingApp.path,
        "--appcast", missingAppcast.path,
        "--sparkle-dir", directory.appendingPathComponent("sparkle").path,
        "--dmg", missingDmg.path,
        "--report-dir", reportDirectory.path,
        "--preflight-only",
        "--allow-empty-subscriptions",
      ],
      currentDirectory: projectRoot,
      environment: ["HOME": homeDirectory.path]
    )

    XCTAssertNotEqual(result.exitCode, 0)

    let summaryURL = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(at: reportDirectory, includingPropertiesForKeys: nil)
        .first { $0.lastPathComponent.hasSuffix(".summary.json") }
    )
    let summary = try Self.jsonObject(at: summaryURL)
    XCTAssertEqual(summary["app"] as? String, missingApp.path)
    XCTAssertGreaterThan(summary["failures"] as? Int ?? 0, 0)

    let eventsPath = try XCTUnwrap(summary["events"] as? String)
    let events = try Self.jsonLines(at: URL(fileURLWithPath: eventsPath))
    let appBundleEvent = try XCTUnwrap(
      events.first { $0["event"] as? String == "app.bundle" }
    )
    let appBundleDetails = try XCTUnwrap(appBundleEvent["details"] as? [String: Any])
    XCTAssertEqual(appBundleDetails["path"] as? String, missingApp.path)
    XCTAssertNil(appBundleDetails["raw"])

    let codesignEvent = try XCTUnwrap(
      events.first { $0["event"] as? String == "codesign.app" }
    )
    let codesignDetails = try XCTUnwrap(codesignEvent["details"] as? [String: Any])
    XCTAssertNotEqual(codesignDetails["exit_code"] as? Int, 0)
  }

  func testTunSmokeJsonSummaryKeepsFailingCommandExitCode() throws {
    let projectRoot = Self.projectRoot()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxTunSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fakeApp = directory.appendingPathComponent("Unsigned.app", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
    let summaryURL = directory.appendingPathComponent("tun-summary.json")

    let result = try Self.runProcess(
      executable: projectRoot.appendingPathComponent("script/tun_smoke_check.sh").path,
      arguments: ["--json", summaryURL.path, fakeApp.path],
      currentDirectory: projectRoot
    )

    XCTAssertEqual(result.exitCode, 0)
    let summary = try Self.jsonObject(at: summaryURL)
    let checks = try XCTUnwrap(summary["checks"] as? [[String: Any]])
    let codesignCheck = try XCTUnwrap(
      checks.first { $0["name"] as? String == "codesign.app" }
    )
    let message = try XCTUnwrap(codesignCheck["message"] as? String)
    XCTAssertTrue(message.contains("exited "))
    XCTAssertFalse(message.contains("exited 0"))
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
    XCTAssertFalse(plist.contains("Contents/MacOS/ClashMaxHelper"))
    XCTAssertTrue(plist.contains("<key>AssociatedBundleIdentifiers</key>"))
    XCTAssertTrue(plist.contains("<string>io.github.clashmax.ClashMax</string>"))

    let data = try Data(contentsOf: launchDaemonPlist)
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dictionary = try XCTUnwrap(object as? [String: Any])
    XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, true)
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
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxCommandRunnerTimeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let scriptURL = directory.appendingPathComponent("hang.sh")
    let pidURL = directory.appendingPathComponent("pid.txt")
    try """
    #!/bin/sh
    printf "%s\\n" "$$" > "$1"
    exec sleep 30
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let runner = ProcessCommandRunner(timeout: 1)
    let startedAt = Date()
    let task = Task {
      try await runner.run(scriptURL.path, [pidURL.path])
    }
    let pid = try await waitForRecordedPID(at: pidURL)
    defer { terminateTestProcessIfNeeded(pid) }

    do {
      _ = try await task.value
      XCTFail("Expected timeout error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    let didExit = await waitForProcessExit(pid, timeout: 1)
    XCTAssertTrue(didExit)
  }

  func testProcessCommandRunnerDrainsLargeOutputWithoutTimingOut() async throws {
    let runner = ProcessCommandRunner(timeout: 2)
    let startedAt = Date()

    let output = try await runner.run(
      "/bin/sh",
      ["-c", "/usr/bin/yes 1234567890 | /usr/bin/head -c 200000"]
    )

    XCTAssertEqual(output.count, 200_000)
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
  }

  func testProcessCommandRunnerTerminatesRunningProcessWhenCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxCommandRunnerCancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let scriptURL = directory.appendingPathComponent("hang.sh")
    let pidURL = directory.appendingPathComponent("pid.txt")
    try """
    #!/bin/sh
    printf "%s\\n" "$$" > "$1"
    exec sleep 30
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let runner = ProcessCommandRunner(timeout: 10)
    let task = Task {
      try await runner.run(scriptURL.path, [pidURL.path])
    }
    let pid = try await waitForRecordedPID(at: pidURL)
    defer { terminateTestProcessIfNeeded(pid) }

    task.cancel()

    do {
      _ = try await withTimeout(seconds: 1) {
        try await task.value
      }
      XCTFail("Expected command runner cancellation.")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let didExit = await waitForProcessExit(pid, timeout: 1)
    XCTAssertTrue(didExit)
  }

  func testProcessCommandRunnerBlocksMutatingNetworkSetupCommandsDuringTests() async throws {
    let runner = ProcessCommandRunner(timeout: 1)

    do {
      _ = try await runner.run("/usr/sbin/networksetup", ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"])
      XCTFail("Expected mutating networksetup command to be blocked under XCTest.")
    } catch {
      XCTAssertTrue(
        UserFacingError.message(for: error).contains("Refusing to run mutating networksetup command inside XCTest")
      )
    }
  }

  func testSystemPingTesterUsesFixedExecutableAndParsesLatency() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/sbin/ping -c 1 -W 5000 example.com": "64 bytes from 93.184.216.34: icmp_seq=0 ttl=56 time=12.4 ms"
    ])
    let tester = SystemPingTester(commandRunner: runner)

    let delay = try await tester.ping(host: " example.com\n", timeoutMilliseconds: 5_000)

    XCTAssertEqual(delay, 12)
    XCTAssertEqual(runner.commands, ["/sbin/ping -c 1 -W 5000 example.com"])
  }

  func testSystemPingTesterRejectsOptionLikeHostsBeforeRunningCommand() async throws {
    let runner = RecordingCommandRunner(outputs: [:])
    let tester = SystemPingTester(commandRunner: runner)

    do {
      _ = try await tester.ping(host: "-c", timeoutMilliseconds: 5_000)
      XCTFail("Expected invalid host error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("invalid host"))
    }
    XCTAssertEqual(runner.commands, [])
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

  func testApplyFallsBackToDefaultRouteWhenActiveInterfaceQueryFails() async throws {
    let runner = FailingCommandRunner(
      outputs: [
        "/usr/sbin/networksetup -listnetworkserviceorder": """
        An asterisk (*) denotes that a network service is disabled.
        (1) Ethernet
        (Hardware Port: Ethernet, Device: en0)

        (2) USB 10/100/1G/2.5G LAN
        (Hardware Port: USB 10/100/1G/2.5G LAN, Device: en8)

        (3) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en1)
        """,
        "/sbin/route -n get default": """
           route to: default
        destination: default
              mask: default
           gateway: 192.168.8.1
         interface: en0
             flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """,
        "/usr/sbin/networksetup -getwebproxy Ethernet": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getsecurewebproxy Ethernet": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getsocksfirewallproxy Ethernet": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getproxybypassdomains Ethernet": "There aren't any bypass domains set.\n"
      ],
      failingCommands: [
        "/usr/sbin/scutil --nwi"
      ]
    )
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890)

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Ethernet 127.0.0.1 7890"))
    XCTAssertFalse(runner.commands.contains { $0.contains("USB 10/100/1G/2.5G LAN") })
    XCTAssertFalse(runner.commands.contains("/usr/sbin/networksetup -listallnetworkservices"))
  }

  func testApplySystemProxyAcceptsCustomBypassDomains() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.apply(host: "127.0.0.1", port: 7890, bypassDomains: ["localhost", "*.corp"])

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi localhost *.corp"))
  }

  func testApplySystemDNSCapturesAndRestoresEmptyDNS() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getdnsservers Wi-Fi": "There aren't any DNS Servers set on Wi-Fi.\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    let applyResult = try await controller.applyDNS(servers: [" 114.114.114.114 ", "114.114.114.114"])
    let restoreResult = try await controller.restoreDNS()

    XCTAssertEqual(applyResult.capturedSnapshotCount, 1)
    XCTAssertEqual(applyResult.appliedServiceCount, 1)
    XCTAssertEqual(restoreResult.restoredSnapshotCount, 1)
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi Empty"))
    XCTAssertFalse(controller.hasManagedSystemDNSState)
  }

  func testApplySystemDNSRestoresMultipleOriginalServers() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getdnsservers Wi-Fi": "1.1.1.1\n2606:4700:4700::1111\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.applyDNS(servers: ["114.114.114.114"])
    _ = try await controller.restoreDNS()

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 114.114.114.114"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 1.1.1.1 2606:4700:4700::1111"))
  }

  func testApplySystemDNSRejectsInvalidServersBeforeRunningNetworkSetup() async throws {
    let runner = RecordingCommandRunner(outputs: [:])
    let controller = SystemProxyController(commandRunner: runner)

    do {
      _ = try await controller.applyDNS(servers: ["not-a-dns-server"])
      XCTFail("Expected invalid DNS server error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("DNS"))
    }

    XCTAssertEqual(runner.commands, [])
  }

  func testCapturedDNSSnapshotsPersistAcrossControllerInstancesUntilRestore() async throws {
    let defaults = try Self.makeIsolatedDefaults()
    let firstRunner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getdnsservers Wi-Fi": "8.8.8.8\n"
    ])
    let firstController = SystemProxyController(commandRunner: firstRunner, snapshotDefaults: defaults)

    try await firstController.applyDNS(servers: ["114.114.114.114"])

    let secondRunner = RecordingCommandRunner(outputs: [:])
    let secondController = SystemProxyController(commandRunner: secondRunner, snapshotDefaults: defaults)

    XCTAssertTrue(secondController.hasManagedSystemDNSState)

    let restoreResult = try await secondController.restoreDNS()

    XCTAssertEqual(restoreResult.restoredSnapshotCount, 1)
    XCTAssertTrue(secondRunner.commands.contains("/usr/sbin/networksetup -setdnsservers Wi-Fi 8.8.8.8"))
    XCTAssertFalse(secondController.hasManagedSystemDNSState)
  }

  func testApplyRestoresCapturedServicesWhenLaterSnapshotFails() async throws {
    let runner = FailingCommandRunner(
      outputs: [
        "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\nEthernet\n",
        "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
        "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n",
        "/usr/sbin/networksetup -getwebproxy Ethernet": "Enabled: No\nServer:\nPort: 0\n"
      ],
      failingCommands: [
        "/usr/sbin/networksetup -getsecurewebproxy Ethernet"
      ]
    )
    let controller = SystemProxyController(commandRunner: runner)

    do {
      try await controller.apply(host: "127.0.0.1", port: 7890)
      XCTFail("Expected apply to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Injected failure"))
    }

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxystate Wi-Fi off"))
    XCTAssertFalse(controller.hasManagedSystemProxyState)
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

  func testProxyGuardMatchesExpectedHostCaseInsensitively() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: Yes\nServer: myhost.lan\nPort: 7890\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: Yes\nServer: myhost.lan\nPort: 7890\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: Yes\nServer: myhost.lan\nPort: 7890\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "Exceptions List\nlocalhost\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.enableGuard(host: "MyHost.lan", port: 7890, bypassDomains: ["localhost"])
    let result = try await controller.verifyGuardOnceDetailed()

    XCTAssertFalse(result.didRepair)
    XCTAssertTrue(result.warnings.isEmpty)
    XCTAssertFalse(runner.commands.contains { $0.contains("-setwebproxy Wi-Fi") })
    XCTAssertFalse(runner.commands.contains { $0.contains("-setsecurewebproxy Wi-Fi") })
    XCTAssertFalse(runner.commands.contains { $0.contains("-setsocksfirewallproxy Wi-Fi") })
  }

  func testProxyGuardQueryFailureReturnsWarningWithoutThrowing() async throws {
    let runner = FailingCommandRunner(
      outputs: [
        "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
        "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n"
      ],
      failingCommands: [
        "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi"
      ]
    )
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.enableGuard(host: "127.0.0.1", port: 7890, bypassDomains: ["localhost"])
    let result = try await controller.verifyGuardOnceDetailed()

    XCTAssertFalse(result.didRepair)
    XCTAssertEqual(result.warnings.count, 1)
    XCTAssertTrue(result.warnings[0].contains("could not read Wi-Fi proxy settings"))
    XCTAssertFalse(runner.commands.contains("/usr/sbin/networksetup -setwebproxy Wi-Fi 127.0.0.1 7890"))
  }

  func testSystemProxyOperationsSerializeNetworkSetupCommands() async throws {
    let runner = DelayedRecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    async let applyResult: Void = controller.apply(host: "127.0.0.1", port: 7890)
    async let restoreResult: Void = controller.restore()
    _ = try await (applyResult, restoreResult)

    XCTAssertEqual(runner.maximumConcurrentRuns, 1)
  }

  func testAsyncOperationGateCancelsQueuedWaiterWithoutRunningOperationOrBlockingLaterWork() async throws {
    let gate = AsyncOperationGate()
    let firstEntered = AsyncTestSignal()
    let releaseFirst = AsyncTestSignal()
    let secondStarted = AsyncTestSignal()
    let probe = AsyncOperationGateProbe()

    let firstTask = Task {
      try await gate.run {
        await firstEntered.signal()
        await releaseFirst.wait()
      }
    }
    await firstEntered.wait()

    let secondTask = Task {
      await secondStarted.signal()
      return try await gate.run {
        await probe.markSecondOperationExecuted()
        return "second"
      }
    }
    await secondStarted.wait()
    for _ in 0..<10 {
      await Task.yield()
    }

    secondTask.cancel()
    await releaseFirst.signal()
    try await firstTask.value

    await XCTAssertThrowsCancellationErrorAsync {
      try await secondTask.value
    }
    let didExecuteSecondOperation = await probe.didExecuteSecondOperation
    XCTAssertFalse(didExecuteSecondOperation)

    let thirdResult = try await gate.run {
      "third"
    }
    XCTAssertEqual(thirdResult, "third")
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

  func testCapturedSnapshotsPersistAcrossControllerInstancesUntilVerifiedRestore() async throws {
    let defaults = try Self.makeIsolatedDefaults()
    let firstRunner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n"
    ])
    let firstController = SystemProxyController(commandRunner: firstRunner, snapshotDefaults: defaults)

    try await firstController.apply(host: "127.0.0.1", port: 7890)

    let secondRunner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n"
    ])
    let secondController = SystemProxyController(commandRunner: secondRunner, snapshotDefaults: defaults)

    XCTAssertTrue(secondController.hasManagedSystemProxyState)

    let result = try await secondController.restoreAndVerify(
      hosts: ["127.0.0.1"],
      ports: [7890],
      disableWhenNoSnapshot: false
    )

    XCTAssertTrue(result.verified)
    XCTAssertFalse(result.didFallbackDisable)
    XCTAssertTrue(secondRunner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
    XCTAssertFalse(secondController.hasManagedSystemProxyState)

    let thirdController = SystemProxyController(commandRunner: RecordingCommandRunner(outputs: [:]), snapshotDefaults: defaults)
    XCTAssertFalse(thirdController.hasManagedSystemProxyState)
  }

  func testRestoreAndVerifyDisablesResidualClashProxyBeforeClearingSnapshots() async throws {
    let defaults = try Self.makeIsolatedDefaults()
    let runner = SequencedCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": [
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n"
      ],
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": [
        "There aren't any bypass domains set.\n",
        "Exceptions List\n\(SystemProxySettings.defaultBypassDomains.joined(separator: "\n"))\n",
        "Exceptions List\n\(SystemProxySettings.defaultBypassDomains.joined(separator: "\n"))\n",
        "There aren't any bypass domains set.\n"
      ]
    ])
    let controller = SystemProxyController(commandRunner: runner, snapshotDefaults: defaults)

    try await controller.apply(host: "127.0.0.1", port: 7890)

    let result = try await controller.restoreAndVerify(
      hosts: ["127.0.0.1", "localhost", "::1"],
      ports: [7890],
      disableWhenNoSnapshot: true
    )

    XCTAssertTrue(result.verified)
    XCTAssertTrue(result.didFallbackDisable)
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsecurewebproxystate Wi-Fi off"))
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setsocksfirewallproxystate Wi-Fi off"))
    XCTAssertFalse(controller.hasManagedSystemProxyState)
  }

  @MainActor
  func testCoordinatorRestoreDisablesResidualProxyOnAdditionalKnownPort() async throws {
    // Regression for issue #19: restore must consider every ClashMax-owned local
    // port, not only the current mixed port. A residual proxy left on the preview
    // runtime port (17890) while the current mixed port is 7890 must still be
    // detected and disabled rather than silently "verified" and cleared.
    let defaults = try Self.makeIsolatedDefaults()
    let runner = SequencedCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": Array(repeating: "Wi-Fi\n", count: 6),
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": [
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 17890\n",
        "Enabled: Yes\nServer: 127.0.0.1\nPort: 17890\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": Array(repeating: "Enabled: No\nServer:\nPort: 0\n", count: 6),
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": Array(repeating: "Enabled: No\nServer:\nPort: 0\n", count: 6),
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": Array(repeating: "There aren't any bypass domains set.\n", count: 6)
    ])
    let controller = SystemProxyController(commandRunner: runner, snapshotDefaults: defaults)
    let coordinator = SystemProxyCoordinator(controller: controller, defaults: defaults)

    let result = try await coordinator.restore(
      settings: .default,
      mixedPort: 7890,
      additionalPorts: [17_890],
      disableWhenNoSnapshot: false
    )

    XCTAssertTrue(result.didFallbackDisable)
    XCTAssertTrue(result.verified)
    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setwebproxystate Wi-Fi off"))
  }

  func testRestoreAndVerifySetHostsMatchesResidualProxyCaseInsensitively() async throws {
    let runner = SequencedRecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": [
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n",
        "Wi-Fi\n"
      ],
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": [
        "Enabled: Yes\nServer: myhost.lan\nPort: 7890\n",
        "Enabled: Yes\nServer: myhost.lan\nPort: 7890\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": [
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n",
        "Enabled: No\nServer:\nPort: 0\n"
      ],
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": [
        "There aren't any bypass domains set.\n",
        "There aren't any bypass domains set.\n",
        "There aren't any bypass domains set.\n"
      ]
    ])
    let controller = SystemProxyController(commandRunner: runner)

    let result = try await controller.restoreAndVerify(
      hosts: Set(["MyHost.lan"]),
      ports: Set([7890]),
      disableWhenNoSnapshot: true
    )

    XCTAssertTrue(result.didFallbackDisable)
  }

  func testRestoreClearsBypassDomainsWhenNoSnapshotExists() async throws {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n"
    ])
    let controller = SystemProxyController(commandRunner: runner)

    try await controller.restore()

    XCTAssertTrue(runner.commands.contains("/usr/sbin/networksetup -setproxybypassdomains Wi-Fi Empty"))
  }

  private static func makeIsolatedDefaults() throws -> UserDefaults {
    let suiteName = "ClashMaxSystemProxyControllerTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

private extension SystemProxyControllerTests {
  struct ProcessResult {
    var exitCode: Int32
    var output: String
  }

  static func projectRoot() -> URL {
    let testFile = URL(fileURLWithPath: #filePath)
    return testFile.deletingLastPathComponent().deletingLastPathComponent()
  }

  static func runProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL,
    environment: [String: String] = [:]
  ) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
      override
    }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return ProcessResult(
      exitCode: process.terminationStatus,
      output: String(data: data, encoding: .utf8) ?? ""
    )
  }

  static func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func jsonLines(at url: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: url)
    let content = try XCTUnwrap(String(data: data, encoding: .utf8))
    return try content.split(separator: "\n").map { line in
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      )
    }
  }
}

private actor AsyncTestSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isSignaled {
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    isSignaled = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }
}

private actor AsyncOperationGateProbe {
  private var executedSecondOperation = false

  var didExecuteSecondOperation: Bool {
    executedSecondOperation
  }

  func markSecondOperationExecuted() {
    executedSecondOperation = true
  }
}

private func waitForRecordedPID(at url: URL, timeout: TimeInterval = 1) async throws -> pid_t {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let text = try? String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let pid = pid_t(text),
      pid > 1 {
      return pid
    }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  throw NSError(
    domain: "ClashMaxTests.ProcessPID",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for process PID at \(url.path)."]
  )
}

private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if !isProcessAlive(pid) {
      return true
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return !isProcessAlive(pid)
}

private func terminateTestProcessIfNeeded(_ pid: pid_t) {
  guard pid > 1 else { return }
  guard isProcessAlive(pid) else { return }
  kill(pid, SIGTERM)
  let deadline = Date().addingTimeInterval(1)
  while Date() < deadline && isProcessAlive(pid) {
    usleep(20_000)
  }
  if isProcessAlive(pid) {
    kill(pid, SIGKILL)
  }
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
  guard pid > 1 else { return false }
  return kill(pid, 0) == 0 || errno == EPERM
}

private final class DelayedRecordingCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let delayNanoseconds: UInt64
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.DelayedRecordingCommandRunner")
  private var _commands: [String] = []
  private var inFlight = 0
  private var maxInFlight = 0

  init(outputs: [String: String], delayNanoseconds: UInt64 = 5_000_000) {
    self.outputs = outputs
    self.delayNanoseconds = delayNanoseconds
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  var maximumConcurrentRuns: Int {
    queue.sync { maxInFlight }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
      inFlight += 1
      maxInFlight = max(maxInFlight, inFlight)
    }
    try? await Task.sleep(nanoseconds: delayNanoseconds)
    queue.sync {
      inFlight -= 1
    }
    return outputs[command] ?? ""
  }
}

private final class SequencedCommandRunner: CommandRunning, @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.SequencedCommandRunner")
  private var outputs: [String: [String]]
  private var _commands: [String] = []

  init(outputs: [String: [String]]) {
    self.outputs = outputs
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    return queue.sync {
      _commands.append(command)
      guard var values = outputs[command], !values.isEmpty else {
        return ""
      }
      let value = values.removeFirst()
      outputs[command] = values
      return value
    }
  }
}

private final class FailingCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  let failingCommands: Set<String>
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.FailingCommandRunner")
  private var _commands: [String] = []

  init(outputs: [String: String], failingCommands: Set<String>) {
    self.outputs = outputs
    self.failingCommands = failingCommands
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
    }
    if failingCommands.contains(command) {
      throw NSError(
        domain: "ClashMaxTests.FailingCommandRunner",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Injected failure for \(command)"]
      )
    }
    return outputs[command] ?? ""
  }
}
