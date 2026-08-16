import Foundation

/// A local copy of the same helper `CoreModels` keeps file-private: a stored snippet written by an
/// older build is missing keys this type has since gained, and a throwing decode would drop the
/// user's whole snippet library rather than one field.
private extension KeyedDecodingContainer {
  func decodeDefault<T: Decodable>(
    _ type: T.Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> T
  ) -> T {
    (try? decodeIfPresent(type, forKey: key)) ?? defaultValue()
  }
}

/// The protocols the bundled core knows how to sniff.
///
/// The raw values are the exact keys Mihomo accepts under `sniffer.sniff`. Anything else fails the
/// config test with `level=error msg="not find the sniffer[BOGUS]"`, verified against the bundled
/// core (v1.19.29) on 2026-08-15 — which is why this is a closed enum rather than free text.
enum SnifferProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
  case tls = "TLS"
  case http = "HTTP"
  case quic = "QUIC"

  var id: String { rawValue }

  var displayName: String { rawValue }

  /// What ClashMax proposes when the protocol is added to the sniff map. TLS carries the SNI and
  /// HTTP the `Host` header, so these are the ports where a domain is actually recoverable.
  ///
  /// Deliberately wider than `coreFallbackPorts`: the core's own fallback is a single port, which
  /// misses the alternate ports these protocols are routinely served on.
  var defaultPorts: [String] {
    switch self {
    case .tls:
      return ["443", "8443"]
    case .http:
      return ["80", "8080-8880"]
    case .quic:
      return ["443"]
    }
  }

  /// What the core sniffs when the entry lists no ports at all.
  ///
  /// An empty port list is not "every port" and not "no port": it is one default port per protocol.
  /// Measured against the bundled v1.19.29 on 2026-08-15 by driving live connections through it —
  /// `sniff: {TLS: {}}` sniffed a connection on 443 and left 8443 and 9443 alone, `sniff: {HTTP: {}}`
  /// sniffed a connection on 80 and left 8080 alone, and adding the odd port back to the entry made
  /// each of them sniff again. QUIC is the core's documented default rather than a measurement here,
  /// because reaching the QUIC sniffer needs a QUIC client.
  var coreFallbackPorts: [String] {
    switch self {
    case .tls, .quic:
      return ["443"]
    case .http:
      return ["80"]
    }
  }

  /// The transport the core reads this protocol on.
  ///
  /// TLS and HTTP are registered on TCP and QUIC on UDP (`SupportNetwork` on each sniffer in the
  /// bundled binary), so a UDP connection is only ever seen by the QUIC entry — which is why a
  /// domainless UDP flow stays domainless no matter how many TCP ports are listed.
  func handles(network: String) -> Bool {
    let normalized = network.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch self {
    case .tls, .http:
      return normalized == "tcp"
    case .quic:
      return normalized == "udp"
    }
  }

  /// Why a user would turn this on, in one line — the editor has to answer "should I?".
  var explanation: String {
    switch self {
    case .tls:
      return String(localized: "Reads the SNI from the TLS handshake. This is where most domains come back.")
    case .http:
      return String(localized: "Reads the Host header from plaintext HTTP requests.")
    case .quic:
      return String(localized: "Reads the SNI from a QUIC initial packet. Off by default: it is the least reliable of the three.")
    }
  }
}

/// One entry of the `sniffer.sniff` map.
struct SnifferProtocolSettings: Codable, Equatable, Sendable, Identifiable {
  var networkProtocol: SnifferProtocol
  /// Port tokens exactly as Mihomo parses them: `"443"` or `"8000-9000"`.
  var ports: [String]
  /// `nil` inherits the block-level `override-destination`.
  var overrideDestination: Bool?

  private enum CodingKeys: String, CodingKey {
    case networkProtocol
    case ports
    case overrideDestination
  }

