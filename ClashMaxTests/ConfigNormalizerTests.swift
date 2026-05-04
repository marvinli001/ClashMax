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
    XCTAssertEqual(tun["enable"] as? Bool, true)
    XCTAssertEqual(tun["stack"] as? String, "mixed")
    XCTAssertEqual(tun["auto-route"] as? Bool, true)
    XCTAssertEqual(tun["auto-detect-interface"] as? Bool, true)
    XCTAssertNil(tun["auto-redirect"])
  }

  func testInvalidYamlProducesReadableError() {
    XCTAssertThrowsError(try ConfigNormalizer().runtimeConfig(from: "not: [valid", overrides: .defaultForLaunch())) { error in
      XCTAssertTrue(String(describing: error).contains("YAML"))
    }
  }
}

