import Foundation

protocol MihomoAPIControlling: Sendable {
  func updateMode(_ mode: RunMode) async throws
  func updateIPv6(_ enabled: Bool) async throws
  func proxyGroups() async throws -> [ProxyGroup]
  func structuredProxyProviders() async throws -> [ProxyProvider]
  func ruleProviders() async throws -> [RuleProvider]
  func rules() async throws -> [RuntimeRule]
  func connections() async throws -> [ConnectionSnapshot]
  func selectProxy(group: String, proxy: String) async throws
  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int
  func healthCheckProvider(named provider: String) async throws
  func updateProxyProvider(named provider: String) async throws
  func updateRuleProvider(named provider: String) async throws
  func closeConnection(id: String) async throws
  func closeAllConnections() async throws
  func setTunEnabled(_ enabled: Bool) async throws
  func reloadConfig(path: String, force: Bool) async throws
  func restart(configPath: String?) async throws
  func trafficStream() -> AsyncThrowingStream<TrafficSample, Error>
  func logStream(level: String) -> AsyncThrowingStream<LogEntry, Error>
  func connectionStream(interval: Int) -> AsyncThrowingStream<[ConnectionSnapshot], Error>
}

extension MihomoAPIControlling {
  func reloadConfig(path: String) async throws {
    try await reloadConfig(path: path, force: true)
  }
}