  init(
    networkProtocol: SnifferProtocol,
    ports: [String]? = nil,
    overrideDestination: Bool? = nil
  ) {
    self.networkProtocol = networkProtocol
    self.ports = SnifferSettings.normalizedList(ports ?? networkProtocol.defaultPorts)
    self.overrideDestination = overrideDestination
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      networkProtocol: container.decodeDefault(SnifferProtocol.self, forKey: .networkProtocol, default: .tls),
      ports: container.decodeDefault([String].self, forKey: .ports, default: []),
      overrideDestination: try? container.decodeIfPresent(Bool.self, forKey: .overrideDestination)
    )
  }

  var id: SnifferProtocol { networkProtocol }

  /// The ports this entry actually sniffs on, with the core's fallback filled in — what a diagnosis
  /// has to reason about, since the written config and the running behaviour differ when the list is
  /// empty (see `SnifferProtocol.coreFallbackPorts`).
  var effectivePorts: [String] { ports.isEmpty ? networkProtocol.coreFallbackPorts : ports }

  /// Whether a connection on `port` is inside this entry's port set.
  func covers(port: Int) -> Bool {
    effectivePorts.contains { token in
      let bounds = token
        .split(separator: "-", omittingEmptySubsequences: false)
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      switch bounds.count {
      case 1:
        return bounds[0] == port
      case 2:
        return (bounds[0]...max(bounds[0], bounds[1])).contains(port)
      default:
        return false
      }
    }
  }

  var summary: String {
    let portSummary = ports.isEmpty
      ? String(
        format: String(localized: "%@ (core default)"),
        effectivePorts.joined(separator: ", ")
      )
      : ports.joined(separator: ", ")
    guard let overrideDestination else {
      return "\(networkProtocol.displayName) \(portSummary)"
    }
    return overrideDestination
      ? String(format: String(localized: "%@ %@ (override on)"), networkProtocol.displayName, portSummary)
      : String(format: String(localized: "%@ %@ (override off)"), networkProtocol.displayName, portSummary)
  }

  /// An empty port list is deliberately *not* an error: the core falls back to its own default port
  /// for the protocol, which is a legitimate — and the most common — way for a subscription to write
  /// the entry. A port the core parses and can never match is the trap this catches instead.
  var validationError: String? {
    if let invalid = ports.first(where: { !SnifferSettings.isValidPortToken($0) }) {
      return String(
        format: String(localized: "Invalid %@ sniffer port: %@. Use a port from 1 to 65535, or a low-high range."),
        networkProtocol.displayName,
        invalid
      )
    }
    return nil
  }
}

/// The `sniffer` block, as a value ClashMax owns rather than a string the profile happens to carry.
///
/// Modeled on `TunDNSSettings`: optional scalars mean "leave whatever is underneath alone", lists
/// merge into what is already there, and `validationError` refuses configurations the core would
/// accept and then quietly ignore. The core's own validation is thinner than it looks — measured on
/// 2026-08-15 against v1.19.29, `sniff: {}`, a missing `sniff` key, `ports: ["9000-100"]` and
/// `ports: ["70000"]` all pass `mihomo -t` while sniffing nothing useful, so those are rejected here.
struct SnifferSettings: Codable, Equatable, Sendable {
  var enabled: Bool?
  var overrideDestination: Bool?
  var forceDNSMapping: Bool?
  var parsePureIP: Bool?
  /// The `sniff` map. Non-empty means "this is the whole map": a snippet listing TLS replaces the
  /// protocol map underneath it rather than merging port lists, so what the editor shows is what
  /// the core gets. Empty leaves the underlying map untouched.
  var protocols: [SnifferProtocolSettings]
  var forceDomain: [String]
  var skipDomain: [String]
  var skipSourceAddress: [String]
  var skipDestinationAddress: [String]

  private enum CodingKeys: String, CodingKey {
    case enabled
    case overrideDestination
    case forceDNSMapping
    case parsePureIP
    case protocols
    case forceDomain
    case skipDomain
    case skipSourceAddress
    case skipDestinationAddress
  }

