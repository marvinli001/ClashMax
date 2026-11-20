import Foundation

enum AIService: String, CaseIterable, Identifiable, Sendable {
  case openAI = "OpenAI", anthropic = "Anthropic", gemini = "Google Gemini"
  var id: Self { self }

  /// Anonymous GETs measured 2026-11-20. The model-list APIs answered 401 for OpenAI and
  /// Anthropic. Google's list returned a non-geographic 403 ACCESS_DENIED; its public discovery
  /// document identifies the API without requiring a key. Both Cloudflare web hosts returned loc.
  var endpoints: (web: URL, api: URL, trace: URL?) {
    switch self {
    case .openAI: (URL(string: "https://chatgpt.com/")!, URL(string: "https://api.openai.com/v1/models")!, URL(string: "https://chatgpt.com/cdn-cgi/trace")!)
    case .anthropic: (URL(string: "https://claude.ai/")!, URL(string: "https://api.anthropic.com/v1/models")!, URL(string: "https://claude.ai/cdn-cgi/trace")!)
    case .gemini: (URL(string: "https://gemini.google.com/")!, URL(string: "https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta")!, nil)
    }
  }

  // Country-level policies checked 2026-11-20. A listed country may still have subregional restrictions.
  // https://help.openai.com/en/articles/7947663
  // https://www.anthropic.com/legal/supported-regions (includes dependencies of listed countries).
  private static let openAIRegions = Set("AD AE AF AG AL AM AO AR AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BR BS BT BW BZ CA CD CF CG CH CI CL CM CO CR CV CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FM FO FR GA GB GD GE GF GH GL GM GN GP GQ GR GT GW GY HN HR HT HU ID IE IL IN IQ IS IT JM JO JP KE KG KH KI KM KN KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MQ MR MT MU MV MW MX MY MZ NA NC NE NG NI NL NO NP NR NZ OM PA PE PF PG PH PK PL PM PS PT PW PY QA RE RO RS RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SZ TD TF TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VN VU WF WS YE YT ZA ZM ZW".split(separator: " ").map(String.init))
  private static let anthropicRegions = Set("AD AE AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BZ CA CC CD CF CG CH CI CK CL CM CO CR CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HM HN HR HT HU ID IE IL IM IN IO IQ IS IT JE JM JO JP KE KG KH KI KM KN KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MN MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VG VI VN VU WF WS YT ZA ZM ZW".split(separator: " ").map(String.init))

  func supports(region: String) -> Bool? {
    guard Locale.Region.isoRegions.contains(Locale.Region(region)) else { return nil }
    switch self {
    case .openAI: return Self.openAIRegions.contains(region)
    case .anthropic: return Self.anthropicRegions.contains(region)
    case .gemini: return nil
    }
  }

  static func traceRegion(_ text: String, host: String) -> String? {
    let fields = text.split(whereSeparator: \.isNewline)
    guard fields.contains("h=\(host)"), let loc = fields.first(where: { $0.hasPrefix("loc=") }) else { return nil }
    let value = String(loc.dropFirst(4))
    return Locale.Region.isoRegions.contains(Locale.Region(value)) && value.count == 2 ? value : nil
  }
}

enum AIProbeCause: Int, Sendable {
  case normal, unavailable, direct, serviceDenied, unreachable, tls, region
  var title: String {
    switch self {
    case .direct: String(localized: "Rules routed to DIRECT")
    case .unreachable: String(localized: "Node or destination unreachable")
    case .tls: String(localized: "TLS failed")
    case .region: String(localized: "Region denied")
    case .serviceDenied: String(localized: "Service refused the request")
    case .normal: String(localized: "Reachable")
    case .unavailable: String(localized: "Unavailable — insufficient evidence")
    }
  }
}

enum AIProbeClassifier {
  static func content(service: AIService, api: Bool, status: Int?, body: String, challenge: Bool = false, redirect: URL? = nil, error: URLError.Code? = nil) -> AIProbeCause {
    if let error {
      switch error {
      case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
           .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired: return .tls
      case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet: return .unreachable
      default: return .unavailable
      }
    }
    guard let status else { return .unavailable }
    let text = body.lowercased()
    if !(200..<300).contains(status) || !api && text.count < 8192 {
      if ["unsupported_country_region_territory", "user location is not supported", "not available in your region", "not available in your country"].contains(where: text.contains) { return .region }
    }
    if challenge || text.contains("<title>just a moment") { return .serviceDenied }
    if api, status == 401 {
      if service == .openAI && text.contains("missing bearer authentication") || service == .anthropic && text.contains("authentication_error") { return .normal }
    }
    if !api, (300..<400).contains(status), let redirect, redirect.scheme == "https" {
      if redirect.host() == service.endpoints.web.host(), ["/login", "/auth/login", "/signin"].contains(redirect.path()) { return .normal }
      if service == .gemini, redirect.host() == "accounts.google.com", redirect.path().hasPrefix("/ServiceLogin") { return .normal }
    }
    if (400...599).contains(status) { return .serviceDenied }
    guard (200..<300).contains(status) else { return .unavailable }
    if api {
      guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return .unavailable }
      if service == .gemini { return json["kind"] as? String == "discovery#restDescription" && json["name"] as? String == "generativelanguage" ? .normal : .unavailable }
      return json["data"] is [Any] ? .normal : .unavailable
    }
    let marker = switch service { case .openAI: "chatgpt"; case .anthropic: "claude"; case .gemini: "gemini" }
    return text.contains("<html") && text.contains(marker) ? .normal : .unavailable
  }

  static func verdict(content: AIProbeCause, connection: ConnectionSnapshot?, regionSupported: Bool?) -> AIProbeCause {
    if content == .region || regionSupported == false && content == .serviceDenied { return .region }
    if let connection, connection.rule != nil, ProxyEffectDiagnosticsBuilder.isDirect(connection.chain.first) { return .direct }
    return content
  }
}

struct AIProbeFact: Identifiable, Sendable {
  var id: String { title }
  var title: String
  var value: String
  var source: DiagnosticFactSource
  var date: Date
  var text: String { [title, value, source.title, date.formatted(date: .abbreviated, time: .standard)].joined(separator: " · ") }
}

struct AIEndpointResult: Identifiable, Sendable {
  var id: String { host }
  var host: String
  var cause: AIProbeCause
  var facts: [AIProbeFact]
  var connection: ConnectionSnapshot?
}

struct AIServiceResult: Identifiable, Sendable {
  var id: AIService { service }
  var service: AIService
  var endpoints: [AIEndpointResult]
  var nodeMode: Bool
  var date: Date
  var cause: AIProbeCause { endpoints.map(\.cause).max(by: { $0.rawValue < $1.rawValue }) ?? .unavailable }
  var summary: String {
    if nodeMode, cause == .unreachable { return String(localized: "Unreachable") }
    return cause.title
  }

  var source: DiagnosticFactSource { nodeMode ? .core : .simulation }
  var report: String {
    let heading = [service.rawValue, nodeMode ? String(localized: "Specified node") : String(localized: "Current rules"), summary, source.title, date.formatted(date: .abbreviated, time: .standard)].joined(separator: " · ")
    return ([heading] + endpoints.flatMap { [$0.host] + $0.facts.map(\.text) }).joined(separator: "\n")
  }
}
