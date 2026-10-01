import Foundation
import Yams

// Roadmap C1: a subscription is a configuration someone else wrote. On every import and update
// ClashMax says, in plain language, what the profile tried to change, what ClashMax overrode, and
// what it let through — and every `danger` item says what would actually happen.

/// Roadmap C3: whether a subscription's own `listeners` that other machines can reach are started.
/// `nil` on the profile means nobody has been asked yet, which keeps them off.
enum InheritedListenerPolicy: String, Codable, Equatable, Sendable {
  case allowExposed
  case blockExposed
}

struct SubscriptionAuditReport: Codable, Equatable, Sendable {
  enum Trigger: String, Codable, Equatable, Sendable {
    case imported
    case updated
    case automaticUpdate
    /// Run from the profile menu for a profile that had no report yet.
    case onDemand
  }

  enum Disposition: String, Codable, Equatable, Sendable {
    /// ClashMax replaced or removed the value before the core saw it.
    case overridden
    /// The core runs the profile's value as authored.
    case passedThrough
  }

  struct Item: Codable, Equatable, Sendable, Identifiable {
    var key: String
    var severity: ProviderOptionsRisk.Severity
    var disposition: Disposition
    /// What the profile asked for, without any secret value in it.
    var attempted: String
    /// What ClashMax did about it.
    var outcome: String
    /// The concrete effect; always present for `danger`.
    var consequence: String?

    var id: String { key }
  }

  /// A listener in the profile that other machines can reach.
  struct ExposedListener: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var type: String
    var endpoint: String
    var id: String { "\(name)|\(endpoint)" }
  }

  /// Bounds what is kept per profile: the report rides in the profile manifest.
  static let itemLimit = 40
  static let exposedListenerLimit = 20
  static let textLimit = 300

  var generatedAt: Date
  var trigger: Trigger
  /// The profile is a node list only; ClashMax writes every other key itself.
  var isNodeListOnly: Bool
  var items: [Item]
  var exposedListeners: [ExposedListener]
  var listenerPolicy: InheritedListenerPolicy?
  /// Why the outcome column could not be computed, when ClashMax failed to generate a config.
  var generationFailure: String?
  var acknowledged: Bool

  var overridden: [Item] {
    items.filter { $0.disposition == .overridden }
  }

  var passedThrough: [Item] {
    items.filter { $0.disposition == .passedThrough }
  }

  var isClean: Bool {
    items.isEmpty
  }

  /// Exposed listeners exist and nobody has decided about them yet.
  var needsListenerDecision: Bool {
    !exposedListeners.isEmpty && listenerPolicy == nil
  }

  /// Shown as a marker on the profile and announced after a background update until reviewed.
  var needsAttention: Bool {
    guard !acknowledged else { return false }
    return needsListenerDecision
      || items.contains { $0.severity == .danger && $0.disposition == .passedThrough }
  }
}

enum SubscriptionAuditBuilder {
  /// `sourceYAML` is the profile as fetched; `runtimeYAML` is what ClashMax generates from it with
  /// the user's settings and without the user's own snippets, so every difference is a decision
  /// ClashMax made about the subscription, not something the user wrote.
  static func build(
    sourceYAML: String,
    runtimeYAML: String?,
    generationFailure: String? = nil,
    listenerPolicy: InheritedListenerPolicy?,
    trigger: SubscriptionAuditReport.Trigger,
    generatedAt: Date
  ) -> SubscriptionAuditReport {
    let source = (try? Yams.load(yaml: sourceYAML)) as? [String: Any]
    let runtime = runtimeYAML.flatMap { (try? Yams.load(yaml: $0)) as? [String: Any] }
    guard let source, !ProfileConfigInspector.isProxyProviderContent(sourceYAML) else {
      return SubscriptionAuditReport(
        generatedAt: generatedAt,
        trigger: trigger,
        isNodeListOnly: true,
        items: [],
        exposedListeners: [],
        listenerPolicy: listenerPolicy,
        generationFailure: generationFailure,
        acknowledged: false
      )
    }
    let context = Context(source: source, runtime: runtime, listenerPolicy: listenerPolicy)
    var items: [SubscriptionAuditReport.Item] = []
    for key in source.keys.sorted() {
      items.append(contentsOf: context.items(forKey: key))
    }
    let exposed = ListenerRuntimeFacts.facts(from: source).exposedListeners.map {
      SubscriptionAuditReport.ExposedListener(name: $0.name, type: $0.type, endpoint: $0.summary)
    }
    // Danger first, then warnings, then the rest; stable within a severity.
    let ranked = items.enumerated().sorted { lhs, rhs in
      let left = rank(lhs.element.severity)
      let right = rank(rhs.element.severity)
      return left == right ? lhs.offset < rhs.offset : left < right
    }.map(\.element)
    return SubscriptionAuditReport(
      generatedAt: generatedAt,
      trigger: trigger,
      isNodeListOnly: false,
      items: Array(ranked.prefix(SubscriptionAuditReport.itemLimit)).map(bounded),
      exposedListeners: Array(exposed.prefix(SubscriptionAuditReport.exposedListenerLimit)),
      listenerPolicy: listenerPolicy,
      generationFailure: generationFailure.map { bounded($0) },
      acknowledged: false
    )
  }

