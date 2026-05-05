import Foundation

struct SubscriptionFetcher {
  typealias Attempt = @Sendable (SubscriptionFetchStrategy) async throws -> (Data, URLResponse)

  func request(url: URL, options: SubscriptionFetchOptions = SubscriptionFetchOptions()) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = options.timeout
    request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/yaml, application/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
    return request
  }

  func fetch(url: URL, options: SubscriptionFetchOptions = SubscriptionFetchOptions()) async throws -> SubscriptionFetchResult {
    try await fetch(url: url, options: options) { strategy in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = options.timeout
      configuration.timeoutIntervalForResource = options.timeout
      configuration.connectionProxyDictionary = proxyDictionary(for: strategy, options: options)
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      return try await session.data(for: request(url: url, options: options))
    }
  }

  func fetch(
    url: URL,
    options: SubscriptionFetchOptions = SubscriptionFetchOptions(),
    attempt: Attempt
  ) async throws -> SubscriptionFetchResult {
    var lastError: Error?
    for strategy in options.retryOrder {
      do {
        let (data, response) = try await attempt(strategy)
        return try decode(data: data, response: response)
      } catch {
        lastError = error
      }
    }

    throw lastError ?? AppError.invalidSubscriptionResponse
  }

  func decode(data: Data, response: URLResponse) throws -> SubscriptionFetchResult {
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let source = String(data: data, encoding: .utf8)
    else {
      throw AppError.invalidSubscriptionResponse
    }

    let cleanedSource = stripUTF8BOM(from: source)
    try ProfileConfigValidator.validateProfileSource(cleanedSource)

    return SubscriptionFetchResult(
      source: cleanedSource,
      metadata: metadata(from: http)
    )
  }

  private func metadata(from response: HTTPURLResponse) -> SubscriptionMetadata {
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
      guard let key = item.key as? String else { return }
      result[key.lowercased()] = String(describing: item.value)
    }

    return SubscriptionMetadata(
      traffic: headers["subscription-userinfo"].flatMap(parseTrafficUsage),
      remoteFileName: headers["content-disposition"].flatMap(parseFilename),
      updateIntervalMinutes: headers["profile-update-interval"].flatMap(parseUpdateIntervalMinutes),
      webPageURL: headers["profile-web-page-url"].flatMap(URL.init(string:)),
      lastFetchedAt: Date()
    )
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

  private func unquoted(_ value: String) -> String {
    var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
      value.removeFirst()
      value.removeLast()
    }
    return value
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
      kCFNetworkProxiesHTTPSEnable as String: false
    ]
  case .localClashProxy:
    return [
      kCFNetworkProxiesHTTPEnable as String: true,
      kCFNetworkProxiesHTTPProxy as String: options.localProxyHost,
      kCFNetworkProxiesHTTPPort as String: options.localProxyPort,
      kCFNetworkProxiesHTTPSEnable as String: true,
      kCFNetworkProxiesHTTPSProxy as String: options.localProxyHost,
      kCFNetworkProxiesHTTPSPort as String: options.localProxyPort
    ]
  case .systemProxy:
    return nil
  }
}
