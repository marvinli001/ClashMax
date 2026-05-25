import XCTest

final class NetworkExtensionProjectConfigurationTests: XCTestCase {
  func testProjectDefinesSystemExtensionTargetAndEmbedding() throws {
    let root = try projectRoot()
    let projectYAML = try String(
      contentsOf: root.appendingPathComponent("project.yml"),
      encoding: .utf8
    )

    XCTAssertTrue(projectYAML.contains("ClashMaxNetworkExtension:"))
    XCTAssertTrue(projectYAML.contains("type: system-extension"))
    XCTAssertTrue(projectYAML.contains("PRODUCT_BUNDLE_IDENTIFIER: io.github.clashmax.ClashMax.NetworkExtension"))
    XCTAssertTrue(projectYAML.contains("Library/SystemExtensions/io.github.clashmax.ClashMax.NetworkExtension.systemextension"))
    XCTAssertTrue(projectYAML.contains("Config/ClashMaxNetworkExtension.entitlements"))

    let appTarget = try targetBlock(named: "ClashMax", in: projectYAML)
    let networkExtensionTarget = try targetBlock(named: "ClashMaxNetworkExtension", in: projectYAML)
    XCTAssertEqual(
      try buildSetting(named: "MARKETING_VERSION", in: networkExtensionTarget),
      try buildSetting(named: "MARKETING_VERSION", in: appTarget)
    )
    XCTAssertEqual(
      try buildSetting(named: "CURRENT_PROJECT_VERSION", in: networkExtensionTarget),
      try buildSetting(named: "CURRENT_PROJECT_VERSION", in: appTarget)
    )
    XCTAssertTrue(networkExtensionTarget.contains("Shared/Socks5ConnectRequest.swift"))
    XCTAssertTrue(networkExtensionTarget.contains("Shared/NetworkExtensionRuntimeConstants.swift"))
  }

  func testAppAndExtensionEntitlementsContainNetworkExtensionKeys() throws {
    let root = try projectRoot()
    let appEntitlements = try String(
      contentsOf: root.appendingPathComponent("Config/ClashMax.entitlements"),
      encoding: .utf8
    )
    let extensionEntitlements = try String(
      contentsOf: root.appendingPathComponent("Config/ClashMaxNetworkExtension.entitlements"),
      encoding: .utf8
    )

    for entitlements in [appEntitlements, extensionEntitlements] {
      XCTAssertTrue(entitlements.contains("com.apple.developer.networking.networkextension"))
      XCTAssertTrue(entitlements.contains("app-proxy-provider-systemextension"))
      XCTAssertTrue(entitlements.contains("com.apple.security.application-groups"))
      XCTAssertTrue(entitlements.contains("group.678WA95W4U.io.github.clashmax.ClashMax.network-extension"))
    }
    XCTAssertTrue(appEntitlements.contains("com.apple.developer.system-extension.install"))
  }

