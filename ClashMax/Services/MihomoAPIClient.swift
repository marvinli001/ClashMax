import Foundation

protocol MihomoAPIControlling: Sendable {
  func updateMode(_ mode: RunMode) async throws
  func proxyGroups() async throws -> [ProxyGroup]
  func rules() async throws -> [String]
  func connections() async throws -> [ConnectionSnapshot]
  func selectProxy(group: String, proxy: String) async throws
  func testDelay(proxy: String, testURL: URL, timeout: Int) async throws -> Int
  func trafficStream() -> AsyncThrowingStream<TrafficSample, Error>
  func logStream(level: String) -> AsyncThrowingStream<LogEntry, Error>
  func connectionStream(interval: Int) -> AsyncThrowingStream<[ConnectionSnapshot], Error>
}

struct MihomoAPIClient: Sendable {
  enum ClientError: Error {
    case invalidResponse
    case httpStatus(Int)
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
    var request = request(path: "/configs")
    request.httpMethod = "PATCH"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    _ = try await data(for: request)
  }

  func restart(configPath: String? = nil) async throws {
    var request = request(path: "/restart")
    request.httpMethod = "POST"
    if let configPath {
      request.httpBody = try JSONSerialization.data(withJSONObject: ["path": configPath])
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    _ = try await data(for: request)
  }

  func proxyGroups() async throws -> [ProxyGroup] {
    let data = try await data(for: request(path: "/proxies"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let proxies = object?["proxies"] as? [String: Any] ?? [:]
    let proxyTypes = proxies.reduce(into: [String: String]()) { result, item in
      guard let proxy = item.value as? [String: Any],
            let type = proxy["type"] as? String
      else { return }
      result[item.key] = type
    }

    return proxies.compactMap { name, value in
      guard let item = value as? [String: Any] else { return nil }
      let type = item["type"] as? String ?? "Unknown"
      let all = item["all"] as? [String] ?? []
      guard !all.isEmpty else { return nil }
      let history = item["history"] as? [[String: Any]] ?? []
      let nodes = all.map { proxyName in
        ProxyNode(
          name: proxyName,
          type: proxyTypes[proxyName] ?? "proxy",
          delay: Self.delay(for: proxyName, history: history),
          isSelectable: true
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

  func rules() async throws -> [String] {
    let data = try await data(for: request(path: "/rules"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rules = object?["rules"] as? [[String: Any]] ?? []
    return rules.map { rule in
      [rule["type"], rule["payload"], rule["proxy"]]
        .compactMap { $0 as? String }
        .joined(separator: ",")
    }
  }

  func connections() async throws -> [ConnectionSnapshot] {
    let data = try await data(for: request(path: "/connections"))
    return try Self.decodeConnections(from: data)
  }

  func selectProxy(group: String, proxy: String) async throws {
    var request = request(path: apiPath("proxies", group))
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

  private func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath = path
    if !queryItems.isEmpty {
      components.queryItems = queryItems
    }
    var request = URLRequest(url: components.url!)
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
      var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
      components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
      components.percentEncodedPath = path
      if !queryItems.isEmpty {
        components.queryItems = queryItems
      }
      var request = URLRequest(url: components.url!)
      request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
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
        upload: item["upload"] as? Int ?? 0,
        download: item["download"] as? Int ?? 0,
        chain: chains,
        rule: item["rule"] as? String,
        startedAt: nil
      )
    }
  }

  private static func delay(for proxyName: String, history: [[String: Any]]) -> Int? {
    history
      .first { $0["name"] as? String == proxyName }?["delay"] as? Int
  }
}

extension MihomoAPIClient: MihomoAPIControlling {}