  private static func rank(_ severity: ProviderOptionsRisk.Severity) -> Int {
    switch severity {
    case .danger: 0
    case .warning: 1
    case .info: 2
    }
  }

  /// The report is persisted and shown later, so it carries no URL path, query or credential and
  /// no unbounded text.
  private static func bounded(_ item: SubscriptionAuditReport.Item) -> SubscriptionAuditReport.Item {
    var item = item
    item.attempted = bounded(item.attempted)
    item.outcome = bounded(item.outcome)
    item.consequence = item.consequence.map { bounded($0) }
    return item
  }

  private static func bounded(_ text: String) -> String {
    let redacted = StructuredLogRedactor.redactCredentials(in: text)
    guard redacted.count > SubscriptionAuditReport.textLimit else { return redacted }
    return String(redacted.prefix(SubscriptionAuditReport.textLimit - 1)) + "…"
  }

  // MARK: Per key

  private struct Context {
    var source: [String: Any]
    var runtime: [String: Any]?
    var listenerPolicy: InheritedListenerPolicy?

    func items(forKey key: String) -> [SubscriptionAuditReport.Item] {
      let normalized = key.lowercased()
      let value = source[key] as Any
      switch normalized {
      case "external-controller":
        return [controllerItem(key: key, value: value)]
      case "secret":
        return [secretItem(key: key)]
      case "external-controller-cors":
        return [scalarOverride(
          key: key,
          severity: .warning,
          attempted: String(localized: "Set which web pages may call the control API."),
          overridden: String(localized: "ClashMax writes this from its own External Control settings.")
        )]
      case _ where normalized.hasPrefix("external-controller-"):
        return [secondControllerItem(key: key, value: value)]
      case "allow-lan":
        return [allowLANItem(key: key, value: value)]
      case "mixed-port", "port", "socks-port", "http-port", "redir-port", "tproxy-port":
        return [portItem(key: key, value: value)]
      case "tun":
        return [mappingItem(
          key: key,
          severity: .warning,
          attempted: String(localized: "TUN settings."),
          note: String(localized: "ClashMax decides whether TUN is on, and while it is, its stack, device, routes and DNS hijack.")
        )]
      case "dns":
        return [mappingItem(
          key: key,
          severity: .warning,
          attempted: String(localized: "DNS settings."),
          note: String(localized: "The nameservers that stay as authored decide how every name resolves while this profile is active.")
        )]
      case "sniffer":
        return [snifferItem(key: key, value: value)]
      case "listeners":
        return [listenersItem(key: key)]
      case "authentication":
        return [authenticationItem(key: key, value: value)]
      case "script":
        return [SubscriptionAuditReport.Item(
          key: key,
          severity: .info,
          disposition: .passedThrough,
          attempted: String(localized: "A script block."),
          outcome: String(localized: "Passed through, and ignored: the bundled core does not run scripts and rejects SCRIPT rules, so a profile that uses one fails to load."),
          consequence: nil
        )]
      case "external-ui", "external-ui-url", "external-ui-name":
        return [externalUIItem(key: key, value: value)]
      case "hosts":
        return [hostsItem(key: key, value: value)]
      case "find-process-mode":
        return findProcessModeItem(key: key, value: value)
      case _ where normalized.hasSuffix("-port"):
        return [portItem(key: key, value: value)]
      default:
        return []
      }
    }

    private func runtimeValue(_ key: String) -> Any? {
      runtime?[key]
    }

    private var runtimeKnown: Bool {
      runtime != nil
    }

    private func disposition(for key: String, sourceValue: Any) -> SubscriptionAuditReport.Disposition? {
      guard runtimeKnown else { return nil }
      guard let runtimeValue = runtimeValue(key) else { return .overridden }
      return SubscriptionAuditBuilder.equal(sourceValue, runtimeValue) ? .passedThrough : .overridden
    }