  init(
    enabled: Bool? = nil,
    overrideDestination: Bool? = nil,
    forceDNSMapping: Bool? = nil,
    parsePureIP: Bool? = nil,
    protocols: [SnifferProtocolSettings] = [],
    forceDomain: [String] = [],
    skipDomain: [String] = [],
    skipSourceAddress: [String] = [],
    skipDestinationAddress: [String] = []
  ) {
    self.enabled = enabled
    self.overrideDestination = overrideDestination
    self.forceDNSMapping = forceDNSMapping
    self.parsePureIP = parsePureIP
    self.protocols = Self.normalizedProtocols(protocols)
    self.forceDomain = Self.normalizedList(forceDomain)
    self.skipDomain = Self.normalizedList(skipDomain)
    self.skipSourceAddress = Self.normalizedList(skipSourceAddress)
    self.skipDestinationAddress = Self.normalizedList(skipDestinationAddress)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try? container.decodeIfPresent(Bool.self, forKey: .enabled),
      overrideDestination: try? container.decodeIfPresent(Bool.self, forKey: .overrideDestination),
      forceDNSMapping: try? container.decodeIfPresent(Bool.self, forKey: .forceDNSMapping),
      parsePureIP: try? container.decodeIfPresent(Bool.self, forKey: .parsePureIP),
      protocols: container.decodeDefault([SnifferProtocolSettings].self, forKey: .protocols, default: []),
      forceDomain: container.decodeDefault([String].self, forKey: .forceDomain, default: []),
      skipDomain: container.decodeDefault([String].self, forKey: .skipDomain, default: []),
      skipSourceAddress: container.decodeDefault([String].self, forKey: .skipSourceAddress, default: []),
      skipDestinationAddress: container.decodeDefault([String].self, forKey: .skipDestinationAddress, default: [])
    )
  }

  /// What ClashMax generates when the profile says nothing about sniffing at all.
  ///
  /// On by default because the alternative is the failure this whole item exists for: a connection
  /// opened straight to an IP carries no domain, so every `DOMAIN-SUFFIX` rule written for it is
  /// structurally unreachable and the user reads that as "my rules do not work" (roadmap A1).
  /// QUIC stays off — it is the least reliable of the three and has not been measured here.
  static let appManagedDefault = SnifferSettings(
    enabled: true,
    overrideDestination: true,
    protocols: [
      SnifferProtocolSettings(networkProtocol: .tls),
      SnifferProtocolSettings(networkProtocol: .http),
    ],
    // The two entries every Mihomo deployment ends up adding: Xiaomi's cloud speaks a protocol the
    // TLS sniffer mis-reads, and Apple's push connection breaks when its destination is rewritten.
    skipDomain: ["Mijia Cloud", "+.push.apple.com"]
  )

  /// Turns sniffing off without deleting the user's protocol list — the escape hatch of INV-2.
  static let off = SnifferSettings(enabled: false)

  static let empty = SnifferSettings()

  /// Whether the core would sniff at all. `nil` is the core's own default, which is off.
  var isSniffingEnabled: Bool { enabled ?? false }

  /// Whether a sniffed name replaces the destination the connection was opened to.
  ///
  /// The core's default is on: measured against the bundled v1.19.29 on 2026-08-15, a `sniffer`
  /// block with no `override-destination` key reported `host = speed.cloudflare.com` with an empty
  /// `destinationIP`, exactly like an explicit `true`, while `false` left the IP in place.
  var isDestinationOverridden: Bool { overrideDestination ?? true }

  /// The sniff entries that would look at a connection on this transport and port — the question
  /// "could a name have been recovered here?" reduces to whether this is empty.
  func coveringProtocols(network: String, port: Int?) -> [SnifferProtocolSettings] {
    protocols.filter { entry in
      guard entry.networkProtocol.handles(network: network) else { return false }
      guard let port else { return true }
      return entry.covers(port: port)
    }
  }

  var hasRuntimeOverlay: Bool {
    enabled != nil
      || overrideDestination != nil
      || forceDNSMapping != nil
      || parsePureIP != nil
      || !protocols.isEmpty
      || !forceDomain.isEmpty
      || !skipDomain.isEmpty
      || !skipSourceAddress.isEmpty
      || !skipDestinationAddress.isEmpty
  }

  var summary: String {
    guard hasRuntimeOverlay else {
      return String(localized: "No sniffer changes")
    }
    if enabled == false {
      return String(localized: "Sniffing off")
    }
    var parts: [String] = []
    if !protocols.isEmpty {
      parts.append(protocols.map(\.networkProtocol.displayName).joined(separator: "+"))
    }
    if enabled == true, parts.isEmpty {
      parts.append(String(localized: "Sniffing on"))
    }
    if overrideDestination == true {
      parts.append(String(localized: "override on"))
    } else if overrideDestination == false {
      parts.append(String(localized: "override off"))
    }
    let listCount = forceDomain.count + skipDomain.count + skipSourceAddress.count + skipDestinationAddress.count
    if listCount > 0 {
      parts.append(String(format: String(localized: "%lld exceptions"), Int64(listCount)))
    }
    return parts.joined(separator: ", ")
  }

  /// Field-level validity. Safe to run against a patch, which is allowed to be sparse — a snippet
  /// that only turns sniffing on inherits the protocol map from the layer underneath it.
  var validationError: String? {
    var seen = Set<SnifferProtocol>()
    for entry in protocols {
      guard seen.insert(entry.networkProtocol).inserted else {
        return String(
          format: String(localized: "%@ is listed twice in the sniff map."),
          entry.networkProtocol.displayName
        )
      }
      if let entryError = entry.validationError {
        return entryError
      }
    }
    for (title, values) in [
      ("skip-src-address", skipSourceAddress),
      ("skip-dst-address", skipDestinationAddress),
    ] {
      if let invalid = values.first(where: { !Self.isValidAddressToken($0) }) {
        return String(
          format: String(localized: "Invalid sniffer %@ entry: %@. Use an IP or CIDR."),
          title,
          invalid
        )
      }
    }
    return nil
  }

  /// Validity of a *merged* value that is about to be written into the runtime config. Sniffing
  /// turned on with an empty sniff map is the trap this adds: `mihomo -t` accepts it and then sniffs
  /// nothing, so the config looks applied while the domain never comes back (measured 2026-08-15).
  var effectiveValidationError: String? {
    if enabled == true, protocols.isEmpty {
      return String(localized: "Sniffing is on but no protocol is listed, so nothing would be sniffed. Add TLS, HTTP, or QUIC.")
    }
    return validationError
  }

  /// Folds a patch on top of this value. Scalars override when set, domain and address lists merge,
  /// and a non-empty protocol list replaces the map wholesale (see `protocols`).
  func patched(with patch: SnifferSettings) -> SnifferSettings {
    SnifferSettings(
      enabled: patch.enabled ?? enabled,
      overrideDestination: patch.overrideDestination ?? overrideDestination,
      forceDNSMapping: patch.forceDNSMapping ?? forceDNSMapping,
      parsePureIP: patch.parsePureIP ?? parsePureIP,
      protocols: patch.protocols.isEmpty ? protocols : patch.protocols,
      forceDomain: forceDomain + patch.forceDomain,
      skipDomain: skipDomain + patch.skipDomain,
      skipSourceAddress: skipSourceAddress + patch.skipSourceAddress,
      skipDestinationAddress: skipDestinationAddress + patch.skipDestinationAddress
    )
  }

  static func combined(_ patches: [SnifferSettings]) -> SnifferSettings {
    patches.reduce(SnifferSettings.empty) { $0.patched(with: $1) }
  }

  func settings(for networkProtocol: SnifferProtocol) -> SnifferProtocolSettings? {
    protocols.first { $0.networkProtocol == networkProtocol }
  }

  static func normalizedList(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return seen.insert(trimmed.lowercased()).inserted ? trimmed : nil
    }
  }

  private static func normalizedProtocols(_ entries: [SnifferProtocolSettings]) -> [SnifferProtocolSettings] {
    var seen = Set<SnifferProtocol>()
    return entries.filter { seen.insert($0.networkProtocol).inserted }
  }

  /// `"443"` or `"8000-9000"`. The core accepts `"70000"` and `"9000-100"` and then sniffs nothing
  /// on them, so both are rejected here instead.
  static func isValidPortToken(_ value: String) -> Bool {
    let parts = value
      .split(separator: "-", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 1 || parts.count == 2 else { return false }
    guard let first = Int(parts[0]), (1...65_535).contains(first) else { return false }
    guard parts.count == 2 else { return true }
    guard let last = Int(parts[1]), (1...65_535).contains(last) else { return false }
    return first <= last
  }

  /// `skip-domain` and `force-domain` are deliberately unvalidated: Mihomo matches them against the
  /// sniffed name, and the canonical entry `Mijia Cloud` is not a domain at all.
  private static func isValidAddressToken(_ value: String) -> Bool {
    NetworkExtensionRoutingSettings.isValidCIDR(value)
  }
}

