import XCTest
import Yams
@testable import ClashMax

final class ConfigNormalizerTests: XCTestCase {
  func testRuntimeConfigPreservesUnknownFieldsAndAppliesSafeOverrides() throws {
    let source = """
    mixed-port: 7000
    mode: global
    custom-field:
      nested: kept
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [DIRECT]
    tun:
      enable: false
      auto-redirect: true
    """

    let overrides = RuntimeOverrides(
      mixedPort: 7890,
      externalControllerHost: "127.0.0.1",
      externalControllerPort: 9097,
      secret: "secret-token",
      allowLan: false,
      mode: .rule,
      logLevel: "info",
      dnsEnabled: true,
      tunEnabled: true
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(yaml["mixed-port"] as? Int, 7890)
    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
    XCTAssertEqual(yaml["secret"] as? String, "secret-token")
    XCTAssertEqual(yaml["mode"] as? String, "rule")
    XCTAssertEqual((yaml["custom-field"] as? [String: Any])?["nested"] as? String, "kept")

    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    XCTAssertEqual(tun["enable"] as? Bool, true)
    XCTAssertEqual(tun["stack"] as? String, "mixed")
    XCTAssertEqual(tun["auto-route"] as? Bool, true)
    XCTAssertEqual(tun["auto-detect-interface"] as? Bool, true)
    XCTAssertNil(tun["route-exclude-address"])
    XCTAssertNil(tun["auto-redirect"])
    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(dns["nameserver"] as? [String], ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"])
    XCTAssertEqual(dns["fallback"] as? [String], ["tls://8.8.4.4", "tls://1.1.1.1"])
    XCTAssertTrue((dns["fake-ip-filter"] as? [String])?.contains("*.lan") == true)
    XCTAssertTrue((dns["fake-ip-filter"] as? [String])?.contains("captive.apple.com") == true)
  }

  func testInvalidYamlProducesReadableError() {
    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "not: [valid", overrides: .defaultForLaunch())) { error in
      XCTAssertTrue(String(describing: error).contains("YAML"))
    }
  }

  func testTunSettingsAreAppliedOnlyWhenTunIsEnabled() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    tun:
      enable: false
      stack: system
      auto-redirect: true
      route-exclude-address: [10.0.0.0/8]
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true
    overrides.tunSettings = TunSettings(
      stack: .gvisor,
      device: "utun9",
      autoRoute: false,
      strictRoute: true,
      autoDetectInterface: false,
      dnsHijack: ["any:53"],
      mtu: 1400,
      routeExcludeAddresses: [" 192.168.0.0/16 ", "10.0.0.0/8"]
    )

    let enabledOutput = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let enabledYAML = try XCTUnwrap(Yams.load(yaml: enabledOutput) as? [String: Any])
    let enabledTun = try XCTUnwrap(enabledYAML["tun"] as? [String: Any])
    let enabledDNS = try XCTUnwrap(enabledYAML["dns"] as? [String: Any])

