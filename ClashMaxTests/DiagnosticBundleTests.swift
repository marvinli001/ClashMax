@testable import ClashMax
import Foundation
import XCTest

/// Roadmap A5: every secret is gone before a byte is written. The assertions run over the bytes the
/// writer actually put on disk, so a leak anywhere between collection and `write` fails here.
final class DiagnosticBundleTests: XCTestCase {
  // Every category the criterion names, each planted where it would really turn up.
  private let controllerSecret = "ctl-secret-7f3a9c2e"
  private let subscriptionURL = "https://sub.airport-example.net/api/v1/client/subscribe?token=SUBTOKEN0123456789abc"
  private let subscriptionToken = "SUBTOKEN0123456789abc"
  private let subscriptionHost = "sub.airport-example.net"
  private let pathTokenURL = "https://panel.other-example.org/link/AbCdEfGhIjKlMnOpQrSt?clash=1"
  private let pathToken = "AbCdEfGhIjKlMnOpQrSt"
  private let nodePassword = "node-pass-Q9w8E7r6"
  private let nodeUUID = "1b6c7a5e-0d3f-4e2a-9c8b-7a6f5e4d3c2b"
  private let wireGuardKey = "wgPrivKey+AbCdEfGhIjKlMnOpQrStUvWxYz0123456789="
  private let inboundUser = "alice-lan-user"
  private let inboundPassword = "hunter2-lan-pass"
  private let ssid = "Marvin Home-5G"
  private let policySSID = "CorpNet-Guest"
  private let publicIP = "203.0.113.77"
  private let providerPath = "/Users/tester/Library/Application Support/ClashMax/Runtime/provider-abc.yaml"

  // MARK: Byte-level leak test

