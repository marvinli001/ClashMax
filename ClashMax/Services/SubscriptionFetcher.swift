import Darwin
import Foundation
import Network

struct SubscriptionURLResolution: Equatable, Sendable {
  var url: URL
  var displayNameHint: String?
}

struct SubscriptionFetchError: Error, LocalizedError, CustomStringConvertible, Sendable {
  var kind: SubscriptionUpdateFailureKind
  var message: String
  var diagnostics: SubscriptionFetchDiagnostics

  var errorDescription: String? { message }
  var description: String { message }
}

enum SubscriptionProxySessionFactoryError: Error, LocalizedError, Equatable, Sendable {
  case missingEndpoint
  case invalidEndpoint
  case missingSecret

  var errorDescription: String? {
    switch self {
    case .missingEndpoint:
      return "The profile upstream proxy is unavailable."
    case .invalidEndpoint:
      return "The profile upstream proxy configuration is invalid."
    case .missingSecret:
      return "The profile upstream proxy credential is unavailable."
    }
  }
}

struct SubscriptionProxySessionPlan: Equatable, Sendable {
  enum ProxyKind: Equatable, Sendable {
    case socks5
    case httpConnect
  }

  var endpointName: String
  var proxyKind: ProxyKind
  var host: String
  var port: Int
  var usesTLS: Bool
  var tlsServerName: String?
  var skipsCertificateVerification: Bool
  var usesCredential: Bool
  var allowFailover: Bool
}

enum SubscriptionProxySessionFactory {
  private static let insecureTLSVerificationQueue = DispatchQueue(
    label: "io.github.clashmax.subscription-proxy-tls-verification"
  )

  static func plan(
    for resolvedEndpoint: ResolvedOutboundProxyEndpoint
  ) throws -> SubscriptionProxySessionPlan {
    let endpoint = resolvedEndpoint.endpoint
    let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isValidHost(host), (1...65_535).contains(endpoint.port) else {
      throw SubscriptionProxySessionFactoryError.invalidEndpoint
    }

    let usesCredential = endpoint.authentication != nil
    if let authentication = endpoint.authentication {
      guard
        !authentication.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        resolvedEndpoint.secretState == .ready
      else {
        throw SubscriptionProxySessionFactoryError.missingSecret
      }
    }

    let usesTLS = endpoint.kind == .http && endpoint.httpOptions.tlsEnabled
    let tlsServerName = usesTLS
      ? normalizedOptional(endpoint.httpOptions.serverName)
      : nil
    if let tlsServerName, !isValidHost(tlsServerName) {
      throw SubscriptionProxySessionFactoryError.invalidEndpoint
    }

    return SubscriptionProxySessionPlan(
      endpointName: endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines),
      proxyKind: endpoint.kind == .socks5 ? .socks5 : .httpConnect,
      host: host,
      port: endpoint.port,
      usesTLS: usesTLS,
      tlsServerName: tlsServerName,
      skipsCertificateVerification: usesTLS
        && endpoint.httpOptions.skipCertificateVerification,
      usesCredential: usesCredential,
      allowFailover: false
    )
  }

  static func configuration(
    for resolvedEndpoint: ResolvedOutboundProxyEndpoint,
    timeout: TimeInterval
  ) throws -> URLSessionConfiguration {
    let plan = try plan(for: resolvedEndpoint)
    guard let port = NWEndpoint.Port(rawValue: UInt16(plan.port)) else {
      throw SubscriptionProxySessionFactoryError.invalidEndpoint
    }
    let hostPort = NWEndpoint.hostPort(host: NWEndpoint.Host(plan.host), port: port)
    var proxyConfiguration: ProxyConfiguration
    switch plan.proxyKind {
    case .socks5:
      proxyConfiguration = ProxyConfiguration(socksv5Proxy: hostPort)
    case .httpConnect:
      let tlsOptions: NWProtocolTLS.Options?
      if plan.usesTLS {
        let options = NWProtocolTLS.Options()
        if let serverName = plan.tlsServerName {
          sec_protocol_options_set_tls_server_name(
            options.securityProtocolOptions,
            serverName
          )
        }
        if plan.skipsCertificateVerification {
          sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, _, completion in completion(true) },
            insecureTLSVerificationQueue
          )
        }
        tlsOptions = options
      } else {
        tlsOptions = nil
      }
      proxyConfiguration = ProxyConfiguration(
        httpCONNECTProxy: hostPort,
        tlsOptions: tlsOptions
      )
    }
    proxyConfiguration.matchDomains = [""]
    proxyConfiguration.allowFailover = plan.allowFailover
    if let authentication = resolvedEndpoint.endpoint.authentication,
       let password = resolvedEndpoint.password
    {
      proxyConfiguration.applyCredential(
        username: authentication.username,
        password: password
      )
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.proxyConfigurations = [proxyConfiguration]
    return configuration
  }

  private static func normalizedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isValidHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.count <= 253 else { return false }
    guard !host.unicodeScalars.contains(where: {
      CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
    }) else {
      return false
    }
    guard
      !host.contains("://"),
      !host.contains("/"),
      !host.contains("\\"),
      !host.contains("@"),
      !host.contains("?"),
      !host.contains("#")
    else {
      return false
    }

    let unwrappedHost: String
    if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
      unwrappedHost = String(host.dropFirst().dropLast())
    } else {
      unwrappedHost = host
    }
    if isIPAddress(unwrappedHost, family: AF_INET)
      || isIPAddress(unwrappedHost, family: AF_INET6)
    {
      return true
    }
    guard !host.contains(":"), !host.hasPrefix("["), !host.hasSuffix("]") else {
      return false
    }

    let candidate = host.hasSuffix(".") ? String(host.dropLast()) : host
    let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return false }
    return labels.allSatisfy { label in
      guard
        !label.isEmpty,
        label.count <= 63,
        label.first != "-",
        label.last != "-"
      else {
        return false
      }
      return label.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).contains($0)
      }
    }
  }

  private static func isIPAddress(_ host: String, family: Int32) -> Bool {
    var address = in6_addr()
    return host.withCString { inet_pton(family, $0, &address) } == 1
  }
}

