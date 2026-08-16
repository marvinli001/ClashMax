import Foundation

/// Pure, view-agnostic answer to "can my domain rules see this connection, and if not, why not?".
///
/// This is the second half of roadmap A1. `ConnectionDomainOrigin` (A1a) records whether a domain
/// ever reached the core; `SnifferSettings` (A1b) records what the running config sniffs. Neither is
/// an answer on its own: the user's question is "I wrote `DOMAIN-SUFFIX,example.com,Proxy` and it
/// does not fire", and answering it means saying which of the several possible reasons applies —
/// sniffing is off, the port is not covered, the address is on a skip list, or the traffic genuinely
/// carries no name and needs an IP rule instead.
///
/// Deliberately a value-in/value-out builder like `ProxyEffectDiagnosticsBuilder`: every branch is
/// reachable from a test without a running core.
struct SnifferDiagnosticsSnapshot: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    /// A domain is in play, so domain rules can match.
    case pass
    /// Worth knowing, but nothing is broken.
    case info
    /// This connection cannot be matched by any domain rule.
    case warn
  }

  /// Stable, locale-independent classification so views can pick icons and tests can assert the
  /// branch without depending on localized copy.
  enum Cause: String, Equatable, Sendable {
    case domainReported
    case domainRecoveredBySniffing
    case sniffedWithoutDestinationOverride
    case snifferConfigurationUnknown
    case domainlessSnifferChangedAfterStart
    case domainlessSnifferDisabled
    case domainlessProtocolNotCovered
    case domainlessSkippedByAddress
    case domainlessNotSniffable
  }

  struct Fact: Equatable, Sendable {
    /// Stable identity so a surface can drop a fact it already shows elsewhere, and so tests can
    /// assert on the fact without depending on localized copy.
    enum Key: String, Hashable, Sendable {
      case domain
      case destination
      case sniffing
      case matchOnDomain
      case matchWithoutDomain
    }

    var key: Key
    var title: String
    var value: String
  }

  var status: Status
  var cause: Cause
  var headline: String
  var reason: String
  var facts: [Fact]
  var recoveryActions: [String]
  /// The one-click repair, when there is one that ClashMax can make on the user's behalf.
  var fix: SnifferDiagnosticsFix?

  /// Whether any domain rule could have matched this connection at all.
  var canDomainRulesMatch: Bool {
    switch cause {
    case .domainReported, .domainRecoveredBySniffing, .sniffedWithoutDestinationOverride:
      return true
    case .snifferConfigurationUnknown, .domainlessSnifferChangedAfterStart,
         .domainlessSnifferDisabled, .domainlessProtocolNotCovered, .domainlessSkippedByAddress,
         .domainlessNotSniffable:
      return false
    }
  }

  /// Stable English label used inside the copyable diagnostics report.
  var statusLabel: String {
    switch status {
    case .pass: return "Pass"
    case .info: return "Info"
    case .warn: return "Warn"
    }
  }

  /// Kept in stable English to match the rest of the copyable reports. The reason already names the
  /// destination, port and domain, so the facts are not repeated here.
  var plainTextLines: [String] {
    var lines = [
      "Sniffer: \(statusLabel) (\(cause.rawValue))",
      "Reason: \(reason)",
    ]
    if !recoveryActions.isEmpty {
      lines.append("Recovery Actions:")
      lines.append(contentsOf: recoveryActions.map { "- \($0)" })
    }
    return lines
  }
}

/// A repair the Connections panel can apply without sending the user to Routing to reconstruct it.
///
/// `patch` goes through the ordinary sniffer-snippet path — preflight, hot reload, rollback — so a
/// fix applied from here is the same change the Routing editor would have made by hand (INV-1).
struct SnifferDiagnosticsFix: Equatable, Sendable {
  var title: String
  var patch: SnifferSettings
}

