@testable import ClashMax
import XCTest

final class MihomoAPIClientTests: XCTestCase {
  func testCoreAPIEndpointBuildsBracketedIPv6BaseURL() throws {
    let endpoint = CoreAPIEndpoint(host: "::1", port: 9097, secret: "abc")

    let url = try endpoint.baseURL

    XCTAssertEqual(url.absoluteString, "http://[::1]:9097")
  }

  func testCoreAPIEndpointRejectsEmptyHostInsteadOfCrashing() {
    let endpoint = CoreAPIEndpoint(host: " ", port: 9097, secret: "abc")

    XCTAssertThrowsError(try endpoint.baseURL) { error in
      guard case MihomoAPIClient.ClientError.invalidURL = error else {
        return XCTFail("Expected invalidURL, got \(error)")
      }
    }
  }

  func testRESTRequestRejectsInvalidBaseURLInsteadOfCrashing() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://:9097")!, secret: "abc", session: session)

    do {
      _ = try await client.version()
      XCTFail("Expected invalid URL to throw")
    } catch MihomoAPIClient.ClientError.invalidURL {
      XCTAssertNil(recorder.lastRequest)
    }
  }

  func testWebSocketStreamRejectsInvalidBaseURLInsteadOfCrashing() async throws {
    let client = MihomoAPIClient(baseURL: URL(string: "http://:9097")!, secret: "abc")
    var iterator = client.trafficStream().makeAsyncIterator()

    do {
      _ = try await iterator.next()
      XCTFail("Expected invalid URL to throw")
    } catch MihomoAPIClient.ClientError.invalidURL {}
  }

  func testVersionRequestUsesConfiguredTimeout() async throws {
    let recorder = URLProtocolRecorder(responseBody: #"{"version":"v-test"}"#)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(
      baseURL: URL(string: "http://127.0.0.1:9097")!,
      secret: "abc",
      session: session,
      requestTimeout: 0.75
    )

    let version = try await client.version()
    XCTAssertEqual(version, "v-test")

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.timeoutInterval, 0.75, accuracy: 0.01)
  }

  func testSwitchProxyBuildsAuthenticatedPutRequest() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.selectProxy(group: "Proxy", proxy: "Japan")

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(request.url?.path, "/proxies/Proxy")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    let body = try XCTUnwrap(recorder.lastBody)
    XCTAssertEqual(String(data: body, encoding: .utf8), #"{"name":"Japan"}"#)
  }

  func testDelayRequestUsesUrlAndTimeoutQueryItems() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    _ = try await client.testDelay(proxy: "Japan", testURL: URL(string: "https://www.gstatic.com/generate_204")!, timeout: 5000)

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.url?.path, "/proxies/Japan/delay")
    XCTAssertTrue(request.url?.query?.contains("timeout=5000") == true)
    XCTAssertTrue(request.url?.query?.contains("url=https://www.gstatic.com/generate_204") == true)
  }

  func testDelayHTTPStatusIsReportedAsProbeFailureNotControllerFailure() async throws {
    let recorder = URLProtocolRecorder(statusCode: 503)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    do {
      _ = try await client.testDelay(
        proxy: "Japan",
        testURL: URL(string: "https://www.gstatic.com/generate_204")!,
        timeout: 5000
      )
      XCTFail("Expected the delay probe to fail")
    } catch {
      guard let clientError = error as? MihomoAPIClient.ClientError,
            case let .delayTestHTTPStatus(status) = clientError
      else {
        return XCTFail("Expected delayTestHTTPStatus, got \(error)")
      }
      XCTAssertEqual(status, 503)
      XCTAssertEqual(
        clientError.errorDescription,
        "Mihomo delay probe returned HTTP 503. The controller responded, but the selected node or test URL could not complete the probe."
      )
    }

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
  }

  func testDelayAuthenticationHTTPStatusRemainsAControllerError() async throws {
    let recorder = URLProtocolRecorder(statusCode: 401)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    do {
      _ = try await client.testDelay(
        proxy: "Japan",
        testURL: URL(string: "https://www.gstatic.com/generate_204")!,
        timeout: 5000
      )
      XCTFail("Expected the delay probe to fail")
    } catch {
      guard let clientError = error as? MihomoAPIClient.ClientError,
            case let .httpStatus(status) = clientError
      else {
        return XCTFail("Expected httpStatus, got \(error)")
      }
      XCTAssertEqual(status, 401)
    }

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
  }

  func testProxyGroupNamesArePercentEncodedInRequests() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.selectProxy(group: "Auto/Asia", proxy: "HK 01")

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/proxies/Auto%2FAsia")
  }

  func testProxyGroupsUseRuntimeProxyTypesForNodeRows() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "proxies": {
        "Elite": {
          "type": "Selector",
          "now": "Japan",
          "all": ["Japan", "PASS-RULE", "COMPATIBLE", "DIRECT"],
          "history": [
            { "name": "Japan", "delay": 157 }
          ]
        },
        "Japan": {
          "type": "Hysteria2",
          "history": []
        },
        "DIRECT": {
          "type": "Direct",
          "history": []
        }
      }
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let groups = try await client.proxyGroups()
    let group = try XCTUnwrap(groups.first)

    XCTAssertEqual(group.name, "Elite")
    XCTAssertEqual(group.nodes.map(\.type), ["Hysteria2", "pass-rule", "compatible", "Direct"])
    XCTAssertEqual(group.nodes.first?.delay, 157)
  }

  func testProxyGroupsCarryRuntimeProxyEndpointsForNativePing() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "proxies": {
        "Elite": {
          "type": "Selector",
          "now": "Japan",
          "all": ["Japan", "DIRECT"],
          "history": []
        },
        "Japan": {
          "type": "Vless",
          "server": "jp.example",
          "port": 443,
          "history": []
        },
        "DIRECT": {
          "type": "Direct",
          "history": []
        }
      }
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let groups = try await client.proxyGroups()
    let group = try XCTUnwrap(groups.first)

    XCTAssertEqual(group.nodes[0].name, "Japan")
    XCTAssertEqual(group.nodes[0].serverHost, "jp.example")
    XCTAssertEqual(group.nodes[0].serverPort, 443)
    XCTAssertNil(group.nodes[1].serverHost)
    XCTAssertNil(group.nodes[1].serverPort)
  }

  func testProviderHealthCheckUsesGetRequest() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.healthCheckProvider(named: "remote/sub")

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/providers/proxies/remote%2Fsub/healthcheck")
  }

  func testProxyProvidersAreDecodedIntoStructuredRows() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "providers": {
        "remote": {
          "name": "remote",
          "type": "Proxy",
          "vehicleType": "HTTP",
          "updatedAt": "2026-05-05T09:30:00Z",
          "subscriptionInfo": {
            "upload": 1024,
            "download": 2048,
            "total": 4096,
            "expire": 1770000000
          },
          "proxies": [
            { "name": "Japan", "type": "Vless" },
            { "name": "DIRECT", "type": "Direct" }
          ]
        }
      }
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let providers = try await client.structuredProxyProviders()

    XCTAssertEqual(providers, [
      ProxyProvider(
        name: "remote",
        type: "Proxy",
        vehicleType: "HTTP",
        updatedAt: ISO8601DateFormatter().date(from: "2026-05-05T09:30:00Z"),
        subscriptionInfo: ProviderSubscriptionInfo(
          upload: 1024,
          download: 2048,
          total: 4096,
          expireAt: Date(timeIntervalSince1970: 1770000000)
        ),
        proxies: [
          ProxyNode(name: "Japan", type: "Vless", delay: nil, isSelectable: true, providerName: "remote"),
          ProxyNode(name: "DIRECT", type: "Direct", delay: nil, isSelectable: true, providerName: "remote"),
        ]
      ),
    ])
  }

  func testRuleProvidersAreDecodedIntoStructuredRows() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "providers": {
        "rules/remote": {
          "name": "rules/remote",
          "type": "Rule",
          "vehicleType": "HTTP",
          "behavior": "domain",
          "format": "yaml",
          "updatedAt": "2026-05-05T09:30:00Z",
          "ruleCount": 42
        }
      }
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let providers = try await client.ruleProviders()

    XCTAssertEqual(providers, [
      RuleProvider(
        name: "rules/remote",
        type: "Rule",
        vehicleType: "HTTP",
        behavior: "domain",
        format: "yaml",
        updatedAt: ISO8601DateFormatter().date(from: "2026-05-05T09:30:00Z"),
        ruleCount: 42
      ),
    ])
  }

  func testRulesAreDecodedIntoStructuredRows() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "rules": [
        { "type": "DOMAIN-SUFFIX", "payload": "example.com", "proxy": "DIRECT", "provider": "local" },
        { "type": "MATCH", "payload": "", "proxy": "Proxy" }
      ]
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let rules = try await client.rules()

    XCTAssertEqual(rules, [
      RuntimeRule(
        index: 1,
        type: "DOMAIN-SUFFIX",
        payload: "example.com",
        policy: "DIRECT",
        providerName: "local",
        raw: "DOMAIN-SUFFIX,example.com,DIRECT"
      ),
      RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Proxy", raw: "MATCH,Proxy"),
    ])
  }

  func testProviderUpdateRequestsUseAuthenticatedPutRequests() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.updateProxyProvider(named: "remote/sub")
    var request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(
      try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
      "/providers/proxies/remote%2Fsub"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")

    try await client.updateRuleProvider(named: "rules/sub")
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(
      try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
      "/providers/rules/rules%2Fsub"
    )
  }

  func testConnectionsDecodeProcessEndpointsAndRulePayload() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "connections": [
        {
          "id": "abc",
          "upload": 128,
          "download": 256,
          "rule": "DOMAIN-SUFFIX",
          "rulePayload": "example.com",
          "chains": ["Proxy", "Japan"],
          "metadata": {
            "network": "tcp",
            "host": "example.com",
            "sourceIP": "192.168.1.2",
            "sourcePort": "53000",
            "destinationIP": "93.184.216.34",
            "destinationPort": 443,
            "inboundPort": "7890",
            "processName": "Safari",
            "processPath": "/Applications/Safari.app"
          }
        }
      ]
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let connections = try await client.connections()
    let connection = try XCTUnwrap(connections.first)

    XCTAssertEqual(connection.processName, "Safari")
    XCTAssertEqual(connection.processPath, "/Applications/Safari.app")
    XCTAssertEqual(connection.sourceAddress, "192.168.1.2:53000")
    XCTAssertEqual(connection.destinationAddress, "93.184.216.34:443")
    XCTAssertEqual(connection.inboundPort, 7890)
    XCTAssertEqual(connection.ruleSummary, "DOMAIN-SUFFIX example.com")
    XCTAssertEqual(connection.chain, ["Proxy", "Japan"])
  }

  func testConnectionCloseAndReloadRequestsUseAuthenticatedControlEndpoints() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.closeConnection(id: "abc/123")
    var request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/connections/abc%2F123")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")

    try await client.closeAllConnections()
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(request.url?.path, "/connections")

    try await client.reloadConfig(path: "/tmp/runtime.yaml")
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(request.url?.path, "/configs")
    XCTAssertEqual(request.url?.query, "force=true")
    XCTAssertEqual(try String(data: XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"path":"/tmp/runtime.yaml"}"#)

    try await client.updateIPv6(true)
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PATCH")
    XCTAssertEqual(request.url?.path, "/configs")
    XCTAssertEqual(try String(data: XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"ipv6":true}"#)

    try await client.setTunEnabled(false)
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PATCH")
    XCTAssertEqual(request.url?.path, "/configs")
    XCTAssertEqual(try String(data: XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"tun":{"enable":false}}"#)
  }

  /// Roadmap A1a. The decoder used to backfill a missing domain with the destination IP, so no
  /// consumer could tell "the domain is example.com" from "this connection never had a domain".
  /// These fixtures are the metadata shapes the bundled core actually emits — see the table on
  /// `ConnectionDomainOrigin`, measured against v1.19.29 over a mixed inbound.
  func testConnectionsDecodeDomainProvenanceInsteadOfBackfillingTheDestinationIP() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "connections": [
        {
          "id": "reported",
          "upload": 0,
          "download": 0,
          "chains": ["Proxy"],
          "metadata": {
            "network": "tcp",
            "host": "example.com",
            "sniffHost": "",
            "destinationIP": "",
            "remoteDestination": "172.66.147.243",
            "destinationPort": 443,
            "dnsMode": "normal"
          }
        },
        {
          "id": "sniffed-overriding",
          "upload": 0,
          "download": 0,
          "chains": ["Proxy"],
          "metadata": {
            "network": "tcp",
            "host": "example.com",
            "sniffHost": "example.com",
            "destinationIP": "",
            "remoteDestination": "104.20.23.154",
            "destinationPort": 443
          }
        },
        {
          "id": "sniffed-not-overriding",
          "upload": 0,
          "download": 0,
          "chains": ["Proxy"],
          "metadata": {
            "network": "tcp",
            "host": "",
            "sniffHost": "example.com",
            "destinationIP": "172.66.147.243",
            "remoteDestination": "172.66.147.243",
            "destinationPort": 443
          }
        },
        {
          "id": "domainless",
          "upload": 0,
          "download": 0,
          "chains": ["DIRECT"],
          "metadata": {
            "network": "tcp",
            "host": "",
            "sniffHost": "",
            "destinationIP": "104.20.23.154",
            "remoteDestination": "104.20.23.154",
            "destinationPort": 443,
            "specialProxy": "pinned"
          }
        },
        {
          "id": "domainless-keys-absent",
          "upload": 0,
          "download": 0,
          "chains": ["DIRECT"],
          "metadata": {
            "network": "udp",
            "remoteDestination": "2606:4700::6810:1a9a",
            "destinationPort": 443
          }
        },
        {
          "id": "ip-literal-host",
          "upload": 0,
          "download": 0,
          "chains": ["DIRECT"],
          "metadata": {
            "network": "tcp",
            "host": "104.20.23.154",
            "destinationPort": 443
          }
        }
      ]
    }
    """)
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    let connections = try await client.connections()
    XCTAssertEqual(connections.map(\.id), [
      "reported",
      "sniffed-overriding",
      "sniffed-not-overriding",
      "domainless",
      "domainless-keys-absent",
      "ip-literal-host",
    ])
    let byID = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

    // The client named the destination: no sniffing involved, and the raw address survives in
    // `remoteDestination` because the core empties `destinationIP` whenever a domain is in play.
    let reported = try XCTUnwrap(byID["reported"])
    XCTAssertEqual(reported.domainOrigin, .reported)
    XCTAssertEqual(reported.domain, "example.com")
    XCTAssertNil(reported.sniffHost)
    XCTAssertEqual(reported.destinationIPAddress, "172.66.147.243")
    XCTAssertEqual(reported.destinationAddress, "172.66.147.243:443")
    XCTAssertEqual(reported.dnsMode, "normal")

    // Sniffed with `override-destination: true`: the recovered name is copied into `host` as well,
    // and `sniffHost` is what distinguishes it from a name the client actually sent.
    let overriding = try XCTUnwrap(byID["sniffed-overriding"])
    XCTAssertEqual(overriding.domainOrigin, .sniffed)
    XCTAssertEqual(overriding.domain, "example.com")
    XCTAssertEqual(overriding.reportedHost, "example.com")
    XCTAssertEqual(overriding.destinationAddress, "104.20.23.154:443")

    // Sniffed with `override-destination: false`: `host` stays empty, so before A1a this connection
    // was indistinguishable from one that never had a domain — even though the core matched its
    // rules on the sniffed name.
    let notOverriding = try XCTUnwrap(byID["sniffed-not-overriding"])
    XCTAssertEqual(notOverriding.domainOrigin, .sniffed)
    XCTAssertEqual(notOverriding.domain, "example.com")
    XCTAssertNil(notOverriding.reportedHost)
    XCTAssertEqual(notOverriding.host, "example.com")

    // No domain at all. The IP is still shown, but as a presentation fallback above a model that
    // records the absence — the fact roadmap A1c needs in order to explain an unmatched rule.
    let domainless = try XCTUnwrap(byID["domainless"])
    XCTAssertEqual(domainless.domainOrigin, .none)
    XCTAssertNil(domainless.domain)
    XCTAssertEqual(domainless.host, "104.20.23.154")
    XCTAssertEqual(domainless.destinationAddress, "104.20.23.154:443")
    XCTAssertEqual(domainless.specialProxy, "pinned")

    // Both keys missing outright, not merely empty.
    let keysAbsent = try XCTUnwrap(byID["domainless-keys-absent"])
    XCTAssertEqual(keysAbsent.domainOrigin, .none)
    XCTAssertNil(keysAbsent.domain)
    XCTAssertNil(keysAbsent.reportedHost)
    XCTAssertEqual(keysAbsent.destinationIPAddress, "2606:4700::6810:1a9a")

    // An IP literal reported as the host is an address, not a domain: `DOMAIN-SUFFIX` cannot match
    // it, so counting it as a domain would hide the very case this distinction exists to expose.
    let literal = try XCTUnwrap(byID["ip-literal-host"])
    XCTAssertEqual(literal.domainOrigin, .none)
    XCTAssertNil(literal.domain)
    XCTAssertEqual(literal.destinationIPAddress, "104.20.23.154")
    XCTAssertEqual(literal.host, "104.20.23.154")
  }
}
