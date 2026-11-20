import Foundation
import Synchronization

struct AIServiceProbe: Sendable {
  let client: any MihomoAPIControlling
  let mixedPort: Int

  /// Bundled v1.19.34, isolated on loopback: hidden:true + include-all-proxies and an inbound
  /// pinned with proxy: worked. PUT changed only its selection, but the group also appeared in
  /// GLOBAL.all. The per-node delay endpoint instead accepted even HTTP 503 with expected=200-499
  /// (and 401 with expected=200). Its success proves an HTTP exchange, never content or region.
  func check(_ service: AIService, node: String?) async throws -> AIServiceResult {
    let targets = service.endpoints
    var results: [AIEndpointResult] = []
    for (url, api) in [(targets.web, false), (targets.api, true)] {
      try Task.checkCancellation()
      if let node {
        let cause: AIProbeCause
        do {
          let delay = try await client.probeHTTPReachability(proxy: node, url: url)
          cause = delay ? .normal : .unreachable
        } catch MihomoAPIClient.ClientError.delayTestHTTPStatus { cause = .unreachable }
        catch { cause = .unavailable }
        let now = Date()
        results.append(.init(host: url.host()!, cause: cause, facts: [
          .init(title: String(localized: "HTTP reachability"), value: cause == .unreachable ? String(localized: "Unreachable") : cause.title, source: .core, date: now),
          .init(title: String(localized: "Exit IP / region"), value: String(localized: "Unavailable — node probe returns reachability only"), source: .core, date: now),
        ]))
      } else {
        try await results.append(checkEndpoint(url, service: service, api: api))
      }
    }
    try Task.checkCancellation()
    return .init(service: service, endpoints: results, nodeMode: node != nil, date: Date())
  }

  private func checkEndpoint(_ url: URL, service: AIService, api: Bool) async throws -> AIEndpointResult {
    let host = url.host()!
    let config = try PublicIPInfoClient.loopbackConfiguration(port: mixedPort)
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    async let dns = dnsFact(host)
    let start = Date()
    let watcher = Task { await capture(host: host, since: start) }
    var request = URLRequest(url: url)
    if api && service == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    let http = await Self.fetch(request, session: session)
    let end = Date()
    watcher.cancel()
    var candidates = await watcher.value
    try Task.checkCancellation()
    if let tail = try? await client.connections() { candidates += tail.connections }
    let connection = Self.connection(for: host, port: mixedPort, window: start...end, localPort: http.metrics.port, candidates: candidates)
    let content = AIProbeClassifier.content(service: service, api: api, status: http.status, body: http.body, challenge: http.challenge, redirect: http.redirect, error: http.error)
    let missingMetrics = String(localized: "Unavailable — URLSession omitted this timing")
    let missingHTTP = String(localized: "Unavailable — no HTTP response")
    var facts = await [dns,
                       AIProbeFact(title: String(localized: "TCP to proxy"), value: http.metrics.tcp == nil ? missingMetrics : String(localized: "Connected"), source: .probe, date: http.metrics.tcp ?? end),
                       AIProbeFact(title: "TLS", value: http.metrics.tls == nil ? missingMetrics : String(localized: "Handshake completed"), source: .probe, date: http.metrics.tls ?? end),
                       AIProbeFact(title: "HTTP", value: http.status.map(String.init) ?? missingHTTP, source: .probe, date: end),
                       AIProbeFact(title: String(localized: "Response interpretation"), value: content.title, source: .simulation, date: end)]
    if let connection {
      let direct = ProxyEffectDiagnosticsBuilder.isDirect(connection.chain.first)
      facts.append(.init(title: String(localized: "Path"), value: direct ? "DIRECT" : String(localized: "Connection captured"), source: .core, date: connection.startedAt ?? end))
    } else {
      facts.append(.init(title: String(localized: "Path"), value: String(localized: "Unavailable — no unique connection in the request window"), source: .core, date: end))
    }

    let region: String?
    var sameTunnelRegionSupported: Bool?
    if !api, let trace = service.endpoints.trace {
      try Task.checkCancellation()
      let read = await Self.fetch(URLRequest(url: trace), session: session)
      region = read.status == 200 ? AIService.traceRegion(read.body, host: host) : nil
      // A load-balanced group can pick a new egress on a new CONNECT. Only use the trace to
      // interpret a refusal when URLSession reused the same proxy tunnel for this host.
      if read.metrics.reused, let port = http.metrics.port, port == read.metrics.port {
        sameTunnelRegionSupported = region.flatMap(service.supports)
      }
    } else { region = nil }
    let regionDate = Date()
    facts.append(.init(title: String(localized: "Exit region (same-host trace)"), value: region ?? String(localized: "Unavailable — no valid region trace for this endpoint"), source: .probe, date: regionDate))
    if let supported = region.flatMap(service.supports) {
      facts.append(.init(title: String(localized: "Published region list"), value: supported ? String(localized: "Country listed") : String(localized: "Country outside the list"), source: .simulation, date: regionDate))
    }
    let cause = AIProbeClassifier.verdict(content: content, connection: connection, regionSupported: http.challenge ? nil : sameTunnelRegionSupported)
    return .init(host: host, cause: cause, facts: facts, connection: connection)
  }