struct SnifferDiagnosticsInput: Equatable, Sendable {
  var domainOrigin: ConnectionDomainOrigin
  var domain: String?
  var destinationIP: String?
  var destinationPort: Int?
  var sourceIP: String?
  /// `metadata.network`, which decides which sniffer could even see the connection: TLS and HTTP
  /// read TCP, QUIC reads UDP.
  var network: String
  /// The sniffer block of the config the core is running. `nil` means ClashMax has not read it,
  /// which is reported as such instead of being guessed at.
  var sniffer: SnifferSettings?
  /// When this connection was opened, and when the sniffer configuration last changed. Settings
  /// newer than the connection never governed it, and judging it by them would turn every applied
  /// fix into a fresh false verdict on the row the user just fixed.
  var startedAt: Date?
  var snifferChangedAt: Date?
  var rules: [RuntimeRule]

  init(
    domainOrigin: ConnectionDomainOrigin = .none,
    domain: String? = nil,
    destinationIP: String? = nil,
    destinationPort: Int? = nil,
    sourceIP: String? = nil,
    network: String = "tcp",
    sniffer: SnifferSettings? = nil,
    startedAt: Date? = nil,
    snifferChangedAt: Date? = nil,
    rules: [RuntimeRule] = []
  ) {
    self.domainOrigin = domainOrigin
    self.domain = domain
    self.destinationIP = destinationIP
    self.destinationPort = destinationPort
    self.sourceIP = sourceIP
    self.network = network
    self.sniffer = sniffer
    self.startedAt = startedAt
    self.snifferChangedAt = snifferChangedAt
    self.rules = rules
  }

  init(
    connection: ConnectionSnapshot,
    sniffer: SnifferSettings?,
    snifferChangedAt: Date? = nil,
    rules: [RuntimeRule] = []
  ) {
    self.init(
      domainOrigin: connection.domainOrigin,
      domain: connection.domain,
      destinationIP: connection.destinationIPAddress,
      destinationPort: connection.destinationPort,
      sourceIP: connection.sourceIP,
      network: connection.network,
      sniffer: sniffer,
      startedAt: connection.startedAt,
      snifferChangedAt: snifferChangedAt,
      rules: rules
    )
  }
}