    private func controllerItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let address = SubscriptionAuditBuilder.scalar(value)
      let after = runtimeValue(key).map(SubscriptionAuditBuilder.scalar)
      let disposition = disposition(for: key, sourceValue: value) ?? .overridden
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .danger,
        disposition: disposition,
        attempted: String(format: String(localized: "Move the control API to %@."), address),
        outcome: disposition == .overridden
          ? String(format: String(localized: "Overridden: ClashMax binds it to %@ with a secret of its own."), after ?? "127.0.0.1")
          : String(localized: "Matches the address ClashMax uses."),
        consequence: String(format: String(localized: "Anyone who can reach %@ could read your connections and change where your traffic goes."), address)
      )
    }

    private func secretItem(key: String) -> SubscriptionAuditReport.Item {
      SubscriptionAuditReport.Item(
        key: key,
        severity: .danger,
        disposition: .overridden,
        attempted: String(localized: "Set the password of the control API."),
        outcome: String(localized: "Overridden: ClashMax generates a new secret every time the core starts."),
        consequence: String(localized: "Whoever wrote the subscription would know the password to your core's control API.")
      )
    }

    private func secondControllerItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      // The normalizer drops the variants it knows; one it does not would run as authored.
      let unmeasured: SubscriptionAuditReport.Disposition = ConfigNormalizer.profileControllerVariantKeys.contains(key)
        ? .overridden
        : .passedThrough
      let disposition = disposition(for: key, sourceValue: value) ?? unmeasured
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .danger,
        disposition: disposition,
        attempted: String(format: String(localized: "Open another control API: %@ %@."), key, SubscriptionAuditBuilder.scalar(value)),
        outcome: disposition == .overridden
          ? String(localized: "Removed by ClashMax.")
          : String(localized: "Passed through: ClashMax does not manage this key."),
        consequence: String(localized: "A second way to control the core, on an address or path ClashMax does not manage, so ClashMax cannot tell who can reach it.")
      )
    }

    private func allowLANItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let requested = SubscriptionAuditBuilder.scalar(value)
      let disposition = disposition(for: key, sourceValue: value) ?? .overridden
      let after = runtimeValue(key).map(SubscriptionAuditBuilder.scalar) ?? "false"
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .warning,
        disposition: disposition,
        attempted: String(format: String(localized: "allow-lan: %@."), requested),
        outcome: disposition == .overridden
          ? String(format: String(localized: "Overridden with your Allow LAN setting (%@)."), after)
          : String(localized: "Matches your Allow LAN setting."),
        consequence: nil
      )
    }

    private func portItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let disposition = disposition(for: key, sourceValue: value) ?? .overridden
      let mixedPort = runtimeValue("mixed-port").map(SubscriptionAuditBuilder.scalar) ?? "—"
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .warning,
        disposition: disposition,
        attempted: String(format: String(localized: "Open inbound port %@ (%@)."), SubscriptionAuditBuilder.scalar(value), key),
        outcome: disposition == .overridden
          ? String(format: String(localized: "Overridden: ClashMax opens only its own mixed port, %@."), mixedPort)
          : String(localized: "Passed through."),
        consequence: nil
      )
    }

    private func mappingItem(
      key: String,
      severity: ProviderOptionsRisk.Severity,
      attempted: String,
      note: String
    ) -> SubscriptionAuditReport.Item {
      let sourceMap = source[key] as? [String: Any] ?? [:]
      let runtimeMap = runtimeValue(key) as? [String: Any]
      let keys = sourceMap.keys.sorted()
      guard let runtimeMap else {
        return SubscriptionAuditReport.Item(
          key: key,
          severity: severity,
          disposition: runtimeKnown ? .overridden : .passedThrough,
          attempted: "\(attempted) \(SubscriptionAuditBuilder.list(keys))",
          outcome: runtimeKnown ? String(localized: "Removed by ClashMax.") : note,
          consequence: nil
        )
      }
      let changed = keys.filter { subkey in
        guard let after = runtimeMap[subkey] else { return true }
        return !SubscriptionAuditBuilder.equal(sourceMap[subkey] as Any, after)
      }
      let kept = keys.filter { !changed.contains($0) }
      var outcome: [String] = []
      if !changed.isEmpty {
        outcome.append(String(format: String(localized: "ClashMax replaced %@."), SubscriptionAuditBuilder.list(changed)))
      }
      if !kept.isEmpty {
        outcome.append(String(format: String(localized: "Kept as authored: %@."), SubscriptionAuditBuilder.list(kept)))
      }
      outcome.append(note)
      return SubscriptionAuditReport.Item(
        key: key,
        severity: severity,
        disposition: kept.isEmpty ? .overridden : .passedThrough,
        attempted: "\(attempted) \(SubscriptionAuditBuilder.list(keys))",
        outcome: outcome.joined(separator: " "),
        consequence: nil
      )
    }

    /// Roadmap A1d: what the subscription's sniffer would change, and what ClashMax kept.
    private func snifferItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let sourceMap = value as? [String: Any] ?? [:]
      var attempted: [String] = []
      if let enable = sourceMap["enable"] as? Bool {
        attempted.append(enable ? String(localized: "turn sniffing on") : String(localized: "turn sniffing off"))
      }
      if let override = sourceMap["override-destination"] as? Bool {
        attempted.append(String(format: String(localized: "override-destination: %@"), String(override)))
      }
      for listKey in ["skip-domain", "force-domain", "skip-src-address", "skip-dst-address"] {
        if let list = sourceMap[listKey] as? [Any], !list.isEmpty {
          attempted.append(String(format: String(localized: "%@: %lld entries"), listKey, Int64(list.count)))
        }
      }
      if let sniff = sourceMap["sniff"] as? [String: Any], !sniff.isEmpty {
        attempted.append(String(format: String(localized: "sniff %@"), SubscriptionAuditBuilder.list(sniff.keys.sorted())))
      }
      var item = mappingItem(
        key: key,
        severity: .warning,
        attempted: String(localized: "Sniffer settings:"),
        note: String(localized: "A Sniffer snippet in Routing takes precedence over these.")
      )
      item.attempted = String(format: String(localized: "Sniffer settings: %@."), attempted.isEmpty ? key : attempted.joined(separator: ", "))
      if sourceMap["enable"] as? Bool == false, item.disposition == .passedThrough {
        item.consequence = String(localized: "With sniffing off, a connection dialed straight to an IP carries no domain, so DOMAIN and GEOSITE rules never match it.")
      }
      return item
    }

    private func listenersItem(key: String) -> SubscriptionAuditReport.Item {
      let sourceFacts = ListenerRuntimeFacts.facts(from: source)
      let runtimeFacts = runtime.map(ListenerRuntimeFacts.facts(from:))
      let exposed = sourceFacts.exposedListeners
      let attempted = String(
        format: String(localized: "Open %lld extra inbound listener(s): %@."),
        Int64(sourceFacts.listeners.count),
        sourceFacts.listeners.map(\.summary).joined(separator: "; ")
      )
      let runningExposed = runtimeFacts?.exposedListeners ?? (listenerPolicy == .allowExposed ? exposed : [])
      let authenticated = runtimeFacts?.hasInboundAuthentication ?? sourceFacts.hasInboundAuthentication
      if exposed.isEmpty {
        return SubscriptionAuditReport.Item(
          key: key,
          severity: .info,
          disposition: .passedThrough,
          attempted: attempted,
          outcome: String(localized: "Passed through: every one listens on this Mac only."),
          consequence: nil
        )
      }
      let ports = exposed.map(\.summary).joined(separator: "; ")
      let consequence = authenticated
        ? String(format: String(localized: "Other devices on your network can use your proxy through %@ with the credentials in the profile's authentication list."), ports)
        : String(format: String(localized: "Anyone on your network can use your proxy through %@ — no password is required."), ports)
      if runningExposed.isEmpty {
        return SubscriptionAuditReport.Item(
          key: key,
          severity: .danger,
          disposition: .overridden,
          attempted: attempted,
          outcome: listenerPolicy == .blockExposed
            ? String(localized: "Kept off: you chose not to allow listeners that other devices can reach.")
            : String(localized: "Kept off until you allow them. Listeners on this Mac only still run."),
          consequence: String(format: String(localized: "If allowed: %@"), consequence)
        )
      }
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .danger,
        disposition: .passedThrough,
        attempted: attempted,
        outcome: String(localized: "Running: you allowed listeners that other devices can reach."),
        consequence: consequence
      )
    }

    /// Measured against v1.19.31: with an `authentication` list, a request from this Mac to the
    /// mixed port without credentials was answered 407, with them 200 — unless the source address
    /// is in `skip-auth-prefixes`, which the normalizer fills with loopback. A request from the
    /// LAN still needed the credentials. Whether this Mac is exempt is read from the generated
    /// config, so the report cannot claim a fix the normalizer stopped making.
    private func authenticationItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let count = (value as? [Any])?.count ?? 0
      let disposition = disposition(for: key, sourceValue: value) ?? .passedThrough
      let enforced = count > 0 && disposition == .passedThrough
      let runtimePrefixes = Set(((runtimeValue("skip-auth-prefixes") as? [Any]) ?? []).map {
        SubscriptionAuditBuilder.scalar($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      })
      let thisMacExempt = ConfigNormalizer.loopbackSkipAuthPrefixes.allSatisfy(runtimePrefixes.contains)
      let gatesThisMac = enforced && runtimeKnown && !thisMacExempt
      let outcome = if disposition == .overridden {
        String(localized: "Removed by ClashMax.")
      } else if enforced, thisMacExempt {
        String(
          format: String(localized: "Passed through. Apps on this Mac are exempt: ClashMax adds %@ to skip-auth-prefixes."),
          ConfigNormalizer.loopbackSkipAuthPrefixes.joined(separator: ", ")
        )
      } else {
        String(localized: "Passed through.")
      }
      let consequence: String? = if gatesThisMac {
        String(localized: "ClashMax's own port asks for these credentials too, so apps using the system proxy get HTTP 407 and stop connecting.")
      } else if enforced {
        String(localized: "Other devices that reach your proxy, through Allow LAN or a listener, must sign in with these credentials, which whoever wrote the subscription also knows.")
      } else {
        nil
      }
      return SubscriptionAuditReport.Item(
        key: key,
        severity: gatesThisMac ? .warning : .info,
        disposition: disposition,
        attempted: String(format: String(localized: "Require a username and password on inbound proxies (%lld account(s))."), Int64(count)),
        outcome: outcome,
        consequence: consequence
      )
    }

    private func externalUIItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let raw = SubscriptionAuditBuilder.scalar(value)
      let host = URL(string: raw)?.host ?? raw
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .warning,
        disposition: disposition(for: key, sourceValue: value) ?? .passedThrough,
        attempted: key == "external-ui-url"
          ? String(format: String(localized: "Download a web dashboard from %@."), host)
          : String(format: String(localized: "Serve a web dashboard (%@)."), key),
        outcome: String(localized: "Passed through: the dashboard is served from the core's control port, which stays on this Mac."),
        consequence: nil
      )
    }

    private func hostsItem(key: String, value: Any) -> SubscriptionAuditReport.Item {
      let count = (value as? [String: Any])?.count ?? 0
      return SubscriptionAuditReport.Item(
        key: key,
        severity: .warning,
        disposition: disposition(for: key, sourceValue: value) ?? .passedThrough,
        attempted: String(format: String(localized: "Pin %lld host name(s) to fixed addresses."), Int64(count)),
        outcome: String(localized: "Passed through."),
        consequence: String(localized: "Those names skip DNS entirely and go wherever the profile says, whatever the real address is.")
      )
    }

    private func findProcessModeItem(key: String, value: Any) -> [SubscriptionAuditReport.Item] {
      let mode = SubscriptionAuditBuilder.scalar(value)
      guard mode.lowercased() == "off" else { return [] }
      return [SubscriptionAuditReport.Item(
        key: key,
        severity: .warning,
        disposition: disposition(for: key, sourceValue: value) ?? .passedThrough,
        attempted: String(localized: "find-process-mode: off."),
        outcome: String(localized: "Passed through."),
        consequence: String(localized: "Mihomo stops identifying which app opened a connection, so per-app rules never match.")
      )]
    }

    private func scalarOverride(
      key: String,
      severity: ProviderOptionsRisk.Severity,
      attempted: String,
      overridden: String
    ) -> SubscriptionAuditReport.Item {
      let disposition = disposition(for: key, sourceValue: source[key] as Any) ?? .overridden
      return SubscriptionAuditReport.Item(
        key: key,
        severity: severity,
        disposition: disposition,
        attempted: attempted,
        outcome: disposition == .overridden ? overridden : String(localized: "Passed through."),
        consequence: nil
      )
    }
  }

  // MARK: Values

  static func scalar(_ value: Any) -> String {
    switch value {
    case let string as String: string
    case let bool as Bool: bool ? "true" : "false"
    case let int as Int: String(int)
    case let double as Double: String(double)
    default: String(describing: value)
    }
  }

  static func list(_ keys: [String]) -> String {
    keys.isEmpty ? "—" : keys.joined(separator: ", ")
  }

  /// Structural equality over decoded YAML, so a value that only round-tripped through the
  /// normalizer is not reported as changed.
  static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    switch (lhs, rhs) {
    case let (left as [String: Any], right as [String: Any]):
      guard left.count == right.count else { return false }
      return left.allSatisfy { key, value in right[key].map { equal(value, $0) } ?? false }
    case let (left as [Any], right as [Any]):
      return left.count == right.count && zip(left, right).allSatisfy { equal($0, $1) }
    default:
      return scalar(lhs) == scalar(rhs)
    }
  }
}