extension SnifferSettings {
  /// The YAML key names this value would write, for a layer view that names what changed instead of
  /// dumping the block twice.
  var changedKeyNames: [String] {
    var names: [String] = []
    if enabled != nil { names.append("enable") }
    if overrideDestination != nil { names.append("override-destination") }
    if forceDNSMapping != nil { names.append("force-dns-mapping") }
    if parsePureIP != nil { names.append("parse-pure-ip") }
    if !protocols.isEmpty { names.append("sniff") }
    if !forceDomain.isEmpty { names.append("force-domain") }
    if !skipDomain.isEmpty { names.append("skip-domain") }
    if !skipSourceAddress.isEmpty { names.append("skip-src-address") }
    if !skipDestinationAddress.isEmpty { names.append("skip-dst-address") }
    return names
  }

  /// Reads a `sniffer` mapping out of a profile or a generated runtime config.
  ///
  /// `GET /configs` reports only `sniffing: true|false`, so the generated YAML is the single source
  /// of truth for *what* is being sniffed (roadmap A1.0). This is how a typed view of it is taken —
  /// deliberately tolerant, because the mapping comes from a subscription ClashMax does not control.
  init(runtimeMapping mapping: [String: Any]) {
    var protocols: [SnifferProtocolSettings] = []
    if let sniff = mapping["sniff"] as? [String: Any] {
      for networkProtocol in SnifferProtocol.allCases {
        guard let entry = Self.protocolEntry(for: networkProtocol, in: sniff) else { continue }
        protocols.append(
          SnifferProtocolSettings(
            networkProtocol: networkProtocol,
            ports: Self.portTokens(entry["ports"]),
            overrideDestination: entry["override-destination"] as? Bool
          )
        )
      }
    }
    self.init(
      enabled: mapping["enable"] as? Bool,
      overrideDestination: mapping["override-destination"] as? Bool,
      forceDNSMapping: mapping["force-dns-mapping"] as? Bool,
      parsePureIP: mapping["parse-pure-ip"] as? Bool,
      protocols: protocols,
      forceDomain: Self.stringList(mapping["force-domain"]),
      skipDomain: Self.stringList(mapping["skip-domain"]),
      skipSourceAddress: Self.stringList(mapping["skip-src-address"]),
      skipDestinationAddress: Self.stringList(mapping["skip-dst-address"])
    )
  }

