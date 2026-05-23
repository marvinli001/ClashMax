import XCTest
@testable import ClashMax

final class SubscriptionFetcherTests: XCTestCase {
  func testRequestMovesBasicAuthCredentialsIntoAuthorizationHeader() throws {
    let fetcher = SubscriptionFetcher()
    let request = fetcher.request(url: URL(string: "https://user:p%40ss@example.com/sub?token=abc")!)

    XCTAssertEqual(request.url?.absoluteString, "https://example.com/sub?token=abc")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Basic \(Data("user:p@ss".utf8).base64EncodedString())"
    )
  }

  func testRequestUsesCustomFetchOptions() throws {
    let fetcher = SubscriptionFetcher()
    let request = fetcher.request(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(
        userAgent: "Clash Verge/2.0.0",
        timeout: 45,
        customHeaders: ["X-Panel-Token": "secret"]
      )
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Clash Verge/2.0.0")
    XCTAssertEqual(request.timeoutInterval, 45)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Panel-Token"), "secret")
  }

  func testSubscriptionFetchSettingsBuildOptionsFromCurrentMixedPort() throws {
    let settings = SubscriptionFetchSettings(
      userAgent: " Custom UA ",
      timeoutSeconds: 500,
      useLocalClashProxy: true,
      useSystemProxy: false,
      allowsInsecureTLS: true,
      automaticUpdatesEnabled: false
    )

    let options = settings.fetchOptions(currentMixedPort: 8899)

    XCTAssertEqual(options.userAgent, "Custom UA")
    XCTAssertEqual(options.timeout, TimeInterval(SubscriptionFetchSettings.maximumTimeoutSeconds))
    XCTAssertEqual(options.localProxyPort, 8899)
    XCTAssertTrue(options.allowsInsecureTLS)
    XCTAssertEqual(options.retryOrder, [.direct, .localClashProxy])
  }

  func testSubscriptionProviderOptionsCustomizeHeadersAndFetchProxy() throws {
    let base = SubscriptionFetchOptions(retryOrder: [.direct, .localClashProxy, .systemProxy])
    let providerOptions = SubscriptionProviderOptions(
      requestHeaders: [
        SubscriptionRequestHeader(name: " X-Token ", value: " secret "),
        SubscriptionRequestHeader(name: " ", value: "ignored")
      ],
      fetchProxy: .localClashProxy
    )

    let options = providerOptions.fetchOptions(from: base)

    XCTAssertEqual(options.retryOrder, [.localClashProxy])
    XCTAssertEqual(options.customHeaders, ["X-Token": "secret"])
  }

  func testResolverAcceptsAdditionalClashDeepLinkSchemes() throws {
    let cases = [
      "clashmeta://install-config?url=https%3A%2F%2Fexample.com%2Fsub%3Ftoken%3Dabc&name=Meta",
      "flclash://install-config?url=https%3A%2F%2Fexample.com%2Fsub%3Ftoken%3Ddef&name=FlClash"
    ]

    let resolved = cases.compactMap { SubscriptionURLResolver.resolve(rawInput: $0) }

    XCTAssertEqual(resolved.map(\.url.absoluteString), [
      "https://example.com/sub?token=abc",
      "https://example.com/sub?token=def"
    ])
    XCTAssertEqual(resolved.map(\.displayNameHint), ["Meta", "FlClash"])
  }

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

  func testFetchParsesPrefixedSubscriptionUserInfoHeader() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "x-amz-meta-subscription-userinfo": "upload=512; download=1024; total=2048"
      ]
    )!

    let result = try fetcher.decode(
      data: Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
      response: response
    )

    XCTAssertEqual(result.metadata.traffic?.upload, 512)
    XCTAssertEqual(result.metadata.traffic?.download, 1024)
    XCTAssertEqual(result.metadata.traffic?.total, 2048)
  }

  func testDecodeHonorsResponseCharset() throws {
    let fetcher = SubscriptionFetcher()
    let source = "proxies:\n  - name: Café\n    type: direct\n"
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=iso-8859-1"]
    )!

    let result = try fetcher.decode(data: source.data(using: .isoLatin1)!, response: response)

    XCTAssertEqual(result.source, source)
  }

  func testDecodeClassifiesHTMLLoginPageAsSubscriptionPanelError() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/html; charset=utf-8"]
    )!

    XCTAssertThrowsError(
      try fetcher.decode(
        data: Data("<!doctype html><html><title>Login</title></html>".utf8),
        response: response
      )
    ) { error in
      XCTAssertTrue(String(describing: error).contains("subscription returned a login or error page"))
    }
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