enum SubscriptionURLResolver {
  private static let deepLinkSchemes: Set<String> = ["clash", "clash-verge", "clashmeta", "flclash"]

  static func resolve(rawInput: String) -> SubscriptionURLResolution? {
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
    return resolve(url: url)
  }

  static func resolve(url: URL) -> SubscriptionURLResolution? {
    if isDeepLink(url) {
      return resolveDeepLink(url: url)
    }
    return SubscriptionURLResolution(url: repairMissingQueryMarker(in: url), displayNameHint: nil)
  }

  static func requestTarget(for url: URL) -> (url: URL, authorization: String?) {
    guard let user = url.user(percentEncoded: false), !user.isEmpty else {
      return (url, nil)
    }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.user = nil
    components?.password = nil
    let password = url.password(percentEncoded: false) ?? ""
    let credentials = "\(user):\(password)"
    return (
      components?.url ?? url,
      "Basic \(Data(credentials.utf8).base64EncodedString())"
    )
  }

  static func normalizedDisplayName(_ value: String?) -> String? {
    guard let value else { return nil }
    let decoded = repeatedlyRemovingPercentEncoding(from: value.replacingOccurrences(of: "+", with: " "))
    let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func resolveDeepLink(url: URL) -> SubscriptionURLResolution? {
    let items = queryItems(from: url)
    guard let rawNestedURL = value(named: "url", in: items),
          let nestedResolution = resolve(rawInput: repeatedlyRemovingPercentEncoding(from: rawNestedURL))
    else {
      return nil
    }

    return SubscriptionURLResolution(
      url: nestedResolution.url,
      displayNameHint: normalizedDisplayName(value(named: "name", in: items)) ?? nestedResolution.displayNameHint
    )
  }

  private static func isDeepLink(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return deepLinkSchemes.contains(scheme)
  }

  private static func queryItems(from url: URL) -> [URLQueryItem] {
    if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
      return items
    }

    guard let urlRange = url.absoluteString.range(of: "url=", options: [.caseInsensitive]) else {
      return []
    }
    let query = String(url.absoluteString[urlRange.lowerBound...])
    return URLComponents(string: "clashmax://subscription?\(query)")?.queryItems ?? []
  }