enum SnifferDiagnosticsBuilder {
  static func build(_ input: SnifferDiagnosticsInput) -> SnifferDiagnosticsSnapshot {
    let destination = input.destinationIP ?? String(localized: "an IP address")
    let facts = facts(for: input)

    func make(
      status: SnifferDiagnosticsSnapshot.Status,
      cause: SnifferDiagnosticsSnapshot.Cause,
      headline: String,
      reason: String,
      recovery: [String] = [],
      fix: SnifferDiagnosticsFix? = nil
    ) -> SnifferDiagnosticsSnapshot {
      SnifferDiagnosticsSnapshot(
        status: status,
        cause: cause,
        headline: headline,
        reason: reason,
        facts: facts,
        recoveryActions: recovery,
        fix: fix
      )
    }

    // 1. A name reached the core on its own. Nothing about sniffing matters here.
    if input.domainOrigin == .reported {
      return make(
        status: .pass,
        cause: .domainReported,
        headline: String(localized: "The app named the destination"),
        reason: String(
          format: String(localized: "This connection arrived with %@, so domain rules can match it."),
          input.domain ?? String(localized: "a domain")
        )
      )
    }

    // 2. The sniffer recovered the name. Whether it also rewrote the destination changes what the
    //    rest of the app shows, but not whether domain rules match — measured on 2026-08-15, a
    //    connection sniffed with `override-destination: false` still matched `DOMAIN-SUFFIX`.
    if input.domainOrigin == .sniffed {
      let domain = input.domain ?? String(localized: "a domain")
      if input.sniffer?.isDestinationOverridden == false {
        return make(
          status: .info,
          cause: .sniffedWithoutDestinationOverride,
          headline: String(localized: "Sniffed, destination left as the IP"),
          reason: String(
            format: String(localized: "Sniffing read %@ out of the traffic and domain rules match that name, but Rewrite Target is off, so the connection still dials the original IP."),
            domain
          ),
          recovery: [String(localized: "Turn on Rewrite Target if the connection should also be sent to the sniffed name.")]
        )
      }
      return make(
        status: .pass,
        cause: .domainRecoveredBySniffing,
        headline: String(localized: "Sniffing recovered the domain"),
        reason: String(
          format: String(localized: "This connection was opened to an IP with no domain. Sniffing read %@ out of the traffic, so domain rules can match it."),
          domain
        )
      )
    }

    // 3. No domain, and no idea what the core was told to sniff. Saying "sniffing is off" here would
    //    be a guess, and a wrong one every time the config was written outside this session.
    guard let sniffer = input.sniffer else {
      return make(
        status: .info,
        cause: .snifferConfigurationUnknown,
        headline: String(localized: "No domain, sniffer settings unknown"),
        reason: String(
          format: String(localized: "This connection was opened straight to %@ with no domain. ClashMax has not read the running sniffer configuration, so it cannot say whether a name could have been recovered."),
          destination
        ),
        recovery: [String(localized: "Start the core, or open Routing to load the effective configuration.")]
      )
    }

    // 4. The settings are newer than the connection, so they never governed it. Without this the
    //    fix applied from this very panel would re-judge the row it just fixed and claim the
    //    traffic carries no name — a false verdict manufactured by the repair.
    if let changedAt = input.snifferChangedAt, let startedAt = input.startedAt, startedAt < changedAt {
      return make(
        status: .info,
        cause: .domainlessSnifferChangedAfterStart,
        headline: String(localized: "No domain, opened before the current settings"),
        reason: String(
          format: String(localized: "This connection was opened straight to %@ with no domain, before the current sniffer settings took effect, so they say nothing about it."),
          destination
        ),
        recovery: [String(localized: "Open the same destination again to see the current settings applied.")]
      )
    }

    // 5. Sniffing off: the plainest answer, and the one behind most "my rules do not work" reports.
    guard sniffer.isSniffingEnabled else {
      return make(
        status: .warn,
        cause: .domainlessSnifferDisabled,
        headline: String(localized: "No domain, sniffing is off"),
        reason: String(
          format: String(localized: "This connection was opened straight to %@ with no domain, so DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD and GEOSITE rules cannot match it. Sniffing is off, so no name is recovered."),
          destination
        ),
        recovery: [String(localized: "Turn sniffing on so TLS and HTTP traffic gives its domain back.")],
        fix: SnifferDiagnosticsFix(
          title: String(localized: "Turn On Sniffing"),
          patch: SnifferSettings(
            enabled: true,
            overrideDestination: true,
            protocols: sniffer.protocols.isEmpty ? SnifferSettings.appManagedDefault.protocols : []
          )
        )
      )
    }

    // 6. Sniffing is on and was told to leave this address alone.
    if let skip = skipEntry(matching: input, sniffer: sniffer) {
      return make(
        status: .warn,
        cause: .domainlessSkippedByAddress,
        headline: String(localized: "No domain, this address is skipped"),
        reason: String(
          format: String(localized: "This connection was opened straight to %@ with no domain, and %@ matches the sniffer's %@ list, so it was deliberately left alone."),
          destination,
          skip.value,
          skip.keyName
        ),
        recovery: [
          String(
            format: String(localized: "Remove %@ from %@ if this traffic should be sniffed."),
            skip.value,
            skip.keyName
          ),
        ]
      )
    }

    // 7. Sniffing is on but nothing is watching this transport and port. The port list is a real
    //    gate, measured on 2026-08-15: a TLS entry listing only 443 ignored the same handshake on
    //    9443, and an entry with no ports at all fell back to the core's single default port.
    if sniffer.coveringProtocols(network: input.network, port: input.destinationPort).isEmpty {
      let target = fixProtocol(for: input)
      let portToken = input.destinationPort.map(String.init)
      return make(
        status: .warn,
        cause: .domainlessProtocolNotCovered,
        headline: String(localized: "No domain, this port is not sniffed"),
        reason: String(
          format: String(localized: "This connection was opened straight to %@ with no domain. Sniffing is on, but no sniff entry covers %@ %@, so nothing looked at it."),
          destination,
          input.network.uppercased(),
          portToken.map { String(format: String(localized: "port %@"), $0) } ?? String(localized: "this port")
        ),
        recovery: [
          String(
            format: String(localized: "Add %@ to %@ sniffing."),
            portToken.map { String(format: String(localized: "port %@"), $0) } ?? String(localized: "this port"),
            target.displayName
          ),
        ],
        fix: portToken.map { token in
          SnifferDiagnosticsFix(
            title: String(format: String(localized: "Sniff %@ Port %@"), target.displayName, token),
            patch: SnifferSettings(protocols: protocols(in: sniffer, adding: token, to: target))
          )
        }
      )
    }

    // 8. Everything is pointed at this connection and no name came back. That is an answer too: the
    //    traffic carries none, so only address, port and process rules can ever match it.
    return make(
      status: .warn,
      cause: .domainlessNotSniffable,
      headline: String(localized: "No domain in this traffic"),
      reason: String(
        format: String(localized: "This connection was opened straight to %@ with no domain. Sniffing covers it and still recovered no name, so the traffic carries none — match it with IP-CIDR, GEOIP, DST-PORT or process rules instead."),
        destination
      ),
      recovery: [String(localized: "Write an address, port, or process rule for this destination instead of a domain rule.")]
    )
  }

