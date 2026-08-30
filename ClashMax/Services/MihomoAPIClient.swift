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
  func testGroupDelay(group: String, testURL: URL, timeout: Int) async throws -> [String: Int]
  func flushFakeIPCache() async throws
  func dnsQuery(name: String, type: String) async throws -> DNSQueryResult
  func updateGeoDatabases(timeout: TimeInterval) async throws
  func healthCheckProvider(named provider: String) async throws
  func updateProxyProvider(named provider: String) async throws
  func updateRuleProvider(named provider: String) async throws
  func closeConnection(id: String) async throws
  func closeAllConnections() async throws
  func setTunEnabled(_ enabled: Bool) async throws
  func reloadConfig(path: String, force: Bool) async throws
  func restart(configPath: String?) async throws
  func trafficStream() -> AsyncThrowingStream<TrafficSample, Error>
  func memoryStream() -> AsyncThrowingStream<CoreMemorySample, Error>
  func logStream(level: String) -> AsyncThrowingStream<LogEntry, Error>
  func connectionStream(interval: Int) -> AsyncThrowingStream<[ConnectionSnapshot], Error>
}

extension MihomoAPIControlling {
  func reloadConfig(path: String) async throws {
    try await reloadConfig(path: path, force: true)
  }

  func updateGeoDatabases() async throws {
    try await updateGeoDatabases(timeout: MihomoAPIClient.defaultGeoUpdateTimeout)
  }

  func dnsQuery(name: String) async throws -> DNSQueryResult {
    try await dnsQuery(name: name, type: DNSQueryType.coreDefault.rawValue)
  }
}

struct MihomoAPIClient: Sendable {
  enum ClientError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case delayTestHTTPStatus(Int)
    /// An HTTP failure whose body carried Mihomo's own `{"message": "..."}` explanation. Kept
    /// separate from `httpStatus` because that reason is the only actionable thing the user gets
    /// from a failed geo update — the status code alone says nothing.
    case coreMessage(status: Int, message: String)
    case unknownProxyGroup(String)

