import Foundation
import Network

enum DiagnosticFactSource: String, Sendable {
  case core, probe, simulation, log

  var title: String {
    switch self {
    case .core: String(localized: "Core report")
    case .probe: String(localized: "Live probe")
    case .simulation: String(localized: "Simulation")
    case .log: String(localized: "Log inference")
    }
  }
}

struct ConnectionDNSObservation: Codable, Equatable, Sendable {
  var date: Date
  var addresses: [String]
  var upstream: String?
  var cacheHit: Bool
}

/// Measured with bundled v1.19.34, a loopback DNS responder and /logs?level=debug:
/// /dns/query had answers and TTLs only. A completed lookup logged
/// "[DNS] host --> [address] A from udp://host:port"; a repeat logged
/// "[DNS] cache hit host --> [address] A, expire at ...", without an upstream.
/// Neither line carries a connection ID. Never turn the dialled IP into a DNS answer.
struct ConnectionDNSLogIndex: Sendable {
  private var entries: [String: [ConnectionDNSObservation]] = [:]
  private static let lifetime: TimeInterval = 15
  private static let domainLimit = 128

  mutating func record(_ entry: LogEntry) {
    guard entry.level == "debug", entry.message.hasPrefix("[DNS] ") else { return }
    var line = entry.message.dropFirst(6)
    let cached = line.hasPrefix("cache hit ")
    if cached { line = line.dropFirst(10) }
    guard let arrow = line.range(of: " --> ["), let closing = line[arrow.upperBound...].range(of: "] ") else { return }
    let host = String(line[..<arrow.lowerBound]).lowercased()
    let addresses = line[arrow.upperBound..<closing.lowerBound].split(separator: " ").map(String.init)
    guard !host.isEmpty, !addresses.isEmpty, addresses.allSatisfy({ IPv4Address($0) != nil || IPv6Address($0) != nil }) else { return }
    let detail = line[closing.upperBound...]
    let upstream: String?
    if cached {
      guard detail.hasPrefix("A, expire at ") || detail.hasPrefix("AAAA, expire at ") else { return }
      upstream = nil
    } else {
      guard let split = detail.range(of: " from "), ["A", "AAAA"].contains(String(detail[..<split.lowerBound])) else { return }
      // Resolver URLs may contain credentials, a private path or query. Retain only their authority.
      let raw = String(detail[split.upperBound...])
      let url = URLComponents(string: raw.contains("://") ? raw : "udp://\(raw)")
      guard let server = url?.host, let scheme = url?.scheme else { return }
      upstream = "\(scheme)://\(server)" + (url?.port.map { ":\($0)" } ?? "")
    }
    if entries[host] == nil, entries.count >= Self.domainLimit,
       let oldest = entries.min(by: { ($0.value.last?.date ?? .distantPast) < ($1.value.last?.date ?? .distantPast) })
    {
      entries.removeValue(forKey: oldest.key)
    }
    let recent = entries[host, default: []].suffix(3).filter { entry.date.timeIntervalSince($0.date) <= Self.lifetime }
    entries[host] = recent + [ConnectionDNSObservation(date: entry.date, addresses: addresses, upstream: upstream, cacheHit: cached)]
  }

  func observation(for connection: ConnectionSnapshot, now: Date) -> ConnectionDNSObservation? {
    guard let host = connection.domain?.lowercased(), let start = connection.startedAt else { return nil }
    return entries[host]?.filter { entry in
      (0...Self.lifetime).contains(now.timeIntervalSince(entry.date))
        && abs(entry.date.timeIntervalSince(start)) <= 2
        && (connection.remoteDestinationIP.map(entry.addresses.contains) ?? true)
    }.min { abs($0.date.timeIntervalSince(start)) < abs($1.date.timeIntervalSince(start)) }
  }
}

struct ConnectionPathFact: Identifiable, Equatable {
  enum Step: CaseIterable { case host, dns, rule, verification, groups, node, exit }
  var id: Step
  var title: String
  var value: String
  var source: DiagnosticFactSource
  var date: Date?
  var mismatch = false
}

enum ConnectionPath {
  /// On bundled v1.19.34 /connections returned [DIRECT, Inner, Outer], a fractional RFC3339
  /// start, inboundName and an empty inboundUser for a loopback mixed CONNECT.
  static func facts(_ connection: ConnectionSnapshot, rules: [RuntimeRule], exit: PublicIPInfoState = .idle,
                    now: Date = Date()) -> [ConnectionPathFact]
  {
    let groups = connection.chain.dropFirst().reversed()
    let observed = connection.lastSeenAt ?? connection.startedAt
    let missing = String(localized: "Unavailable — omitted by the core")
    let domains = [connection.reportedHost.map { String(format: String(localized: "Host: %@"), $0) },
                   connection.sniffHost.map { String(format: String(localized: "Sniffed: %@"), $0) }].compactMap(\.self)
    let dns = connection.dnsObservation
    let dnsValue = dns.map {
      let resolver = $0.upstream ?? String(localized: "upstream unavailable on cache hits")
      return [$0.addresses.joined(separator: ", "), $0.cacheHit ? String(localized: "Cache hit") : String(localized: "Upstream answer"), resolver].joined(separator: " · ")
    } ?? String(localized: "Unavailable — no matching debug DNS answer near connection start")
    let result = RuleExplanationBuilder().explanation(for: connection, rules: rules)
    let mismatch: Bool
    switch result.localOutcome {
    case let .matched(rule):
      mismatch = connection.rule.map {
        RuntimeRuleTypeName.canonical($0) != RuntimeRuleTypeName.canonical(rule.type)
          || (connection.rulePayload ?? "") != rule.payload
          || connection.chain.last.map { $0 != rule.policy } == true
      } ?? false
    case .noMatch: mismatch = !rules.isEmpty && connection.rule != nil
    case .mihomoOnly: mismatch = false
    }
    let exitValue: String
    switch exit {
    case .idle: exitValue = String(localized: "Unavailable — current exit has not been probed")
    case .loading: exitValue = String(localized: "Checking current exit…")
    case let .loaded(info):
      exitValue = [info.ipAddress, info.countryName ?? info.countryCode ?? String(localized: "Region unavailable"), info.sourceName].joined(separator: " · ")
    case let .failed(message, _, _): exitValue = message
    }
    return [
      .init(id: .host, title: String(localized: "Request / sniffed host"), value: domains.isEmpty ? missing : domains.joined(separator: " · "), source: .core, date: observed),
      .init(id: .dns, title: String(localized: "DNS answer"), value: dnsValue, source: .log, date: dns?.date),
      .init(id: .rule, title: String(localized: "Matched Rule"), value: connection.ruleSummary.isEmpty ? missing : connection.ruleSummary, source: .core, date: observed),
      .init(id: .verification, title: String(localized: "Check against current rules"), value: rules.isEmpty ? String(localized: "Unavailable — no runtime rules") : result.localSummary, source: .simulation, date: now, mismatch: mismatch),
      .init(id: .groups, title: String(localized: "Policy group chain"), value: connection.chain.isEmpty ? missing : groups.isEmpty ? String(localized: "No intermediate group") : groups.joined(separator: " → "), source: .core, date: observed),
      .init(id: .node, title: String(localized: "Actual outbound"), value: connection.chain.first ?? missing, source: .core, date: observed),
      .init(id: .exit, title: String(localized: "Exit IP / region"), value: exitValue, source: .probe, date: exit.refreshAnchor),
    ]
  }
}
