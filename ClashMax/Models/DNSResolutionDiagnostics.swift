import Foundation

/// What the resolution panel is currently showing. Kept as an explicit outcome rather than three
/// loose optionals so "nothing asked yet" and "asked and got nothing" cannot be confused.
enum DNSResolutionOutcome: Equatable, Sendable {
  case idle
  case querying
  case answered(DNSQueryResult)
  /// The core's own reason, verbatim: `invalid query type`, `DNS section is disabled`, a transport
  /// failure. Paraphrasing it here would hide the only text that names the fix.
  case failed(String)
}

/// Pure, view-agnostic answer to "what does the core resolve this name to, and where would that
/// answer send my traffic?".
///
/// This is roadmap A2. `GET /dns/query` asks the **core's** resolver — the same nameservers, the
/// same `nameserver-policy`, the same `respect-rules` — which is a different question from what
/// `dig` on the same machine answers, and it is the one that decides routing.
///
/// Two measured facts shape what this can honestly claim (bundled core, v1.19.30, 2026-08-30):
/// - **The reply carries no nameserver field.** The core never says which upstream answered, so the
///   panel states that outright instead of leaving a blank the user reads as "the default one".
///   Roadmap A2 originally asked for that attribution; it is not obtainable from this endpoint.
/// - **In fake-ip mode this endpoint still answers from upstream.** An app resolving the same name
///   through the core's DNS listener gets a `fake-ip-range` placeholder. Both answers are correct
///   about different things, so the panel says which one it is showing.
///
/// Deliberately a value-in/value-out builder like `FakeIPDiagnosticsBuilder`: every branch is
/// reachable from a test with no core running.
struct DNSResolutionSnapshot: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    /// The core answered with something usable.
    case pass
    /// Nothing is wrong; there is just nothing to report yet.
    case info
    /// The core answered, but the answer is not one traffic can be routed on.
    case warn
    /// The query did not produce an answer.
    case fail
  }

  /// Stable, locale-independent classification so views pick icons and tests assert the branch
  /// rather than localized copy.
  enum Cause: String, Equatable, Sendable {
    case coreNotRunning
    case dnsDisabled
    case configurationUnknown
    case ready
    case querying
    case resolved
    case emptyAnswer
    case nameNotFound
    case serverFailure
    case responseError
    case queryFailed
  }

  struct Fact: Equatable, Sendable {
    enum Key: String, Hashable, Sendable {
      case question
      case response
      case addresses
      case canonicalName
      case ttl
      case authority
      case resolver
      case respectRules
      case fakeIP
      case matchedRule
      case matchedPolicy
      case matchOnAddress
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
  /// Every record the core returned, for the panel's record table. Answers first, then the
  /// authority section — an `NXDOMAIN`'s SOA is the only record it has to show.
  var records: [DNSQueryRecord]
  /// Whether asking the core again can produce an answer. False where the core would refuse, so the
  /// button is offered disabled with `reason` as the explanation rather than hidden.
  var canQuery: Bool

  /// Stable English label used inside the copyable diagnostics report.
  var statusLabel: String {
    switch status {
    case .pass: return "Pass"
    case .info: return "Info"
    case .warn: return "Warn"
    case .fail: return "Fail"
    }
  }

  var plainTextLines: [String] {
    var lines = [
      "DNS Resolution: \(statusLabel) (\(cause.rawValue))",
      "Reason: \(reason)",
    ]
    for fact in facts {
      lines.append("\(fact.title): \(fact.value)")
    }
    if !records.isEmpty {
      lines.append("Records:")
      lines.append(contentsOf: records.map { "- \($0.name) \($0.ttl) \($0.typeName) \($0.data)" })
    }
    if !recoveryActions.isEmpty {
      lines.append("Recovery Actions:")
      lines.append(contentsOf: recoveryActions.map { "- \($0)" })
    }
    return lines
  }
}

struct DNSResolutionInput: Equatable, Sendable {
  var isCoreRunning: Bool
  /// `nil` while the applied runtime config has not been read back yet. Reported as unknown rather
  /// than assumed off, which would refuse a query the core would have answered.
  var dnsFacts: DNSRuntimeFacts?
  /// What the user typed, before trimming.
  var query: String
  var queryType: DNSQueryType
  var outcome: DNSResolutionOutcome
  /// The running rule list, used to carry the answer one step further: an address is only
  /// interesting because of the rule it would match.
  var rules: [RuntimeRule]

  init(
    isCoreRunning: Bool = true,
    dnsFacts: DNSRuntimeFacts? = nil,
    query: String = "",
    queryType: DNSQueryType = .a,
    outcome: DNSResolutionOutcome = .idle,
    rules: [RuntimeRule] = []
  ) {
    self.isCoreRunning = isCoreRunning
    self.dnsFacts = dnsFacts
    self.query = query
    self.queryType = queryType
    self.outcome = outcome
    self.rules = rules
  }

  var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The core answers a blank `name` by resolving the root zone and returning 200, so a blank query
  /// is caught here rather than being sent and its reply read as an answer about nothing.
  var hasQuery: Bool {
    !trimmedQuery.isEmpty
  }
}

enum DNSResolutionDiagnosticsBuilder {
  static func snapshot(for input: DNSResolutionInput) -> DNSResolutionSnapshot {
    guard input.isCoreRunning else {
      return DNSResolutionSnapshot(
        status: .info,
        cause: .coreNotRunning,
        headline: String(localized: "Core is not running"),
        reason: String(localized: "Resolution goes through the running core's own resolver, so there is nothing to ask while it is stopped."),
        facts: [],
        recoveryActions: [String(localized: "Start the core, then resolve the name again.")],
        records: [],
        canQuery: false
      )
    }

    // `dns.enable` defaults to false in Mihomo, so an absent key means DNS is off — the same
    // reading `FakeIPDiagnosticsBuilder` uses. The core answers such a query 500 with
    // `DNS section is disabled`, so refusing here just says it earlier and with the fix attached.
    if let dnsFacts = input.dnsFacts, dnsFacts.enable != true {
      return DNSResolutionSnapshot(
        status: .info,
        cause: .dnsDisabled,
        headline: String(localized: "DNS is off"),
        reason: String(localized: "The core is not running a DNS server, so it cannot resolve names for you. Traffic still resolves through the system resolver or at the proxy."),
        facts: [],
        recoveryActions: [String(localized: "Enable DNS in Settings, or turn on TUN or NE Proxy, then resolve the name again.")],
        records: [],
        canQuery: false
      )
    }

    switch input.outcome {
    case .idle:
      return idleSnapshot(for: input)
    case .querying:
      return DNSResolutionSnapshot(
        status: .info,
        cause: .querying,
        headline: String(localized: "Resolving…"),
        reason: String(
          format: String(localized: "Asking the core to resolve %1$@ (%2$@)."),
          input.trimmedQuery,
          input.queryType.displayName
        ),
        facts: [],
        recoveryActions: [],
        records: [],
        canQuery: false
      )
    case let .failed(message):
      return DNSResolutionSnapshot(
        status: .fail,
        cause: .queryFailed,
        headline: String(localized: "Resolution failed"),
        reason: message,
        facts: [],
        recoveryActions: [String(localized: "Check the name and query type, then try again. The core reports the reason verbatim.")],
        records: [],
        canQuery: true
      )
    case let .answered(result):
      return answeredSnapshot(result: result, input: input)
    }
  }

  private static func idleSnapshot(for input: DNSResolutionInput) -> DNSResolutionSnapshot {
    let reason = input.dnsFacts == nil
      ? String(localized: "ClashMax has not read the applied config back yet, so it cannot say whether the core's DNS server is on. Resolving anyway is safe: the core answers with the reason if it is off.")
      : String(localized: "Resolution uses the core's own resolver, which is the one that decides where traffic goes — not the system resolver.")
    return DNSResolutionSnapshot(
      status: .info,
      cause: input.dnsFacts == nil ? .configurationUnknown : .ready,
      headline: String(localized: "Ready to resolve"),
      reason: reason,
      facts: [],
      recoveryActions: [],
      records: [],
      canQuery: true
    )
  }

  private static func answeredSnapshot(result: DNSQueryResult, input: DNSResolutionInput) -> DNSResolutionSnapshot {
    var facts: [DNSResolutionSnapshot.Fact] = [
      .init(
        key: .question,
        title: String(localized: "Question"),
        value: "\(result.displayName) \(result.queryType)"
      ),
      .init(
        key: .response,
        title: String(localized: "Response"),
        value: result.statusName
      ),
    ]

    let records = result.answers + result.authorities

    if !result.addresses.isEmpty {
      facts.append(.init(
        key: .addresses,
        title: String(localized: "Addresses"),
        value: result.addresses.joined(separator: ", ")
      ))
    }
    if let canonicalName = result.canonicalName {
      facts.append(.init(
        key: .canonicalName,
        title: String(localized: "Canonical Name"),
        value: canonicalName
      ))
    }
    if let ttl = records.map(\.ttl).min(), ttl > 0 {
      facts.append(.init(
        key: .ttl,
        title: String(localized: "TTL"),
        value: String(format: String(localized: "%lld s"), Int64(ttl))
      ))
    }
    // On a negative answer the SOA is the whole content of the reply: it names the zone that denied
    // the name and how long the denial is cached for.
    if result.answers.isEmpty, let authority = result.authorities.first {
      facts.append(.init(
        key: .authority,
        title: String(localized: "Authority"),
        value: "\(authority.name) \(authority.summary)"
      ))
    }

    facts.append(.init(
      key: .resolver,
      title: String(localized: "Resolver"),
      value: String(localized: "Not reported — the core's answer carries no upstream")
    ))
    if let dnsFacts = input.dnsFacts {
      facts.append(.init(
        key: .respectRules,
        title: String(localized: "Respect Rules"),
        value: dnsFacts.respectRules
          ? String(localized: "On — DNS queries follow your rules")
          : String(localized: "Off — DNS queries go straight to the nameservers")
      ))
      if dnsFacts.isFakeIPMode {
        let range = dnsFacts.values[.fakeIPRange] ?? "198.18.0.1/16"
        facts.append(.init(
          key: .fakeIP,
          title: String(localized: "Fake IP"),
          value: String(
            format: String(localized: "On (%@). Apps receive a placeholder from that range; the address above is the one the core dials."),
            range
          )
        ))
      }
    }

    facts.append(contentsOf: routingFacts(result: result, input: input))

    guard result.isSuccess else {
      return failedResponseSnapshot(result: result, facts: facts, records: records)
    }

    guard !result.answers.isEmpty else {
      return DNSResolutionSnapshot(
        status: .warn,
        cause: .emptyAnswer,
        headline: String(localized: "No records of this type"),
        reason: String(
          format: String(localized: "%1$@ exists, but the core found no %2$@ record for it."),
          result.displayName,
          result.queryType
        ),
        facts: facts,
        recoveryActions: [String(localized: "Try another record type — a name with only IPv4 addresses answers empty for AAAA.")],
        records: records,
        canQuery: true
      )
    }

    return DNSResolutionSnapshot(
      status: .pass,
      cause: .resolved,
      headline: String(
        format: String(localized: "Resolved %@"),
        result.displayName
      ),
      reason: result.addresses.isEmpty
        ? String(format: String(localized: "The core answered with %lld record(s)."), Int64(result.answers.count))
        : String(format: String(localized: "The core resolves this name to %@."), result.addresses.joined(separator: ", ")),
      facts: facts,
      recoveryActions: [],
      records: records,
      canQuery: true
    )
  }

  private static func failedResponseSnapshot(
    result: DNSQueryResult,
    facts: [DNSResolutionSnapshot.Fact],
    records: [DNSQueryRecord]
  ) -> DNSResolutionSnapshot {
    switch result.status {
    case DNSResponseCode.nameError:
      return DNSResolutionSnapshot(
        status: .fail,
        cause: .nameNotFound,
        headline: String(localized: "Name does not exist"),
        reason: String(
          format: String(localized: "The core's resolver answered NXDOMAIN for %@: the authoritative zone says there is no such name."),
          result.displayName
        ),
        facts: facts,
        recoveryActions: [String(localized: "Check the spelling. If the name resolves elsewhere, a nameserver-policy entry or a rule may be sending this query to the wrong resolver.")],
        records: records,
        canQuery: true
      )
    case DNSResponseCode.serverFailure:
      return DNSResolutionSnapshot(
        status: .fail,
        cause: .serverFailure,
        headline: String(localized: "Resolver failed"),
        reason: String(localized: "The core's upstream nameserver returned SERVFAIL, so the query never produced an answer."),
        facts: facts,
        recoveryActions: [
          String(localized: "Check that the configured nameservers are reachable on this network."),
          String(localized: "If DNS queries are routed through a proxy, confirm the node is up."),
        ],
        records: records,
        canQuery: true
      )
    default:
      return DNSResolutionSnapshot(
        status: .fail,
        cause: .responseError,
        headline: String(
          format: String(localized: "Resolver answered %@"),
          result.statusName
        ),
        reason: String(
          format: String(localized: "The core's resolver rejected the query for %1$@ with %2$@."),
          result.displayName,
          result.statusName
        ),
        facts: facts,
        recoveryActions: [String(localized: "Check the configured nameservers and any nameserver-policy entry that covers this name.")],
        records: records,
        canQuery: true
      )
    }
  }

  /// The half of A2 that makes the panel worth having: an address on its own says nothing, so the
  /// answer is carried through the same rule engine the Routing page uses — name first, then the
  /// address the name resolved to, because those two can match different rules and that gap is
  /// exactly what a "why did this go DIRECT?" question is about.
  private static func routingFacts(
    result: DNSQueryResult,
    input: DNSResolutionInput
  ) -> [DNSResolutionSnapshot.Fact] {
    let candidates = RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: input.rules)
    guard !candidates.isEmpty else { return [] }
    let simulator = RuleMatchSimulator()
    var facts: [DNSResolutionSnapshot.Fact] = []

    let nameTrace = simulator.simulate(
      input: RuleMatchSimulationInput(destination: result.displayName),
      candidates: candidates
    )
    facts.append(.init(
      key: .matchedRule,
      title: String(localized: "Match On Name"),
      value: nameTrace.outcome.detail
    ))
    if let policy = nameTrace.policy, !policy.isEmpty {
      facts.append(.init(
        key: .matchedPolicy,
        title: String(localized: "Policy"),
        value: policy
      ))
    }

    if let address = result.addresses.first {
      let addressTrace = simulator.simulate(
        input: RuleMatchSimulationInput(destination: address),
        candidates: candidates
      )
      // Named after what it answers: this is the rule that wins when the connection carries only
      // the address — no sniffed name, no fake-ip mapping — which is where the two verdicts diverge.
      facts.append(.init(
        key: .matchOnAddress,
        title: String(localized: "Match On Address"),
        value: "\(address) → \(addressTrace.outcome.detail)"
      ))
    }
    return facts
  }
}