  private static func value(named name: String, in items: [URLQueryItem]) -> String? {
    items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func repairMissingQueryMarker(in url: URL) -> URL {
    guard let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.percentEncodedQuery == nil,
          let markerRange = components.percentEncodedPath.range(of: "&")
    else {
      return url
    }

    let query = String(components.percentEncodedPath[markerRange.upperBound...])
    guard query.contains("=") else { return url }

    let repairedPath = String(components.percentEncodedPath[..<markerRange.lowerBound])
    components.percentEncodedPath = repairedPath.isEmpty ? "/" : repairedPath
    components.percentEncodedQuery = query
    return components.url ?? url
  }

  private static func repeatedlyRemovingPercentEncoding(from value: String) -> String {
    var current = value
    for _ in 0..<3 {
      guard let decoded = current.removingPercentEncoding, decoded != current else { break }
      current = decoded
    }
    return current
  }
}

struct SubscriptionFetcher {
  /// Performs a single fetch for the given strategy using the supplied User-Agent. The UA is
  /// passed per attempt so the fetcher can retry the same strategy with a compatibility UA.
  typealias Attempt = @Sendable (SubscriptionFetchStrategy, String) async throws -> (Data, URLResponse)

  private struct DecodeContext {
    var sanitizedURL: String
    var userAgent: String
    var attemptedStrategies: [SubscriptionFetchStrategy]
    var successfulStrategy: SubscriptionFetchStrategy?
    var endpointName: String?
    var failureStage: String?
    var requestHeaders: [SubscriptionHeaderDiagnostic]
  }