  /// Writes this value onto `base`, leaving every key it does not set — including keys ClashMax does
  /// not model — exactly as it found them.
  func runtimeMapping(applyingTo base: [String: Any]) -> [String: Any] {
    var mapping = base
    if let enabled {
      mapping["enable"] = enabled
    }
    if let overrideDestination {
      mapping["override-destination"] = overrideDestination
    }
    if let forceDNSMapping {
      mapping["force-dns-mapping"] = forceDNSMapping
    }
    if let parsePureIP {
      mapping["parse-pure-ip"] = parsePureIP
    }
    if !protocols.isEmpty {
      var sniff: [String: Any] = [:]
      for entry in protocols {
        // An empty list is written as an absent key, not as `ports: []`: that is the shape the
        // core's own fallback was measured against, and it reads as "the core decides".
        var protocolMapping: [String: Any] = entry.ports.isEmpty ? [:] : ["ports": entry.ports]
        if let overrideDestination = entry.overrideDestination {
          protocolMapping["override-destination"] = overrideDestination
        }
        sniff[entry.networkProtocol.rawValue] = protocolMapping
      }
      mapping["sniff"] = sniff
    }
    for (key, values) in [
      ("force-domain", forceDomain),
      ("skip-domain", skipDomain),
      ("skip-src-address", skipSourceAddress),
      ("skip-dst-address", skipDestinationAddress),
    ] where !values.isEmpty {
      mapping[key] = Self.normalizedList(Self.stringList(base[key]) + values)
    }
    return mapping
  }

