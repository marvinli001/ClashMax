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

  func testSubscriptionFetchSettingsUseClashXGapDefaultCadence() throws {
    let settings = SubscriptionFetchSettings.default

    XCTAssertEqual(settings.defaultUpdateIntervalMinutes, 48 * 60)
    XCTAssertEqual(settings.backgroundCheckIntervalMinutes, 2 * 60)
    XCTAssertEqual(settings.retryCapMinutes, 6 * 60)
    XCTAssertFalse(settings.notifyOnUpdateFailure)
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
      url: URL(string: "https://user:secret@example.com/sub?token=abc&flag")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "text/yaml; charset=UTF-8",
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
    XCTAssertEqual(result.diagnostics.sanitizedURL, "https://example.com/sub?token=<redacted>&flag")
    XCTAssertEqual(result.diagnostics.userAgent, "clash.meta")
    XCTAssertEqual(result.diagnostics.httpStatusCode, 200)
    XCTAssertEqual(result.diagnostics.contentType, "text/yaml; charset=UTF-8")
    XCTAssertEqual(result.diagnostics.subscriptionUserInfo, "upload=1024; download=2048; total=4096; expire=1893456000")
    XCTAssertEqual(result.diagnostics.rawProfileUpdateInterval, "12")
    XCTAssertEqual(result.diagnostics.parsedProfileUpdateIntervalMinutes, 720)
    XCTAssertEqual(result.diagnostics.declaredCharset, "UTF-8")
    XCTAssertEqual(result.diagnostics.decodedCharset, "utf-8")
    XCTAssertTrue(result.diagnostics.responseHeaderNames.contains("subscription-userinfo"))
    XCTAssertTrue(result.diagnostics.responseHeaderNames.contains("profile-update-interval"))
  }

  func testFetchDiagnosticsRedactsSubscriptionTokensInURLPath() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://user:secret@example.com/link/path-token-123456?flag")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=UTF-8"]
    )!

    let result = try fetcher.decode(
      data: Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
      response: response
    )

    XCTAssertEqual(result.diagnostics.sanitizedURL, "https://example.com/link/<redacted>?flag")
  }

  func testFetchDiagnosticsRedactsUUIDSubscriptionTokensInURLPath() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/api/client/00000000-0000-0000-0000-000000000000?token=abc")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=UTF-8"]
    )!

    let result = try fetcher.decode(
      data: Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
      response: response
    )

    XCTAssertEqual(result.diagnostics.sanitizedURL, "https://example.com/api/client/<redacted>?token=<redacted>")
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
    XCTAssertEqual(result.diagnostics.declaredCharset, "iso-8859-1")
    XCTAssertEqual(result.diagnostics.decodedCharset, "iso-8859-1")
  }

  func testDecodeAcceptsValidYamlWithTextHTMLContentType() throws {
    let fetcher = SubscriptionFetcher()
    let source = """
    mixed-port: 7890
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [DIRECT]
    proxies:
      - name: DIRECT
        type: direct
    rules:
      - MATCH,DIRECT
    """
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: [
        "Content-Type": "text/html; charset=UTF-8",
        "subscription-userinfo": "upload=1; download=2; total=3",
        "content-disposition": "attachment; filename*=UTF-8''Remote%20Profile.yaml"
      ]
    )!

    let result = try fetcher.decode(data: Data(source.utf8), response: response)

    XCTAssertEqual(result.source, source)
    XCTAssertEqual(result.metadata.traffic?.download, 2)
    XCTAssertEqual(result.metadata.remoteFileName, "Remote Profile.yaml")
  }

  func testDecodeAcceptsBase64ProviderContentWithTextHTMLContentType() throws {
    let fetcher = SubscriptionFetcher()
    let providerContent = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#VLESS%20Node
    vmess://eyJuYW1lIjoiVk1lc3MgTm9kZSJ9
    """
    let encoded = Data(providerContent.utf8).base64EncodedString()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/html; charset=UTF-8"]
    )!

    let result = try fetcher.decode(data: Data(encoded.utf8), response: response)

    XCTAssertEqual(result.source, encoded)
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
      let fetchError = error as? SubscriptionFetchError
      XCTAssertEqual(fetchError?.kind, .panelResponse)
      XCTAssertEqual(fetchError?.diagnostics.httpStatusCode, 200)
      XCTAssertEqual(fetchError?.diagnostics.contentType, "text/html; charset=utf-8")
      XCTAssertTrue(String(describing: error).contains("subscription returned a login or error page"))
    }
  }

  func testDecodeClassifiesJSONPanelErrorAsSubscriptionPanelError() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json; charset=utf-8"]
    )!

    XCTAssertThrowsError(
      try fetcher.decode(
        data: Data(#"{"message":"invalid token"}"#.utf8),
        response: response
      )
    ) { error in
      let fetchError = error as? SubscriptionFetchError
      XCTAssertEqual(fetchError?.kind, .panelResponse)
      XCTAssertEqual(fetchError?.diagnostics.httpStatusCode, 200)
      XCTAssertEqual(fetchError?.diagnostics.contentType, "application/json; charset=utf-8")
      XCTAssertTrue(String(describing: error).contains("subscription returned a login or error page"))
    }
  }

  func testDecodeClassifiesHTTPStatusAndRecordsDiagnostics() throws {
    let fetcher = SubscriptionFetcher()
    let response = HTTPURLResponse(
      url: URL(string: "https://user:secret@example.com/sub?token=abc")!,
      statusCode: 403,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/plain"]
    )!

    XCTAssertThrowsError(
      try fetcher.decode(data: Data("Forbidden".utf8), response: response)
    ) { error in
      let fetchError = error as? SubscriptionFetchError
      XCTAssertEqual(fetchError?.kind, .httpStatus)
      XCTAssertEqual(fetchError?.diagnostics.httpStatusCode, 403)
      XCTAssertEqual(fetchError?.diagnostics.contentType, "text/plain")
      XCTAssertEqual(fetchError?.diagnostics.sanitizedURL, "https://example.com/sub?token=<redacted>")
      XCTAssertEqual(fetchError?.diagnostics.responseHeaderNames, ["Content-Type"])
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
      url: URL(string: "https://user:secret@example.com/sub?token=abc")!,
      options: SubscriptionFetchOptions(
        userAgent: "Custom UA",
        retryOrder: attempts,
        customHeaders: ["X-Panel-Token": "secret"]
      )
    ) { strategy, _ in
      let attemptCount = await recorder.record(strategy)
      if attemptCount < 3 {
        throw URLError(.cannotConnectToHost)
      }
      return (Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8), goodResponse)
    }

    let attemptedStrategies = await recorder.strategies()
    XCTAssertEqual(attemptedStrategies, [.direct, .localClashProxy, .systemProxy])
    XCTAssertEqual(result.source, "proxies:\n  - name: DIRECT\n    type: direct\n")
    XCTAssertEqual(result.diagnostics.sanitizedURL, "https://example.com/sub?token=<redacted>")
    XCTAssertEqual(result.diagnostics.userAgent, "Custom UA")
    XCTAssertEqual(result.diagnostics.attemptedStrategies, [.direct, .localClashProxy, .systemProxy])
    XCTAssertEqual(result.diagnostics.successfulStrategy, .systemProxy)
    XCTAssertEqual(
      result.diagnostics.requestHeaders.map(\.name),
      ["Accept", "Authorization", "User-Agent", "X-Panel-Token"]
    )
    XCTAssertEqual(result.diagnostics.requestHeaders.map(\.hasValue), [true, true, true, true])
  }

  func testInvalidProfileResponseRetriesOnceWithBundledCompatibilityUserAgent() async throws {
    let fetcher = SubscriptionFetcher()
    let recorder = UserAgentAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
    )!
    // Valid YAML mapping but no proxies/proxy-providers -> classified as invalidProfile, not a panel error.
    let invalidProfile = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n"
    let validProfile = "proxies:\n  - name: DIRECT\n    type: direct\n"

    let result = try await fetcher.fetch(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(
        userAgent: "clash.meta",
        retryOrder: [.direct],
        compatibilityUserAgent: "mihomo/1.19.27"
      )
    ) { _, userAgent in
      await recorder.record(userAgent)
      let body = userAgent == "clash.meta" ? invalidProfile : validProfile
      return (Data(body.utf8), response)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta", "mihomo/1.19.27"])
    XCTAssertEqual(result.source, validProfile)
    XCTAssertEqual(result.diagnostics.userAgent, "mihomo/1.19.27")
  }

  func testPanelErrorResponseRetriesOnceWithBundledCompatibilityUserAgent() async throws {
    let fetcher = SubscriptionFetcher()
    let recorder = UserAgentAttemptRecorder()
    let panelResponse = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/html; charset=utf-8"]
    )!
    let yamlResponse = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
    )!
    let validProfile = "proxies:\n  - name: DIRECT\n    type: direct\n"

    let result = try await fetcher.fetch(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(
        userAgent: "clash.meta",
        retryOrder: [.direct],
        compatibilityUserAgent: "mihomo/1.19.27"
      )
    ) { _, userAgent in
      await recorder.record(userAgent)
      if userAgent == "clash.meta" {
        return (Data("<!doctype html><html><title>Login</title></html>".utf8), panelResponse)
      }
      return (Data(validProfile.utf8), yamlResponse)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta", "mihomo/1.19.27"])
    XCTAssertEqual(result.source, validProfile)
    XCTAssertEqual(result.diagnostics.userAgent, "mihomo/1.19.27")
  }

  func testHTTPStatusErrorDoesNotTriggerCompatibilityUserAgentFallback() async throws {
    let fetcher = SubscriptionFetcher()
    let recorder = UserAgentAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 500,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/plain"]
    )!

    do {
      _ = try await fetcher.fetch(
        url: URL(string: "https://example.com/sub")!,
        options: SubscriptionFetchOptions(
          userAgent: "clash.meta",
          retryOrder: [.direct, .localClashProxy],
          compatibilityUserAgent: "mihomo/1.19.27"
        )
      ) { _, userAgent in
        await recorder.record(userAgent)
        return (Data("Server Error".utf8), response)
      }
      XCTFail("Expected HTTP 500 to throw a fetch error")
    } catch {
      XCTAssertEqual((error as? SubscriptionFetchError)?.kind, .httpStatus)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta", "clash.meta"])
  }

  func testNetworkErrorDoesNotTriggerCompatibilityUserAgentFallback() async throws {
    let fetcher = SubscriptionFetcher()
    let recorder = UserAgentAttemptRecorder()

    do {
      _ = try await fetcher.fetch(
        url: URL(string: "https://example.com/sub")!,
        options: SubscriptionFetchOptions(
          userAgent: "clash.meta",
          retryOrder: [.direct],
          compatibilityUserAgent: "mihomo/1.19.27"
        )
      ) { _, userAgent in
        await recorder.record(userAgent)
        throw URLError(.cannotConnectToHost)
      }
      XCTFail("Expected network error to throw a fetch error")
    } catch {
      XCTAssertEqual((error as? SubscriptionFetchError)?.kind, .network)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta"])
  }

  func testBlankOrMatchingCompatibilityUserAgentDoesNotTriggerFallback() async throws {
    let fetcher = SubscriptionFetcher()
    let recorder = UserAgentAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
    )!
    let invalidProfile = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n"

    do {
      _ = try await fetcher.fetch(
        url: URL(string: "https://example.com/sub")!,
        options: SubscriptionFetchOptions(
          userAgent: "clash.meta",
          retryOrder: [.direct],
          compatibilityUserAgent: "  clash.meta  "
        )
      ) { _, userAgent in
        await recorder.record(userAgent)
        return (Data(invalidProfile.utf8), response)
      }
      XCTFail("Expected invalid profile to throw a fetch error")
    } catch {
      XCTAssertEqual((error as? SubscriptionFetchError)?.kind, .invalidProfile)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta"])
  }

  func testFetchSettingsInjectBundledCompatibilityUserAgentIntoOptions() throws {
    let settings = SubscriptionFetchSettings(userAgent: "clash.meta")

    let injected = settings.fetchOptions(currentMixedPort: 7890, compatibilityUserAgent: "mihomo/1.19.27")
    XCTAssertEqual(injected.userAgent, "clash.meta")
    XCTAssertEqual(injected.compatibilityUserAgent, "mihomo/1.19.27")

    let pure = settings.fetchOptions(currentMixedPort: 7890)
    XCTAssertNil(pure.compatibilityUserAgent)
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

private actor UserAgentAttemptRecorder {
  private var recordedUserAgents: [String] = []

  func record(_ userAgent: String) {
    recordedUserAgents.append(userAgent)
  }

  func userAgents() -> [String] {
    recordedUserAgents
  }
}
