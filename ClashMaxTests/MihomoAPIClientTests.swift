import XCTest
@testable import ClashMax

final class MihomoAPIClientTests: XCTestCase {
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
}