  private static func protocolEntry(for networkProtocol: SnifferProtocol, in sniff: [String: Any]) -> [String: Any]? {
    // Mihomo matches the sniffer name case-insensitively in practice; profiles in the wild write
    // both `TLS` and `tls`.
    guard let key = sniff.keys.first(where: { $0.caseInsensitiveCompare(networkProtocol.rawValue) == .orderedSame })
    else { return nil }
    return sniff[key] as? [String: Any] ?? [:]
  }

  private static func portTokens(_ value: Any?) -> [String] {
    switch value {
    case let value as String:
      return [value]
    case let value as Int:
      return [String(value)]
    case let values as [Any]:
      return values.compactMap { element in
        switch element {
        case let element as String:
          return element
        case let element as Int:
          return String(element)
        case let element as NSNumber:
          return element.stringValue
        default:
          return nil
        }
      }
    default:
      return []
    }
  }

  private static func stringList(_ value: Any?) -> [String] {
    switch value {
    case let value as String:
      return [value]
    case let values as [Any]:
      return values.compactMap { $0 as? String }
    default:
      return []
    }
  }
}

/// Where the `sniffer` block in the generated runtime config came from.
///
/// A subscription can change which rules match by shipping `skip-domain`, `force-domain`, or
/// `override-destination: false`. ClashMax neither ignores that block nor silently replaces it: the
/// profile's own sniffer is kept as authored unless the user wrote a sniffer snippet, and either way
/// the decision is named here so the Routing layer can show it (roadmap A1b, A1d).
enum SnifferPlanSource: String, Codable, Equatable, Sendable {
  /// The profile said nothing about sniffing, so ClashMax generated its managed default.
  case appManaged
  /// ClashMax's managed default with the user's sniffer snippets folded in.
  case appManagedPatched
  /// The profile ships its own `sniffer` block and no snippet touches it — kept verbatim.
  case profileKept
  /// The profile ships its own `sniffer` block and the user's snippets patch it.
  case profilePatched

  var displayName: String {
    switch self {
    case .appManaged:
      return String(localized: "App-managed sniffer")
    case .appManagedPatched:
      return String(localized: "App-managed sniffer, patched by snippets")
    case .profileKept:
      return String(localized: "Profile sniffer kept")
    case .profilePatched:
      return String(localized: "Profile sniffer patched by snippets")
    }
  }

  var explanation: String {
    switch self {
    case .appManaged:
      return String(localized: "The profile does not configure sniffing, so ClashMax recovers domains from TLS and HTTP traffic itself.")
    case .appManagedPatched:
      return String(localized: "ClashMax's sniffer settings with your snippet changes applied on top.")
    case .profileKept:
      return String(localized: "This profile configures sniffing itself. ClashMax left it exactly as authored — add a sniffer snippet to change it.")
    case .profilePatched:
      return String(localized: "This profile configures sniffing itself, and your sniffer snippets change it.")
    }
  }