  private func dnsFact(_ host: String) async -> AIProbeFact {
    let answer = try? await client.dnsQuery(name: host, type: "A")
    let value = answer.map { "\($0.statusName) · A × \($0.addresses.count)" } ?? String(localized: "Unavailable — core DNS query failed")
    return .init(title: String(localized: "Core DNS query (separate request)"), value: value, source: .core, date: Date())
  }

  private func capture(host: String, since start: Date) async -> [ConnectionSnapshot] {
    var matches: [String: ConnectionSnapshot] = [:]
    while !Task.isCancelled {
      if let report = try? await client.connections() {
        for item in report.connections where item.domain == host && item.startedAt.map({ $0 >= start }) == true { matches[item.id] = item }
      }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
    }
    return Array(matches.values)
  }

  static func connection(for host: String, port: Int, window: ClosedRange<Date>, localPort: Int?, candidates: [ConnectionSnapshot]) -> ConnectionSnapshot? {
    let matches = candidates.filter {
      $0.domain?.caseInsensitiveCompare(host) == .orderedSame && $0.inboundPort == port && $0.startedAt.map(window.contains) == true
        && (localPort == nil || $0.sourcePort == localPort)
    }
    let ids = Set(matches.map(\.id))
    return ids.count == 1 ? matches.last : nil
  }

  private struct Transport: Sendable {
    var tcp: Date?
    var tls: Date?
    var port: Int?
    var reused = false
  }

  private final class Metrics: NSObject, URLSessionTaskDelegate {
    let measured = Mutex(Transport())

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
      guard let hop = metrics.transactionMetrics.last else { return }
      measured.withLock { $0 = Transport(tcp: hop.connectEndDate, tls: hop.secureConnectionEndDate, port: hop.localPort, reused: hop.isReusedConnection) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
      completionHandler(nil)
    }
  }

  private struct HTTPReading {
    var status: Int?
    var body = ""
    var redirect: URL?
    var challenge = false
    var error: URLError.Code?
    var metrics: Transport
  }

  private static func fetch(_ request: URLRequest, session: URLSession) async -> HTTPReading {
    let metrics = Metrics()
    do {
      let (data, response) = try await session.data(for: request, delegate: metrics)
      let http = response as? HTTPURLResponse
      return HTTPReading(status: http?.statusCode, body: String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self),
                         redirect: http?.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL },
                         challenge: http?.value(forHTTPHeaderField: "cf-mitigated") == "challenge", metrics: metrics.measured.withLock { $0 })
    } catch {
      return HTTPReading(error: (error as? URLError)?.code ?? .unknown, metrics: metrics.measured.withLock { $0 })
    }
  }
}
