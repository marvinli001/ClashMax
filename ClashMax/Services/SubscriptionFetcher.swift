import Foundation

struct SubscriptionURLResolution: Equatable, Sendable {
  var url: URL
  var displayNameHint: String?
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
  typealias Attempt = @Sendable (SubscriptionFetchStrategy) async throws -> (Data, URLResponse)

  func request(url: URL, options: SubscriptionFetchOptions = SubscriptionFetchOptions()) -> URLRequest {
    let target = SubscriptionURLResolver.requestTarget(for: url)
    var request = URLRequest(url: target.url)
    request.httpMethod = "GET"
    request.timeoutInterval = options.timeout
    request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/yaml, application/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
    if let authorization = target.authorization {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    return request
  }

  func fetch(url: URL, options: SubscriptionFetchOptions = SubscriptionFetchOptions()) async throws -> SubscriptionFetchResult {
    try await fetch(url: url, options: options) { strategy in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = options.timeout
      configuration.timeoutIntervalForResource = options.timeout
      configuration.connectionProxyDictionary = proxyDictionary(for: strategy, options: options)
      let delegate = options.allowsInsecureTLS ? SubscriptionInsecureTrustDelegate() : nil
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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
          (200..<300).contains(http.statusCode)
    else {
      throw AppError.invalidSubscriptionResponse
    }

    guard let source = decodedString(from: data, response: http) else {
      throw AppError.invalidSubscriptionResponse
    }
    let cleanedSource = stripUTF8BOM(from: source)
    try rejectPanelErrorPageIfNeeded(cleanedSource, response: http)
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
      traffic: headerValue("subscription-userinfo", in: headers).flatMap(parseTrafficUsage),
      remoteFileName: headerValue("content-disposition", in: headers).flatMap(parseFilename),
      updateIntervalMinutes: headerValue("profile-update-interval", in: headers).flatMap(parseUpdateIntervalMinutes),
      webPageURL: headerValue("profile-web-page-url", in: headers).flatMap(URL.init(string:)),
      lastFetchedAt: Date()
    )
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

  private func decodedString(from data: Data, response: HTTPURLResponse) -> String? {
    var encodings: [String.Encoding] = []
    if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
       let declaredEncoding = encoding(fromContentType: contentType) {
      encodings.append(declaredEncoding)
    }
    encodings.append(.utf8)

    var seen: Set<String.Encoding> = []
    for encoding in encodings where seen.insert(encoding).inserted {
      if let source = String(data: data, encoding: encoding) {
        return source
      }
    }
    return nil
  }

  private func encoding(fromContentType contentType: String) -> String.Encoding? {
    let parameters = contentType.split(separator: ";").dropFirst()
    guard let charsetParameter = parameters.first(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("charset=")
    }) else {
      return nil
    }

    let rawCharset = charsetParameter
      .split(separator: "=", maxSplits: 1)
      .last
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      .lowercased()

    switch rawCharset {
    case "utf-8", "utf8":
      return .utf8
    case "utf-16", "utf16":
      return .utf16
    case "iso-8859-1", "latin1", "latin-1":
      return .isoLatin1
    case "windows-1252", "cp1252":
      return String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(1252))
      )
    case "gb18030":
      return stringEncoding(from: CFStringEncodings.GB_18030_2000)
    case "gbk":
      return stringEncoding(from: CFStringEncodings.GBK_95)
    case "gb2312":
      return stringEncoding(from: CFStringEncodings.GB_2312_80)
    case "big5", "big-5":
      return stringEncoding(from: CFStringEncodings.big5)
    case "shift_jis", "shift-jis", "sjis":
      return stringEncoding(from: CFStringEncodings.shiftJIS)
    default:
      return nil
    }
  }

  private func stringEncoding(from encoding: CFStringEncodings) -> String.Encoding {
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
  }

  private func rejectPanelErrorPageIfNeeded(_ source: String, response: HTTPURLResponse) throws {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowercased = trimmed.lowercased()
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("text/html") ||
      lowercased.hasPrefix("<!doctype html") ||
      lowercased.hasPrefix("<html") ||
      lowercased.contains("<title>") ||
      lowercased.contains("<form") {
      throw panelError()
    }

    if lowercased.hasPrefix("{") || lowercased.hasPrefix("[") {
      throw panelError()
    }
  }

  private func panelError() -> AppError {
    AppError.invalidProfileConfig(
      "subscription returned a login or error page instead of a Clash/Mihomo profile. Check the subscription URL, token, account login, or panel status."
    )
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

private final class SubscriptionInsecureTrustDelegate: NSObject, URLSessionDelegate {
  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust
    else {
      return (.performDefaultHandling, nil)
    }
    return (.useCredential, URLCredential(trust: trust))
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