  func testWrittenBytesContainNoPlantedSecret() throws {
    let bundle = DiagnosticBundleBuilder.build(plantedInput())
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("clashmax-bundle-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }

    try DiagnosticBundleWriter.write(bundle, to: url)
    let written = try Data(contentsOf: url)

    XCTAssertEqual(written, bundle.data, "the writer must write exactly the previewed bytes")
    let secrets = [
      controllerSecret,
      subscriptionURL,
      subscriptionToken,
      subscriptionHost,
      pathToken,
      nodePassword,
      nodeUUID,
      wireGuardKey,
      inboundUser,
      inboundPassword,
      ssid,
      ssid.lowercased(),
      policySSID,
      publicIP,
      // The masked form the copyable report uses still narrows the egress to one network.
      "203.xxx.xxx.77",
      providerPath,
      "/Users/tester",
    ]
    for secret in secrets {
      XCTAssertNil(written.range(of: Data(secret.utf8)), "leaked: \(secret)")
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testRedactionKeepsTheFactsADiagnosisNeeds() {
    let text = DiagnosticBundleBuilder.build(plantedInput()).contents.text

    XCTAssertTrue(text.contains("Tokyo 01"), "node names stay")
    XCTAssertTrue(text.contains("jp1.node-example.com"), "server addresses stay")
    XCTAssertTrue(text.contains("https://www.gstatic.com/"), "a public URL in a log keeps its scheme and host")
    // The config view redacts every http(s) URL in YAML, because http and https are proxy share-link
    // schemes too; it must do so once, not render `https://<redacted>>`.
    XCTAssertTrue(text.contains("geoip: https://<redacted>\n"))
    XCTAssertFalse(text.contains("<redacted>>"))
    XCTAssertTrue(text.contains("ssid=notAssociated"), "an unavailable-SSID reason is the diagnosis, not a name")
    XCTAssertTrue(text.contains("Public IP Region: Japan (JP)"), "the country of the egress stays")
    XCTAssertTrue(text.contains("Public IP: <redacted>"))
    XCTAssertTrue(text.contains("Wi-Fi: connected (network name redacted)"))
    XCTAssertTrue(text.contains("Mihomo (running): v1.19.31"))
    XCTAssertTrue(text.contains("Source: the config the running core loaded"))
  }

  func testTheSameSecretIsRemovedOutsideTheYAMLItCameFrom() {
    let text = DiagnosticBundleBuilder.build(plantedInput()).contents.text

    // Planted in `lastError`, a core output line and a log line respectively.
    XCTAssertFalse(text.contains(nodePassword))
    XCTAssertFalse(text.contains(nodeUUID))
    XCTAssertTrue(text.contains("Last Error: proxy JP-01 rejected password <redacted>"))
  }

  func testACredentialTooShortToReplaceEverywhereIsStillRemovedByKey() {
    var input = plantedInput()
    input.config = .loadedByCore(yaml: """
    proxies:
      - name: Short
        type: ss
        server: s.example.com
        port: 443
        password: ab
    """, path: "/tmp/runtime.yaml")

    let text = DiagnosticBundleBuilder.build(input).contents.text

    XCTAssertFalse(text.contains("password: ab"))
    XCTAssertTrue(text.contains("password: <redacted>"))
    // "ab" was not stripped from every word in the file.
    XCTAssertTrue(text.contains("Probe Host: api.ip.sb"))
  }

  // MARK: Missing data

  func testEverySectionExplainsMissingDataInsteadOfStayingEmpty() {
    let text = DiagnosticBundleBuilder.build(emptyInput()).contents.text

    for expected in [
      "Mihomo (bundled): unknown — the bundled core manifest could not be read",
      "Mihomo (running): no core is running",
      "Core Memory: no reading — the core reports memory only while it is running",
      "Readiness: ready to start",
      "Last Error: none",
      "Public IP: not checked yet",
      "Proxy Effect: not evaluated — no public IP result or current node to judge",
      "TUN Checks: not applicable — routing mode is",
      "Sniffer: unknown — the effective config could not be generated",
      "Running Core: not known — no core is running",
      "Fake IP: not evaluated",
      "Geo Databases: not evaluated",
      "Listener Exposure: not evaluated",
      "DNS Override: unknown — the effective config could not be generated",
      "DNS Resolution: no query has been made from the DNS panel",
      "Wi-Fi: not checked yet",
      "Last Applied Policy: none",
      "Last Network Change: none seen since ClashMax started",
      "Unavailable: no active profile is selected",
      "No log entries have been recorded since ClashMax started.",
      "The helper reported no output.",
      "The core process has written nothing since it was last started.",
    ] {
      XCTAssertTrue(text.contains(expected), "missing explanation: \(expected)\n\n\(text)")
    }
    // No section is left without a line of its own: a `--` subsection is followed straight away by
    // content, and a `==` section by content or a subsection, never by the next `==` section.
    let lines = text.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      if line.hasPrefix("-- ") {
        let next = lines.indices.contains(index + 1) ? lines[index + 1] : ""
        XCTAssertFalse(next.isEmpty || next.hasPrefix("== ") || next.hasPrefix("-- "), "empty section: \(line)")
      } else if line.hasPrefix("== ") {
        let next = lines[(index + 1)...].first { !$0.isEmpty }
        XCTAssertNotNil(next, "empty section at the end: \(line)")
        XCTAssertFalse(next?.hasPrefix("== ") ?? true, "empty section: \(line)")
      }
    }
  }

  func testTunChecksThatHaveNotRunSaySoInTunMode() {
    var input = emptyInput()
    input.report.routingMode = .tun

    let text = DiagnosticBundleBuilder.build(input).contents.text

    XCTAssertTrue(text.contains("TUN Checks: none have run yet — refresh TUN diagnostics on the Status page"))
  }

  // MARK: Redactor rules

  func testSSIDRedactionIsCaseInsensitiveAndWordBounded() {
    let redactor = DiagnosticBundleRedactor(secrets: DiagnosticBundleSecrets(ssids: ["Home"]))

    let text = redactor.redact("Applied Office for home. ssid=Cafe-2G, HomePod stays, ssid=wiFiPoweredOff").text

    XCTAssertEqual(text, "Applied Office for <ssid>. ssid=<ssid>, HomePod stays, ssid=wiFiPoweredOff")
  }

  func testSubscriptionPartsAreRemovedEvenWhenTheURLAppearsReshaped() {
    let redactor = DiagnosticBundleRedactor(secrets: DiagnosticBundleSecrets(subscriptionURLs: [subscriptionURL]))

    let text = redactor.redact("""
    fetch \(subscriptionURL) failed
    retry host=\(subscriptionHost) token \(subscriptionToken)
    """).text

    XCTAssertFalse(text.contains(subscriptionToken))
    XCTAssertFalse(text.contains(subscriptionHost))
    XCTAssertTrue(text.contains("fetch <redacted> failed"))
    XCTAssertTrue(text.contains("host=<subscription-host>"))
  }

  func testRedactionIsIdempotent() {
    let redactor = DiagnosticBundleRedactor(secrets: plantedInput().secrets)
    let once = redactor.redact(DiagnosticBundleBuilder.build(plantedInput()).contents.text).text
    let twice = redactor.redact(once).text

    XCTAssertEqual(once, twice)
  }

  // MARK: Fixtures

  private func plantedInput() -> DiagnosticBundleInput {
    let runtimeYAML = """
    mixed-port: 7890
    secret: \(controllerSecret)
    external-controller: 127.0.0.1:9097
    authentication:
      - \(inboundUser):\(inboundPassword)
    listeners:
      - name: lan
        type: mixed
        port: 7999
        users:
          - username: \(inboundUser)
            password: \(inboundPassword)
    proxies:
      - name: Tokyo 01
        type: vmess
        server: jp1.node-example.com
        port: 443
        uuid: \(nodeUUID)
      - name: JP-01
        type: ss
        server: jp2.node-example.com
        port: 8388
        cipher: aes-128-gcm
        password: \(nodePassword)
      - name: WG
        type: wireguard
        server: wg.node-example.com
        port: 51820
        private-key: \(wireGuardKey)
    proxy-providers:
      airport:
        type: http
        url: \(subscriptionURL)
        path: \(providerPath)
    geox-url:
      geoip: https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat
    """
    var report = Self.report(
      controllerSecret: controllerSecret,
      lastError: "proxy JP-01 rejected password \(nodePassword)",
      helperLogs: ["helper: egress \(publicIP) via utun5", "Bearer \(controllerSecret)"]
    )
    report.publicIPInfo = PublicIPInfo(
      ipAddress: publicIP,
      countryCode: "JP",
      countryName: "Japan",
      city: "Shibuya",
      asn: "AS64500",
      sourceName: "ip.sb",
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    report.profileName = "Airport"
    return DiagnosticBundleInput(
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      versions: DiagnosticBundleVersions(
        appVersion: "1.1.2",
        appBuild: "32",
        bundledCore: "v1.19.31",
        runningCore: "v1.19.31",
        operatingSystem: "Version 26.0 (Build 25A354)",
        hardwareArchitecture: "arm64",
        processArchitecture: "arm64",
        isTranslated: false
      ),
      report: report,
      config: .loadedByCore(yaml: runtimeYAML, path: "/Users/tester/Library/Application Support/ClashMax/Runtime/runtime.yaml"),
      dnsOverride: nil,
      sniffer: nil,
      runningCoreSniffing: true,
      dnsResolution: nil,
      network: DiagnosticBundleNetwork(
        wiFi: .joined(ssid),
        savedPolicyCount: 1,
        autoApplyEnabled: true,
        lastAppliedPolicyName: "Office",
        policyStatus: "Applied Office for \(ssid.lowercased()).",
        lastNetworkChange: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      logs: [
        LogEntry(level: "info", message: "Network environment changed via path: path=satisfied, ssid=\(ssid)"),
        LogEntry(level: "info", message: "Network environment changed via path: path=satisfied, ssid=notAssociated"),
        LogEntry(level: "warn", message: "Could not auto-update subscription Airport: GET \(subscriptionURL) returned 403"),
        LogEntry(level: "debug", message: "GET \(pathTokenURL) authorization: Bearer \(controllerSecret)"),
        LogEntry(level: "info", message: "Leaving \(policySSID); restoring the previous network state"),
        LogEntry(level: "error", message: "dial jp1.node-example.com:443 uuid=\(nodeUUID) failed"),
        LogEntry(level: "info", message: "Wrote \(providerPath)"),
        LogEntry(level: "info", message: "probe https://www.gstatic.com/generate_204 answered 204"),
      ],
      coreProcessOutput: "level=error msg=\"vmess uuid \(nodeUUID) rejected\"\nlevel=info msg=\"public ip \(publicIP)\"",
      secrets: DiagnosticBundleSecrets(
        controllerSecrets: [controllerSecret],
        subscriptionURLs: [subscriptionURL, pathTokenURL],
        ssids: [ssid, policySSID],
        publicIPAddresses: [publicIP],
        providerContentPaths: [providerPath],
        homeDirectory: "/Users/tester"
      ),
      credentialSourceYAMLs: ["proxies:\n  - {name: JP-01, type: ss, password: \(nodePassword)}"]
    )
  }

  private func emptyInput() -> DiagnosticBundleInput {
    DiagnosticBundleInput(
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      versions: DiagnosticBundleVersions(
        appVersion: "1.1.2",
        appBuild: "32",
        bundledCore: nil,
        runningCore: nil,
        operatingSystem: "Version 26.0",
        hardwareArchitecture: "arm64",
        processArchitecture: "arm64",
        isTranslated: false
      ),
      report: Self.report(controllerSecret: "", lastError: nil, helperLogs: []),
      config: .unavailable("no active profile is selected, so there is no runtime config to show"),
      dnsOverride: nil,
      sniffer: nil,
      runningCoreSniffing: nil,
      dnsResolution: nil,
      network: DiagnosticBundleNetwork(
        wiFi: .notChecked,
        savedPolicyCount: 0,
        autoApplyEnabled: false,
        lastAppliedPolicyName: nil,
        policyStatus: nil,
        lastNetworkChange: nil
      ),
      logs: [],
      coreProcessOutput: "",
      secrets: DiagnosticBundleSecrets()
    )
  }

  private static func report(controllerSecret: String, lastError: String?, helperLogs: [String]) -> RuntimeDiagnosticsReport {
    RuntimeDiagnosticsReport(
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      statusSummary: "Stopped",
      profileName: "No Profile",
      runtimeOwner: .stopped,
      routingMode: .systemProxy,
      runMode: .rule,
      controllerHost: "127.0.0.1",
      controllerPort: 9097,
      controllerSecret: controllerSecret,
      coreStatus: "Stopped",
      systemProxyEnabled: false,
      tunEnabled: false,
      networkExtensionEnabled: false,
      tunSystemDNS: "Off",
      networkExtensionSystemDNS: "Off",
      tunDNSMode: "profile",
      ruleOverlaySummary: "Disabled",
      helperDetail: .unknown,
      tunDiagnostics: .empty,
      networkExtensionDiagnostics: .empty,
      readinessIssue: nil,
      lastError: lastError,
      recentLogs: [],
      helperLogs: helperLogs,
      publicIPInfo: nil,
      probeHost: "api.ip.sb",
      proxyEffect: nil
    )
  }
}