    var errorDescription: String? {
      switch self {
      case let .invalidURL(url):
        return "Invalid Mihomo controller URL: \(url)"
      case .invalidResponse:
        return "Mihomo controller returned an invalid response."
      case let .httpStatus(status):
        return "Mihomo controller returned HTTP \(status)."
      case let .delayTestHTTPStatus(status):
        return "Mihomo delay probe returned HTTP \(status). The controller responded, but the selected node or test URL could not complete the probe."
      case let .coreMessage(status, message):
        return "Mihomo controller returned HTTP \(status): \(message)"
      case let .unknownProxyGroup(group):
        return "Mihomo does not know a proxy group named \(group)."
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
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
          type: proxyTypes[proxyName] ?? MihomoBuiltInProxy.type(for: proxyName) ?? "proxy",
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
    // Do not alphabetically sort groups here: the `/proxies` JSON object has no
    // reliable ordering, so the configured `proxy-groups` order is restored later
    // against the profile preview groups (see ProxyGroupProfileOrdering).
  }

  func proxyProviders() async throws -> [String: Any] {
    let data = try await data(for: request(path: "/providers/proxies"))
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
          type: proxy["type"] as? String ?? MihomoBuiltInProxy.type(for: name) ?? "proxy",
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
    let object = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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
    let data: Data
    do {
      data = try await self.data(for: request(
        path: apiPath("proxies", proxy, "delay"),
        queryItems: [
          URLQueryItem(name: "url", value: testURL.absoluteString),
          URLQueryItem(name: "timeout", value: String(timeout)),
        ]
      ))
    } catch let ClientError.httpStatus(status) where status == 503 || status == 504 {
      // Mihomo uses 503/504 when the controller itself is reachable but the
      // selected node or probe target cannot complete the delay check. Keep
      // those distinct from controller-unavailable failures without masking
      // authentication, request, or API compatibility errors.
      throw ClientError.delayTestHTTPStatus(status)
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["delay"] as? Int ?? -1
  }

  /// Whole-group delay test via `GET /group/{name}/delay`.
  ///
  /// Contract measured against the bundled core (v1.19.30) on 2026-08-27, and it is *not* the
  /// per-node model:
  /// - 200 with a flat `{"node name": milliseconds}` object.
  /// - **A node that failed its probe is silently omitted from that object.** Absence is the only
  ///   signal of failure, so the caller must already know the full member list to tell "failed"
  ///   from "not in this group" (this is what preserves the issue #18 batch semantics).
  /// - The request blocks for the full `timeout` when any member is dead, so there is no
  ///   incremental progress to report — unlike `/proxies/{name}/delay`, which answers 504 per node.
  /// - An unknown group is 404, which is a caller bug rather than a node failure and is surfaced as
  ///   its own error instead of "every node failed".
  func testGroupDelay(group: String, testURL: URL, timeout: Int) async throws -> [String: Int] {
    let data: Data
    do {
      data = try await self.data(for: request(
        path: apiPath("group", group, "delay"),
        queryItems: [
          URLQueryItem(name: "url", value: testURL.absoluteString),
          URLQueryItem(name: "timeout", value: String(timeout)),
        ],
        // The core holds the response open for the whole probe window, so the transport timeout has
        // to outlast it or every large group would fail as a client-side timeout.
        timeoutOverride: Self.groupDelayRequestTimeout(forProbeTimeout: timeout)
      ))
    } catch let ClientError.httpStatus(status) where status == 404 {
      throw ClientError.unknownProxyGroup(group)
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    return object.reduce(into: [String: Int]()) { result, item in
      guard let delay = Self.int(from: item.value) else { return }
      result[item.key] = delay
    }
  }

  /// The transport timeout to allow for a group probe that itself blocks for `probeTimeout` ms.
  static func groupDelayRequestTimeout(forProbeTimeout probeTimeout: Int) -> TimeInterval {
    // The core returns as soon as the slowest member resolves or the probe window closes, so the
    // probe window plus a fixed allowance for connection setup and the JSON write is enough.
    max(TimeInterval(probeTimeout) / 1000 + 15, 30)
  }

  /// Drops every fake-ip mapping the core currently holds, via `POST /cache/fakeip/flush`.
  ///
  /// Measured against the bundled core (v1.19.30): **204 with an empty body**, and `GET` is 405 —
  /// so nothing may be decoded from the response. The core answers 204 whether or not it is
  /// actually in fake-ip mode, which is why callers gate this on the effective `enhanced-mode`
  /// rather than on the status code.
  func flushFakeIPCache() async throws {
    var request = try request(path: "/cache/fakeip/flush")
    request.httpMethod = "POST"
    _ = try await data(for: request)
  }

  /// Asks the running core to resolve a name, via `GET /dns/query?name=&type=`.
  ///
  /// This is the core's *own* resolver path — the same nameservers, the same `nameserver-policy`,
  /// the same `respect-rules` routing — which is the entire point: a system `dig` answers a
  /// different question from the one that decides where the user's traffic goes.
  ///
  /// Failure modes are the core's, preserved verbatim through `ClientError.coreMessage` because the
  /// message *is* the diagnosis: `dns.enable: false` answers 500 `DNS section is disabled`, and an
  /// unknown type answers 400 `invalid query type`. Both are user-fixable and neither is legible as
  /// a status code. An empty `name` is **not** an error — the core resolves the root zone and
  /// answers 200 — so callers reject a blank query before it is sent rather than reading the reply
  /// as an answer about nothing.
  func dnsQuery(name: String, type: String = DNSQueryType.coreDefault.rawValue) async throws -> DNSQueryResult {
    let request = try request(
      path: "/dns/query",
      queryItems: [
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "type", value: type),
      ]
    )
    let data = try await dataPreservingCoreMessage(for: request)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClientError.invalidResponse
    }
    return DNSQueryResult.decode(object, queryType: type, fallbackName: name)
  }

  /// Re-downloads the GeoIP/GeoSite/ASN databases via `POST /configs/geo`.
  ///
  /// Contract measured against the bundled core (v1.19.30) on 2026-08-27:
  /// - **Synchronous.** The response is written only after every database the running config needs
  ///   has been fetched, so this is not a fire-and-forget trigger and needs a long timeout.
  /// - **204 on success** — and also on a complete no-op: the core only fetches the databases its
  ///   *running rules* actually reference, so a config with no `GEOSITE`/`GEOIP`/ASN rule issues no
  ///   request at all and still answers 204.
  /// - **500 with `{"message": "..."}`** on failure, e.g. `can't download GeoSite database file:
  ///   500 Internal Server Error`. That message is the only actionable detail the user gets, so it
  ///   is preserved through `ClientError.coreMessage` rather than collapsed into a status code.
  /// - A failed download leaves the existing databases byte-identical on disk (verified by size and
  ///   mtime), so a failure here never needs a rollback of our own.
  /// - Downloads are dialed **through the core's own tunnel and matched against the user's rules**,
  ///   so a `MATCH` to a dead proxy breaks geo updates.
  func updateGeoDatabases(timeout: TimeInterval = MihomoAPIClient.defaultGeoUpdateTimeout) async throws {
    var request = try request(path: "/configs/geo", timeoutOverride: timeout)
    request.httpMethod = "POST"
    _ = try await dataPreservingCoreMessage(for: request)
  }

  /// Databases are tens of megabytes and are fetched through the proxy chain, so the ceiling is
  /// generous: the alternative to waiting is reporting a failure for a download that succeeds.
  static let defaultGeoUpdateTimeout: TimeInterval = 300

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

  /// The core's resident memory, one frame per second, over the same socket shape as `/traffic`.
  ///
  /// The core opens with a `{"inuse":0,"oslimit":0}` priming frame before its first real reading
  /// (measured on the bundled core, v1.19.30), which is why `CoreMemorySample.hasReading` exists:
  /// yielding that frame as "0 B resident" would report a number the core never claimed.
  func memoryStream() -> AsyncThrowingStream<CoreMemorySample, Error> {
    webSocketStream(path: "/memory") { data in
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      return CoreMemorySample(
        inUse: object?["inuse"] as? Int ?? 0,
        osLimit: object?["oslimit"] as? Int ?? 0
      )
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

  private func request(
    path: String,
    queryItems: [URLQueryItem] = [],
    timeoutOverride: TimeInterval? = nil
  ) throws -> URLRequest {
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
    // A call that blocks inside the core for its whole probe/download window needs more than the
    // shared client timeout, which is sized for ordinary control requests.
    if let timeout = timeoutOverride ?? requestTimeout {
      request.timeoutInterval = timeout
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

  /// Like `data(for:)`, but keeps Mihomo's own `{"message": "..."}` failure reason instead of
  /// reducing it to a status code. Used where that reason is the whole diagnostic value of the
  /// call (a geo update reports *which* database could not be downloaded, and why).
  private func dataPreservingCoreMessage(for request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      guard let message = Self.coreMessage(from: data) else {
        throw ClientError.httpStatus(http.statusCode)
      }
      throw ClientError.coreMessage(status: http.statusCode, message: message)
    }
    return data
  }

  private static func coreMessage(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = object["message"] as? String
    else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
              try continuation.yield(decode(data))
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
      // The host is passed through verbatim: a connection opened straight to an IP carries no
      // domain, and folding the destination IP in here (as this did before roadmap A1a) left no
      // consumer able to tell "the domain is example.com" from "there is no domain". The IP
      // fallback now lives in `ConnectionSnapshot.host`, where it is a display choice.
      return ConnectionSnapshot(
        id: id,
        network: metadata["network"] as? String ?? "",
        host: Self.stringValue(for: ["host"], in: metadata) ?? "",
        sniffHost: Self.stringValue(for: ["sniffHost", "sniff-host"], in: metadata),
        sourceIP: Self.stringValue(for: ["sourceIP", "source-ip", "srcIP", "source"], in: metadata),
        sourcePort: Self.intValue(for: ["sourcePort", "source-port", "srcPort"], in: metadata),
        destinationIP: Self.stringValue(for: ["destinationIP", "destination-ip", "dstIP"], in: metadata),
        remoteDestinationIP: Self.stringValue(
          for: ["remoteDestination", "remote-destination", "remoteDst"],
          in: metadata
        ),
        destinationPort: Self.intValue(for: ["destinationPort", "destination-port", "dstPort"], in: metadata),
        inboundPort: Self.intValue(for: ["inboundPort", "inbound-port", "inPort"], in: metadata),
        processName: Self.stringValue(for: ["process", "processName", "process-name"], in: metadata),
        processPath: Self.stringValue(for: ["processPath", "process-path"], in: metadata),
        dnsMode: Self.stringValue(for: ["dnsMode", "dns-mode"], in: metadata),
        specialProxy: Self.stringValue(for: ["specialProxy", "special-proxy"], in: metadata),
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
         let value = object[matchingKey] as? [String: Any]
      {
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