  func testProjectUsesManualDeveloperIDSigning() throws {
    let root = try projectRoot()
    let projectYAML = try String(
      contentsOf: root.appendingPathComponent("project.yml"),
      encoding: .utf8
    )

    XCTAssertTrue(projectYAML.contains("DEVELOPMENT_TEAM: 678WA95W4U"))
    XCTAssertTrue(projectYAML.contains("CODE_SIGN_STYLE: Manual"))
    XCTAssertTrue(projectYAML.contains(#"CODE_SIGN_IDENTITY: "Developer ID Application""#))
    XCTAssertTrue(projectYAML.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO"))
    XCTAssertTrue(projectYAML.contains("PROVISIONING_PROFILE_SPECIFIER: ClashMax Developer ID"))
    XCTAssertTrue(projectYAML.contains("PROVISIONING_PROFILE_SPECIFIER: ClashMax NetworkExtension Developer ID"))
  }

  func testNetworkExtensionInfoPlistContainsProviderClassAndMachService() throws {
    let root = try projectRoot()
    let plist = try String(
      contentsOf: root.appendingPathComponent("Config/ClashMaxNetworkExtension-Info.plist"),
      encoding: .utf8
    )

    XCTAssertTrue(plist.contains("NEProviderClasses"))
    XCTAssertTrue(plist.contains("com.apple.networkextension.app-proxy"))
    XCTAssertTrue(plist.contains("$(PRODUCT_MODULE_NAME).TransparentProxyProvider"))
    XCTAssertTrue(plist.contains("CFBundleShortVersionString"))
    XCTAssertTrue(plist.contains("CFBundleVersion"))
    XCTAssertTrue(plist.contains("NSSystemExtensionUsageDescription"))
    XCTAssertTrue(plist.contains("NEMachServiceName"))
    XCTAssertTrue(plist.contains("group.678WA95W4U.io.github.clashmax.ClashMax.network-extension"))
  }

  func testAppRegistersCommandURLSchemeAndAppShortcuts() throws {
    let root = try projectRoot()
    let projectYAML = try String(
      contentsOf: root.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let appInfoPlist = try String(
      contentsOf: root.appendingPathComponent("Config/ClashMax-Info.plist"),
      encoding: .utf8
    )
    let appIntents = try String(
      contentsOf: root.appendingPathComponent("ClashMax/App/ClashMaxAppIntents.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(projectYAML.contains("- clashmax"))
    XCTAssertTrue(appInfoPlist.contains("<string>clashmax</string>"))
    XCTAssertTrue(appIntents.contains("StartClashMaxIntent"))
    XCTAssertTrue(appIntents.contains("ToggleSystemProxyIntent"))
    XCTAssertTrue(appIntents.contains("ClashMaxAppShortcuts"))
    XCTAssertTrue(appIntents.contains("AppShortcutsProvider"))
  }

  func testRunScriptVerifiesEmbeddedSystemExtensionWithoutResigning() throws {
    let root = try projectRoot()
    let projectYAML = try String(
      contentsOf: root.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let script = try String(
      contentsOf: root.appendingPathComponent("script/build_and_run.sh"),
      encoding: .utf8
    )

    XCTAssertTrue(projectYAML.contains("Clean Network Extension Extended Attributes"))
    XCTAssertTrue(projectYAML.contains("Embed Network Extension\n        basedOnDependencyAnalysis: false"))
    XCTAssertTrue(projectYAML.contains(#"xattr -cr "$product" || true"#))
    XCTAssertFalse(projectYAML.contains("Signing embedded Network Extension"))
    XCTAssertTrue(script.contains("Contents/Library/SystemExtensions/io.github.clashmax.ClashMax.NetworkExtension.systemextension"))
    XCTAssertFalse(script.contains("Config/ClashMaxNetworkExtension.entitlements"))
    XCTAssertFalse(script.contains("codesign --force"))
    XCTAssertTrue(script.contains(#"codesign --verify --strict --verbose=2 "$APP_BUNDLE""#))
    XCTAssertTrue(script.contains("codesign --verify --strict --verbose=2 \"$SYSTEM_EXTENSION\""))
  }

  func testCoreBinariesUseStableSigningIdentifiersForTransparentProxyBypass() throws {
    let root = try projectRoot()
    let projectYAML = try String(
      contentsOf: root.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let script = try String(
      contentsOf: root.appendingPathComponent("script/build_and_run.sh"),
      encoding: .utf8
    )
    let constants = try String(
      contentsOf: root.appendingPathComponent("Shared/NetworkExtensionRuntimeConstants.swift"),
      encoding: .utf8
    )
    let provider = try String(
      contentsOf: root.appendingPathComponent("ClashMaxNetworkExtension/TransparentProxyProvider.swift"),
      encoding: .utf8
    )

    for content in [projectYAML, constants] {
      XCTAssertTrue(content.contains("io.github.clashmax.ClashMax.Mihomo.arm64"))
      XCTAssertTrue(content.contains("io.github.clashmax.ClashMax.Mihomo.amd64"))
    }
    XCTAssertFalse(script.contains("io.github.clashmax.ClashMax.Mihomo.arm64"))
    XCTAssertFalse(script.contains("io.github.clashmax.ClashMax.Mihomo.amd64"))
    XCTAssertTrue(provider.contains("mihomoArm64SigningIdentifier"))
    XCTAssertTrue(provider.contains("mihomoAmd64SigningIdentifier"))
    XCTAssertTrue(projectYAML.contains(#"--identifier "$core_identifier""#))
    XCTAssertFalse(script.contains(#"--identifier "$core_identifier""#))
  }

  func testTransparentProxyProviderAndSOCKSBridgeArePresent() throws {
    let root = try projectRoot()
    let provider = try String(
      contentsOf: root.appendingPathComponent("ClashMaxNetworkExtension/TransparentProxyProvider.swift"),
      encoding: .utf8
    )
    let socksRequest = try String(
      contentsOf: root.appendingPathComponent("Shared/Socks5ConnectRequest.swift"),
      encoding: .utf8
    )
    let notices = try String(
      contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
      encoding: .utf8
    )

    XCTAssertTrue(provider.contains("NETransparentProxyProvider"))
    XCTAssertTrue(provider.contains("NETransparentProxyNetworkSettings"))
    XCTAssertTrue(provider.contains("NEAppProxyTCPFlow"))
    XCTAssertTrue(provider.contains("NEAppProxyUDPFlow"))
    XCTAssertTrue(provider.contains("protocol: .TCP"))
    XCTAssertTrue(provider.contains("UDPFlowBridge"))
    XCTAssertTrue(provider.contains("protocol: .UDP"))
    XCTAssertTrue(provider.contains("excludedNetworkRules"))
    XCTAssertTrue(provider.contains("sourceAppSigningIdentifier"))
    XCTAssertTrue(provider.contains("diagnosticsFilename"))
    XCTAssertTrue(provider.contains("Socks5UDPDatagramCodec"))
    XCTAssertTrue(provider.contains("guard let endpoint = Self.socksEndpoint(from: remoteEndpoint) else"))
    XCTAssertTrue(provider.contains("Bypassed UDP flow with unsupported remote endpoint."))
    XCTAssertTrue(provider.contains("initialEndpoint: endpoint"))
    XCTAssertFalse(provider.contains("initialEndpoint: Self.socksEndpoint(from: remoteEndpoint)"))
    XCTAssertTrue(socksRequest.contains("udpAssociateBytes"))
    XCTAssertTrue(socksRequest.contains("Socks5ConnectRequest"))
    XCTAssertFalse(notices.contains("hev-socks5-tunnel"))
  }

  private func projectRoot() throws -> URL {
    let url = URL(fileURLWithPath: #filePath)
    return url
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func targetBlock(named targetName: String, in projectYAML: String) throws -> String {
    let marker = "\n  \(targetName):\n"
    guard let start = projectYAML.range(of: marker) else {
      XCTFail("Missing target \(targetName)")
      return ""
    }

    let remainder = projectYAML[start.upperBound...]
    guard let end = remainder.range(
      of: #"\n  [A-Za-z0-9_]+:\n"#,
      options: .regularExpression
    ) else {
      return String(remainder)
    }
    return String(remainder[..<end.lowerBound])
  }

  private func buildSetting(named settingName: String, in targetBlock: String) throws -> String {
    for line in targetBlock.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("\(settingName):") else {
        continue
      }

      return String(trimmed.dropFirst(settingName.count + 1))
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: #"""#))
    }

    XCTFail("Missing build setting \(settingName)")
    return ""
  }
}