    XCTAssertEqual(enabledTun["enable"] as? Bool, true)
    XCTAssertEqual(enabledTun["stack"] as? String, "gvisor")
    XCTAssertEqual(enabledTun["device"] as? String, "utun9")
    XCTAssertEqual(enabledTun["auto-route"] as? Bool, false)
    XCTAssertEqual(enabledTun["strict-route"] as? Bool, true)
    XCTAssertEqual(enabledTun["auto-detect-interface"] as? Bool, false)
    XCTAssertEqual(enabledTun["dns-hijack"] as? [String], ["any:53"])
    XCTAssertEqual(enabledTun["mtu"] as? Int, 1400)
    XCTAssertEqual(enabledTun["route-exclude-address"] as? [String], ["10.0.0.0/8", "192.168.0.0/16"])
    XCTAssertNil(enabledTun["auto-redirect"])
    XCTAssertEqual(enabledDNS["enable"] as? Bool, true)
    XCTAssertEqual(enabledDNS["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(enabledDNS["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(enabledDNS["nameserver"] as? [String], ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"])
    XCTAssertEqual(enabledDNS["fallback"] as? [String], ["tls://8.8.4.4", "tls://1.1.1.1"])
    XCTAssertTrue((enabledDNS["fake-ip-filter"] as? [String])?.contains("router.asus.com") == true)

    overrides.tunEnabled = false
    let disabledOutput = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let disabledYAML = try XCTUnwrap(Yams.load(yaml: disabledOutput) as? [String: Any])
    let disabledTun = try XCTUnwrap(disabledYAML["tun"] as? [String: Any])

    XCTAssertEqual(disabledTun["enable"] as? Bool, false)
    XCTAssertEqual(disabledTun["stack"] as? String, "system")
    XCTAssertNil(disabledTun["auto-redirect"])
    XCTAssertNil(disabledYAML["dns"])
  }

  func testRuntimeConfigPreservesProfileRouteExcludeAddressWhenTunSettingsAreDefault() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    tun:
      enable: true
      auto-redirect: true
      route-exclude-address:
        - " 10.0.0.0/8 "
        - 10.0.0.0/8
        - 172.16.0.0/12
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(tun["route-exclude-address"] as? [String], ["10.0.0.0/8", "172.16.0.0/12"])
    XCTAssertNil(tun["auto-redirect"])
  }

  func testRuntimeConfigMergesTunDNSOverlayWithoutMutatingSourceProfileFields() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    dns:
      enable: false
      fake-ip-filter:
        - "*.corp"
      nameserver:
        - 8.8.8.8
      hosts:
        router.lan: 192.168.1.1
    tun:
      enable: false
      auto-redirect: true
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true
    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(
        fakeIPFilter: ["*.corp", "*.lan"],
        nameserver: ["8.8.8.8", "https://dns.example/dns-query"],
        fallback: ["1.1.1.1"],
        proxyServerNameserver: ["9.9.9.9"],
        directNameserver: ["223.5.5.5"],
        nameserverPolicy: ["+.corp": "system"],
        hosts: ["internal.test": "10.0.0.2"]
      )
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(dns["fake-ip-filter"] as? [String], ["*.corp", "*.lan"])
    XCTAssertEqual(dns["nameserver"] as? [String], ["8.8.8.8", "https://dns.example/dns-query"])
    XCTAssertEqual(dns["fallback"] as? [String], ["1.1.1.1"])
    XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["9.9.9.9"])
    XCTAssertEqual(dns["direct-nameserver"] as? [String], ["223.5.5.5"])
    XCTAssertEqual((dns["nameserver-policy"] as? [String: String])?["+.corp"], "system")
    XCTAssertEqual((dns["hosts"] as? [String: String])?["router.lan"], "192.168.1.1")
    XCTAssertEqual((dns["hosts"] as? [String: String])?["internal.test"], "10.0.0.2")
    XCTAssertNil(tun["auto-redirect"])
  }

  func testRuntimeConfigCanApplyTunDNSOverlayWithoutFakeIP() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    dns:
      enable: false
      enhanced-mode: redir-host
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true
    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dnsFakeIPEnabled: false,
      dns: TunDNSSettings(nameserver: ["1.1.1.1"])
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "redir-host")
    XCTAssertNil(dns["fake-ip-range"])
    XCTAssertEqual(dns["nameserver"] as? [String], ["1.1.1.1"])
  }

  func testRuntimeConfigRejectsInvalidTunRouteExcludeCIDRs() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    tun:
      enable: true
      route-exclude-address: [foo/24]
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN route exclude CIDR: foo/24"))
    }

    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: ["192.168.0.0/33"]
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN route exclude CIDR: 192.168.0.0/33"))
    }
  }

  func testRuntimeConfigRejectsInvalidTunDNSOverlay() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true
    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(nameserver: ["bad resolver"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS nameserver: bad resolver"))
    }

    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(
        nameserver: ["999.1.1.1"],
        fallback: ["ftp://dns.example/query"]
      )
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS nameserver: 999.1.1.1"))
    }

    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(nameserver: ["https://999.1.1.1/dns-query"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS nameserver: https://999.1.1.1/dns-query"))
    }

    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(fallback: ["ftp://dns.example/query"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS fallback: ftp://dns.example/query"))
    }
  }

  func testRuntimeConfigInjectsNetworkExtensionFakeIPDNS() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    dns:
      enable: false
      fake-ip-filter:
        - "*.corp"
    tun:
      enable: true
      auto-redirect: true
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = false

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: overrides,
      options: RuntimeConfigOptions(networkExtensionRoutingSettings: .default)
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["listen"] as? String, "127.0.0.1:1053")
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertNil(dns["use-hosts"])
    XCTAssertNil(dns["use-system-hosts"])
    XCTAssertEqual(dns["fake-ip-filter"] as? [String], ["*.corp"])
    XCTAssertEqual(tun["enable"] as? Bool, false)
    XCTAssertNil(tun["auto-redirect"])
  }

  func testRuntimeConfigCanLeaveNetworkExtensionDNSOnProfileDefaults() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    dns:
      enable: false
      enhanced-mode: redir-host
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.dnsEnabled = nil

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: overrides,
      options: RuntimeConfigOptions(
        networkExtensionRoutingSettings: NetworkExtensionRoutingSettings(
          dnsCaptureEnabled: false,
          dnsFakeIPEnabled: false
        )
      )
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, false)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "redir-host")
  }

  func testRuntimeConfigAppliesUnifiedDelayAndExternalControllerCORS() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    external-controller-cors:
      allow-origins: ["https://old.example"]
      allow-private-network: false
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.unifiedDelay = true
    overrides.externalControllerCORS = ExternalControllerCORSSettings(
      enabled: true,
      allowPrivateNetwork: true,
      allowedOrigins: [
        "https://custom.example",
        "https://yacd.metacubex.one"
      ]
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let cors = try XCTUnwrap(yaml["external-controller-cors"] as? [String: Any])

    XCTAssertEqual(yaml["unified-delay"] as? Bool, true)
    XCTAssertEqual(cors["allow-private-network"] as? Bool, true)
    XCTAssertEqual(
      cors["allow-origins"] as? [String],
      [
        "tauri://localhost",
        "http://tauri.localhost",
        "http://localhost:3000",
        "https://custom.example",
        "https://yacd.metacubex.one"
      ]
    )
  }

  func testRuntimeConfigRemovesExternalControllerCORSWhenDisabled() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    external-controller-cors:
      allow-origins: ["https://old.example"]
      allow-private-network: true
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.externalControllerCORS.enabled = false

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertNil(yaml["external-controller-cors"])
  }

  func testRuntimeConfigUsesSavedExternalControllerAddressAndSecret() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "ignored")
    overrides.externalControllerHost = "localhost"
    overrides.externalControllerPort = 19197
    overrides.secret = "saved-secret"
    overrides.externalControllerCORS = ExternalControllerCORSSettings(
      enabled: false,
      allowPrivateNetwork: false,
      allowedOrigins: ["https://yacd.metacubex.one"]
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(yaml["external-controller"] as? String, "localhost:19197")
    XCTAssertEqual(yaml["secret"] as? String, "saved-secret")
    XCTAssertNil(yaml["external-controller-cors"])
  }

  func testRuntimeConfigMaterializerWritesUniqueRuntimeAndProviderFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxRuntimeMaterializerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("source.txt")
    try """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#Provider%20Node
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let runtimeURL = root.appendingPathComponent("profile.runtime.yaml")
    let providerURL = root.appendingPathComponent("profile.provider.txt")
    let materializer = RuntimeConfigMaterializer()
    var firstOverrides = RuntimeOverrides.defaultForLaunch(secret: "first-secret")
    firstOverrides.mixedPort = 7891
    var secondOverrides = RuntimeOverrides.defaultForLaunch(secret: "second-secret")
    secondOverrides.mixedPort = 7892

    let firstURL = try await materializer.materialize(
      RuntimeConfigMaterializationRequest(
        profileName: "Provider",
        sourcePath: sourceURL.path,
        runtimeConfigURL: runtimeURL,
        providerContentURL: providerURL,
        overrides: firstOverrides,
        selectionOverrides: [:]
      )
    )
    let secondURL = try await materializer.materialize(
      RuntimeConfigMaterializationRequest(
        profileName: "Provider",
        sourcePath: sourceURL.path,
        runtimeConfigURL: runtimeURL,
        providerContentURL: providerURL,
        overrides: secondOverrides,
        selectionOverrides: [:]
      )
    )

    XCTAssertNotEqual(firstURL, secondURL)
    XCTAssertNotEqual(firstURL, runtimeURL)
    XCTAssertNotEqual(secondURL, runtimeURL)

    let firstYAML = try XCTUnwrap(Yams.load(yaml: String(contentsOf: firstURL, encoding: .utf8)) as? [String: Any])
    let secondYAML = try XCTUnwrap(Yams.load(yaml: String(contentsOf: secondURL, encoding: .utf8)) as? [String: Any])
    XCTAssertEqual(firstYAML["secret"] as? String, "first-secret")
    XCTAssertEqual(secondYAML["secret"] as? String, "second-secret")

    let firstProviders = try XCTUnwrap(firstYAML["proxy-providers"] as? [String: Any])
    let firstProvider = try XCTUnwrap(firstProviders["Provider"] as? [String: Any])
    let firstProviderPath = try XCTUnwrap(firstProvider["path"] as? String)
    XCTAssertNotEqual(firstProviderPath, providerURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstProviderPath))
    XCTAssertEqual(try posixPermissions(at: firstURL), SecureFileIO.privateFilePermissions)
    XCTAssertEqual(try posixPermissions(at: URL(fileURLWithPath: firstProviderPath)), SecureFileIO.privateFilePermissions)
  }

  func testURIProviderContentBuildsRuntimeConfigWithFileProvider() throws {
    let source = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#VLESS%20Node
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Hysteria2%20Node
    """

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/Users/test/Library/Application Support/ClashMax/Runtime/provider.txt",
      profileName: "Xboard",
      overrides: .defaultForLaunch(secret: "secret-token")
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let provider = try XCTUnwrap(providers["Xboard"] as? [String: Any])

    XCTAssertEqual(provider["type"] as? String, "file")
    XCTAssertEqual(provider["path"] as? String, "/Users/test/Library/Application Support/ClashMax/Runtime/provider.txt")
    XCTAssertNotNil(provider["health-check"])
    XCTAssertEqual(yaml["mixed-port"] as? Int, 7890)
    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
    XCTAssertEqual(yaml["secret"] as? String, "secret-token")

    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let proxyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Proxy" }))
    XCTAssertEqual(proxyGroup["type"] as? String, "select")
    XCTAssertEqual(proxyGroup["use"] as? [String], ["Xboard"])
    XCTAssertEqual(proxyGroup["proxies"] as? [String], ["Auto", "DIRECT"])
    XCTAssertEqual(yaml["rules"] as? [String], ["MATCH,Proxy"])
  }

  func testRuntimeConfigAppliesProviderContentSelectionOverride() throws {
    let source = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#Provider%20Node%20A
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Provider%20Node%20B
    """

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/Users/test/Library/Application Support/ClashMax/Runtime/provider.txt",
      profileName: "Sample Provider",
      overrides: .defaultForLaunch(secret: "secret-token"),
      selectionOverrides: ["Proxy": "Provider Node A"]
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let proxyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Proxy" }))

    XCTAssertEqual(proxyGroup["now"] as? String, "Provider Node A")
  }

  func testRuntimeConfigRejectsUnknownProviderContentSelectionOverride() throws {
    let source = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#Provider%20Node%20A
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Provider%20Node%20B
    """

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/Users/test/Library/Application Support/ClashMax/Runtime/provider.txt",
      profileName: "Sample Provider",
      overrides: .defaultForLaunch(secret: "secret-token"),
      selectionOverrides: ["Proxy": "Missing Provider Node"]
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let proxyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Proxy" }))

    XCTAssertNil(proxyGroup["now"])
  }

  func testRuntimeConfigAllowsSelectionOverrideForDynamicProviderUseGroup() throws {
    let source = """
    proxy-providers:
      Remote:
        type: http
        url: https://example.com/sub.yaml
        path: ./remote.yaml
    proxy-groups:
      - name: MainGroup
        type: select
        use: [Remote]
        proxies: [Auto, DIRECT]
      - name: Auto
        type: url-test
        use: [Remote]
    rules:
      - MATCH,MainGroup
    """

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: .defaultForLaunch(secret: "secret-token"),
      selectionOverrides: ["MainGroup": "Provider Node A"]
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let mainGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "MainGroup" }))
    let autoGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Auto" }))

    XCTAssertEqual(mainGroup["now"] as? String, "Provider Node A")
    XCTAssertNil(autoGroup["now"])
  }

  func testPreviewGroupsExtractXboardStyleInlineYaml() throws {
    let source = """
    mixed-port: 7890
    proxies:
        - { name: '[Hy2]HK Hysteria', server: example.com, port: 23006, skip-cert-verify: true, type: hysteria2, password: password }
        - { name: '[vless]JP Nano', type: vless, server: example.net, port: 443, uuid: 00000000-0000-0000-0000-000000000000, tls: true }
    proxy-groups:
        - { name: Elite, type: select, proxies: [自动选择, '[Hy2]HK Hysteria', '[vless]JP Nano'] }
        - { name: 自动选择, type: url-test, proxies: ['[Hy2]HK Hysteria', '[vless]JP Nano'], url: 'http://www.gstatic.com/generate_204', interval: 86400 }
    rules:
        - MATCH,Elite
    """

    let groups = try ProfilePreviewBuilder().groups(from: source, profileName: "Elite")

    XCTAssertEqual(groups.map(\.name), ["Elite", "自动选择"])
    XCTAssertEqual(groups.first?.nodes.map(\.name), ["自动选择", "[Hy2]HK Hysteria", "[vless]JP Nano"])
    XCTAssertEqual(groups.first?.nodes.map(\.type), ["url-test", "hysteria2", "vless"])
    XCTAssertNil(groups.first?.nodes[0].serverHost)
    XCTAssertEqual(groups.first?.nodes[1].serverHost, "example.com")
    XCTAssertEqual(groups.first?.nodes[1].serverPort, 23006)
    XCTAssertEqual(groups.first?.nodes[2].serverHost, "example.net")
    XCTAssertEqual(groups.first?.nodes[2].serverPort, 443)
  }

  func testPreviewGroupsExtractBase64URIProviderContent() throws {
    let source = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#VLESS%20Node
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Hysteria2%20Node
    """
    let encoded = Data(source.utf8).base64EncodedString()

    let groups = try ProfilePreviewBuilder().groups(from: encoded, profileName: "Xboard")

    XCTAssertEqual(groups.map(\.name), ["Proxy", "Auto"])
    XCTAssertEqual(groups.first?.nodes.map(\.name), ["Auto", "VLESS Node", "Hysteria2 Node", "DIRECT"])
    XCTAssertEqual(groups.first?.nodes.map(\.type), ["url-test", "vless", "hysteria2", "direct"])
    XCTAssertEqual(groups.first?.nodes[1].serverHost, "example.com")
    XCTAssertEqual(groups.first?.nodes[1].serverPort, 443)
    XCTAssertEqual(groups.first?.nodes[2].serverHost, "example.net")
    XCTAssertEqual(groups.first?.nodes[2].serverPort, 8443)
  }

  private func posixPermissions(at url: URL) throws -> Int {
    let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
  }
}
