import Foundation

/// DNS record types the resolution panel names by hand. Everything else is rendered as `TYPE<n>`,
/// the presentation `dig` uses for an unassigned type, so an unexpected record is still legible.
enum DNSRecordType {
  static let a = 1
  static let ns = 2
  static let cname = 5
  static let soa = 6
  static let ptr = 12
  static let mx = 15
  static let txt = 16
  static let aaaa = 28
  static let srv = 33
  static let svcb = 64
  static let https = 65

  private static let names: [Int: String] = [
    a: "A",
    ns: "NS",
    cname: "CNAME",
    soa: "SOA",
    ptr: "PTR",
    mx: "MX",
    txt: "TXT",
    aaaa: "AAAA",
    srv: "SRV",
    svcb: "SVCB",
    https: "HTTPS",
  ]

  static func name(for value: Int) -> String {
    names[value] ?? "TYPE\(value)"
  }
}

/// The query types the panel offers. Mihomo validates the name and answers **400
/// `{"message":"invalid query type"}`** for anything it does not know (measured against the bundled
/// core, v1.19.30), so this list is a convenience, not the boundary — the boundary is the core's.
enum DNSQueryType: String, CaseIterable, Identifiable, Sendable {
  case a = "A"
  case aaaa = "AAAA"
  case cname = "CNAME"
  case txt = "TXT"
  case https = "HTTPS"

  var id: String { rawValue }

  var displayName: String { rawValue }

  /// What the core assumes when `type` is omitted, verified by probing with and without the
  /// parameter and getting the same A answer both times.
  static let coreDefault = DNSQueryType.a
}

/// A DNS response code, named rather than shown as a bare integer — `Status: 3` is the whole
/// explanation for "the domain does not exist", and a number does not say that to anyone.
enum DNSResponseCode {
  static let noError = 0
  static let formatError = 1
  static let serverFailure = 2
  static let nameError = 3
  static let notImplemented = 4
  static let refused = 5

  private static let names: [Int: String] = [
    noError: "NOERROR",
    formatError: "FORMERR",
    serverFailure: "SERVFAIL",
    nameError: "NXDOMAIN",
    notImplemented: "NOTIMP",
    refused: "REFUSED",
  ]

  static func name(for status: Int) -> String {
    names[status] ?? "RCODE\(status)"
  }
}

/// One resource record out of a `/dns/query` answer or authority section.
struct DNSQueryRecord: Equatable, Sendable {
  var name: String
  var type: Int
  var ttl: Int
  var data: String

  var typeName: String { DNSRecordType.name(for: type) }

  var isAddress: Bool { type == DNSRecordType.a || type == DNSRecordType.aaaa }

  var summary: String { "\(typeName) \(data)" }
}

/// The decoded body of `GET /dns/query?name=&type=`.
///
/// Contract measured against the bundled core (v1.19.30) on 2026-08-30 — do not re-derive it from
/// the DoH specification, because the core's reply is DoH-*shaped*, not DoH:
/// - 200 with `Status`, `Question`, `RA`/`RD`/`AD`/`CD`/`TC`, and **`Answer` only when there is
///   one**. A `NOERROR` with no records omits the key entirely rather than sending `[]`.
/// - `Authority` carries the SOA on `NXDOMAIN`, which is the only place the negative answer's TTL
///   and the zone that denied the name appear.
/// - **There is no nameserver field anywhere in the response.** The core does not report which
///   upstream answered, so no surface built on this endpoint can honestly claim to (roadmap A2).
/// - An unknown `type` is 400 `{"message":"invalid query type"}`; `dns.enable: false` is 500
///   `{"message":"DNS section is disabled"}`. Both carry the reason in the body, so they reach the
///   caller through `ClientError.coreMessage`.
/// - The endpoint answers from the **upstream** resolvers even in fake-ip mode: with
///   `enhanced-mode: fake-ip`, `dig` against the core's own listener returned `198.18.0.4` for the
///   same name this endpoint answered with the real address. That is a feature for diagnosis (it is
///   the address the core will actually dial) and a trap for reporting, so the panel says so
///   instead of letting the user assume the two agree.
struct DNSQueryResult: Equatable, Sendable {
  /// The question name as the core echoed it, fully qualified with the trailing dot.
  var name: String
  /// The type this query asked for, kept from the request: the response reports `Qtype` as a
  /// number and the user asked in words.
  var queryType: String
  var status: Int
  var answers: [DNSQueryRecord]
  var authorities: [DNSQueryRecord]
  var isTruncated: Bool
  var isRecursionAvailable: Bool
  var isAuthenticatedData: Bool

  init(
    name: String,
    queryType: String,
    status: Int,
    answers: [DNSQueryRecord] = [],
    authorities: [DNSQueryRecord] = [],
    isTruncated: Bool = false,
    isRecursionAvailable: Bool = false,
    isAuthenticatedData: Bool = false
  ) {
    self.name = name
    self.queryType = queryType
    self.status = status
    self.answers = answers
    self.authorities = authorities
    self.isTruncated = isTruncated
    self.isRecursionAvailable = isRecursionAvailable
    self.isAuthenticatedData = isAuthenticatedData
  }

  var statusName: String { DNSResponseCode.name(for: status) }

  var isSuccess: Bool { status == DNSResponseCode.noError }

  /// The A/AAAA data, which is the only part of the answer a routing decision can be made on.
  var addresses: [String] { answers.filter(\.isAddress).map(\.data) }

  /// The name the answer chain ends on, following `CNAME` records. What a rule for the *queried*
  /// name has to compete with: the core matches on the name the connection carries, not on this
  /// one, but a user reading an unexpected exit needs to see the redirection happened.
  var canonicalName: String? {
    answers.last { $0.type == DNSRecordType.cname }?.data
  }

  /// Display form of the question, without the root dot the wire format requires.
  var displayName: String {
    name.count > 1 && name.hasSuffix(".") ? String(name.dropLast()) : name
  }

  static func decode(_ object: [String: Any], queryType: String, fallbackName: String) -> DNSQueryResult {
    let question = (object["Question"] as? [[String: Any]])?.first
    let name = (question?["Name"] as? String) ?? fallbackName
    return DNSQueryResult(
      name: name,
      queryType: queryType,
      status: intValue(object["Status"]) ?? DNSResponseCode.noError,
      answers: records(from: object["Answer"]),
      authorities: records(from: object["Authority"]),
      isTruncated: object["TC"] as? Bool ?? false,
      isRecursionAvailable: object["RA"] as? Bool ?? false,
      isAuthenticatedData: object["AD"] as? Bool ?? false
    )
  }

  private static func records(from value: Any?) -> [DNSQueryRecord] {
    guard let entries = value as? [[String: Any]] else { return [] }
    return entries.compactMap { entry in
      guard let data = entry["data"] as? String else { return nil }
      return DNSQueryRecord(
        name: entry["name"] as? String ?? "",
        type: intValue(entry["type"]) ?? 0,
        ttl: intValue(entry["TTL"]) ?? 0,
        data: data
      )
    }
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int: return value
    case let value as Double: return Int(value)
    case let value as NSNumber: return value.intValue
    case let value as String: return Int(value)
    default: return nil
    }
  }
}