  // MARK: - Facts

  private static func facts(for input: SnifferDiagnosticsInput) -> [SnifferDiagnosticsSnapshot.Fact] {
    var facts: [SnifferDiagnosticsSnapshot.Fact] = [
      .init(key: .domain, title: String(localized: "Domain"), value: input.domain ?? String(localized: "None")),
      .init(
        key: .destination,
        title: String(localized: "Destination"),
        value: endpointLabel(ip: input.destinationIP, port: input.destinationPort, network: input.network)
      ),
      .init(key: .sniffing, title: String(localized: "Sniffing"), value: snifferSummary(input.sniffer)),
    ]
    let simulator = RuleMatchSimulator()
    let candidates = RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: input.rules)
    guard !candidates.isEmpty else { return facts }
    if let domain = input.domain {
      let trace = simulator.simulate(
        input: RuleMatchSimulationInput(
          destination: domain,
          sourceIP: input.sourceIP ?? "",
          destinationPort: input.destinationPort.map(String.init) ?? ""
        ),
        candidates: candidates
      )
      facts.append(.init(key: .matchOnDomain, title: String(localized: "Match On Domain"), value: trace.outcome.detail))
    }
    if let ip = input.destinationIP {
      let trace = simulator.simulate(
        input: RuleMatchSimulationInput(
          destination: ip,
          sourceIP: input.sourceIP ?? "",
          destinationPort: input.destinationPort.map(String.init) ?? ""
        ),
        candidates: candidates
      )
      // Named "without the domain" rather than "on IP": for a sniffed connection this is exactly the
      // rule that would have won if the name had never come back, which is the comparison the user
      // is actually making.
      facts.append(
        .init(key: .matchWithoutDomain, title: String(localized: "Match Without Domain"), value: trace.outcome.detail)
      )
    }
    return facts
  }

  private static func endpointLabel(ip: String?, port: Int?, network: String) -> String {
    let address = ip ?? "-"
    let transport = network.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let port else {
      return transport.isEmpty ? address : "\(address) (\(transport))"
    }
    let endpoint = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    return transport.isEmpty ? endpoint : "\(endpoint) (\(transport))"
  }

  private static func snifferSummary(_ sniffer: SnifferSettings?) -> String {
    guard let sniffer else { return String(localized: "Unknown") }
    guard sniffer.isSniffingEnabled else { return String(localized: "Sniffing off") }
    let protocols = sniffer.protocols.map(\.summary)
    return protocols.isEmpty ? String(localized: "Sniffing on") : protocols.joined(separator: ", ")
  }

  // MARK: - Skip lists

  private struct SkipMatch {
    var keyName: String
    var value: String
  }

  /// Reuses the rule simulator rather than reimplementing CIDR containment: a `skip-dst-address`
  /// entry is a CIDR and so is an `IP-CIDR` rule, and that matcher is already the tested one.
  private static func skipEntry(
    matching input: SnifferDiagnosticsInput,
    sniffer: SnifferSettings
  ) -> SkipMatch? {
    if let ip = input.destinationIP,
       let entry = firstCIDR(in: sniffer.skipDestinationAddress, containing: ip, type: "IP-CIDR")
    {
      return SkipMatch(keyName: "skip-dst-address", value: entry)
    }
    if let sourceIP = input.sourceIP,
       let entry = firstCIDR(in: sniffer.skipSourceAddress, containing: sourceIP, type: "SRC-IP-CIDR")
    {
      return SkipMatch(keyName: "skip-src-address", value: entry)
    }
    return nil
  }

  private static func firstCIDR(in entries: [String], containing address: String, type: String) -> String? {
    let simulator = RuleMatchSimulator()
    return entries.first { entry in
      let rule = RuntimeRule(index: 0, type: type, payload: entry, policy: "SKIP")
      let input = type == "SRC-IP-CIDR"
        ? RuleMatchSimulationInput(sourceIP: address)
        : RuleMatchSimulationInput(destination: address)
      if case .matched = simulator.simulate(input: input, candidates: [.init(rule: rule, source: .runtimeProfile)]).outcome {
        return true
      }
      return false
    }
  }

  // MARK: - Fixes

  /// Which sniffer would have to look at this connection. UDP is QUIC's alone, and on TCP the SNI is
  /// the realistic recovery for everything except plain HTTP's own port.
  private static func fixProtocol(for input: SnifferDiagnosticsInput) -> SnifferProtocol {
    if SnifferProtocol.quic.handles(network: input.network) { return .quic }
    return input.destinationPort == 80 ? .http : .tls
  }

  /// The whole protocol list with `port` added to `target` — a sniffer patch replaces the sniff map
  /// wholesale, so a patch carrying only the changed entry would delete the others.
  private static func protocols(
    in sniffer: SnifferSettings,
    adding port: String,
    to target: SnifferProtocol
  ) -> [SnifferProtocolSettings] {
    var protocols = sniffer.protocols
    guard let index = protocols.firstIndex(where: { $0.networkProtocol == target }) else {
      protocols.append(
        SnifferProtocolSettings(networkProtocol: target, ports: target.defaultPorts + [port])
      )
      return protocols
    }
    // An entry with no ports of its own is running on the core's fallback, which has to be written
    // out explicitly before the new port is added or the fix would silently drop it.
    protocols[index].ports = protocols[index].effectivePorts + [port]
    return protocols
  }
}