struct MihomoAPIClient: Sendable {
  enum ClientError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
      switch self {
      case let .invalidURL(url):
        return "Invalid Mihomo controller URL: \(url)"
      case .invalidResponse:
        return "Mihomo controller returned an invalid response."
      case let .httpStatus(status):
        return "Mihomo controller returned HTTP \(status)."
      }
    }
  }

  let baseURL: URL
  let secret: String
  let session: URLSession
  let requestTimeout: TimeInterval?

  init(baseURL: URL, secret: String, session: URLSession = .shared, requestTimeout: TimeInterval? = nil) {
    self.baseURL = baseURL
    self.secret = secret
    self.session = session
    self.requestTimeout = requestTimeout
  }

  func version() async throws -> String {
    let data = try await data(for: request(path: "/version"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["version"] as? String ?? "unknown"
  }

  func configs() async throws -> [String: Any] {
    let data = try await data(for: request(path: "/configs"))
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  func updateMode(_ mode: RunMode) async throws {
    var request = try request(path: "/configs")
    request.httpMethod = "PATCH"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func updateIPv6(_ enabled: Bool) async throws {
    var request = try request(path: "/configs")
    request.httpMethod = "PATCH"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["ipv6": enabled])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func setTunEnabled(_ enabled: Bool) async throws {
    var request = try request(path: "/configs")
    request.httpMethod = "PATCH"
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["tun": ["enable": enabled]],
      options: [.withoutEscapingSlashes]
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func restart(configPath: String? = nil) async throws {
    var request = try request(path: "/restart")
    request.httpMethod = "POST"
    if let configPath {
      request.httpBody = try JSONSerialization.data(withJSONObject: ["path": configPath], options: [.withoutEscapingSlashes])
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    _ = try await data(for: request)
  }

  func reloadConfig(path: String, force: Bool = true) async throws {
    var request = try request(path: "/configs", queryItems: [URLQueryItem(name: "force", value: force ? "true" : "false")])
    request.httpMethod = "PUT"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["path": path], options: [.withoutEscapingSlashes])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func proxyGroups() async throws -> [ProxyGroup] {
    let data = try await data(for: request(path: "/proxies"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let proxies = object?["proxies"] as? [String: Any] ?? [:]
    let proxyDetails = proxies.compactMapValues { $0 as? [String: Any] }
    let proxyTypes = proxies.reduce(into: [String: String]()) { result, item in
      guard let proxy = item.value as? [String: Any],
            let type = proxy["type"] as? String
      else { return }
      result[item.key] = type
    }
    let proxyEndpoints = proxyDetails.reduce(into: [String: ProxyEndpoint]()) { result, item in
      result[item.key] = ProxyEndpoint(
        host: item.value["server"] as? String,
        port: Self.int(from: item.value["port"])
      )
    }

    return proxies.compactMap { name, value in
      guard let item = value as? [String: Any] else { return nil }
      let type = item["type"] as? String ?? "Unknown"
      let all = item["all"] as? [String] ?? []
      guard !all.isEmpty else { return nil }
      let history = item["history"] as? [[String: Any]] ?? []
      let nodes = all.map { proxyName in
        let proxyDetail = proxyDetails[proxyName] ?? [:]
        return ProxyNode(
          name: proxyName,
          type: proxyTypes[proxyName] ?? "proxy",
          delay: Self.delay(for: proxyName, history: history),
          isSelectable: true,
          serverHost: proxyEndpoints[proxyName]?.host,
          serverPort: proxyEndpoints[proxyName]?.port,
          udpSupported: Self.bool(from: proxyDetail["udp"]),
          tfoSupported: Self.bool(from: proxyDetail["tfo"]),
          xudpSupported: Self.bool(from: proxyDetail["xudp"])
        )
      }
      return ProxyGroup(name: name, type: type, selected: item["now"] as? String, nodes: nodes)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func proxyProviders() async throws -> [String: Any] {
    let data = try await data(for: request(path: "/providers/proxies"))
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  func structuredProxyProviders() async throws -> [ProxyProvider] {
    let object = try await proxyProviders()
    let providers = object["providers"] as? [String: Any] ?? object
    return providers.compactMap { name, value in
      guard let provider = value as? [String: Any] else { return nil }
      let providerName = provider["name"] as? String ?? name
      let proxies = (provider["proxies"] as? [[String: Any]] ?? []).compactMap { proxy -> ProxyNode? in
        guard let name = proxy["name"] as? String else { return nil }
        return ProxyNode(
          name: name,
          type: proxy["type"] as? String ?? "proxy",
          delay: nil,
          isSelectable: true,
          serverHost: proxy["server"] as? String,
          serverPort: Self.int(from: proxy["port"]),
          providerName: providerName,
          udpSupported: Self.bool(from: proxy["udp"]),
          tfoSupported: Self.bool(from: proxy["tfo"]),
          xudpSupported: Self.bool(from: proxy["xudp"])
        )
      }
      return ProxyProvider(
        name: providerName,
        type: provider["type"] as? String ?? "Provider",
        vehicleType: provider["vehicleType"] as? String,
        updatedAt: Self.date(from: provider["updatedAt"]),
        subscriptionInfo: Self.providerSubscriptionInfo(from: provider),
        proxies: proxies
      )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func ruleProviders() async throws -> [RuleProvider] {
    let data = try await data(for: request(path: "/providers/rules"))
    let object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let providers = object["providers"] as? [String: Any] ?? object
    return providers.compactMap { name, value in
      guard let provider = value as? [String: Any] else { return nil }
      return RuleProvider(
        name: provider["name"] as? String ?? name,
        type: provider["type"] as? String ?? "Provider",
        vehicleType: provider["vehicleType"] as? String,
        behavior: provider["behavior"] as? String,
        format: provider["format"] as? String,
        updatedAt: Self.date(from: provider["updatedAt"]),
        ruleCount: Self.ruleCount(from: provider)
      )
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func rules() async throws -> [RuntimeRule] {
    let data = try await data(for: request(path: "/rules"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rules = object?["rules"] as? [[String: Any]] ?? []
    return rules.enumerated().map { index, rule in
      let type = rule["type"] as? String ?? ""
      let payload = rule["payload"] as? String ?? ""
      let policy = (rule["proxy"] as? String) ?? (rule["policy"] as? String) ?? ""
      return RuntimeRule(
        index: index + 1,
        type: type,
        payload: payload,
        policy: policy,
        providerName: rule["provider"] as? String,
        raw: [type, payload, policy].filter { !$0.isEmpty }.joined(separator: ",")
      )
    }
  }

  func connections() async throws -> [ConnectionSnapshot] {
    let data = try await data(for: request(path: "/connections"))
    return try Self.decodeConnections(from: data)
  }

  func selectProxy(group: String, proxy: String) async throws {
    var request = try request(path: apiPath("proxies", group))
    request.httpMethod = "PUT"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": proxy], options: [.withoutEscapingSlashes])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int {
    let data = try await data(for: request(
      path: apiPath("proxies", proxy, "delay"),
      queryItems: [
        URLQueryItem(name: "url", value: testURL.absoluteString),
        URLQueryItem(name: "timeout", value: String(timeout))
      ]
    ))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["delay"] as? Int ?? -1
  }

  func healthCheckProvider(named provider: String) async throws {
    _ = try await data(for: request(path: apiPath("providers", "proxies", provider, "healthcheck")))
  }

  func updateProxyProvider(named provider: String) async throws {
    var request = try request(path: apiPath("providers", "proxies", provider))
    request.httpMethod = "PUT"
    _ = try await data(for: request)
  }

  func updateRuleProvider(named provider: String) async throws {
    var request = try request(path: apiPath("providers", "rules", provider))
    request.httpMethod = "PUT"
    _ = try await data(for: request)
  }

  func closeConnection(id: String) async throws {
    var request = try request(path: apiPath("connections", id))
    request.httpMethod = "DELETE"
    _ = try await data(for: request)
  }

  func closeAllConnections() async throws {
    var request = try request(path: "/connections")
    request.httpMethod = "DELETE"
    _ = try await data(for: request)
  }

  func trafficStream() -> AsyncThrowingStream<TrafficSample, Error> {
    webSocketStream(path: "/traffic") { data in
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      return TrafficSample(upload: object?["up"] as? Int ?? 0, download: object?["down"] as? Int ?? 0)
    }
  }

  func logStream(level: String = "info") -> AsyncThrowingStream<LogEntry, Error> {
    webSocketStream(path: "/logs", queryItems: [URLQueryItem(name: "level", value: level)]) { data in
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      return LogEntry(level: object?["type"] as? String ?? "info", message: object?["payload"] as? String ?? "")
    }
  }

  func connectionStream(interval: Int = 1000) -> AsyncThrowingStream<[ConnectionSnapshot], Error> {
    webSocketStream(path: "/connections", queryItems: [URLQueryItem(name: "interval", value: String(interval))]) { data in
      try Self.decodeConnections(from: data)
    }
  }

  private func request(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
    var components = try urlComponents()
    components.percentEncodedPath = path
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw ClientError.invalidURL(components.string ?? baseURL.absoluteString)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    if let requestTimeout {
      request.timeoutInterval = requestTimeout
    }
    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func apiPath(_ components: String...) -> String {
    "/" + components.map(Self.percentEncodedPathSegment).joined(separator: "/")
  }

  private static func percentEncodedPathSegment(_ segment: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
  }

  private func data(for request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ClientError.httpStatus(http.statusCode)
    }
    return data
  }

  private func webSocketStream<T>(
    path: String,
    queryItems: [URLQueryItem] = [],
    decode: @Sendable @escaping (Data) throws -> T
  ) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
      let request: URLRequest
      do {
        request = try webSocketRequest(path: path, queryItems: queryItems)
      } catch {
        continuation.finish(throwing: error)
        return
      }
      let task = session.webSocketTask(with: request)

      @Sendable func receiveNext() {
        task.receive { result in
          switch result {
          case let .failure(error):
            continuation.finish(throwing: error)
          case let .success(message):
            do {
              let data: Data
              switch message {
              case let .data(messageData):
                data = messageData
              case let .string(string):
                data = Data(string.utf8)
              @unknown default:
                data = Data()
              }
              continuation.yield(try decode(data))
              receiveNext()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }

      continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }
      task.resume()
      receiveNext()
    }
  }

  private func webSocketRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
    var components = try urlComponents()
    let scheme = components.scheme?.lowercased()
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.percentEncodedPath = path
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    guard let url = components.url else {
      throw ClientError.invalidURL(components.string ?? baseURL.absoluteString)
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func urlComponents() throws -> URLComponents {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host,
          !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ClientError.invalidURL(baseURL.absoluteString)
    }
    components.scheme = scheme
    return components
  }

  private static func decodeConnections(from data: Data) throws -> [ConnectionSnapshot] {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let connections = object?["connections"] as? [[String: Any]] ?? []
    return connections.compactMap { item in
      guard let id = item["id"] as? String else { return nil }
      let metadata = item["metadata"] as? [String: Any] ?? [:]
      let chains = item["chains"] as? [String] ?? []
      return ConnectionSnapshot(
        id: id,
        network: metadata["network"] as? String ?? "",
        host: metadata["host"] as? String ?? metadata["destinationIP"] as? String ?? "",
        sourceIP: Self.stringValue(for: ["sourceIP", "source-ip", "srcIP", "source"], in: metadata),
        sourcePort: Self.intValue(for: ["sourcePort", "source-port", "srcPort"], in: metadata),
        destinationIP: Self.stringValue(for: ["destinationIP", "destination-ip", "dstIP"], in: metadata),
        destinationPort: Self.intValue(for: ["destinationPort", "destination-port", "dstPort"], in: metadata),
        inboundPort: Self.intValue(for: ["inboundPort", "inbound-port", "inPort"], in: metadata),
        processName: Self.stringValue(for: ["process", "processName", "process-name"], in: metadata),
        processPath: Self.stringValue(for: ["processPath", "process-path"], in: metadata),
        upload: item["upload"] as? Int ?? 0,
        download: item["download"] as? Int ?? 0,
        chain: chains,
        rule: item["rule"] as? String,
        rulePayload: item["rulePayload"] as? String ?? item["rule-payload"] as? String,
        startedAt: nil
      )
    }
  }

  private static func delay(for proxyName: String, history: [[String: Any]]) -> Int? {
    history
      .first { $0["name"] as? String == proxyName }?["delay"] as? Int
  }

  private static func int(from value: Any?) -> Int? {
    switch value {
    case let value as Int:
      return value
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    case let value as CustomStringConvertible:
      return Int(String(describing: value))
    default:
      return nil
    }
  }

  private static func bool(from value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let value as NSNumber:
      return value.boolValue
    case let value as String:
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) {
        return true
      }
      if ["false", "no", "0"].contains(normalized) {
        return false
      }
      return nil
    default:
      return nil
    }
  }

  private static func date(from value: Any?) -> Date? {
    switch value {
    case let string as String:
      if let date = ISO8601DateFormatter().date(from: string) {
        return date
      }
      if let timestamp = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return Date(timeIntervalSince1970: timestamp)
      }
      return nil
    case let value as Double:
      return Date(timeIntervalSince1970: value)
    case let value as Int:
      return Date(timeIntervalSince1970: TimeInterval(value))
    case let value as NSNumber:
      return Date(timeIntervalSince1970: value.doubleValue)
    default:
      return nil
    }
  }

  private static func providerSubscriptionInfo(from provider: [String: Any]) -> ProviderSubscriptionInfo? {
    guard let info = dictionaryValue(
      for: ["subscriptionInfo", "subscription-info", "SubscriptionInfo"],
      in: provider
    ) else { return nil }
    let subscription = ProviderSubscriptionInfo(
      upload: intValue(for: ["upload", "Upload", "up"], in: info),
      download: intValue(for: ["download", "Download", "down"], in: info),
      total: intValue(for: ["total", "Total"], in: info),
      expireAt: dateValue(for: ["expire", "Expire", "expireAt", "expire-at"], in: info)
    )
    return subscription.upload == nil
      && subscription.download == nil
      && subscription.total == nil
      && subscription.expireAt == nil
      ? nil
      : subscription
  }

  private static func ruleCount(from provider: [String: Any]) -> Int? {
    if let count = intValue(for: ["ruleCount", "rule-count", "count"], in: provider) {
      return count
    }
    if let rules = provider["rules"] as? [Any] {
      return rules.count
    }
    if let payload = provider["payload"] as? [Any] {
      return payload.count
    }
    return nil
  }

  private static func dictionaryValue(for keys: [String], in object: [String: Any]) -> [String: Any]? {
    for key in keys {
      if let value = object[key] as? [String: Any] {
        return value
      }
      if let matchingKey = object.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
         let value = object[matchingKey] as? [String: Any] {
        return value
      }
    }
    return nil
  }

  private static func intValue(for keys: [String], in object: [String: Any]) -> Int? {
    keys.lazy.compactMap { key in
      int(from: object[key] ?? object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value)
    }.first
  }

  private static func dateValue(for keys: [String], in object: [String: Any]) -> Date? {
    keys.lazy.compactMap { key in
      date(from: object[key] ?? object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value)
    }.first
  }

  private static func stringValue(for keys: [String], in object: [String: Any]) -> String? {
    keys.lazy.compactMap { key -> String? in
      let value = object[key] ?? object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
      switch value {
      case let string as String:
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      case let convertible as CustomStringConvertible:
        let trimmed = String(describing: convertible).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      default:
        return nil
      }
    }.first
  }
}

private struct ProxyEndpoint {
  var host: String?
  var port: Int?
}

extension MihomoAPIClient: MihomoAPIControlling {}
