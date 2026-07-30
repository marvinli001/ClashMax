import Foundation
import Network
import XCTest
@testable import ClashMax

final class SubscriptionFetcherTests: XCTestCase {
  func testProfileUpstreamBindingForcesStrictRetryAndProviderCannotOverrideIt() async throws {
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Profile upstream",
        kind: .socks5,
        host: "proxy.example.com",
        port: 1080
      ),
      password: nil
    )
    let base = SubscriptionFetchOptions(
      retryOrder: [.direct, .localClashProxy, .systemProxy],
      profileUpstreamEndpoint: endpoint
    )
    let options = SubscriptionProviderOptions(fetchProxy: .direct).fetchOptions(from: base)
    let recorder = StrategyAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml"]
    )!

    let result = try await SubscriptionFetcher().fetch(
      url: URL(string: "https://example.com/sub")!,
      options: options
    ) { strategy, _ in
      _ = await recorder.record(strategy)
      return (
        Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
        response
      )
    }

    let attemptedStrategies = await recorder.strategies()
    XCTAssertEqual(base.retryOrder, [.profileUpstream])
    XCTAssertEqual(options.retryOrder, [.profileUpstream])
    XCTAssertEqual(attemptedStrategies, [.profileUpstream])
    XCTAssertEqual(result.diagnostics.successfulStrategy, .profileUpstream)
  }

  func testProviderOptionsCannotOverrideExplicitProfileUpstreamStrategyWithoutEndpoint() throws {
    let base = SubscriptionFetchOptions(retryOrder: [.profileUpstream])

    for fetchProxy in [
      SubscriptionProviderFetchProxy.direct,
      .localClashProxy,
      .systemProxy
    ] {
      let options = SubscriptionProviderOptions(fetchProxy: fetchProxy)
        .fetchOptions(from: base)
      XCTAssertEqual(options.retryOrder, [.profileUpstream])
    }
  }

  func testProfileUpstreamSOCKSFactoryUsesStrictNetworkProxyConfiguration() throws {
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Profile upstream",
        kind: .socks5,
        host: "proxy.example.com",
        port: 1080
      ),
      password: nil
    )

    let configuration = try SubscriptionProxySessionFactory.configuration(
      for: endpoint,
      timeout: 37
    )

    XCTAssertEqual(configuration.timeoutIntervalForRequest, 37)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 37)
    XCTAssertEqual(configuration.proxyConfigurations.count, 1)
    XCTAssertTrue(configuration.proxyConfigurations[0].debugDescription.contains("socksv5"))
    XCTAssertTrue(configuration.proxyConfigurations[0].debugDescription.contains("proxy.example.com:1080"))
    XCTAssertEqual(configuration.proxyConfigurations[0].matchDomains, [""])
    XCTAssertFalse(configuration.proxyConfigurations[0].allowFailover)

    let plan = try SubscriptionProxySessionFactory.plan(for: endpoint)
    XCTAssertEqual(plan.proxyKind, .socks5)
    XCTAssertFalse(plan.usesTLS)
    XCTAssertFalse(plan.usesCredential)
    XCTAssertFalse(plan.allowFailover)
  }

  func testProfileUpstreamHTTPFactoryAppliesAuthenticationAndTLSOptions() throws {
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Secure HTTP upstream",
        kind: .http,
        host: "proxy.example.com",
        port: 8443,
        authentication: OutboundProxyAuthentication(username: "sensitive-user"),
        httpOptions: OutboundProxyHTTPOptions(
          tlsEnabled: true,
          serverName: "proxy-sni.example.com",
          skipCertificateVerification: true
        )
      ),
      password: "sensitive-password"
    )

    let plan = try SubscriptionProxySessionFactory.plan(for: endpoint)
    let configuration = try SubscriptionProxySessionFactory.configuration(
      for: endpoint,
      timeout: 20
    )

    XCTAssertEqual(plan.proxyKind, .httpConnect)
    XCTAssertEqual(plan.host, "proxy.example.com")
    XCTAssertEqual(plan.port, 8443)
    XCTAssertTrue(plan.usesTLS)
    XCTAssertEqual(plan.tlsServerName, "proxy-sni.example.com")
    XCTAssertTrue(plan.skipsCertificateVerification)
    XCTAssertTrue(plan.usesCredential)
    XCTAssertFalse(plan.allowFailover)
    XCTAssertEqual(configuration.proxyConfigurations.count, 1)
    XCTAssertTrue(configuration.proxyConfigurations[0].debugDescription.contains("http_connect"))
    XCTAssertTrue(configuration.proxyConfigurations[0].debugDescription.contains("proxy.example.com:8443"))
    XCTAssertEqual(configuration.proxyConfigurations[0].matchDomains, [""])
    XCTAssertFalse(configuration.proxyConfigurations[0].allowFailover)
  }

  func testProfileUpstreamSOCKS5PerformsAuthenticatedFetchWithoutMihomoCore() async throws {
    let origin = try LocalOpenSSLSubscriptionOrigin()
    defer { origin.stop() }
    let proxy = try LocalSubscriptionProxyServer(
      kind: .socks5,
      username: "proxy-user",
      password: "proxy-password",
      relayPort: origin.port
    )
    defer { proxy.stop() }
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Local SOCKS",
        kind: .socks5,
        host: "127.0.0.1",
        port: proxy.port,
        authentication: OutboundProxyAuthentication(username: "proxy-user")
      ),
      password: "proxy-password"
    )

    let result = try await SubscriptionFetcher().fetch(
      url: origin.url,
      options: SubscriptionFetchOptions(
        timeout: 5,
        allowsInsecureTLS: true,
        profileUpstreamEndpoint: endpoint
      )
    )

    XCTAssertTrue(result.source.contains("name: DIRECT"))
    XCTAssertEqual(result.diagnostics.successfulStrategy, .profileUpstream)
    let snapshot = proxy.snapshot()
    XCTAssertGreaterThanOrEqual(snapshot.acceptedConnectionCount, 1)
    XCTAssertGreaterThanOrEqual(snapshot.successfulAuthenticationCount, 1)
    XCTAssertEqual(snapshot.servedResponseCount, 1)
    XCTAssertTrue(snapshot.requestedTargets.contains {
      $0.contains("subscription.local:\(origin.port)")
    })
  }

  func testProfileUpstreamHTTPConnectPerformsAuthenticatedFetchWithoutMihomoCore() async throws {
    let origin = try LocalOpenSSLSubscriptionOrigin()
    defer { origin.stop() }
    let proxy = try LocalSubscriptionProxyServer(
      kind: .httpConnect,
      username: "proxy-user",
      password: "proxy-password",
      relayPort: origin.port
    )
    defer { proxy.stop() }
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Local HTTP",
        kind: .http,
        host: "127.0.0.1",
        port: proxy.port,
        authentication: OutboundProxyAuthentication(username: "proxy-user")
      ),
      password: "proxy-password"
    )

    let result = try await SubscriptionFetcher().fetch(
      url: origin.url,
      options: SubscriptionFetchOptions(
        timeout: 5,
        allowsInsecureTLS: true,
        profileUpstreamEndpoint: endpoint
      )
    )

    XCTAssertTrue(result.source.contains("name: DIRECT"))
    XCTAssertEqual(result.diagnostics.successfulStrategy, .profileUpstream)
    let snapshot = proxy.snapshot()
    XCTAssertGreaterThanOrEqual(snapshot.acceptedConnectionCount, 1)
    XCTAssertGreaterThanOrEqual(snapshot.successfulAuthenticationCount, 1)
    XCTAssertEqual(snapshot.servedResponseCount, 1)
    XCTAssertTrue(snapshot.requestedTargets.contains {
      $0.contains("subscription.local:\(origin.port)")
    })
  }

  func testProfileUpstreamWrongPasswordFailsClosedForLocalSOCKS5AndHTTPConnect() async throws {
    for kind in [
      LocalSubscriptionProxyServer.Kind.socks5,
      .httpConnect
    ] {
      let proxy = try LocalSubscriptionProxyServer(
        kind: kind,
        username: "proxy-user",
        password: "correct-password"
      )
      defer { proxy.stop() }
      let endpoint = ResolvedOutboundProxyEndpoint(
        endpoint: OutboundProxyEndpoint(
          name: "Rejecting local proxy",
          kind: kind == .socks5 ? .socks5 : .http,
          host: "127.0.0.1",
          port: proxy.port,
          authentication: OutboundProxyAuthentication(username: "proxy-user")
        ),
        password: "wrong-password"
      )

      do {
        _ = try await SubscriptionFetcher().fetch(
          url: try XCTUnwrap(URL(string: "https://subscription.invalid/profile")),
          options: SubscriptionFetchOptions(
            timeout: 2,
            retryOrder: [.direct, .systemProxy],
            profileUpstreamEndpoint: endpoint
          )
        )
        XCTFail("Expected \(kind) authentication to fail")
      } catch let error as SubscriptionFetchError {
        XCTAssertEqual(error.diagnostics.attemptedStrategies, [.profileUpstream])
        XCTAssertEqual(error.diagnostics.failureStage, "transport")
      }

      let snapshot = proxy.snapshot()
      XCTAssertGreaterThanOrEqual(snapshot.rejectedAuthenticationCount, 1)
      XCTAssertEqual(snapshot.successfulAuthenticationCount, 0)
      XCTAssertEqual(snapshot.servedResponseCount, 0)
    }
  }

  func testProfileUpstreamBindingCannotBeBypassedByMutatingRetryOrder() async throws {
    var options = SubscriptionFetchOptions(
      retryOrder: [.systemProxy],
      profileUpstreamEndpoint: profileUpstreamEndpoint()
    )
    options.retryOrder = [.direct, .systemProxy]
    let recorder = StrategyAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml"]
    )!

    let result = try await SubscriptionFetcher().fetch(
      url: URL(string: "https://example.com/sub")!,
      options: options
    ) { strategy, _ in
      _ = await recorder.record(strategy)
      return (
        Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
        response
      )
    }

    let strategies = await recorder.strategies()
    XCTAssertEqual(strategies, [.profileUpstream])
    XCTAssertEqual(result.diagnostics.attemptedStrategies, [.profileUpstream])
    XCTAssertEqual(result.diagnostics.endpointName, "Profile upstream")
    XCTAssertNil(result.diagnostics.failureStage)
  }

  func testProfileUpstreamCompatibilityUserAgentRetriesTheSameStrategy() async throws {
    let strategyRecorder = StrategyAttemptRecorder()
    let userAgentRecorder = UserAgentAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
    )!
    let invalidProfile = "mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n"
    let validProfile = "proxies:\n  - name: DIRECT\n    type: direct\n"

    let result = try await SubscriptionFetcher().fetch(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(
        userAgent: "clash.meta",
        retryOrder: [.direct, .systemProxy],
        compatibilityUserAgent: "mihomo/1.19.29",
        profileUpstreamEndpoint: profileUpstreamEndpoint()
      )
    ) { strategy, userAgent in
      _ = await strategyRecorder.record(strategy)
      await userAgentRecorder.record(userAgent)
      return (
        Data((userAgent == "clash.meta" ? invalidProfile : validProfile).utf8),
        response
      )
    }

    let strategies = await strategyRecorder.strategies()
    let userAgents = await userAgentRecorder.userAgents()
    XCTAssertEqual(strategies, [.profileUpstream, .profileUpstream])
    XCTAssertEqual(userAgents, ["clash.meta", "mihomo/1.19.29"])
    XCTAssertEqual(result.diagnostics.successfulStrategy, .profileUpstream)
    XCTAssertEqual(result.diagnostics.endpointName, "Profile upstream")
  }

  func testProfileUpstreamFailsClosedWithoutEndpointBeforeAttemptingTransport() async throws {
    let recorder = StrategyAttemptRecorder()
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml"]
    )!

    do {
      _ = try await SubscriptionFetcher().fetch(
        url: URL(string: "https://example.com/sub")!,
        options: SubscriptionFetchOptions(retryOrder: [.profileUpstream])
      ) { strategy, _ in
        _ = await recorder.record(strategy)
        return (
          Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
          response
        )
      }
      XCTFail("Expected missing profile upstream endpoint to fail closed")
    } catch let error as SubscriptionFetchError {
      XCTAssertEqual(error.diagnostics.attemptedStrategies, [])
      XCTAssertNil(error.diagnostics.endpointName)
      XCTAssertEqual(error.diagnostics.failureStage, "configuration")
    }

    let strategies = await recorder.strategies()
    XCTAssertEqual(strategies, [])
  }

  func testProfileUpstreamFactoryRejectsMissingSecretAndInvalidHostPortWithoutLeakingSecrets() throws {
    let missingSecret = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Authenticated upstream",
        kind: .socks5,
        host: "proxy.example.com",
        port: 1080,
        authentication: OutboundProxyAuthentication(username: "sensitive-user")
      ),
      password: " "
    )

    XCTAssertThrowsError(
      try SubscriptionProxySessionFactory.configuration(for: missingSecret, timeout: 20)
    ) { error in
      let text = "\(error) \(error.localizedDescription)"
      XCTAssertFalse(text.contains("sensitive-user"))
      XCTAssertFalse(text.contains("sensitive-password"))
    }

    let invalidEndpoints: [(String, Int)] = [
      ("", 1080),
      ("bad host", 1080),
      ("https://proxy.example.com", 1080),
      ("proxy.example.com", 0),
      ("proxy.example.com", 65_536)
    ]
    for (host, port) in invalidEndpoints {
      let endpoint = ResolvedOutboundProxyEndpoint(
        endpoint: OutboundProxyEndpoint(
          name: "Invalid upstream",
          kind: .socks5,
          host: host,
          port: port
        ),
        password: nil
      )
      XCTAssertThrowsError(
        try SubscriptionProxySessionFactory.configuration(for: endpoint, timeout: 20),
        "Expected \(host):\(port) to be rejected"
      )
    }
  }

  func testProfileUpstreamTransportErrorAndDiagnosticsExcludeSecretsAndProxyAuthorization() async throws {
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Safe endpoint name",
        kind: .socks5,
        host: "proxy.example.com",
        port: 1080,
        authentication: OutboundProxyAuthentication(username: "sensitive-user")
      ),
      password: "sensitive-password"
    )
    let options = SubscriptionFetchOptions(
      customHeaders: [
        "Proxy-Authorization": "Basic sensitive-auth-header",
        "X-Safe": "present"
      ],
      profileUpstreamEndpoint: endpoint
    )

    do {
      _ = try await SubscriptionFetcher().fetch(
        url: URL(string: "https://example.com/sub")!,
        options: options
      ) { _, _ in
        throw NSError(
          domain: "sensitive-user",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "sensitive-password Proxy-Authorization Basic sensitive-auth-header"
          ]
        )
      }
      XCTFail("Expected transport failure")
    } catch let error as SubscriptionFetchError {
      let diagnosticsJSON = String(
        decoding: try JSONEncoder().encode(error.diagnostics),
        as: UTF8.self
      )
      let combined = [
        error.message,
        error.description,
        error.localizedDescription,
        diagnosticsJSON
      ].joined(separator: "\n")
      for sensitiveValue in [
        "sensitive-user",
        "sensitive-password",
        "sensitive-auth-header",
        "Proxy-Authorization"
      ] {
        XCTAssertFalse(combined.contains(sensitiveValue), "Leaked \(sensitiveValue)")
      }
      XCTAssertEqual(error.diagnostics.endpointName, "Safe endpoint name")
      XCTAssertEqual(error.diagnostics.failureStage, "transport")
      XCTAssertEqual(error.diagnostics.requestHeaders.map(\.name), ["Accept", "User-Agent", "X-Safe"])
    }
  }

  func testProfileUpstreamUnsafeOrBlankEndpointNameCannotReenableSecretLeakage() async throws {
    for endpointName in [" ", "sensitive-user sensitive-password"] {
      let endpoint = ResolvedOutboundProxyEndpoint(
        endpoint: OutboundProxyEndpoint(
          name: endpointName,
          kind: .socks5,
          host: "proxy.example.com",
          port: 1080,
          authentication: OutboundProxyAuthentication(username: "sensitive-user")
        ),
        password: "sensitive-password"
      )

      do {
        _ = try await SubscriptionFetcher().fetch(
          url: URL(string: "https://example.com/sub")!,
          options: SubscriptionFetchOptions(profileUpstreamEndpoint: endpoint)
        ) { _, _ in
          throw NSError(
            domain: "sensitive-user",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "sensitive-password"]
          )
        }
        XCTFail("Expected transport failure")
      } catch let error as SubscriptionFetchError {
        let diagnosticsJSON = String(
          decoding: try JSONEncoder().encode(error.diagnostics),
          as: UTF8.self
        )
        let combined = "\(error.message)\n\(error.localizedDescription)\n\(diagnosticsJSON)"
        XCTAssertFalse(combined.contains("sensitive-user"))
        XCTAssertFalse(combined.contains("sensitive-password"))
        XCTAssertNil(error.diagnostics.endpointName)
        XCTAssertEqual(error.diagnostics.failureStage, "transport")
      }
    }
  }

  func testProfileUpstreamResponseFailuresRecordSpecificFailureStage() async throws {
    let url = URL(string: "https://example.com/sub")!
    let cases: [(Data, HTTPURLResponse, SubscriptionUpdateFailureKind, String)] = [
      (
        Data("Service unavailable".utf8),
        HTTPURLResponse(
          url: url,
          statusCode: 503,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/plain"]
        )!,
        .httpStatus,
        "response"
      ),
      (
        Data([0xFF, 0xFE, 0xFF]),
        HTTPURLResponse(
          url: url,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
        )!,
        .decoding,
        "decoding"
      ),
      (
        Data("mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n".utf8),
        HTTPURLResponse(
          url: url,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "text/yaml; charset=utf-8"]
        )!,
        .invalidProfile,
        "validation"
      )
    ]

    for (data, response, expectedKind, expectedStage) in cases {
      do {
        _ = try await SubscriptionFetcher().fetch(
          url: url,
          options: SubscriptionFetchOptions(
            profileUpstreamEndpoint: profileUpstreamEndpoint()
          )
        ) { _, _ in
          (data, response)
        }
        XCTFail("Expected \(expectedKind) failure")
      } catch let error as SubscriptionFetchError {
        XCTAssertEqual(error.kind, expectedKind)
        XCTAssertEqual(error.diagnostics.endpointName, "Profile upstream")
        XCTAssertEqual(error.diagnostics.failureStage, expectedStage)
      }
    }
  }

  func testProfileUpstreamSuccessfulDiagnosticsExcludeProxyAuthorizationAndSecrets() async throws {
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Safe endpoint name",
        kind: .http,
        host: "proxy.example.com",
        port: 8080,
        authentication: OutboundProxyAuthentication(username: "sensitive-user")
      ),
      password: "sensitive-password"
    )
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/sub")!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "text/yaml"]
    )!

    let result = try await SubscriptionFetcher().fetch(
      url: URL(string: "https://example.com/sub")!,
      options: SubscriptionFetchOptions(
        customHeaders: ["Proxy-Authorization": "Basic sensitive-auth-header"],
        profileUpstreamEndpoint: endpoint
      )
    ) { _, _ in
      (
        Data("proxies:\n  - name: DIRECT\n    type: direct\n".utf8),
        response
      )
    }

    let diagnosticsJSON = String(
      decoding: try JSONEncoder().encode(result.diagnostics),
      as: UTF8.self
    )
    XCTAssertEqual(result.diagnostics.endpointName, "Safe endpoint name")
    XCTAssertFalse(result.diagnostics.requestHeaders.contains { $0.name == "Proxy-Authorization" })
    for sensitiveValue in [
      "sensitive-user",
      "sensitive-password",
      "sensitive-auth-header",
      "Proxy-Authorization"
    ] {
      XCTAssertFalse(diagnosticsJSON.contains(sensitiveValue), "Leaked \(sensitiveValue)")
    }
  }

  func testSubscriptionFetchDiagnosticsDecodeOlderPayloadWithoutUpstreamFields() throws {
    let original = SubscriptionFetchDiagnostics(
      sanitizedURL: "https://example.com/sub",
      userAgent: "clash.meta",
      attemptedStrategies: [.direct],
      successfulStrategy: .direct
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
        as? [String: Any]
    )
    object.removeValue(forKey: "endpointName")
    object.removeValue(forKey: "failureStage")

    let decoded = try JSONDecoder().decode(
      SubscriptionFetchDiagnostics.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(decoded.endpointName)
    XCTAssertNil(decoded.failureStage)
  }

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

  func testRequestStripsProxyAuthorizationOnlyForProfileUpstreamFetches() throws {
    let fetcher = SubscriptionFetcher()
    let url = URL(string: "https://example.com/sub")!
    let customHeaders = [
      "pRoXy-AuThOrIzAtIoN": "Basic sensitive-proxy-credential",
      "X-Panel-Token": "safe-custom-header"
    ]

    var endpointBoundOptions = SubscriptionFetchOptions(
      retryOrder: [.direct],
      customHeaders: customHeaders,
      profileUpstreamEndpoint: profileUpstreamEndpoint()
    )
    endpointBoundOptions.retryOrder = [.direct]
    let endpointBoundRequest = fetcher.request(url: url, options: endpointBoundOptions)

    let explicitStrategyRequest = fetcher.request(
      url: url,
      options: SubscriptionFetchOptions(
        retryOrder: [.profileUpstream],
        customHeaders: customHeaders
      )
    )
    let directRequest = fetcher.request(
      url: url,
      options: SubscriptionFetchOptions(
        retryOrder: [.direct],
        customHeaders: customHeaders
      )
    )

    XCTAssertNil(endpointBoundRequest.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(
      endpointBoundRequest.value(forHTTPHeaderField: "X-Panel-Token"),
      "safe-custom-header"
    )
    XCTAssertNil(explicitStrategyRequest.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(
      explicitStrategyRequest.value(forHTTPHeaderField: "X-Panel-Token"),
      "safe-custom-header"
    )
    XCTAssertEqual(
      directRequest.value(forHTTPHeaderField: "Proxy-Authorization"),
      "Basic sensitive-proxy-credential"
    )
    XCTAssertEqual(
      directRequest.value(forHTTPHeaderField: "X-Panel-Token"),
      "safe-custom-header"
    )
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
        compatibilityUserAgent: "mihomo/1.19.29"
      )
    ) { _, userAgent in
      await recorder.record(userAgent)
      let body = userAgent == "clash.meta" ? invalidProfile : validProfile
      return (Data(body.utf8), response)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta", "mihomo/1.19.29"])
    XCTAssertEqual(result.source, validProfile)
    XCTAssertEqual(result.diagnostics.userAgent, "mihomo/1.19.29")
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
        compatibilityUserAgent: "mihomo/1.19.29"
      )
    ) { _, userAgent in
      await recorder.record(userAgent)
      if userAgent == "clash.meta" {
        return (Data("<!doctype html><html><title>Login</title></html>".utf8), panelResponse)
      }
      return (Data(validProfile.utf8), yamlResponse)
    }

    let userAgents = await recorder.userAgents()
    XCTAssertEqual(userAgents, ["clash.meta", "mihomo/1.19.29"])
    XCTAssertEqual(result.source, validProfile)
    XCTAssertEqual(result.diagnostics.userAgent, "mihomo/1.19.29")
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
          compatibilityUserAgent: "mihomo/1.19.29"
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
          compatibilityUserAgent: "mihomo/1.19.29"
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

    let injected = settings.fetchOptions(currentMixedPort: 7890, compatibilityUserAgent: "mihomo/1.19.29")
    XCTAssertEqual(injected.userAgent, "clash.meta")
    XCTAssertEqual(injected.compatibilityUserAgent, "mihomo/1.19.29")

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

private func profileUpstreamEndpoint() -> ResolvedOutboundProxyEndpoint {
  ResolvedOutboundProxyEndpoint(
    endpoint: OutboundProxyEndpoint(
      name: "Profile upstream",
      kind: .socks5,
      host: "proxy.example.com",
      port: 1080
    ),
    password: nil
  )
}

private final class LocalOpenSSLSubscriptionOrigin: @unchecked Sendable {
  private enum StartupError: Error {
    case unavailable
    case certificateGenerationFailed(Int32)
    case serverExited(Int32)
    case timedOut
  }

  private let directoryURL: URL
  private let process: Process
  private let lock = NSLock()
  private var stopped = false

  let port: Int

  var url: URL {
    URL(string: "https://subscription.local:\(port)/profile")!
  }

  init() throws {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clashmax-local-subscription-origin-\(UUID().uuidString)",
      isDirectory: true
    )
    let process = Process()
    let port = try Self.reserveUnusedTCPPort()
    self.directoryURL = directoryURL
    self.process = process
    self.port = port

    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      try Data(
        """
        proxies:
          - name: DIRECT
            type: direct
        """.utf8
      ).write(
        to: directoryURL.appendingPathComponent("profile"),
        options: .atomic
      )
      try Self.generateCertificate(in: directoryURL)

      process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
      process.arguments = [
        "s_server",
        "-accept", "\(port)",
        "-cert", "cert.pem",
        "-key", "key.pem",
        "-WWW",
        "-quiet"
      ]
      process.currentDirectoryURL = directoryURL
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      try waitUntilListening()
    } catch {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: directoryURL)
      throw error
    }
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    lock.unlock()

    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: directoryURL)
  }

  private static func generateCertificate(in directoryURL: URL) throws {
    let generator = Process()
    generator.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    generator.arguments = [
      "req",
      "-x509",
      "-newkey", "rsa:2048",
      "-nodes",
      "-keyout", "key.pem",
      "-out", "cert.pem",
      "-subj", "/CN=subscription.local",
      "-days", "1"
    ]
    generator.currentDirectoryURL = directoryURL
    generator.standardOutput = FileHandle.nullDevice
    generator.standardError = FileHandle.nullDevice
    try generator.run()
    generator.waitUntilExit()
    guard generator.terminationStatus == 0 else {
      throw StartupError.certificateGenerationFailed(generator.terminationStatus)
    }
  }

  private static func reserveUnusedTCPPort() throws -> Int {
    let listener = try NWListener(using: .tcp, on: .any)
    let queue = DispatchQueue(
      label: "io.github.clashmax.tests.local-subscription-origin-port",
      qos: .userInitiated
    )
    let semaphore = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    nonisolated(unsafe) var startupError: Error?
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        semaphore.signal()
      case let .failed(error):
        stateLock.lock()
        startupError = error
        stateLock.unlock()
        semaphore.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { connection in
      connection.cancel()
    }
    listener.start(queue: queue)
    guard semaphore.wait(timeout: .now() + 2) == .success else {
      listener.cancel()
      throw StartupError.timedOut
    }
    stateLock.lock()
    let error = startupError
    stateLock.unlock()
    guard error == nil, let port = listener.port else {
      listener.cancel()
      throw error ?? StartupError.unavailable
    }
    listener.cancel()
    return Int(port.rawValue)
  }

  private func waitUntilListening() throws {
    for _ in 0..<40 {
      guard process.isRunning else {
        throw StartupError.serverExited(process.terminationStatus)
      }
      let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: UInt16(port))!,
        using: .tcp
      )
      let semaphore = DispatchSemaphore(value: 0)
      let stateLock = NSLock()
      nonisolated(unsafe) var ready = false
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          stateLock.lock()
          ready = true
          stateLock.unlock()
          semaphore.signal()
        case .failed, .cancelled:
          semaphore.signal()
        default:
          break
        }
      }
      connection.start(
        queue: DispatchQueue.global(qos: .userInitiated)
      )
      _ = semaphore.wait(timeout: .now() + 0.1)
      stateLock.lock()
      let didBecomeReady = ready
      stateLock.unlock()
      connection.cancel()
      if didBecomeReady {
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw StartupError.timedOut
  }
}