/// The single snippet sniffer fixes are written into, mirroring `QuickRuleLibrary`.
///
/// One fixed id so repeated fixes collect in one editable place instead of spawning a snippet each
/// time, and always enabled and bound to the active profile: a fix folded into a disabled snippet
/// would be stored and change nothing, which is the silent no-op this whole area exists to remove.
enum SnifferFixLibrary {
  static let snippetID = UUID(uuidString: "3C6D0F71-5A2B-4E19-9D84-7F2A6B1C8E30")!

  static var snippetName: String {
    String(localized: "Sniffer Fixes")
  }

  static func targetSnippet(in snippets: [RuntimeSnippet], activeProfileID: UUID?) -> RuntimeSnippet {
    guard let existing = snippets.first(where: { $0.id == snippetID }),
          case .sniffer = existing.payload
    else {
      // A snippet squatting on the id with another payload (only reachable through a restored
      // backup) is left alone rather than converted, so no user data is overwritten.
      return activated(
        RuntimeSnippet(
          id: snippets.contains(where: { $0.id == snippetID }) ? UUID() : snippetID,
          name: snippetName,
          payload: .sniffer(.empty)
        ),
        activeProfileID: activeProfileID
      )
    }
    return activated(existing, activeProfileID: activeProfileID)
  }

  /// Folds a fix into the snippet. The patch's protocol list replaces the snippet's, matching how
  /// `SnifferSettings.patched(with:)` merges into the running config — so what the editor shows
  /// afterwards is exactly what the core is told.
  static func adding(_ fix: SnifferDiagnosticsFix, to snippet: RuntimeSnippet) -> RuntimeSnippet {
    var snippet = snippet
    let existing: SnifferSettings
    if case let .sniffer(settings) = snippet.payload {
      existing = settings
    } else {
      existing = .empty
    }
    snippet.payload = .sniffer(existing.patched(with: fix.patch))
    return snippet
  }

  private static func activated(_ snippet: RuntimeSnippet, activeProfileID: UUID?) -> RuntimeSnippet {
    var snippet = snippet
    snippet.enabled = true
    if let activeProfileID, !snippet.binding.applies(to: activeProfileID) {
      snippet.binding = .profiles(snippet.binding.profileIDs + [activeProfileID])
    }
    return snippet
  }
}
