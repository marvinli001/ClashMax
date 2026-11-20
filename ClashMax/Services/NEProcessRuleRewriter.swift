import Darwin
import Foundation

/// Measured with two SOCKS clients on bundled v1.19.34: IN-NAME is case-sensitive and accepts
/// slash-separated names. Both TCP CONNECT and UDP ASSOCIATE reported the listener in metadata
/// and matched the same rule. A nested AND/OR with an IN-NAME leaf passed -t and routed TCP.
/// Add managed listeners after the inherited-listener consent check; C3 classifies the explicit
/// 127.0.0.1 bind as local even with skip-auth-prefixes enabled.
struct NEProcessRuleRewriter {
  private var plan = NEProcessRoutePlan()
  private var routesByPredicate: [NEProcessPredicate: NEProcessRoute] = [:]
  private var omitted: Set<NEProcessPredicate> = []
  private var reservedNames: Set<String> = []
  private var occupiedPorts = IndexSet()
  private var nextName = 1
  private var subRules: [String: [String]] = [:]
  private var visited: Set<String> = []
  private let existing: [NEProcessRoute]

  init(reusing existing: [NEProcessRoute] = []) { self.existing = existing }

  mutating func apply(to root: inout [String: Any], reservedPorts: Set<Int>) throws -> NEProcessRoutePlan {
    guard let rules = root["rules"] as? [String] else { return plan }
    let listeners = root["listeners"] as? [[String: Any]] ?? []
    reservedNames = Set(listeners.compactMap { $0["name"] as? String })
    occupiedPorts = IndexSet(reservedPorts)
    for listener in listeners {
      // v1.19.34 bound both ends of a port range in a single SOCKS listener definition.
      guard let ports = listener["port"] else { continue }
      for part in String(describing: ports).split(whereSeparator: { $0 == "/" || $0 == "," }) {
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
        if let first = bounds.first.flatMap({ UInt16($0) }), let last = bounds.last.flatMap({ UInt16($0) }), first <= last {
          occupiedPorts.insert(integersIn: Int(first)...Int(last))
        }
      }
    }
    subRules = root["sub-rules"] as? [String: [String]] ?? [:]
    let rewritten = try rules.map { try rewriteRule($0, conditional: false) }
    guard !plan.routes.isEmpty else { return plan }
    if root["listeners"] != nil, !(root["listeners"] is [[String: Any]]) {
      throw ConfigNormalizer.NormalizerError.invalidProfile(String(localized: "Invalid listeners in the runtime profile"))
    }
    root["rules"] = rewritten
    if !visited.isEmpty { root["sub-rules"] = subRules }
    root["listeners"] = listeners + plan.routes.map {
      ["type": "socks", "listen": "127.0.0.1", "udp": true, "name": $0.inbound, "port": $0.port]
    }
    return plan
  }

  private mutating func rewriteRule(_ raw: String, conditional: Bool) throws -> String {
    let fields = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count >= 3 else { return raw }
    let type = fields[0].uppercased()
    let condition: String
    let policy: String
    if let kind = NEProcessPredicate.Kind(rawValue: type), !kind.isRegex {
      // Plain process rules have a target in field three. Keep any extra flags on the leaf.
      condition = ([type, fields[1]] + fields.dropFirst(3)).joined(separator: ",")
      policy = fields[2]
    } else {
      guard NEProcessPredicate.Kind(rawValue: type) != nil || ["AND", "OR", "NOT", "SUB-RULE"].contains(type) else { return raw }
      // Like Mihomo's ParseRulePayload, preserve commas inside a regexp or logical expression.
      condition = fields.dropLast().joined(separator: ",")
      policy = fields[fields.count - 1]
    }
    if type == "SUB-RULE", let rules = subRules[policy], visited.insert(policy).inserted {
      subRules[policy] = try rules.map { try rewriteRule($0, conditional: true) }
    }
    guard condition.uppercased().contains("PROCESS-") else { return raw }
    let rewritten = try rewriteCondition(condition, conditional: conditional, depth: 0)
    return rewritten == condition ? raw : rewritten + "," + policy
  }

