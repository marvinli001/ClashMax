import XCTest
@testable import ClashMax

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
    } catch MihomoAPIClient.ClientError.invalidURL {
    }
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

  func testProxyGroupNamesArePercentEncodedInRequests() async throws {
    let recorder = URLProtocolRecorder()
    let session = URLSession(configuration: recorder.configuration)
    let client = MihomoAPIClient(baseURL: URL(string: "http://127.0.0.1:9097")!, secret: "abc", session: session)

    try await client.selectProxy(group: "Auto/Asia", proxy: "HK 01")

    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/proxies/Auto%2FAsia")
  }

  func testProxyGroupsUseRuntimeProxyTypesForNodeRows() async throws {
    let recorder = URLProtocolRecorder(responseBody: """
    {
      "proxies": {
        "Elite": {
          "type": "Selector",
          "now": "Japan",
          "all": ["Japan", "DIRECT"],
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
    XCTAssertEqual(group.nodes.map(\.type), ["Hysteria2", "Direct"])
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
    XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/providers/proxies/remote%2Fsub/healthcheck")
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
          ProxyNode(name: "DIRECT", type: "Direct", delay: nil, isSelectable: true, providerName: "remote")
        ]
      )
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
      )
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
      RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "Proxy", raw: "MATCH,Proxy")
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
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
      "/providers/proxies/remote%2Fsub"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc")

    try await client.updateRuleProvider(named: "rules/sub")
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PUT")
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
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
    XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/connections/abc%2F123")
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
    XCTAssertEqual(String(data: try XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"path":"/tmp/runtime.yaml"}"#)

    try await client.updateIPv6(true)
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PATCH")
    XCTAssertEqual(request.url?.path, "/configs")
    XCTAssertEqual(String(data: try XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"ipv6":true}"#)

    try await client.setTunEnabled(false)
    request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "PATCH")
    XCTAssertEqual(request.url?.path, "/configs")
    XCTAssertEqual(String(data: try XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"tun":{"enable":false}}"#)
  }
}