private final class LocalSubscriptionProxyServer: @unchecked Sendable {
  enum Kind: Equatable, CustomStringConvertible, Sendable {
    case socks5
    case httpConnect

    var description: String {
      switch self {
      case .socks5: "SOCKS5"
      case .httpConnect: "HTTP CONNECT"
      }
    }
  }

  struct Snapshot: Equatable, Sendable {
    var acceptedConnectionCount: Int
    var successfulAuthenticationCount: Int
    var rejectedAuthenticationCount: Int
    var servedResponseCount: Int
    var requestedTargets: [String]
  }

  private enum StartupError: Error {
    case timedOut
    case missingPort
    case failed(String)
  }

  private let listener: NWListener
  private let queue = DispatchQueue(
    label: "io.github.clashmax.tests.local-subscription-proxy"
  )
  private let lock = NSLock()
  private var handlers: [ObjectIdentifier: LocalSubscriptionProxyConnectionHandler] = [:]
  private var state = Snapshot(
    acceptedConnectionCount: 0,
    successfulAuthenticationCount: 0,
    rejectedAuthenticationCount: 0,
    servedResponseCount: 0,
    requestedTargets: []
  )
  private var stopped = false

  var port: Int {
    Int(listener.port?.rawValue ?? 0)
  }

  init(
    kind: Kind,
    username: String?,
    password: String?,
    relayPort: Int? = nil
  ) throws {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    let startupLock = NSLock()
    nonisolated(unsafe) var startupError: Error?
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.signal()
      case let .failed(error):
        startupLock.lock()
        startupError = StartupError.failed(error.localizedDescription)
        startupLock.unlock()
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(
        connection,
        kind: kind,
        username: username,
        password: password,
        relayPort: relayPort
      )
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 2) == .success else {
      listener.cancel()
      throw StartupError.timedOut
    }
    startupLock.lock()
    let error = startupError
    startupLock.unlock()
    if let error {
      listener.cancel()
      throw error
    }
    guard listener.port != nil else {
      listener.cancel()
      throw StartupError.missingPort
    }
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    let activeHandlers = Array(handlers.values)
    handlers.removeAll()
    lock.unlock()