  private mutating func rewriteCondition(_ text: String, conditional: Bool, depth: Int) throws -> String {
    guard let comma = text.firstIndex(of: ",") else { return text }
    let type = text[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
    let payload = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
    if let kind = NEProcessPredicate.Kind(rawValue: type) {
      let value = kind.isRegex ? payload : String(payload.prefix(while: { $0 != "," }))
      let predicate = NEProcessPredicate(kind: kind, value: value)
      guard let route = try route(for: predicate, conditional: conditional) else { return text }
      let leaf: String
      if kind.isRegex {
        leaf = type + "," + Self.logicRegex(payload)
      } else if !Self.hasBalancedParentheses(value) {
        // The logic parser treats even a literal process-name parenthesis as structure. Encode
        // that exact leaf as an anchored literal so e.g. "Helper) Beta" still passes -t.
        let literalKind = kind == .name ? "PROCESS-NAME-REGEX" : "PROCESS-PATH-REGEX"
        let pattern = Self.logicRegex(AppProcessRule.escapedRegexLiteral(value))
        leaf = literalKind + ",\\A" + pattern + "\\z"
      } else {
        leaf = text
      }
      return "OR,((\(leaf)),(IN-NAME,\(route.inbound)))"
    }
    guard ["OR", "AND", "NOT", "SUB-RULE"].contains(type), payload.first == "(", payload.last == ")" else { return text }
    guard depth < 64 else { throw ConfigNormalizer.NormalizerError.invalidProfile(String(localized: "Process rule nesting exceeds 64 levels")) }
    let inner = payload.dropFirst().dropLast()
    if type == "SUB-RULE" {
      let child = try rewriteCondition(String(inner), conditional: true, depth: depth + 1)
      return child == inner ? text : "\(type),(\(child))"
    }
    var result = "", level = 0, start = inner.startIndex
    for i in inner.indices {
      let char = inner[i]
      if char == "(" {
        if level == 0 { start = inner.index(after: i) }
        level += 1
      } else if char == ")" {
        level -= 1
        if level == 0 { result += try "(" + rewriteCondition(String(inner[start..<i]), conditional: true, depth: depth + 1) + ")" }
      } else if level == 0 { result.append(char) }
    }
    return result == inner ? text : "\(type),(\(result))"
  }

  private static func hasBalancedParentheses(_ value: String) -> Bool {
    var depth = 0
    for char in value {
      if char == "(" { depth += 1 }
      if char == ")" {
        guard depth > 0 else { return false }
        depth -= 1
      }
    }
    return depth == 0
  }

  /// The core's logic parser counts even escaped parentheses before handing a leaf to regexp2.
  private static func logicRegex(_ value: String) -> String {
    var result = "", escaped = false, inClass = false
    for char in value {
      if escaped {
        result += char == "(" ? "\\x28" : char == ")" ? "\\x29" : "\\" + String(char)
        escaped = false
      } else if char == "\\" { escaped = true }
      else {
        if char == "[" { inClass = true } else if char == "]" { inClass = false }
        result += inClass && char == "(" ? "\\x28" : inClass && char == ")" ? "\\x29" : String(char)
      }
    }
    return result
  }

  private mutating func route(for predicate: NEProcessPredicate, conditional: Bool) throws -> NEProcessRoute? {
    if let route = routesByPredicate[predicate] { return route }
    guard !omitted.contains(predicate) else { return nil }
    if predicate.kind.isRegex, (try? predicate.expression()) == nil {
      omitted.insert(predicate)
      plan.unsupported += 1
      return nil
    }
    guard plan.routes.count < NEProcessRoutePlan.limit else {
      omitted.insert(predicate)
      plan.overLimit += 1
      return nil
    }
    while reservedNames.contains("clashmax-ne-\(nextName)") { nextName += 1 }
    let name = "clashmax-ne-\(nextName)"
    nextName += 1
    let previous = existing.first { $0.predicate == predicate && !occupiedPorts.contains($0.port) }
    let port = try previous?.port ?? Self.freePort(excluding: occupiedPorts.union(IndexSet(existing.map(\.port))))
    occupiedPorts.insert(port)
    let route = NEProcessRoute(predicate: predicate, inbound: name, port: port, conditional: conditional)
    routesByPredicate[predicate] = route
    plan.routes.append(route)
    return route
  }

  private static func freePort(excluding: IndexSet) throws -> Int {
    for _ in 0..<128 {
      let tcp = socket(AF_INET, SOCK_STREAM, 0)
      guard tcp >= 0 else { break }
      defer { close(tcp) }
      let udp = socket(AF_INET, SOCK_DGRAM, 0)
      guard udp >= 0 else { break }
      defer { close(udp) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      var length = socklen_t(address.sin_len)
      let bound = withUnsafeMutablePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(tcp, $0, length) == 0 && getsockname(tcp, $0, &length) == 0 && bind(udp, $0, length) == 0
        }
      }
      let port = Int(UInt16(bigEndian: address.sin_port))
      if bound, !excluding.contains(port) { return port }
    }
    throw AppError.portUnavailable(String(localized: "No loopback TCP/UDP port available for app attribution"))
  }
}