  func request(
    url: URL,
    options: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    userAgent: String? = nil
  ) -> URLRequest {
    let target = SubscriptionURLResolver.requestTarget(for: url)
    var request = URLRequest(url: target.url)
    request.httpMethod = "GET"
    request.timeoutInterval = options.timeout
    request.setValue(userAgent ?? options.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/yaml, application/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
    if let authorization = target.authorization {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    let usesProfileUpstream = options.profileUpstreamEndpoint != nil ||
      options.effectiveRetryOrder.contains(.profileUpstream)
    for (name, value) in options.customHeaders {
      if usesProfileUpstream,
         name.caseInsensitiveCompare("Proxy-Authorization") == .orderedSame
      {
        continue
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  func fetch(url: URL, options: SubscriptionFetchOptions = SubscriptionFetchOptions()) async throws -> SubscriptionFetchResult {
    try await fetch(url: url, options: options) { strategy, userAgent in
      let configuration: URLSessionConfiguration
      var proxyUsername: String?
      var proxyPassword: String?
      if strategy == .profileUpstream {
        guard let endpoint = options.profileUpstreamEndpoint else {
          throw SubscriptionProxySessionFactoryError.missingEndpoint
        }
        configuration = try SubscriptionProxySessionFactory.configuration(
          for: endpoint,
          timeout: options.timeout
        )
        proxyUsername = endpoint.endpoint.authentication?.username
        proxyPassword = endpoint.password
      } else {
        configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = options.timeout
        configuration.timeoutIntervalForResource = options.timeout
        configuration.connectionProxyDictionary = proxyDictionary(for: strategy, options: options)
      }
      let delegate: SubscriptionSessionDelegate?
      if options.allowsInsecureTLS || (proxyUsername != nil && proxyPassword != nil) {
        delegate = SubscriptionSessionDelegate(
          allowsInsecureTLS: options.allowsInsecureTLS,
          proxyUsername: proxyUsername,
          proxyPassword: proxyPassword
        )
      } else {
        delegate = nil
      }
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }
      return try await session.data(for: request(url: url, options: options, userAgent: userAgent))
    }
  }

  func fetch(
    url: URL,
    options: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    attempt: Attempt
  ) async throws -> SubscriptionFetchResult {
    let request = request(url: url, options: options)
    let requestHeaders = requestHeaderDiagnostics(for: request)
    let sanitizedURL = Self.sanitizedURL(request.url ?? url)
    let compatibilityUserAgent = Self.compatibilityUserAgent(for: options)
    let endpointName = Self.normalizedEndpointName(options.profileUpstreamEndpoint)
    var attemptedStrategies: [SubscriptionFetchStrategy] = []
    var lastError: Error?
    let retryOrder = options.effectiveRetryOrder
    let usesProfileUpstream = retryOrder.contains(.profileUpstream)
    if retryOrder.contains(.profileUpstream) {
      do {
        guard let endpoint = options.profileUpstreamEndpoint else {
          throw SubscriptionProxySessionFactoryError.missingEndpoint
        }
        _ = try SubscriptionProxySessionFactory.plan(for: endpoint)
      } catch {
        throw proxyConfigurationError(
          sanitizedURL: sanitizedURL,
          userAgent: options.userAgent,
          endpointName: endpointName,
          requestHeaders: requestHeaders
        )
      }
    }
    for strategy in retryOrder {
      attemptedStrategies.append(strategy)
      do {
        return try await attemptFetch(
          strategy: strategy,
          userAgent: options.userAgent,
          sanitizedURL: sanitizedURL,
          attemptedStrategies: attemptedStrategies,
          endpointName: endpointName,
          requestHeaders: requestHeaders,
          attempt: attempt
        )
      } catch let error as SubscriptionFetchError {
        lastError = error
        guard
          let compatibilityUserAgent,
          Self.shouldFallBackToCompatibilityUserAgent(for: error.kind)
        else {
          continue
        }
        // The panel rejected the user-configured UA; retry the same strategy once as the
        // bundled Mihomo core would identify itself.
        do {
          return try await attemptFetch(
            strategy: strategy,
            userAgent: compatibilityUserAgent,
            sanitizedURL: sanitizedURL,
            attemptedStrategies: attemptedStrategies,
            endpointName: endpointName,
            requestHeaders: requestHeaders,
            attempt: attempt
          )
        } catch let fallbackError as SubscriptionFetchError {
          lastError = fallbackError
        } catch {
          lastError = transportError(
            error,
            userAgent: compatibilityUserAgent,
            sanitizedURL: sanitizedURL,
            attemptedStrategies: attemptedStrategies,
            endpointName: endpointName,
            usesProfileUpstream: usesProfileUpstream,
            requestHeaders: requestHeaders
          )
        }
      } catch {
        lastError = transportError(
          error,
          userAgent: options.userAgent,
          sanitizedURL: sanitizedURL,
          attemptedStrategies: attemptedStrategies,
          endpointName: endpointName,
          usesProfileUpstream: usesProfileUpstream,
          requestHeaders: requestHeaders
        )
      }
    }

    throw lastError ?? AppError.invalidSubscriptionResponse
  }

  private func attemptFetch(
    strategy: SubscriptionFetchStrategy,
    userAgent: String,
    sanitizedURL: String,
    attemptedStrategies: [SubscriptionFetchStrategy],
    endpointName: String?,
    requestHeaders: [SubscriptionHeaderDiagnostic],
    attempt: Attempt
  ) async throws -> SubscriptionFetchResult {
    let (data, response) = try await attempt(strategy, userAgent)
    return try decode(
      data: data,
      response: response,
      context: DecodeContext(
        sanitizedURL: sanitizedURL,
        userAgent: userAgent,
        attemptedStrategies: attemptedStrategies,
        successfulStrategy: strategy,
        endpointName: endpointName,
        failureStage: nil,
        requestHeaders: requestHeaders
      )
    )
  }

  private func transportError(
    _ error: Error,
    userAgent: String,
    sanitizedURL: String,
    attemptedStrategies: [SubscriptionFetchStrategy],
    endpointName: String?,
    usesProfileUpstream: Bool,
    requestHeaders: [SubscriptionHeaderDiagnostic]
  ) -> SubscriptionFetchError {
    SubscriptionFetchError(
      kind: Self.failureKind(for: error),
      message: usesProfileUpstream
        ? "Subscription fetch through the profile upstream proxy failed."
        : "Subscription fetch failed: \(error.localizedDescription)",
      diagnostics: SubscriptionFetchDiagnostics(
        sanitizedURL: sanitizedURL,
        userAgent: userAgent,
        attemptedStrategies: attemptedStrategies,
        endpointName: endpointName,
        failureStage: usesProfileUpstream ? "transport" : nil,
        requestHeaders: requestHeaders
      )
    )
  }

  private func proxyConfigurationError(
    sanitizedURL: String,
    userAgent: String,
    endpointName: String?,
    requestHeaders: [SubscriptionHeaderDiagnostic]
  ) -> SubscriptionFetchError {
    SubscriptionFetchError(
      kind: .network,
      message: "The profile upstream proxy could not be configured.",
      diagnostics: SubscriptionFetchDiagnostics(
        sanitizedURL: sanitizedURL,
        userAgent: userAgent,
        attemptedStrategies: [],
        endpointName: endpointName,
        failureStage: "configuration",
        requestHeaders: requestHeaders
      )
    )
  }

  /// Only HTML/panel and invalid-profile responses warrant a UA fallback. Network errors,
  /// cancellation, non-2xx HTTP, decoding and TLS failures keep the existing retry behavior.
  private static func shouldFallBackToCompatibilityUserAgent(for kind: SubscriptionUpdateFailureKind) -> Bool {
    switch kind {
    case .panelResponse, .invalidProfile:
      return true
    default:
      return false
    }
  }

  /// Resolves the effective compatibility UA, or nil when it is absent, blank, or identical
  /// to the primary UA (in which case retrying would be pointless).
  private static func compatibilityUserAgent(for options: SubscriptionFetchOptions) -> String? {
    guard let raw = options.compatibilityUserAgent else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed != options.userAgent.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return trimmed
  }

  func decode(data: Data, response: URLResponse) throws -> SubscriptionFetchResult {
    try decode(
      data: data,
      response: response,
      context: DecodeContext(
        sanitizedURL: Self.sanitizedURL(response.url),
        userAgent: SubscriptionFetchOptions().userAgent,
        attemptedStrategies: [],
        successfulStrategy: nil,
        endpointName: nil,
        failureStage: nil,
        requestHeaders: []
      )
    )
  }

  private func decode(data: Data, response: URLResponse, context: DecodeContext) throws -> SubscriptionFetchResult {
    let usesProfileUpstream = context.successfulStrategy == .profileUpstream
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode)
    else {
      var diagnostics = diagnostics(from: response, context: context)
      diagnostics.failureStage = usesProfileUpstream ? "response" : nil
      throw SubscriptionFetchError(
        kind: .httpStatus,
        message: httpStatusMessage(from: response),
        diagnostics: diagnostics
      )
    }

    var diagnostics = diagnostics(from: http, context: context)
    guard let decoded = decodedString(from: data, response: http) else {
      diagnostics.failureStage = usesProfileUpstream ? "decoding" : nil
      throw SubscriptionFetchError(
        kind: .decoding,
        message: "The subscription response could not be decoded as text.",
        diagnostics: diagnostics
      )
    }
    diagnostics.decodedCharset = decoded.decodedCharset
    let cleanedSource = stripUTF8BOM(from: decoded.source)
    if bodyLooksLikePanelError(cleanedSource) {
      diagnostics.failureStage = usesProfileUpstream ? "validation" : nil
      throw SubscriptionFetchError(
        kind: .panelResponse,
        message: panelErrorMessage,
        diagnostics: diagnostics
      )
    }
    do {
      try ProfileConfigValidator.validateProfileSource(cleanedSource)
    } catch {
      diagnostics.failureStage = usesProfileUpstream ? "validation" : nil
      if responseSuggestsPanelError(cleanedSource, response: http) {
        throw SubscriptionFetchError(
          kind: .panelResponse,
          message: panelErrorMessage,
          diagnostics: diagnostics
        )
      }
      throw SubscriptionFetchError(
        kind: .invalidProfile,
        message: UserFacingError.message(for: error),
        diagnostics: diagnostics
      )
    }

    return SubscriptionFetchResult(
      source: cleanedSource,
      metadata: metadata(from: http),
      diagnostics: diagnostics
    )
  }

  private static func sanitizedURL(_ url: URL?) -> String {
    guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "Unavailable"
    }
    components.user = nil
    components.password = nil
    components.path = sanitizedPath(components.path)
    if let queryItems = components.queryItems {
      components.queryItems = queryItems.map { item in
        URLQueryItem(name: item.name, value: item.value == nil ? nil : "<redacted>")
      }
    }
    let value = components.url?.absoluteString ?? url.absoluteString
    return value
      .replacingOccurrences(of: "%3Credacted%3E", with: "<redacted>")
      .replacingOccurrences(of: "%3credacted%3e", with: "<redacted>")
  }

  private static func sanitizedPath(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    var shouldRedactNextSegment = false
    let sanitizedSegments = path
      .split(separator: "/", omittingEmptySubsequences: false)
      .map { rawSegment -> String in
        let segment = String(rawSegment)
        guard !segment.isEmpty else { return segment }
        let decodedSegment = segment.removingPercentEncoding ?? segment
        let shouldRedact = shouldRedactNextSegment || pathSegmentLooksSecret(decodedSegment)
        shouldRedactNextSegment = pathSegmentIntroducesSecret(decodedSegment)
        return shouldRedact ? "<redacted>" : segment
      }
    return sanitizedSegments.joined(separator: "/")
  }

  private static func pathSegmentIntroducesSecret(_ segment: String) -> Bool {
    let normalized = segment
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return [
      "link",
      "links",
      "subscribe",
      "subscription",
      "subscriptions",
      "token",
      "tokens",
      "profile",
      "profiles",
      "download",
    ].contains(normalized)
  }

  private static func pathSegmentLooksSecret(_ segment: String) -> Bool {
    let normalized = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count >= 12 else { return false }
    let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    if normalized.range(of: uuidPattern, options: .regularExpression) != nil {
      return true
    }
    let allowedCharacters = CharacterSet.alphanumerics
      .union(CharacterSet(charactersIn: "-_=."))
    guard normalized.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
      return false
    }
    let hasLetter = normalized.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    let hasDigit = normalized.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    return (hasLetter && hasDigit) || normalized.count >= 24
  }

  private static func failureKind(for error: Error) -> SubscriptionUpdateFailureKind {
    if error is CancellationError {
      return .cancelled
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return .network
    }
    return .unknown
  }

  private func requestHeaderDiagnostics(for request: URLRequest) -> [SubscriptionHeaderDiagnostic] {
    (request.allHTTPHeaderFields ?? [:])
      .filter { name, _ in
        name.caseInsensitiveCompare("Proxy-Authorization") != .orderedSame
      }
      .map { name, value in
        SubscriptionHeaderDiagnostic(
          name: name,
          hasValue: !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func diagnostics(from response: URLResponse, context: DecodeContext) -> SubscriptionFetchDiagnostics {
    guard let http = response as? HTTPURLResponse else {
      return SubscriptionFetchDiagnostics(
        sanitizedURL: context.sanitizedURL,
        userAgent: context.userAgent,
        attemptedStrategies: context.attemptedStrategies,
        successfulStrategy: context.successfulStrategy,
        endpointName: context.endpointName,
        failureStage: context.failureStage,
        requestHeaders: context.requestHeaders
      )
    }

    let headers = normalizedHeaders(from: http)
    let contentType = http.value(forHTTPHeaderField: "Content-Type")
    let rawUpdateInterval = headerValue("profile-update-interval", in: headers)
    return SubscriptionFetchDiagnostics(
      sanitizedURL: context.sanitizedURL,
      userAgent: context.userAgent,
      attemptedStrategies: context.attemptedStrategies,
      successfulStrategy: context.successfulStrategy,
      endpointName: context.endpointName,
      failureStage: context.failureStage,
      requestHeaders: context.requestHeaders,
      responseHeaderNames: http.allHeaderFields.keys.map { String(describing: $0) }.sorted(),
      httpStatusCode: http.statusCode,
      contentType: contentType,
      subscriptionUserInfo: headerValue("subscription-userinfo", in: headers),
      rawProfileUpdateInterval: rawUpdateInterval,
      parsedProfileUpdateIntervalMinutes: rawUpdateInterval.flatMap(parseUpdateIntervalMinutes),
      declaredCharset: charsetName(fromContentType: contentType)
    )
  }

  private func httpStatusMessage(from response: URLResponse) -> String {
    guard let http = response as? HTTPURLResponse else {
      return "The subscription did not return an HTTP response."
    }
    return "The subscription returned HTTP \(http.statusCode)."
  }

  private static func normalizedEndpointName(
    _ resolvedEndpoint: ResolvedOutboundProxyEndpoint?
  ) -> String? {
    guard let resolvedEndpoint else { return nil }
    let name = resolvedEndpoint.endpoint.name
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let sensitiveValues = [
      resolvedEndpoint.endpoint.authentication?.username,
      resolvedEndpoint.password,
    ].compactMap { value -> String? in
      guard let value else { return nil }
      let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedValue.isEmpty ? nil : trimmedValue
    }
    guard !sensitiveValues.contains(where: {
      trimmed.range(of: $0, options: [.caseInsensitive]) != nil
    }) else {
      return nil
    }
    return trimmed
  }

  private func metadata(from response: HTTPURLResponse) -> SubscriptionMetadata {
    let headers = normalizedHeaders(from: response)

    return SubscriptionMetadata(
      traffic: headerValue("subscription-userinfo", in: headers).flatMap(parseTrafficUsage),
      remoteFileName: headerValue("content-disposition", in: headers).flatMap(parseFilename),
      updateIntervalMinutes: headerValue("profile-update-interval", in: headers).flatMap(parseUpdateIntervalMinutes),
      webPageURL: headerValue("profile-web-page-url", in: headers).flatMap(URL.init(string:)),
      lastFetchedAt: Date()
    )
  }

  private func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
    response.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let key = item.key as? String else { return }
      result[key.lowercased()] = String(describing: item.value)
    }
  }

  private func headerValue(_ name: String, in headers: [String: String]) -> String? {
    let key = name.lowercased()
    if let exact = headers[key] { return exact }
    return headers
      .filter { $0.key.hasSuffix("-\(key)") }
      .sorted { $0.key < $1.key }
      .first?
      .value
  }

  private func parseTrafficUsage(_ header: String) -> SubscriptionTrafficUsage {
    let values = header
      .split(separator: ";")
      .reduce(into: [String: String]()) { result, part in
        let pieces = part.split(separator: "=", maxSplits: 1).map {
          String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard pieces.count == 2 else { return }
        result[pieces[0].lowercased()] = pieces[1]
      }

    return SubscriptionTrafficUsage(
      upload: values["upload"].flatMap(Int.init),
      download: values["download"].flatMap(Int.init),
      total: values["total"].flatMap(Int.init),
      expireAt: values["expire"].flatMap(Int.init).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    )
  }

  private func parseFilename(_ header: String) -> String? {
    let parts = header.split(separator: ";").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let encodedPart = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
      let rawValue = String(encodedPart.dropFirst("filename*=".count))
      let encodedName = rawValue.replacingOccurrences(of: "UTF-8''", with: "", options: [.caseInsensitive])
      return unquoted(encodedName).removingPercentEncoding ?? unquoted(encodedName)
    }

    if let filenamePart = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
      let rawValue = String(filenamePart.dropFirst("filename=".count))
      return unquoted(rawValue)
    }

    return nil
  }

  private func parseUpdateIntervalMinutes(_ header: String) -> Int? {
    guard let hours = Int(header.trimmingCharacters(in: .whitespacesAndNewlines)), hours > 0 else {
      return nil
    }
    return hours * 60
  }

  private func stripUTF8BOM(from source: String) -> String {
    source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
  }

  private func decodedString(from data: Data, response: HTTPURLResponse) -> (source: String, decodedCharset: String)? {
    var encodings: [(String.Encoding, String)] = []
    if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
       let declaredEncoding = encoding(fromContentType: contentType)
    {
      encodings.append(declaredEncoding)
    }
    encodings.append((.utf8, "utf-8"))

    var seen: Set<String.Encoding> = []
    for (encoding, label) in encodings where seen.insert(encoding).inserted {
      if let source = String(data: data, encoding: encoding) {
        return (source, label)
      }
    }
    return nil
  }

  private func charsetName(fromContentType contentType: String?) -> String? {
    guard let contentType else { return nil }
    let parameters = contentType.split(separator: ";").dropFirst()
    guard let charsetParameter = parameters.first(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("charset=")
    }) else {
      return nil
    }

    return charsetParameter
      .split(separator: "=", maxSplits: 1)
      .last
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private func encoding(fromContentType contentType: String) -> (String.Encoding, String)? {
    guard let rawCharset = charsetName(fromContentType: contentType)?.lowercased() else {
      return nil
    }

    switch rawCharset {
    case "utf-8", "utf8":
      return (.utf8, "utf-8")
    case "utf-16", "utf16":
      return (.utf16, "utf-16")
    case "iso-8859-1", "latin1", "latin-1":
      return (.isoLatin1, "iso-8859-1")
    case "windows-1252", "cp1252":
      return (
        String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(1252))
        ),
        "windows-1252"
      )
    case "gb18030":
      return (stringEncoding(from: CFStringEncodings.GB_18030_2000), "gb18030")
    case "gbk":
      return (stringEncoding(from: CFStringEncodings.GBK_95), "gbk")
    case "gb2312":
      return (stringEncoding(from: CFStringEncodings.GB_2312_80), "gb2312")
    case "big5", "big-5":
      return (stringEncoding(from: CFStringEncodings.big5), "big5")
    case "shift_jis", "shift-jis", "sjis":
      return (stringEncoding(from: CFStringEncodings.shiftJIS), "shift_jis")
    default:
      return nil
    }
  }