    listener.cancel()
    activeHandlers.forEach { $0.cancel() }
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  private func accept(
    _ connection: NWConnection,
    kind: Kind,
    username: String?,
    password: String?,
    relayPort: Int?
  ) {
    let handler = LocalSubscriptionProxyConnectionHandler(
      connection: connection,
      queue: queue,
      kind: kind,
      username: username,
      password: password,
      relayPort: relayPort,
      recordAuthentication: { [weak self] accepted in
        self?.recordAuthentication(accepted)
      },
      recordTarget: { [weak self] target in
        self?.recordTarget(target)
      },
      recordResponse: { [weak self] in
        self?.recordResponse()
      },
      onFinish: { [weak self] identifier in
        self?.removeHandler(identifier)
      }
    )
    let identifier = ObjectIdentifier(handler)
    lock.lock()
    guard !stopped else {
      lock.unlock()
      handler.cancel()
      return
    }
    state.acceptedConnectionCount += 1
    handlers[identifier] = handler
    lock.unlock()
    handler.start()
  }

  private func recordAuthentication(_ accepted: Bool) {
    lock.lock()
    if accepted {
      state.successfulAuthenticationCount += 1
    } else {
      state.rejectedAuthenticationCount += 1
    }
    lock.unlock()
  }

  private func recordTarget(_ target: String) {
    lock.lock()
    state.requestedTargets.append(target)
    lock.unlock()
  }