  var isProfileSupplied: Bool {
    self == .profileKept || self == .profilePatched
  }

  init(profileDeclaresSniffer: Bool, patchedBySnippets: Bool) {
    switch (profileDeclaresSniffer, patchedBySnippets) {
    case (true, true):
      self = .profilePatched
    case (true, false):
      self = .profileKept
    case (false, true):
      self = .appManagedPatched
    case (false, false):
      self = .appManaged
    }
  }
}

/// The resolved sniffer for one generated config: what will run, and why it looks that way.
struct SnifferPlan: Equatable, Sendable {
  var source: SnifferPlanSource
  /// The effective block, as a typed value. `SnifferDiagnostics` classifies against this rather
  /// than against `/configs`, which reports only a single `sniffing` boolean (roadmap A1.0).
  var settings: SnifferSettings
  /// The keys the user's snippets changed, in YAML spelling.
  var patchedKeyNames: [String]

  var isSniffing: Bool { settings.enabled == true }

  var summary: String {
    guard isSniffing else {
      return String(localized: "Sniffing off")
    }
    return settings.summary
  }

  /// The plan as read back out of a generated runtime config. `settings` is what Mihomo will
  /// actually load rather than what the app intended, the same way the DNS layer reports the merged
  /// result instead of the app's intent.
  static func observed(
    finalSettings: SnifferSettings?,
    profileDeclaresSniffer: Bool,
    patch: SnifferSettings
  ) -> SnifferPlan {
    SnifferPlan(
      source: SnifferPlanSource(
        profileDeclaresSniffer: profileDeclaresSniffer,
        patchedBySnippets: patch.hasRuntimeOverlay
      ),
      settings: finalSettings ?? .empty,
      patchedKeyNames: patch.changedKeyNames
    )
  }

  var plainTextLines: [String] {
    var lines = ["Sniffer: \(source.displayName)", "Effect: \(summary)"]
    if !patchedKeyNames.isEmpty {
      lines.append("Snippet Keys: \(patchedKeyNames.joined(separator: ", "))")
    }
    if isSniffing {
      let protocols = settings.protocols.map(\.summary)
      if !protocols.isEmpty {
        lines.append(contentsOf: protocols.map { "- \($0)" })
      }
    }
    return lines
  }
}

enum SnifferPlanBuilder {
  /// - Parameters:
  ///   - profileMapping: the profile's own `sniffer` block, after any runtime-merge YAML.
  ///   - patch: the fold of the user's enabled sniffer snippets, in Routing order.
  static func plan(profileMapping: [String: Any]?, patch: SnifferSettings) -> SnifferPlan {
    let profileSettings = profileMapping.map(SnifferSettings.init(runtimeMapping:))
    let hasProfileSniffer = profileSettings?.hasRuntimeOverlay == true
    let base = hasProfileSniffer ? (profileSettings ?? .empty) : .appManagedDefault
    return SnifferPlan(
      source: SnifferPlanSource(
        profileDeclaresSniffer: hasProfileSniffer,
        patchedBySnippets: patch.hasRuntimeOverlay
      ),
      settings: base.patched(with: patch),
      patchedKeyNames: patch.changedKeyNames
    )
  }

  /// The mapping to write into the runtime YAML. The profile's own block is never regenerated from
  /// the typed view — it is patched in place, so keys ClashMax does not model survive untouched.
  static func runtimeMapping(profileMapping: [String: Any]?, patch: SnifferSettings) -> [String: Any] {
    let profileMapping = profileMapping ?? [:]
    let hasProfileSniffer = SnifferSettings(runtimeMapping: profileMapping).hasRuntimeOverlay
    guard hasProfileSniffer else {
      return SnifferSettings.appManagedDefault.patched(with: patch).runtimeMapping(applyingTo: profileMapping)
    }
    return patch.runtimeMapping(applyingTo: profileMapping)
  }
}
