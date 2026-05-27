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
      ipv6Enabled: true,
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
    XCTAssertEqual(yaml["ipv6"] as? Bool, true)
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
    XCTAssertEqual(dns["ipv6"] as? Bool, true)
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
      nameserver-policy:
        "+.existing-array":
          - https://1.1.1.1/dns-query
          - tls://8.8.8.8
        "+.existing-string": 8.8.4.4
      proxy-server-nameserver-policy:
        "proxy.example.com":
          - 114.114.114.114
          - tls://1.1.1.1
      fallback-filter:
        geoip: false
        geosite: [category-ads-all]
        ipcidr: [10.0.0.0/8]
        domain: ["+.facebook.com"]
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
        preferH3: false,
        useHosts: false,
        useSystemHosts: true,
        respectRules: true,
        fakeIPFilter: ["*.corp", "*.lan"],
        defaultNameserver: ["223.5.5.5"],
        nameserver: ["8.8.8.8", "https://dns.example/dns-query"],
        fallback: ["1.1.1.1"],
        proxyServerNameserver: ["9.9.9.9"],
        directNameserver: ["223.5.5.5"],
        directNameserverFollowPolicy: true,
        nameserverPolicy: ["+.corp": "system"],
        proxyServerNameserverPolicy: ["www.yournode.com": "114.114.114.114"],
        hosts: ["internal.test": "10.0.0.2"],
        fallbackFilter: TunDNSFallbackFilter(
          geoIP: true,
          geoIPCode: "CN",
          geoSite: ["gfw"],
          ipCIDR: ["240.0.0.0/4"],
          domain: ["+.google.com"]
        )
      )
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["prefer-h3"] as? Bool, false)
    XCTAssertEqual(dns["use-hosts"] as? Bool, false)
    XCTAssertEqual(dns["use-system-hosts"] as? Bool, true)
    XCTAssertEqual(dns["respect-rules"] as? Bool, true)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(dns["fake-ip-filter"] as? [String], ["*.corp", "*.lan"])
    XCTAssertEqual(dns["default-nameserver"] as? [String], ["223.5.5.5"])
    XCTAssertEqual(dns["nameserver"] as? [String], ["8.8.8.8", "https://dns.example/dns-query"])
    XCTAssertEqual(dns["fallback"] as? [String], ["1.1.1.1"])
    XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["9.9.9.9"])
    XCTAssertEqual(dns["direct-nameserver"] as? [String], ["223.5.5.5"])
    XCTAssertEqual(dns["direct-nameserver-follow-policy"] as? Bool, true)
    let nameserverPolicy = try XCTUnwrap(dns["nameserver-policy"] as? [String: Any])
    XCTAssertEqual(nameserverPolicy["+.existing-array"] as? [String], ["https://1.1.1.1/dns-query", "tls://8.8.8.8"])
    XCTAssertEqual(nameserverPolicy["+.existing-string"] as? String, "8.8.4.4")
    XCTAssertEqual(nameserverPolicy["+.corp"] as? String, "system")
    let proxyServerNameserverPolicy = try XCTUnwrap(dns["proxy-server-nameserver-policy"] as? [String: Any])
    XCTAssertEqual(proxyServerNameserverPolicy["proxy.example.com"] as? [String], ["114.114.114.114", "tls://1.1.1.1"])
    XCTAssertEqual(proxyServerNameserverPolicy["www.yournode.com"] as? String, "114.114.114.114")
    XCTAssertEqual((dns["hosts"] as? [String: String])?["router.lan"], "192.168.1.1")
    XCTAssertEqual((dns["hosts"] as? [String: String])?["internal.test"], "10.0.0.2")
    let fallbackFilter = try XCTUnwrap(dns["fallback-filter"] as? [String: Any])
    XCTAssertEqual(fallbackFilter["geoip"] as? Bool, true)
    XCTAssertEqual(fallbackFilter["geoip-code"] as? String, "CN")
    XCTAssertEqual(fallbackFilter["geosite"] as? [String], ["category-ads-all", "gfw"])
    XCTAssertEqual(fallbackFilter["ipcidr"] as? [String], ["10.0.0.0/8", "240.0.0.0/4"])
    XCTAssertEqual(fallbackFilter["domain"] as? [String], ["+.facebook.com", "+.google.com"])
    XCTAssertNil(tun["auto-redirect"])
  }

  func testTunDNSSettingsDecodeLegacyDefaultsForAdvancedFields() throws {
    let decoded = try JSONDecoder().decode(TunDNSSettings.self, from: Data("{}".utf8))

    XCTAssertNil(decoded.preferH3)
    XCTAssertNil(decoded.useHosts)
    XCTAssertNil(decoded.useSystemHosts)
    XCTAssertNil(decoded.respectRules)
    XCTAssertTrue(decoded.defaultNameserver.isEmpty)
    XCTAssertNil(decoded.directNameserverFollowPolicy)
    XCTAssertTrue(decoded.proxyServerNameserverPolicy.isEmpty)
    XCTAssertTrue(decoded.fallbackFilter.isEmpty)
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

    overrides.tunSettings = TunSettings(
      stack: .mixed,
      device: "utun1024",
      autoRoute: true,
      strictRoute: false,
      autoDetectInterface: true,
      dnsHijack: ["any:53"],
      mtu: 1500,
      routeExcludeAddresses: [],
      dns: TunDNSSettings(defaultNameserver: ["bad resolver"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS default-nameserver: bad resolver"))
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
      dns: TunDNSSettings(defaultNameserver: ["https://dns.alidns.com/dns-query"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS default-nameserver: https://dns.alidns.com/dns-query"))
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
      dns: TunDNSSettings(proxyServerNameserverPolicy: ["+.corp": "bad resolver"])
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN proxy-server-nameserver policy: +.corp=bad resolver"))
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
      dns: TunDNSSettings(fallbackFilter: TunDNSFallbackFilter(ipCIDR: ["240.0.0.0/33"]))
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS fallback ipcidr: 240.0.0.0/33"))
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
      dns: TunDNSSettings(fallbackFilter: TunDNSFallbackFilter(domain: ["bad domain"]))
    )

    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "proxies:\n  - name: DIRECT\n    type: direct", overrides: overrides)) { error in
      XCTAssertTrue(String(describing: error).contains("Invalid TUN DNS fallback domain: bad domain"))
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

  func testRuntimeConfigNormalizesLegacyExternalControllerHostAndPreservesPortSecret() throws {
    let source = """
    proxies:
      - name: DIRECT
        type: direct
    """
    for staleHost in ["localhost", "::1"] {
      var overrides = RuntimeOverrides.defaultForLaunch(secret: "ignored")
      overrides.externalControllerHost = staleHost
      overrides.externalControllerPort = 19197
      overrides.secret = "saved-secret"
      overrides.externalControllerCORS = ExternalControllerCORSSettings(
        enabled: false,
        allowPrivateNetwork: false,
        allowedOrigins: ["https://yacd.metacubex.one"]
      )

      let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
      let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

      XCTAssertEqual(overrides.externalControllerHost, "127.0.0.1")
      XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:19197")
      XCTAssertEqual(yaml["secret"] as? String, "saved-secret")
      XCTAssertNil(yaml["external-controller-cors"])
    }
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
    let firstProvider = try XCTUnwrap(firstProviders["clashmax-subscription-provider"] as? [String: Any])
    let firstProviderPath = try XCTUnwrap(firstProvider["path"] as? String)
    XCTAssertNotEqual(firstProviderPath, providerURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstProviderPath))
    XCTAssertEqual(try posixPermissions(at: firstURL), SecureFileIO.privateFilePermissions)
    XCTAssertEqual(try posixPermissions(at: URL(fileURLWithPath: firstProviderPath)), SecureFileIO.privateFilePermissions)
  }

  func testRuntimeConfigMaterializerRetainsProtectedActiveAndNewestGenerations() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxRuntimeRetentionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("source.txt")
    try """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#Provider%20Node
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let runtimeURL = root.appendingPathComponent("profile.runtime.yaml")
    let providerURL = root.appendingPathComponent("profile.provider.txt")
    let unmanagedURLs = [
      runtimeURL,
      providerURL,
      root.appendingPathComponent("profile.runtime.not-a-uuid.yaml"),
      root.appendingPathComponent("profile.provider.not-a-uuid.txt"),
      root.appendingPathComponent(".profile.runtime.\(UUID().uuidString).yaml.tmp"),
      root.appendingPathComponent("other-profile.runtime.\(UUID().uuidString).yaml")
    ]
    for url in unmanagedURLs {
      try "unmanaged".write(to: url, atomically: true, encoding: .utf8)
    }

    let materializer = RuntimeConfigMaterializer()
    var results: [RuntimeConfigMaterializationResult] = []
    for index in 0..<5 {
      var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-\(index)")
      overrides.mixedPort = 7890 + index
      let protectedURLs = results.first?.artifactURLs ?? []
      let result = try await materializer.materializeResult(
        RuntimeConfigMaterializationRequest(
          profileName: "Provider",
          sourcePath: sourceURL.path,
          runtimeConfigURL: runtimeURL,
          providerContentURL: providerURL,
          overrides: overrides,
          selectionOverrides: [:],
          protectedArtifactURLs: protectedURLs,
          retainedGenerationCount: 2
        )
      )
      try setModificationDate(Date(timeIntervalSince1970: TimeInterval(index + 1)), for: result.artifactURLs)
      results.append(result)
    }

    let retainedResults = [results[0], results[3], results[4]]
    for result in retainedResults {
      XCTAssertTrue(FileManager.default.fileExists(atPath: result.runtimeConfigURL.path))
      let providerContentURL = try XCTUnwrap(result.providerContentURL)
      XCTAssertTrue(FileManager.default.fileExists(atPath: providerContentURL.path))
      XCTAssertEqual(try posixPermissions(at: result.runtimeConfigURL), SecureFileIO.privateFilePermissions)
      XCTAssertEqual(try posixPermissions(at: providerContentURL), SecureFileIO.privateFilePermissions)
      XCTAssertEqual(try providerContentPath(in: result.runtimeConfigURL), providerContentURL.path)
    }

    for result in [results[1], results[2]] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: result.runtimeConfigURL.path))
      if let providerContentURL = result.providerContentURL {
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerContentURL.path))
      }
    }
    for url in unmanagedURLs {
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) should not be removed")
    }
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
    let provider = try XCTUnwrap(providers["clashmax-subscription-provider"] as? [String: Any])

    XCTAssertEqual(provider["type"] as? String, "file")
    XCTAssertEqual(provider["path"] as? String, "/Users/test/Library/Application Support/ClashMax/Runtime/provider.txt")
    XCTAssertNotNil(provider["health-check"])
    XCTAssertEqual(yaml["mixed-port"] as? Int, 7890)
    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
    XCTAssertEqual(yaml["secret"] as? String, "secret-token")

    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let proxyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Proxy" }))
    XCTAssertEqual(proxyGroup["type"] as? String, "select")
    XCTAssertEqual(proxyGroup["use"] as? [String], ["clashmax-subscription-provider"])
    XCTAssertEqual(proxyGroup["proxies"] as? [String], ["Auto", "DIRECT"])
    XCTAssertEqual(yaml["rules"] as? [String], ["MATCH,Proxy"])
  }

  func testSubscriptionProviderOptionsDecodeMissingTemplateVersionAsLegacyV1() throws {
    let decoded = try JSONDecoder().decode(SubscriptionProviderOptions.self, from: Data("""
    {
      "intervalSeconds": 300,
      "generatedTemplate": "minimal"
    }
    """.utf8))

    XCTAssertEqual(decoded.generatedTemplateVersion, 1)
    XCTAssertEqual(SubscriptionProviderOptions.default.generatedTemplateVersion, 2)
    XCTAssertTrue(SubscriptionTemplateKind.minimal.versionSummary(version: 2).contains("v2"))
  }

  func testProviderBackedLegacyV1DoesNotEmitDNS() throws {
    let source = "trojan://password@example.com:443#Trojan\n"
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(generatedTemplateVersion: 1)

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertNil(yaml["dns"])
  }

  func testProviderBackedV2EmitsDNSBase() throws {
    let source = "trojan://password@example.com:443#Trojan\n"

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: .defaultForLaunch(secret: "secret-token")
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let fallbackFilter = try XCTUnwrap(dns["fallback-filter"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, true)
    XCTAssertEqual(dns["ipv6"] as? Bool, false)
    XCTAssertEqual(dns["respect-rules"] as? Bool, true)
    XCTAssertEqual(dns["use-system-hosts"] as? Bool, true)
    XCTAssertEqual(dns["enhanced-mode"] as? String, "fake-ip")
    XCTAssertEqual(dns["fake-ip-range"] as? String, "198.18.0.1/16")
    XCTAssertEqual(dns["default-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
    XCTAssertEqual(dns["nameserver"] as? [String], ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"])
    XCTAssertEqual(dns["fallback"] as? [String], ["tls://8.8.4.4", "tls://1.1.1.1"])
    XCTAssertEqual(fallbackFilter["geoip"] as? Bool, true)
    XCTAssertEqual(fallbackFilter["geoip-code"] as? String, "CN")
  }

  func testProviderBackedV2DNSCanBeOverriddenByRuntimeSettings() throws {
    let source = "trojan://password@example.com:443#Trojan\n"
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.dnsEnabled = false
    overrides.ipv6Enabled = true

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: overrides
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])

    XCTAssertEqual(dns["enable"] as? Bool, false)
    XCTAssertEqual(dns["ipv6"] as? Bool, true)
  }

  func testProviderOptionsGuardrailMarksDangerousYAMLKeys() throws {
    let options = SubscriptionProviderOptions(
      overrideYAML: """
      dns:
        enable: true
      """,
      runtimeMergeYAML: """
      external-controller: 0.0.0.0:9090
      secret: leaked
      mixed-port: 7899
      tun:
        enable: true
      listeners: []
      """
    )

    let report = SubscriptionProviderOptionsGuardrailReport.analyze(options: options)
    let keyPaths = Set(report.risks.map(\.keyPath))

    XCTAssertTrue(keyPaths.contains("dns"))
    XCTAssertTrue(keyPaths.contains("external-controller"))
    XCTAssertTrue(keyPaths.contains("secret"))
    XCTAssertTrue(keyPaths.contains("mixed-port"))
    XCTAssertTrue(keyPaths.contains("tun"))
    XCTAssertTrue(keyPaths.contains("listeners"))
    XCTAssertTrue(report.hasDangerousRisks)
    XCTAssertTrue(report.runtimeDiff.contains { $0.isAdvanced && $0.before != $0.after })
  }

  func testURIProviderContentAcceptsMihomo11925SchemesAndUnknownURIs() throws {
    XCTAssertEqual(
      try ProfileConfigInspector.format(of: "tailscale://tag@example.com:443#Tail\n"),
      .proxyProviderContent
    )
    XCTAssertEqual(
      try ProfileConfigInspector.format(of: "openvpn://profile@example.com:1194#OVPN\n"),
      .proxyProviderContent
    )
    XCTAssertEqual(
      try ProfileConfigInspector.format(of: "futureproxy://token@example.com:443#Future\n"),
      .proxyProviderContent
    )
  }

  func testURIProviderContentWritesAppManagedProviderOptions() throws {
    let source = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(
      intervalSeconds: 600,
      filter: "HK|JP",
      excludeFilter: "expired",
      excludeType: "direct",
      overrideYAML: """
      additional-prefix: "[CM] "
      udp: true
      """,
      requestHeaders: [SubscriptionRequestHeader(name: "Authorization", value: "Bearer secret")],
      fetchProxy: .localClashProxy
    )

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let provider = try XCTUnwrap(providers["clashmax-subscription-provider"] as? [String: Any])
    let override = try XCTUnwrap(provider["override"] as? [String: Any])

    XCTAssertEqual(provider["interval"] as? Int, 600)
    XCTAssertEqual(provider["filter"] as? String, "HK|JP")
    XCTAssertEqual(provider["exclude-filter"] as? String, "expired")
    XCTAssertEqual(provider["exclude-type"] as? String, "direct")
    XCTAssertEqual(override["additional-prefix"] as? String, "[CM] ")
    XCTAssertEqual(override["udp"] as? Bool, true)
    XCTAssertNil(provider["header"])
    XCTAssertNil(provider["proxy"])
  }

  func testURIProviderContentCanCustomizeGeneratedGroupsAndFinalPolicy() throws {
    let source = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(
      primaryGroupName: "Manual",
      autoGroupName: "Latency",
      finalRulePolicy: "Manual"
    )

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let manualGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Manual" }))
    let latencyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Latency" }))

    XCTAssertEqual(manualGroup["type"] as? String, "select")
    XCTAssertEqual(manualGroup["proxies"] as? [String], ["Latency", "DIRECT"])
    XCTAssertEqual(latencyGroup["type"] as? String, "url-test")
    XCTAssertEqual(yaml["rules"] as? [String], ["MATCH,Manual"])
  }

  func testProviderContentClassifierDistinguishesRuntimeKinds() throws {
    let shareLinks = "trojan://password@example.com:443#Trojan\nvless://uuid@example.net:443#VLESS\n"
    let encodedLinks = Data(shareLinks.utf8).base64EncodedString()

    XCTAssertEqual(
      try ProfileConfigInspector.contentKind(of: """
      proxies:
        - name: DIRECT
          type: direct
      proxy-groups:
        - name: Proxy
          type: select
          proxies: [DIRECT]
      rules:
        - MATCH,DIRECT
      """
      ),
      .clashConfig
    )
    XCTAssertEqual(
      try ProfileConfigInspector.contentKind(of: "proxies:\n  - name: DIRECT\n    type: direct\n"),
      .proxyProviderContent
    )
    XCTAssertEqual(try ProfileConfigInspector.contentKind(of: shareLinks), .shareLinkList)
    XCTAssertEqual(try ProfileConfigInspector.contentKind(of: encodedLinks), .base64ShareLinkList)
  }

  func testCNDirectTemplateWritesDirectRulesBeforeMatchForProviderContent() throws {
    let source = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(generatedTemplate: .cnDirect)

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "DOMAIN-SUFFIX,local,DIRECT",
        "GEOSITE,private,DIRECT",
        "GEOIP,private,DIRECT,no-resolve",
        "GEOSITE,cn,DIRECT",
        "GEOIP,CN,DIRECT,no-resolve",
        "MATCH,Proxy"
      ]
    )
  }

  func testURIProviderContentUsesInternalProviderNameWhenProfileNameMatchesGroups() throws {
    let source = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      providerContentPath: "/tmp/provider.txt",
      profileName: "Proxy",
      overrides: .defaultForLaunch(secret: "secret-token")
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let proxyGroup = try XCTUnwrap(groups.first(where: { ($0["name"] as? String) == "Proxy" }))

    XCTAssertNil(providers["Proxy"])
    XCTAssertNotNil(providers["clashmax-subscription-provider"])
    XCTAssertEqual(proxyGroup["use"] as? [String], ["clashmax-subscription-provider"])
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

  func testRuntimeConfigMaterializesAdvancedYAMLWithoutDroppingProviderFields() throws {
    let source = """
    proxy-providers:
      BaseProvider: &baseProvider
        type: http
        url: https://example.com/sub.yaml
        path: ./base.yaml
        interval: 3600
        header:
          User-Agent: clash.meta
        filter: "HK|JP"
        exclude-filter: "expired"
        exclude-type: "direct"
        override:
          udp: true
          additional-prefix: "[Remote] "
        payload:
          - { name: Future Node, type: future-proxy, server: future.example, port: 443 }
      Remote:
        <<: *baseProvider
        path: ./remote.yaml
    proxy-groups:
      - name: Main
        type: select
        use: [Remote]
    rules:
      - MATCH,Main
    """

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: .defaultForLaunch(secret: "secret-token"))
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let remote = try XCTUnwrap(providers["Remote"] as? [String: Any])
    let header = try XCTUnwrap(remote["header"] as? [String: Any])
    let override = try XCTUnwrap(remote["override"] as? [String: Any])
    let payload = try XCTUnwrap(remote["payload"] as? [[String: Any]])

    XCTAssertEqual(remote["filter"] as? String, "HK|JP")
    XCTAssertEqual(remote["exclude-filter"] as? String, "expired")
    XCTAssertEqual(remote["exclude-type"] as? String, "direct")
    XCTAssertEqual(header["User-Agent"] as? String, "clash.meta")
    XCTAssertEqual(override["udp"] as? Bool, true)
    XCTAssertEqual(payload.first?["type"] as? String, "future-proxy")
  }

  func testRuntimeConfigAppliesTypedRuleOverlayWithoutMutatingSourceRules() throws {
    let source = """
    mixed-port: 7890
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - DOMAIN-SUFFIX,example.org,Proxy
      - MATCH,DIRECT
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "corp.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .match, policy: "Proxy")
      ]
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "DOMAIN-SUFFIX,corp.example,DIRECT",
        "DOMAIN-SUFFIX,example.org,Proxy",
        "MATCH,DIRECT",
        "MATCH,Proxy"
      ]
    )
    XCTAssertTrue(source.contains("DOMAIN-SUFFIX,example.org,Proxy"))
    XCTAssertFalse(source.contains("corp.example"))
  }

  func testRuntimeConfigRendersFocusedManagedRuleTypes() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - MATCH,DIRECT
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .ruleSet, value: "RemoteRules", policy: "Proxy"),
        ManagedRuleOverlayRule(kind: .subRule, value: "NETWORK,tcp", policy: "tcp-sub"),
        ManagedRuleOverlayRule(kind: .srcGeoIP, value: "CN", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .srcIPASN, value: "9808", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .srcIPCIDR, value: "192.168.1.0/24", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .srcIPSuffix, value: "192.168.1.1/24", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .dstPort, value: "443", policy: "Proxy"),
        ManagedRuleOverlayRule(kind: .srcPort, value: "50000-50100", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .inPort, value: "7890", policy: "Proxy")
      ]
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "RULE-SET,RemoteRules,Proxy",
        "SUB-RULE,(NETWORK,tcp),tcp-sub",
        "SRC-GEOIP,CN,DIRECT",
        "SRC-IP-ASN,9808,DIRECT",
        "SRC-IP-CIDR,192.168.1.0/24,DIRECT",
        "SRC-IP-SUFFIX,192.168.1.1/24,DIRECT",
        "DST-PORT,443,Proxy",
        "SRC-PORT,50000-50100,DIRECT",
        "IN-PORT,7890,Proxy",
        "MATCH,DIRECT"
      ]
    )
    XCTAssertFalse(source.contains("RemoteRules"))
  }

  func testRuntimeConfigRejectsInvalidFocusedRuleValues() throws {
    var invalidCIDR = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    invalidCIDR.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .srcIPCIDR, value: "192.168.1.1", policy: "DIRECT")
      ]
    )
    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: invalidCIDR
      )
    ) { error in
      XCTAssertEqual(String(describing: error), String(localized: "Source IP CIDR must be a valid CIDR range."))
    }

    var invalidPort = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    invalidPort.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .dstPort, value: "70000", policy: "Proxy")
      ]
    )
    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: invalidPort
      )
    ) { error in
      XCTAssertEqual(
        String(describing: error),
        String(localized: "Port rule value must be a port or range between 1 and 65535.")
      )
    }

    var invalidSubRule = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    invalidSubRule.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .subRule, value: "DOMAIN,example.com", policy: "sub")
      ]
    )
    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: invalidSubRule
      )
    ) { error in
      XCTAssertEqual(String(describing: error), String(localized: "Sub-rule condition must be NETWORK,tcp or NETWORK,udp."))
    }
  }

  func testRuntimeConfigCanDisableProfileRulesBeforeAddingManagedRules() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - DOMAIN-SUFFIX,ads.example,REJECT
      - DOMAIN-SUFFIX,corp.example,Proxy
      - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
      - MATCH,DIRECT
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "trusted.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .match, policy: "Proxy")
      ],
      disabledRuleMatchers: [
        ManagedRuleDisableMatcher(mode: .contains, pattern: "ads.example"),
        ManagedRuleDisableMatcher(mode: .exact, pattern: "MATCH,DIRECT"),
        ManagedRuleDisableMatcher(mode: .regex, pattern: #"IP-CIDR,10\."#)
      ]
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "DOMAIN-SUFFIX,trusted.example,DIRECT",
        "DOMAIN-SUFFIX,corp.example,Proxy",
        "MATCH,Proxy"
      ]
    )
    XCTAssertTrue(source.contains("DOMAIN-SUFFIX,ads.example,REJECT"))
  }

  func testRuntimeConfigCombinesGlobalAndProfileRuleOverlays() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - DOMAIN-SUFFIX,ads.example,REJECT
      - DOMAIN-SUFFIX,corp.example,Proxy
      - MATCH,DIRECT
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "global.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "global-after.example", policy: "Proxy")
      ],
      disabledRuleMatchers: [
        ManagedRuleDisableMatcher(mode: .contains, pattern: "ads.example")
      ]
    )
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(
      ruleOverlay: RuleOverlaySettings(
        enabled: true,
        prependRules: [
          ManagedRuleOverlayRule(kind: .domainSuffix, value: "profile.example", policy: "DIRECT")
        ],
        appendRules: [
          ManagedRuleOverlayRule(kind: .match, policy: "Proxy")
        ],
        disabledRuleMatchers: [
          ManagedRuleDisableMatcher(mode: .exact, pattern: "MATCH,DIRECT")
        ]
      )
    )

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides, options: options)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "DOMAIN-SUFFIX,global.example,DIRECT",
        "DOMAIN-SUFFIX,profile.example,DIRECT",
        "DOMAIN-SUFFIX,corp.example,Proxy",
        "MATCH,Proxy",
        "DOMAIN-SUFFIX,global-after.example,Proxy"
      ]
    )
  }

  func testRuntimeConfigAppliesEnabledRuntimeSnippetsInOrder() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    dns:
      nameserver:
        - https://existing.example/dns-query
    rules:
      - DOMAIN-SUFFIX,ads.example,REJECT
      - MATCH,DIRECT
    """
    var options = RuntimeConfigOptions.default
    options.runtimeSnippets = [
      RuntimeSnippet(
        name: "Disabled",
        enabled: false,
        payload: .rules(
          RuleOverlaySettings(
            enabled: true,
            prependRules: [
              ManagedRuleOverlayRule(kind: .domainSuffix, value: "disabled.example", policy: "DIRECT")
            ]
          )
        )
      ),
      RuntimeSnippet(
        name: "DNS",
        payload: .dnsPatch(
          TunDNSSettings(
            fakeIPFilter: ["*.local"],
            nameserver: ["https://dns.example/dns-query"]
          )
        )
      ),
      RuntimeSnippet(
        name: "Rules A",
        payload: .rules(
          RuleOverlaySettings(
            enabled: true,
            prependRules: [
              ManagedRuleOverlayRule(kind: .domainSuffix, value: "a.example", policy: "DIRECT")
            ],
            appendRules: [
              ManagedRuleOverlayRule(kind: .match, policy: "Proxy")
            ],
            disabledRuleMatchers: [
              ManagedRuleDisableMatcher(mode: .contains, pattern: "ads.example")
            ]
          )
        )
      ),
      RuntimeSnippet(
        name: "Rules B",
        payload: .rules(
          RuleOverlaySettings(
            enabled: true,
            prependRules: [
              ManagedRuleOverlayRule(kind: .domainSuffix, value: "b.example", policy: "Proxy")
            ]
          )
        )
      )
    ]

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])

    XCTAssertEqual(
      yaml["rules"] as? [String],
      [
        "DOMAIN-SUFFIX,a.example,DIRECT",
        "DOMAIN-SUFFIX,b.example,Proxy",
        "MATCH,DIRECT",
        "MATCH,Proxy"
      ]
    )
    XCTAssertEqual(dns["nameserver"] as? [String], ["https://existing.example/dns-query", "https://dns.example/dns-query"])
    XCTAssertEqual(dns["fake-ip-filter"] as? [String], ["*.local"])
  }

  func testRuntimeConfigKeepsAppManagedLaunchSettingsAfterRuntimeSnippets() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    tun:
      enable: false
      auto-redirect: true
    rules:
      - MATCH,DIRECT
    """
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.tunEnabled = true
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(
      runtimeMergeYAML: """
      external-controller: 0.0.0.0:9999
      secret: leaked
      tun:
        auto-redirect: true
      dns:
        listen: 0.0.0.0:53
      """
    )
    options.runtimeSnippets = [
      RuntimeSnippet(
        name: "DNS Patch",
        payload: .dnsPatch(
          TunDNSSettings(
            respectRules: true,
            nameserver: ["https://dns.example/dns-query"]
          )
        )
      )
    ]

    let output = try ConfigNormalizer().runtimeConfig(from: source, overrides: overrides, options: options)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let dns = try XCTUnwrap(yaml["dns"] as? [String: Any])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
    XCTAssertEqual(yaml["secret"] as? String, "secret-token")
    XCTAssertEqual(tun["enable"] as? Bool, true)
    XCTAssertNil(tun["auto-redirect"])
    XCTAssertEqual(
      dns["nameserver"] as? [String],
      ["https://dns.example/dns-query", "https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"]
    )
    XCTAssertEqual(dns["respect-rules"] as? Bool, true)
  }

  func testRuntimeSnippetYAMLPatchParserAcceptsOnlyDNSWhitelist() throws {
    let settings = try RuntimeSnippetYAMLPatchParser.dnsPatch(
      from: """
      dns:
        respect-rules: true
        use-system-hosts: false
        fake-ip-filter:
          - "*.local"
        nameserver:
          - https://dns.example/dns-query
        nameserver-policy:
          "+.corp.example": https://corp.example/dns-query
        hosts:
          printer.local: 192.168.1.50
        fallback-filter:
          geoip: true
          geoip-code: CN
          domain:
            - "+.blocked.example"
      """
    )

    XCTAssertEqual(settings.respectRules, true)
    XCTAssertEqual(settings.useSystemHosts, false)
    XCTAssertEqual(settings.fakeIPFilter, ["*.local"])
    XCTAssertEqual(settings.nameserver, ["https://dns.example/dns-query"])
    XCTAssertEqual(settings.nameserverPolicy["+.corp.example"], "https://corp.example/dns-query")
    XCTAssertEqual(settings.hosts["printer.local"], "192.168.1.50")
    XCTAssertEqual(settings.fallbackFilter.geoIP, true)
    XCTAssertEqual(settings.fallbackFilter.geoIPCode, "CN")

    for unsafePatch in [
      "script: {}\n",
      "listeners: []\n",
      "mixed-port: 9999\n",
      "proxies: []\n",
      "proxy-groups: []\n",
      "tun:\n  enable: true\n",
      "dns:\n  listen: 0.0.0.0:53\n",
      "dns:\n  fallback-filter:\n    script: true\n"
    ] {
      XCTAssertThrowsError(try RuntimeSnippetYAMLPatchParser.dnsPatch(from: unsafePatch))
    }
  }

  func testRuntimeConfigAppliesSubscriptionRuntimeMergeBeforeAppOverrides() throws {
    let source = """
    proxies:
      - name: Direct
        type: direct
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Direct, DIRECT]
    rules:
      - MATCH,DIRECT
    tun:
      enable: false
      auto-redirect: true
    """
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(
      runtimeMergeYAML: """
      external-controller: 0.0.0.0:9999
      secret: leaked
      proxies:
        - name: Runtime Proxy
          type: http
          server: runtime.example
          port: 8080
      proxy-groups:
        - name: Runtime Select
          type: select
          proxies: [Runtime Proxy, DIRECT]
      rules:
        - DOMAIN-SUFFIX,merge.example,Runtime Select
      tun:
        auto-redirect: true
      """
    )

    let output = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: .defaultForLaunch(secret: "secret-token"),
      options: options
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let proxies = try XCTUnwrap(yaml["proxies"] as? [[String: Any]])
    let groups = try XCTUnwrap(yaml["proxy-groups"] as? [[String: Any]])
    let tun = try XCTUnwrap(yaml["tun"] as? [String: Any])

    XCTAssertEqual(yaml["external-controller"] as? String, "127.0.0.1:9097")
    XCTAssertEqual(yaml["secret"] as? String, "secret-token")
    XCTAssertTrue(proxies.contains { $0["name"] as? String == "Direct" })
    XCTAssertTrue(proxies.contains { $0["name"] as? String == "Runtime Proxy" })
    XCTAssertTrue(groups.contains { $0["name"] as? String == "Proxy" })
    XCTAssertTrue(groups.contains { $0["name"] as? String == "Runtime Select" })
    XCTAssertEqual(yaml["rules"] as? [String], ["MATCH,DIRECT", "DOMAIN-SUFFIX,merge.example,Runtime Select"])
    XCTAssertNil(tun["auto-redirect"])
  }

  func testRuntimeConfigRejectsInvalidSubscriptionRuntimeMerge() throws {
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = SubscriptionProviderOptions(runtimeMergeYAML: "proxies: [")

    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: .defaultForLaunch(secret: "secret-token"),
        options: options
      )
    ) { error in
      XCTAssertTrue(String(describing: error).contains("Runtime merge YAML parse error"))
    }
  }

  func testRuntimeConfigRejectsInvalidRuleOverlay() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "bad,example", policy: "DIRECT")
      ]
    )

    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: overrides
      )
    ) { error in
      XCTAssertEqual(
        String(describing: error),
        String(localized: "Rule value cannot contain commas or line breaks.")
      )
    }
  }

  func testRuntimeConfigRejectsInvalidDisabledRuleMatcher() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.ruleOverlay = RuleOverlaySettings(
      enabled: true,
      disabledRuleMatchers: [
        ManagedRuleDisableMatcher(mode: .regex, pattern: "[")
      ]
    )

    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "proxies: []\nproxy-groups: []\nrules: []\n",
        overrides: overrides
      )
    ) { error in
      XCTAssertEqual(
        String(describing: error),
        String(localized: "Disabled rule regex is invalid.")
      )
    }
  }

  func testRuleMatchSimulatorUsesRuleOrderBeforeMatchFallback() throws {
    let rules = [
      RuntimeRule(index: 1, type: "DOMAIN-SUFFIX", payload: "example.com", policy: "DIRECT"),
      RuntimeRule(index: 2, type: "DOMAIN-KEYWORD", payload: "example", policy: "Proxy"),
      RuntimeRule(index: 3, type: "MATCH", payload: "", policy: "Proxy")
    ]

    let outcome = RuleMatchSimulator().simulate(target: "api.example.com", rules: rules)

    guard case let .matched(rule) = outcome else {
      return XCTFail("Expected local rule match, got \(outcome)")
    }
    XCTAssertEqual(rule.index, 1)
    XCTAssertEqual(rule.policy, "DIRECT")
  }

  func testRuleMatchSimulatorMatchesIPCIDRNetworks() throws {
    let rules = [
      RuntimeRule(index: 1, type: "IP-CIDR", payload: "10.0.0.0/8", policy: "DIRECT"),
      RuntimeRule(index: 2, type: "IP-CIDR6", payload: "fd00::/8", policy: "DIRECT"),
      RuntimeRule(index: 3, type: "MATCH", payload: "", policy: "Proxy")
    ]

    let ipv4Outcome = RuleMatchSimulator().simulate(target: "10.1.2.3", rules: rules)
    let ipv6Outcome = RuleMatchSimulator().simulate(target: "fd12::1", rules: rules)
    let missOutcome = RuleMatchSimulator().simulate(target: "11.1.2.3", rules: rules)

    guard case let .matched(ipv4Rule) = ipv4Outcome else {
      return XCTFail("Expected IPv4 CIDR rule match, got \(ipv4Outcome)")
    }
    guard case let .matched(ipv6Rule) = ipv6Outcome else {
      return XCTFail("Expected IPv6 CIDR rule match, got \(ipv6Outcome)")
    }
    guard case let .matched(missRule) = missOutcome else {
      return XCTFail("Expected fallback rule match, got \(missOutcome)")
    }
    XCTAssertEqual(ipv4Rule.index, 1)
    XCTAssertEqual(ipv6Rule.index, 2)
    XCTAssertEqual(missRule.index, 3)
  }

  func testRuleMatchSimulatorSupportsProcessRules() throws {
    let rules = [
      RuntimeRule(index: 1, type: "PROCESS-NAME", payload: "Safari", policy: "DIRECT"),
      RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Proxy")
    ]

    let outcome = RuleMatchSimulator().simulate(target: "/Applications/Safari.app", rules: rules)

    guard case let .matched(rule) = outcome else {
      return XCTFail("Expected process rule match, got \(outcome)")
    }
    XCTAssertEqual(rule.type, "PROCESS-NAME")
    XCTAssertEqual(rule.policy, "DIRECT")
  }

  func testRuleMatchSimulatorSupportsSourceCIDRAndPortRules() throws {
    let candidates = [
      RuntimeRuleCandidate(
        rule: RuntimeRule(index: 1, type: "SRC-IP-CIDR", payload: "192.168.1.0/24", policy: "DIRECT"),
        source: .globalPrepend
      ),
      RuntimeRuleCandidate(
        rule: RuntimeRule(index: 2, type: "DST-PORT", payload: "443", policy: "Proxy"),
        source: .profilePrepend
      ),
      RuntimeRuleCandidate(
        rule: RuntimeRule(index: 3, type: "SRC-PORT", payload: "50000-50100", policy: "DIRECT"),
        source: .runtimeProfile
      ),
      RuntimeRuleCandidate(
        rule: RuntimeRule(index: 4, type: "IN-PORT", payload: "7890", policy: "Proxy"),
        source: .profileAppend
      ),
      RuntimeRuleCandidate(
        rule: RuntimeRule(index: 5, type: "MATCH", payload: "", policy: "Fallback"),
        source: .globalAppend
      )
    ]
    let simulator = RuleMatchSimulator()

    let sourceTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "example.com", sourceIP: "192.168.1.44"),
      candidates: candidates
    )
    let destinationPortTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "example.com", destinationPort: "443"),
      candidates: Array(candidates.dropFirst())
    )
    let sourcePortTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "example.com", sourcePort: "50010"),
      candidates: Array(candidates.dropFirst(2))
    )
    let inboundPortTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "example.com", inboundPort: "7890"),
      candidates: Array(candidates.dropFirst(3))
    )

    guard case let .matched(sourceRule) = sourceTrace.outcome else { return XCTFail("Expected source CIDR match") }
    guard case let .matched(destinationPortRule) = destinationPortTrace.outcome else { return XCTFail("Expected destination port match") }
    guard case let .matched(sourcePortRule) = sourcePortTrace.outcome else { return XCTFail("Expected source port match") }
    guard case let .matched(inboundPortRule) = inboundPortTrace.outcome else { return XCTFail("Expected inbound port match") }

    XCTAssertEqual(sourceRule.type, "SRC-IP-CIDR")
    XCTAssertEqual(sourceTrace.source, .globalPrepend)
    XCTAssertEqual(destinationPortRule.type, "DST-PORT")
    XCTAssertEqual(destinationPortTrace.source, .profilePrepend)
    XCTAssertEqual(sourcePortRule.type, "SRC-PORT")
    XCTAssertEqual(inboundPortRule.type, "IN-PORT")
  }

  func testRuleCandidateBuilderPreservesOverlaySources() throws {
    let globalOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "global-pre.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "global-append.example", policy: "DIRECT")
      ]
    )
    let profileOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "profile-pre.example", policy: "Proxy")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "profile-append.example", policy: "Proxy")
      ]
    )
    let snippetOverlay = RuleOverlaySettings(
      enabled: true,
      prependRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "snippet-pre.example", policy: "DIRECT")
      ],
      appendRules: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "snippet-append.example", policy: "DIRECT")
      ]
    )
    let runtimeRule = RuntimeRule(
      index: 99,
      type: "DOMAIN-SUFFIX",
      payload: "runtime.example",
      policy: "Proxy",
      raw: "DOMAIN-SUFFIX,runtime.example,Proxy"
    )

    let candidates = RuntimeRuleCandidateBuilder.candidates(
      globalOverlay: globalOverlay,
      profileOverlay: profileOverlay,
      snippetOverlay: snippetOverlay,
      runtimeRules: [runtimeRule]
    )

    XCTAssertEqual(
      candidates.map(\.source),
      [
        .globalPrepend,
        .profilePrepend,
        .runtimeSnippetPrepend,
        .runtimeProfile,
        .profileAppend,
        .globalAppend,
        .runtimeSnippetAppend
      ]
    )
    XCTAssertEqual(candidates.map(\.rule.index), [1, 2, 3, 4, 5, 6, 7])

    let simulator = RuleMatchSimulator()
    let matches: [(String, RuntimeRuleSource)] = [
      ("api.global-pre.example", .globalPrepend),
      ("api.profile-pre.example", .profilePrepend),
      ("api.snippet-pre.example", .runtimeSnippetPrepend),
      ("api.runtime.example", .runtimeProfile),
      ("api.profile-append.example", .profileAppend),
      ("api.global-append.example", .globalAppend),
      ("api.snippet-append.example", .runtimeSnippetAppend)
    ]
    for (destination, expectedSource) in matches {
      let trace = simulator.simulate(
        input: RuleMatchSimulationInput(destination: destination),
        candidates: candidates
      )
      guard case .matched = trace.outcome else {
        return XCTFail("Expected \(destination) to match a local candidate.")
      }
      XCTAssertEqual(trace.source, expectedSource)
    }
  }

  func testRuleMatchSimulatorTracesMihomoEvaluatedProvidersAndSubRules() throws {
    let ruleSet = RuntimeRuleCandidate(
      rule: RuntimeRule(index: 1, type: "RULE-SET", payload: "RemoteRules", policy: "Proxy"),
      source: .profilePrepend
    )
    let subRule = RuntimeRuleCandidate(
      rule: RuntimeRuleParser.parse(raw: "SUB-RULE,(NETWORK,tcp),tcp-sub", index: 2),
      source: .profileAppend
    )
    let simulator = RuleMatchSimulator()

    let providerTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "chat.openai.com"),
      candidates: [ruleSet]
    )
    let subRuleTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: "example.com"),
      candidates: [subRule]
    )

    guard case .mihomoOnly = providerTrace.outcome else { return XCTFail("Expected RULE-SET to be Mihomo-evaluated") }
    guard case .mihomoOnly = subRuleTrace.outcome else { return XCTFail("Expected SUB-RULE to be Mihomo-evaluated") }
    XCTAssertEqual(providerTrace.source, .profilePrepend)
    XCTAssertEqual(providerTrace.provider, "RemoteRules")
    XCTAssertEqual(providerTrace.policy, "Proxy")
    XCTAssertEqual(subRuleTrace.rule?.payload, "NETWORK,tcp")
    XCTAssertEqual(subRuleTrace.policy, "tcp-sub")
    XCTAssertEqual(subRuleTrace.source, .profileAppend)
  }

  func testRuleExplanationBuilderExplainsDomainCIDRProcessProviderAndMatchRules() throws {
    let rules = [
      RuntimeRule(index: 1, type: "DOMAIN-SUFFIX", payload: "example.com", policy: "Proxy"),
      RuntimeRule(index: 2, type: "IP-CIDR", payload: "10.0.0.0/8", policy: "DIRECT"),
      RuntimeRule(index: 3, type: "PROCESS-NAME", payload: "Safari", policy: "DIRECT"),
      RuntimeRule(index: 4, type: "RULE-SET", payload: "OpenAI", policy: "Proxy"),
      RuntimeRule(index: 5, type: "MATCH", payload: "", policy: "Fallback")
    ]
    let builder = RuleExplanationBuilder()

    let domain = builder.explanation(
      for: ConnectionSnapshot(id: "domain", network: "tcp", host: "api.example.com", upload: 0, download: 0, chain: ["Proxy"], rule: "DOMAIN-SUFFIX", rulePayload: "example.com"),
      rules: rules
    )
    let cidr = builder.explanation(
      for: ConnectionSnapshot(id: "cidr", network: "tcp", host: "10.1.2.3", destinationIP: "10.1.2.3", upload: 0, download: 0, chain: ["DIRECT"], rule: "IP-CIDR", rulePayload: "10.0.0.0/8"),
      rules: rules
    )
    let process = builder.explanation(
      for: ConnectionSnapshot(id: "process", network: "tcp", host: "17.253.144.10", processName: "Safari", upload: 0, download: 0, chain: ["DIRECT"], rule: "PROCESS-NAME", rulePayload: "Safari"),
      rules: rules
    )
    let providerOnly = builder.explanation(
      for: ConnectionSnapshot(id: "ruleset", network: "tcp", host: "chat.openai.com", upload: 0, download: 0, chain: ["Proxy"], rule: "RULE-SET", rulePayload: "OpenAI"),
      rules: [RuntimeRule(index: 1, type: "RULE-SET", payload: "OpenAI", policy: "Proxy")]
    )
    let match = builder.explanation(
      for: ConnectionSnapshot(id: "match", network: "tcp", host: "fallback.test", upload: 0, download: 0, chain: ["Fallback"], rule: "MATCH"),
      rules: [RuntimeRule(index: 1, type: "MATCH", payload: "", policy: "Fallback")]
    )
    let empty = builder.explanation(
      for: ConnectionSnapshot(id: "empty", network: "tcp", host: "empty.test", upload: 0, download: 0, chain: [], rule: nil),
      rules: []
    )

    guard case let .matched(domainRule) = domain.localOutcome else { return XCTFail("Expected domain match") }
    guard case let .matched(cidrRule) = cidr.localOutcome else { return XCTFail("Expected CIDR match") }
    guard case let .matched(processRule) = process.localOutcome else { return XCTFail("Expected process match") }
    guard case .mihomoOnly = providerOnly.localOutcome else { return XCTFail("Expected Mihomo-only provider match") }
    guard case let .matched(matchRule) = match.localOutcome else { return XCTFail("Expected MATCH fallback") }
    guard case .noMatch = empty.localOutcome else { return XCTFail("Expected empty runtime no match") }

    XCTAssertEqual(domainRule.type, "DOMAIN-SUFFIX")
    XCTAssertEqual(cidrRule.type, "IP-CIDR")
    XCTAssertEqual(processRule.type, "PROCESS-NAME")
    XCTAssertEqual(matchRule.type, "MATCH")
  }

  func testRuleExplanationBuilderUsesConnectionSourceAndPortInputs() throws {
    let builder = RuleExplanationBuilder()
    let connection = ConnectionSnapshot(
      id: "ports",
      network: "tcp",
      host: "api.example.com",
      sourceIP: "192.168.1.44",
      sourcePort: 50_010,
      destinationIP: "93.184.216.34",
      destinationPort: 443,
      inboundPort: 7890,
      processName: "Safari",
      upload: 0,
      download: 0,
      chain: ["Proxy"],
      rule: "DST-PORT",
      rulePayload: "443"
    )

    let destinationPort = builder.explanation(
      for: connection,
      rules: [
        RuntimeRule(index: 1, type: "DST-PORT", payload: "443", policy: "Proxy"),
        RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Fallback")
      ]
    )
    let sourcePort = builder.explanation(
      for: connection,
      rules: [
        RuntimeRule(index: 1, type: "SRC-PORT", payload: "50000-50100", policy: "DIRECT"),
        RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Fallback")
      ]
    )
    let inboundPort = builder.explanation(
      for: connection,
      rules: [
        RuntimeRule(index: 1, type: "IN-PORT", payload: "7890", policy: "Proxy"),
        RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Fallback")
      ]
    )
    let sourceIP = builder.explanation(
      for: connection,
      rules: [
        RuntimeRule(index: 1, type: "SRC-IP-CIDR", payload: "192.168.1.0/24", policy: "DIRECT"),
        RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Fallback")
      ]
    )

    guard case let .matched(destinationPortRule) = destinationPort.localOutcome else {
      return XCTFail("Expected destination port rule match")
    }
    guard case let .matched(sourcePortRule) = sourcePort.localOutcome else {
      return XCTFail("Expected source port rule match")
    }
    guard case let .matched(inboundPortRule) = inboundPort.localOutcome else {
      return XCTFail("Expected inbound port rule match")
    }
    guard case let .matched(sourceIPRule) = sourceIP.localOutcome else {
      return XCTFail("Expected source IP rule match")
    }

    XCTAssertEqual(destinationPortRule.type, "DST-PORT")
    XCTAssertEqual(sourcePortRule.type, "SRC-PORT")
    XCTAssertEqual(inboundPortRule.type, "IN-PORT")
    XCTAssertEqual(sourceIPRule.type, "SRC-IP-CIDR")
    XCTAssertEqual(destinationPort.simulationInput.destinationPort, "443")
    XCTAssertEqual(destinationPort.simulationInput.sourcePort, "50010")
    XCTAssertEqual(destinationPort.simulationInput.inboundPort, "7890")
    XCTAssertEqual(destinationPort.simulationInput.sourceIP, "192.168.1.44")
    XCTAssertEqual(destinationPort.simulationInput.process, "Safari")
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

  func testPreviewGroupsExpandInlineProviderPayloads() throws {
    let source = """
    proxy-providers:
      Remote:
        type: file
        path: ./remote.yaml
        payload:
          - { name: Provider Node A, type: hysteria2, server: a.example, port: 443, udp: true, tfo: "true" }
          - { name: Provider Node B, type: vless, server: b.example, port: 8443, xudp: true }
    proxy-groups:
      - name: Main
        type: select
        use: [Remote]
    rules:
      - MATCH,Main
    """

    let groups = try ProfilePreviewBuilder().groups(from: source, profileName: "Remote")

    XCTAssertEqual(groups.map(\.name), ["Main"])
    XCTAssertEqual(groups.first?.nodes.map(\.name), ["Provider Node A", "Provider Node B"])
    XCTAssertEqual(groups.first?.nodes.map(\.providerName), ["Remote", "Remote"])
    XCTAssertEqual(groups.first?.nodes.first?.type, "hysteria2")
    XCTAssertEqual(groups.first?.nodes.first?.serverHost, "a.example")
    XCTAssertEqual(groups.first?.nodes.first?.serverPort, 443)
    XCTAssertEqual(groups.first?.nodes.first?.udpSupported, true)
    XCTAssertEqual(groups.first?.nodes.first?.tfoSupported, true)
    XCTAssertEqual(groups.first?.nodes.last?.xudpSupported, true)
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

  private func providerContentPath(in runtimeConfigURL: URL) throws -> String {
    let output = try String(contentsOf: runtimeConfigURL, encoding: .utf8)
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let providers = try XCTUnwrap(yaml["proxy-providers"] as? [String: Any])
    let provider = try XCTUnwrap(providers["clashmax-subscription-provider"] as? [String: Any])
    return try XCTUnwrap(provider["path"] as? String)
  }

  private func setModificationDate(_ date: Date, for urls: [URL]) throws {
    for url in urls {
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
  }
}