  private func recordResponse() {
    lock.lock()
    state.servedResponseCount += 1
    lock.unlock()
  }

  private func removeHandler(_ identifier: ObjectIdentifier) {
    lock.lock()
    handlers[identifier] = nil
    lock.unlock()
  }
}

private final class LocalSubscriptionProxyConnectionHandler: @unchecked Sendable {
  private static let responseBody = """
  proxies:
    - name: DIRECT
      type: direct
  """

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let kind: LocalSubscriptionProxyServer.Kind
  private let username: String?
  private let password: String?
  private let relayPort: Int?
  private let recordAuthentication: @Sendable (Bool) -> Void
  private let recordTarget: @Sendable (String) -> Void
  private let recordResponse: @Sendable () -> Void
  private let onFinish: @Sendable (ObjectIdentifier) -> Void
  private var buffer = Data()
  private var upstreamConnection: NWConnection?
  private var recordedRelayResponse = false
  private var finished = false

  init(
    connection: NWConnection,
    queue: DispatchQueue,
    kind: LocalSubscriptionProxyServer.Kind,
    username: String?,
    password: String?,
    relayPort: Int?,
    recordAuthentication: @escaping @Sendable (Bool) -> Void,
    recordTarget: @escaping @Sendable (String) -> Void,
    recordResponse: @escaping @Sendable () -> Void,
    onFinish: @escaping @Sendable (ObjectIdentifier) -> Void
  ) {
    self.connection = connection
    self.queue = queue
    self.kind = kind
    self.username = username
    self.password = password
    self.relayPort = relayPort
    self.recordAuthentication = recordAuthentication
    self.recordTarget = recordTarget
    self.recordResponse = recordResponse
    self.onFinish = onFinish
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
    switch kind {
    case .socks5:
      readSOCKS5Greeting()
    case .httpConnect:
      readHTTPProxyRequest()
    }
  }

