import XCTest
@testable import ClashMax

final class ExternalControlHealthCheckerTests: XCTestCase {
  func testControllerHealthCheckUsesVersionEndpointAndBearerSecret() async throws {
    let recorder = URLProtocolRecorder(responseBody: #"{"version":"v-test"}"#)
    let checker = ExternalControlHealthChecker(
      session: URLSession(configuration: recorder.configuration),
      timeout: 0.5
    )

    let result = await checker.checkController(settings: ExternalControllerSettings(secret: "controller-secret"))

    XCTAssertEqual(result.status, .healthy)
    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/version")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer controller-secret")
  }

  func testDashboardHealthCheckDoesNotSendControllerQueryOrSecret() async throws {
    let recorder = URLProtocolRecorder(responseBody: "ok")
    let checker = ExternalControlHealthChecker(
      session: URLSession(configuration: recorder.configuration),
      timeout: 0.5
    )
    let url = try XCTUnwrap(URL(string: "https://dashboard.example/app?hostname=127.0.0.1&port=9097&secret=leak"))

    let result = await checker.checkDashboard(baseURL: url)

    XCTAssertEqual(result.status, .healthy)
    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.httpMethod, "HEAD")
    XCTAssertEqual(request.url?.host, "dashboard.example")
    XCTAssertEqual(request.url?.path, "/app")
    XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  func testDashboardHealthCheckFallsBackToGetWhenHeadIsUnsupported() async throws {
    let recorder = URLProtocolRecorder(responseBody: "ok", statusCodes: [405, 200])
    let checker = ExternalControlHealthChecker(
      session: URLSession(configuration: recorder.configuration),
      timeout: 0.5
    )

    let result = await checker.checkDashboard(baseURL: try XCTUnwrap(URL(string: "https://dashboard.example")))

    XCTAssertEqual(result.status, .healthy)
    XCTAssertEqual(recorder.requests.map(\.httpMethod), ["HEAD", "GET"])
  }

  func testHealthCheckReportsNonSuccessStatus() async throws {
    let recorder = URLProtocolRecorder(responseBody: "no", statusCode: 503)
    let checker = ExternalControlHealthChecker(
      session: URLSession(configuration: recorder.configuration),
      timeout: 0.5
    )

    let result = await checker.checkDashboard(baseURL: try XCTUnwrap(URL(string: "https://dashboard.example")))

    XCTAssertEqual(result.status, .failed)
    XCTAssertEqual(result.httpStatus, 503)
  }
}
