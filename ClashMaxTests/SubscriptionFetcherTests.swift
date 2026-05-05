import XCTest
@testable import ClashMax

final class SubscriptionFetcherTests: XCTestCase {
  func testFetchParsesMetadataHeadersAndStripsUTF8BOM() async throws {
    let fetcher = SubscriptionFetcher()
    let source = "\u{FEFF}proxies:\n  - name: DIRECT\n    type: direct\n"
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "subscription-userinfo": "upload=1024; download=2048; total=4096; expire=1893456000",
        "content-disposition": "attachment; filename*=UTF-8''Remote%20Profile.yaml",
        "profile-update-interval": "12",
        "profile-web-page-url": "https://example.com/dashboard"
      ]
    )!

    let result = try fetcher.decode(data: Data(source.utf8), response: response)

    XCTAssertEqual(result.source, "proxies:\n  - name: DIRECT\n    type: direct\n")
    XCTAssertEqual(result.metadata.traffic?.upload, 1024)
    XCTAssertEqual(result.metadata.traffic?.download, 2048)
    XCTAssertEqual(result.metadata.traffic?.total, 4096)
    XCTAssertEqual(result.metadata.traffic?.expireAt, Date(timeIntervalSince1970: 1_893_456_000))
    XCTAssertEqual(result.metadata.remoteFileName, "Remote Profile.yaml")
    XCTAssertEqual(result.metadata.updateIntervalMinutes, 720)
    XCTAssertEqual(result.metadata.webPageURL, URL(string: "https://example.com/dashboard"))
  }

  func testFetchRetriesDirectThenLocalProxyThenSystemProxy() async throws {
    let attempts = SubscriptionFetchStrategy.defaultRetryOrder
    let fetcher = SubscriptionFetcher()
    let recorder = StrategyAttemptRecorder()
    let goodResponse = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!

    let result = try await fetcher.fetch(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(retryOrder: attempts)
    ) { strategy in
      let attemptCount = await recorder.record(strategy)
      if attemptCount < 3 {
        throw URLError(.cannotConnectToHost)
      }
      return (Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8), goodResponse)
    }

    let attemptedStrategies = await recorder.strategies()
    XCTAssertEqual(attemptedStrategies, [.direct, .localClashProxy, .systemProxy])
    XCTAssertEqual(result.source, "proxies:\n  - name: DIRECT\n    type: direct\n")
  }
}

private actor StrategyAttemptRecorder {
  private var attemptedStrategies: [SubscriptionFetchStrategy] = []

  func record(_ strategy: SubscriptionFetchStrategy) -> Int {
    attemptedStrategies.append(strategy)
    return attemptedStrategies.count
  }

  func strategies() -> [SubscriptionFetchStrategy] {
    attemptedStrategies
  }
}