  func cancel() {
    connection.cancel()
    finish()
  }

  private func readSOCKS5Greeting() {
    readExactly(2) { [weak self] header in
      guard let self, header.first == 0x05 else {
        self?.finish()
        return
      }
      let methodCount = Int(header[header.index(after: header.startIndex)])
      self.readExactly(methodCount) { [weak self] methods in
        guard let self else { return }
        let requiresAuthentication = self.username != nil || self.password != nil
        let method: UInt8 = requiresAuthentication ? 0x02 : 0x00
        guard methods.contains(method) else {
          self.send(Data([0x05, 0xFF]), closeAfterSending: true)
          return
        }
        self.send(Data([0x05, method])) { [weak self] in
          if requiresAuthentication {
            self?.readSOCKS5Authentication()
          } else {
            self?.recordAuthentication(true)
            self?.readSOCKS5ConnectRequest()
          }
        }
      }
    }
  }

  private func readSOCKS5Authentication() {
    readExactly(2) { [weak self] header in
      guard let self, header.first == 0x01 else {
        self?.finish()
        return
      }
      let usernameLength = Int(header[header.index(after: header.startIndex)])
      self.readExactly(usernameLength + 1) { [weak self] usernameAndPasswordLength in
        guard let self,
              let passwordLengthByte = usernameAndPasswordLength.last
        else {
          self?.finish()
          return
        }
        let receivedUsername = String(
          decoding: usernameAndPasswordLength.dropLast(),
          as: UTF8.self
        )
        self.readExactly(Int(passwordLengthByte)) { [weak self] passwordData in
          guard let self else { return }
          let receivedPassword = String(decoding: passwordData, as: UTF8.self)
          let accepted = receivedUsername == self.username
            && receivedPassword == self.password
          self.recordAuthentication(accepted)
          self.send(Data([0x01, accepted ? 0x00 : 0x01]), closeAfterSending: !accepted) { [weak self] in
            self?.readSOCKS5ConnectRequest()
          }
        }
      }
    }
  }