  private func stringEncoding(from encoding: CFStringEncodings) -> String.Encoding {
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
  }

  private func responseSuggestsPanelError(_ source: String, response: HTTPURLResponse) -> Bool {
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    return contentType.contains("text/html") || bodyLooksLikePanelError(source)
  }

  private func bodyLooksLikePanelError(_ source: String) -> Bool {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("<!doctype html") ||
      lowercased.hasPrefix("<html") ||
      lowercased.contains("<title>") ||
      lowercased.contains("<form")
    {
      return true
    }

    if lowercased.hasPrefix("{") || lowercased.hasPrefix("[") {
      return true
    }
    return false
  }

  private var panelErrorMessage: String {
    "subscription returned a login or error page instead of a Clash/Mihomo profile. Check the subscription URL, token, account login, or panel status."
  }

  private func unquoted(_ value: String) -> String {
    var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
      value.removeFirst()
      value.removeLast()
    }
    return value
  }
}

private final class SubscriptionSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let allowsInsecureTLS: Bool
  private let proxyUsername: String?
  private let proxyPassword: String?

  init(
    allowsInsecureTLS: Bool,
    proxyUsername: String?,
    proxyPassword: String?
  ) {
    self.allowsInsecureTLS = allowsInsecureTLS
    self.proxyUsername = proxyUsername
    self.proxyPassword = proxyPassword
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (
      URLSession.AuthChallengeDisposition,
      URLCredential?
    ) -> Void
  ) {
    if let credential = proxyCredential(for: challenge) {
      completionHandler(.useCredential, credential)
      return
    }
    guard
      allowsInsecureTLS,
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (
      URLSession.AuthChallengeDisposition,
      URLCredential?
    ) -> Void
  ) {
    guard let credential = proxyCredential(for: challenge) else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, credential)
  }

  private func proxyCredential(
    for challenge: URLAuthenticationChallenge
  ) -> URLCredential? {
    let supportedMethods = [
      NSURLAuthenticationMethodDefault,
      NSURLAuthenticationMethodHTTPBasic,
      NSURLAuthenticationMethodHTTPDigest,
    ]
    guard
      challenge.protectionSpace.isProxy(),
      supportedMethods.contains(challenge.protectionSpace.authenticationMethod),
      challenge.previousFailureCount == 0,
      let proxyUsername,
      let proxyPassword
    else {
      return nil
    }
    return URLCredential(
      user: proxyUsername,
      password: proxyPassword,
      persistence: .forSession
    )
  }
}

private func proxyDictionary(
  for strategy: SubscriptionFetchStrategy,
  options: SubscriptionFetchOptions
) -> [AnyHashable: Any]? {
  switch strategy {
  case .direct:
    return [
      kCFNetworkProxiesHTTPEnable as String: false,
      kCFNetworkProxiesHTTPSEnable as String: false,
    ]
  case .localClashProxy:
    return [
      kCFNetworkProxiesHTTPEnable as String: true,
      kCFNetworkProxiesHTTPProxy as String: options.localProxyHost,
      kCFNetworkProxiesHTTPPort as String: options.localProxyPort,
      kCFNetworkProxiesHTTPSEnable as String: true,
      kCFNetworkProxiesHTTPSProxy as String: options.localProxyHost,
      kCFNetworkProxiesHTTPSPort as String: options.localProxyPort,
    ]
  case .systemProxy:
    return nil
  case .profileUpstream:
    return nil
  }
}
