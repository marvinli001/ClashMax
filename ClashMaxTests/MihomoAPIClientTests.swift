import XCTest
@testable import ClashMax

final class MihomoAPIClientTests: XCTestCase {
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
        proxies: [
          ProxyNode(name: "Japan", type: "Vless", delay: nil, isSelectable: true),
          ProxyNode(name: "DIRECT", type: "Direct", delay: nil, isSelectable: true)
        ]
      )
    ])
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
    XCTAssertEqual(String(data: try XCTUnwrap(recorder.lastBody), encoding: .utf8), #"{"path":"/tmp/runtime.yaml"}"#)
  }
}