  private func readSOCKS5ConnectRequest() {
    readExactly(4) { [weak self] header in
      guard let self,
            header.first == 0x05,
            header[header.index(header.startIndex, offsetBy: 1)] == 0x01
      else {
        self?.finish()
        return
      }
      let addressType = header[header.index(header.startIndex, offsetBy: 3)]
      switch addressType {
      case 0x01:
        self.readExactly(6) { [weak self] addressAndPort in
          let bytes = Array(addressAndPort)
          let target = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3]):\(Int(bytes[4]) << 8 | Int(bytes[5]))"
          self?.completeSOCKS5Connect(target: target)
        }
      case 0x03:
        self.readExactly(1) { [weak self] lengthData in
          guard let self, let length = lengthData.first else { return }
          self.readExactly(Int(length) + 2) { [weak self] hostAndPort in
            let hostBytes = hostAndPort.dropLast(2)
            let portBytes = hostAndPort.suffix(2)
            let port = Int(portBytes[portBytes.startIndex]) << 8
              | Int(portBytes[portBytes.index(after: portBytes.startIndex)])
            self?.completeSOCKS5Connect(
              target: "\(String(decoding: hostBytes, as: UTF8.self)):\(port)"
            )
          }
        }
      case 0x04:
        self.readExactly(18) { [weak self] addressAndPort in
          let bytes = Array(addressAndPort)
          let groups = stride(from: 0, to: 16, by: 2).map {
            String(format: "%02x%02x", bytes[$0], bytes[$0 + 1])
          }
          let port = Int(bytes[16]) << 8 | Int(bytes[17])
          self?.completeSOCKS5Connect(target: "\(groups.joined(separator: ":")):\(port)")
        }
      default:
        finish()
      }
    }
  }

  private func completeSOCKS5Connect(target: String) {
    recordTarget(target)
    let successResponse = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0])
    if relayPort != nil {
      connectToRelay(proxySuccessResponse: successResponse)
    } else {
      send(successResponse) { [weak self] in
        self?.readTunneledHTTPRequest()
      }
    }
  }

  private func readHTTPProxyRequest() {
    readHeaders { [weak self] headerData in
      guard let self else { return }
      let header = String(decoding: headerData, as: UTF8.self)
      let requestLines = header.components(separatedBy: "\r\n")
      let requestLine = requestLines.first ?? ""
      let headerNames = requestLines.dropFirst().compactMap { line -> String? in
        guard let separator = line.firstIndex(of: ":") else { return nil }
        return String(line[..<separator]).lowercased()
      }
      self.recordTarget(
        "\(requestLine) headers=\(headerNames.sorted().joined(separator: ","))"
      )
      let accepted = self.httpProxyAuthorizationIsValid(header)
      self.recordAuthentication(accepted)
      guard accepted else {
        self.sendFinal(
          Data((
            "HTTP/1.1 407 Proxy Authentication Required\r\n"
              + "Proxy-Authenticate: Basic realm=\"ClashMax Tests\"\r\n"
              + "Content-Length: 0\r\n"
              + "Proxy-Connection: close\r\n"
              + "Connection: close\r\n"
              + "\r\n"
          ).utf8)
        )
        return
      }

      if requestLine.uppercased().hasPrefix("CONNECT ") {
        let successResponse = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        if self.relayPort != nil {
          self.connectToRelay(proxySuccessResponse: successResponse)
        } else {
          self.send(successResponse) { [weak self] in
            self?.readTunneledHTTPRequest()
          }
        }
      } else {
        self.sendSubscriptionResponse()
      }
    }
  }

  private func httpProxyAuthorizationIsValid(_ header: String) -> Bool {
    guard let username, let password else { return true }
    return header.components(separatedBy: "\r\n").contains { line in
      let parts = line.split(separator: ":", maxSplits: 1).map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard
        parts.count == 2,
        parts[0].caseInsensitiveCompare("Proxy-Authorization") == .orderedSame
      else {
        return false
      }
      let authorizationParts = parts[1].split(
        maxSplits: 1,
        omittingEmptySubsequences: true,
        whereSeparator: \.isWhitespace
      )
      guard
        authorizationParts.count == 2,
        authorizationParts[0].caseInsensitiveCompare("Basic") == .orderedSame,
        let credentialData = Data(base64Encoded: String(authorizationParts[1]))
      else {
        return false
      }
      return String(decoding: credentialData, as: UTF8.self) == "\(username):\(password)"
    }
  }

  private func readTunneledHTTPRequest() {
    readHeaders { [weak self] _ in
      self?.sendSubscriptionResponse()
    }
  }

  private func sendSubscriptionResponse() {
    let body = Self.responseBody
    let response = """
    HTTP/1.1 200 OK\r
    Content-Type: text/yaml; charset=utf-8\r
    Content-Length: \(Data(body.utf8).count)\r
    Connection: close\r
    \r
    \(body)
    """
    recordResponse()
    send(Data(response.utf8), closeAfterSending: true)
  }

  private func connectToRelay(proxySuccessResponse: Data) {
    guard
      let relayPort,
      let port = NWEndpoint.Port(rawValue: UInt16(relayPort))
    else {
      finish()
      return
    }
    let upstream = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    upstreamConnection = upstream
    upstream.stateUpdateHandler = { [weak self, weak upstream] state in
      guard let self, let upstream else { return }
      switch state {
      case .ready:
        upstream.stateUpdateHandler = nil
        self.send(proxySuccessResponse) { [weak self, weak upstream] in
          guard let self, let upstream else { return }
          self.relay(from: self.connection, to: upstream, recordsResponse: false)
          self.relay(from: upstream, to: self.connection, recordsResponse: true)
        }
      case .failed, .cancelled:
        self.finish()
      default:
        break
      }
    }
    upstream.start(queue: queue)
  }

  private func relay(
    from source: NWConnection,
    to destination: NWConnection,
    recordsResponse: Bool
  ) {
    source.receive(
      minimumIncompleteLength: 1,
      maximumLength: 65_536
    ) { [weak self, weak source, weak destination] data, _, isComplete, error in
      guard let self, let source, let destination else { return }
      if let data, !data.isEmpty {
        if recordsResponse, !self.recordedRelayResponse {
          self.recordedRelayResponse = true
          self.recordResponse()
        }
        destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
          guard let self else { return }
          if sendError != nil || isComplete {
            self.finish()
          } else {
            self.relay(
              from: source,
              to: destination,
              recordsResponse: recordsResponse
            )
          }
        })
      } else if error != nil || isComplete {
        self.finish()
      } else {
        self.relay(
          from: source,
          to: destination,
          recordsResponse: recordsResponse
        )
      }
    }
  }

  private func readHeaders(
    completion: @escaping @Sendable (Data) -> Void
  ) {
    let separator = Data("\r\n\r\n".utf8)
    if let range = buffer.range(of: separator) {
      let header = buffer[..<range.upperBound]
      buffer.removeSubrange(..<range.upperBound)
      completion(Data(header))
      return
    }
    receiveMore {
      self.readHeaders(completion: completion)
    }
  }

  private func readExactly(
    _ count: Int,
    completion: @escaping @Sendable (Data) -> Void
  ) {
    guard count >= 0 else {
      finish()
      return
    }
    if buffer.count >= count {
      let value = buffer.prefix(count)
      buffer.removeFirst(count)
      completion(Data(value))
      return
    }
    receiveMore {
      self.readExactly(count, completion: completion)
    }
  }

  private func receiveMore(
    completion: @escaping @Sendable () -> Void
  ) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 65_536
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.buffer.append(data)
      }
      if error != nil || (isComplete && self.buffer.isEmpty) {
        self.finish()
      } else {
        completion()
      }
    }
  }

  private func send(
    _ data: Data,
    closeAfterSending: Bool = false,
    completion: (@Sendable () -> Void)? = nil
  ) {
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      guard error == nil else {
        self.finish()
        return
      }
      if closeAfterSending {
        self.connection.cancel()
        self.finish()
      } else {
        completion?()
      }
    })
  }

  private func sendFinal(_ data: Data) {
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      guard error == nil else {
        self.finish()
        return
      }
      self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
        self.finish()
      }
    })
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    connection.cancel()
    upstreamConnection?.cancel()
    onFinish(ObjectIdentifier(self))
  }
}
