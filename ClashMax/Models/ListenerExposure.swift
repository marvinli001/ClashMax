import Foundation

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

/// One entry of the runtime config's `listeners:` block — an extra inbound the core listens on,
/// beyond the `mixed-port` ClashMax manages itself.
///
/// Contract measured against the bundled core (v1.19.30) on 2026-08-30:
/// - **`GET /configs` carries no `listeners` key at all**, so the generated runtime YAML is the only
///   place this can be read back from, exactly as for `dns` and `sniffer`.
/// - **`allow-lan` does not gate them.** With `allow-lan: false`, a `listen: 0.0.0.0` entry was
///   reachable from another host on the LAN (HTTP 200 through it) while the app-managed
///   `mixed-port` refused the same request. `allow-lan` governs the default inbounds only.
/// - **An omitted `listen` binds every interface** (`*:port`), so the exposed choice is the default
///   one, and a config that simply does not mention `listen` is already sharing the port.
/// - **The global `authentication:` list does apply**: without credentials the same LAN request
///   answered 407, with them 200. An exposed listener and an empty `authentication` list together
///   are an open proxy for anyone who can reach the port.
/// - **`skip-auth-prefixes` exempts by source address, on every inbound** (v1.19.31). With a list,
///   `ConfigNormalizer` adds loopback so apps on this Mac can use `mixed-port`; the exposed listener
///   still answered the Mac's own LAN address with 407. A config's own prefixes that reach past
///   loopback are where the list stops applying, so they are judged too (`SkipAuthPrefixes`).
struct RuntimeListener: Equatable, Sendable, Identifiable {
  var name: String
  var type: String
  /// The address as written, or empty when the key is absent — which is *not* the same as loopback.
  var listen: String
  var port: String
  /// The outbound this inbound's traffic is pinned to, when the entry names one.
  var proxy: String?

  var id: String { "\(name)|\(type)|\(listen)|\(port)" }

  init(name: String, type: String, listen: String = "", port: String = "", proxy: String? = nil) {
    self.name = name
    self.type = type
    self.listen = listen
    self.port = port
    self.proxy = proxy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  /// The host part of `listen`, tolerating the `host:port` form Mihomo also accepts.
  var listenHost: String {
    let trimmed = listen.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasPrefix("[") {
      // `[::1]:1080` — an IPv6 literal keeps its brackets, so cut at the closing one.
      guard let end = trimmed.firstIndex(of: "]") else { return trimmed }
      return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
    }
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    // Two parts means `host:port`; more means a bare IPv6 literal, which has no port to strip.
    return parts.count == 2 ? String(parts[0]) : trimmed
  }

  /// Whether traffic from other machines can reach this inbound.
  ///
  /// An absent `listen` counts as exposed because the core binds every interface when the key is
  /// missing — measured, not assumed. Reporting the default as safe would be the one mistake that
  /// matters here.
  var isLANExposed: Bool {
    switch listenHost.lowercased() {
    case "127.0.0.1", "localhost", "::1":
      return false
    default:
      return true
    }
  }

  /// How the entry reads in a fact row: `mixed on 0.0.0.0:7890 → 🇯🇵 Node`.
  var summary: String {
    let host = listenHost.isEmpty ? String(localized: "all interfaces") : listenHost
    let endpoint = port.isEmpty ? host : "\(host):\(port)"
    guard let proxy else { return "\(type) \(endpoint)" }
    return "\(type) \(endpoint) → \(proxy)"
  }
}

/// What the runtime config says about extra inbounds. `nil` facts mean "not read yet"; a present
/// value with an empty list means the config genuinely defines none.
struct ListenerRuntimeFacts: Equatable, Sendable {
  var listeners: [RuntimeListener]
  /// Whether the config carries a non-empty global `authentication:` list. Measured to gate
  /// `listeners:` entries too, so it is the difference between an extra inbound and an open proxy —
  /// for every source except the ones in `skipAuthPrefixesBeyondThisMac`. `ConfigNormalizer` keys
  /// its loopback exemption off this alone, so it must not start meaning "effective".
  var hasInboundAuthentication: Bool
  /// The config's `skip-auth-prefixes` entries that let other machines in (`SkipAuthPrefixes.Scope`),
  /// as written. Each one lets the devices it covers past the `authentication:` list on every inbound.
  var skipAuthPrefixesBeyondThisMac: [String]

  /// Named `empty` rather than `none` on purpose: this type is held as an optional, and
  /// `ListenerRuntimeFacts.none` would be read by the compiler as `Optional.none` wherever one is
  /// expected — silently turning "the config defines no listeners" into "not read yet", which are
  /// the two states this whole model exists to keep apart.
  static let empty = ListenerRuntimeFacts(listeners: [], hasInboundAuthentication: false)

  init(listeners: [RuntimeListener], hasInboundAuthentication: Bool, skipAuthPrefixesBeyondThisMac: [String] = []) {
    self.listeners = listeners
    self.hasInboundAuthentication = hasInboundAuthentication
    self.skipAuthPrefixesBeyondThisMac = skipAuthPrefixesBeyondThisMac
  }

  var exposedListeners: [RuntimeListener] {
    listeners.filter(\.isLANExposed)
  }

  /// Whether every other machine that reaches an inbound has to send credentials.
  var requiresCredentialsFromOtherMachines: Bool {
    hasInboundAuthentication && skipAuthPrefixesBeyondThisMac.isEmpty
  }

  /// Parses `listeners`, `authentication` and `skip-auth-prefixes` out of a decoded runtime config
  /// root. Entries with neither a name nor a type are dropped: a listener the core cannot start is
  /// not something to report as running.
  static func facts(from root: [String: Any]) -> ListenerRuntimeFacts {
    let entries = (root["listeners"] as? [Any]) ?? []
    let listeners: [RuntimeListener] = entries.compactMap { entry in
      guard let mapping = entry as? [String: Any] else { return nil }
      let name = string(mapping["name"])
      let type = string(mapping["type"])
      guard !name.isEmpty || !type.isEmpty else { return nil }
      return RuntimeListener(
        name: name.isEmpty ? type : name,
        type: type,
        listen: string(mapping["listen"]),
        // `port` is an Int in every example config, and `ports` is the range form some listener
        // types take instead.
        port: string(mapping["port"]).nilIfEmpty ?? string(mapping["ports"]),
        proxy: string(mapping["proxy"]).nilIfEmpty
      )
    }
    let authentication = (root["authentication"] as? [Any])?.compactMap { string($0).nilIfEmpty } ?? []
    return ListenerRuntimeFacts(
      listeners: listeners,
      hasInboundAuthentication: !authentication.isEmpty,
      skipAuthPrefixesBeyondThisMac: SkipAuthPrefixes.entries(root["skip-auth-prefixes"]).filter {
        SkipAuthPrefixes.scope(of: $0) == .beyondThisMac
      }
    )
  }

  fileprivate static func string(_ value: Any?) -> String {
    switch value {
    case let value as String: return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case let value as Int: return String(value)
    case let value as Bool: return value ? "true" : "false"
    case let value as NSNumber: return value.stringValue
    default: return ""
    }
  }
}

/// `skip-auth-prefixes`: the source ranges Mihomo lets past the global `authentication:` list.
///
/// Measured against the bundled core (v1.19.31) on 2026-10-02 with `authentication: ["u:p"]`, a
/// `listen: 0.0.0.0` mixed listener, and requests from this Mac's own `en0` address, which the core
/// sees as another machine:
/// - `0.0.0.0/0`, `192.168.0.0/16` and `192.168.8.65/16` (host bits are masked) let that address
///   through with no credentials — SOCKS5 `05 00`, HTTP 200 — while `10.0.0.0/8` left it at 407.
///   Under Allow LAN, `0.0.0.0/0` opened the mixed port to it the same way.
/// - Families do not cross: `::/0` exempted `::1` and the link-local `en0` address but neither
///   `127.0.0.1` nor the LAN address, and `fe80::/10` exempted the link-local source.
/// - The core unmaps an IPv4 source before matching, so `::ffff:0:0/96` exempted nobody, even on a
///   dual-stack `listen: "::"` listener, and `::ffff:127.0.0.0/104` on its own left even
///   `127.0.0.1` at 407.
/// - An entry without a length fails the whole config: `netip.ParsePrefix("192.168.8.65"): no '/'`.
enum SkipAuthPrefixes {
  /// Every entry as written. A lone string is one entry, as `ConfigNormalizer` treats it.
  static func entries(_ value: Any?) -> [String] {
    let values: [Any] = switch value {
    case let list as [Any]: list
    case let entry as String: [entry]
    default: []
    }
    return values.map { ListenerRuntimeFacts.string($0) }.filter { !$0.isEmpty }
  }

  /// Who an entry lets past the list.
  enum Scope: Equatable, Sendable {
    /// Only this Mac: an IPv4 prefix inside `127.0.0.0/8`, or `::1/128`.
    case loopback
    /// Nobody: a prefix inside `::ffff:0:0/96`. The core unmaps an IPv4 source before matching
    /// (measured above), so no source is ever IPv4-mapped; the bundled-core test pins this.
    case ipv4Mapped
    /// Other machines. Text that is not a prefix lands here too, so the verdict errs toward "open".
    case beyondThisMac
  }

  /// A bare address is read as the one host it names.
  static func scope(of entry: String) -> Scope {
    let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    let written = trimmed.contains("/") ? trimmed : "\(trimmed)/\(trimmed.contains(":") ? 128 : 32)"
    guard let prefix = try? NetworkExtensionRouteCIDR(written) else { return .beyondThisMac }
    switch prefix.family {
    case .ipv4:
      var address = in_addr()
      guard inet_pton(AF_INET, prefix.address, &address) == 1 else { return .beyondThisMac }
      // From /8 on, the first octet is part of the network, so it alone decides.
      return prefix.prefix >= 8 && UInt32(bigEndian: address.s_addr) >> 24 == 127 ? .loopback : .beyondThisMac
    case .ipv6:
      var address = in6_addr()
      guard inet_pton(AF_INET6, prefix.address, &address) == 1 else { return .beyondThisMac }
      let bytes = withUnsafeBytes(of: address) { Array($0) }
      if prefix.prefix == 128, bytes == Array(repeating: 0, count: 15) + [1] {
        return .loopback
      }
      // Ten zero bytes then `ff ff`, all inside the network part from /96 on.
      let mapped = prefix.prefix >= 96
        && bytes[0..<10].allSatisfy { $0 == 0 }
        && bytes[10] == 0xff && bytes[11] == 0xff
      return mapped ? .ipv4Mapped : .beyondThisMac
    }
  }

  /// How exempted entries read in a sentence. A `/0` is glossed: "devices at 0.0.0.0/0" does not
  /// tell most people that it means every device.
  static func describe(_ entries: [String]) -> String {
    entries.map { entry in
      guard let prefix = try? NetworkExtensionRouteCIDR(entry), prefix.prefix == 0 else { return entry }
      return prefix.family == .ipv4
        ? String(format: String(localized: "any IPv4 address (%@)"), entry)
        : String(format: String(localized: "any IPv6 address (%@)"), entry)
    }
    .joined(separator: ", ")
  }
}

/// Pure, view-agnostic answer to "is this profile listening on ports other machines can reach?".
///
/// This is roadmap C3. The decision recorded there is that `listeners:` is supported at L3 — a
/// user reaches it through the Raw YAML snippet like any other Mihomo key (INV-2, §2.4: no bespoke
/// toggle for a key the generic override already reaches) — but that support comes with one
/// obligation the app cannot skip: exposure has to be *visible*. `allow-lan` does not gate these
/// inbounds, `GET /configs` does not report them, and the exposed bind is the default, so a
/// listener smuggled in by a subscription would otherwise be an invisible open door. Subscriptions
/// keep stripping the key; this reports what the applied config actually opened.
struct ListenerExposureSnapshot: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    /// Extra inbounds exist and every one is loopback-only.
    case pass
    /// Nothing to report — no extra inbounds, or nothing read yet.
    case info
    /// At least one inbound is reachable from the network.
    case warn
    /// Reachable from the network *and* usable without credentials: an open proxy, for everyone or
    /// for the sources `skip-auth-prefixes` exempts.
    case fail
  }

  enum Cause: String, Equatable, Sendable {
    case coreNotRunning
    case configurationUnknown
    case noListeners
    case loopbackOnly
    case lanExposed
    case openProxy
    /// An `authentication:` list is set, but `skip-auth-prefixes` exempts sources beyond this Mac.
    case authenticationSkipped
  }

  struct Fact: Equatable, Sendable {
    enum Key: String, Hashable, Sendable {
      case listener
      case exposure
      case authentication
      case allowLan
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
  /// The exposed entries, so a view can list them without re-deriving the filter.
  var exposedListeners: [RuntimeListener]

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
      "Inbound Listeners: \(statusLabel) (\(cause.rawValue))",
      "Reason: \(reason)",
    ]
    for fact in facts {
      lines.append("\(fact.title): \(fact.value)")
    }
    if !recoveryActions.isEmpty {
      lines.append("Recovery Actions:")
      lines.append(contentsOf: recoveryActions.map { "- \($0)" })
    }
    return lines
  }
}

struct ListenerExposureInput: Equatable, Sendable {
  var isCoreRunning: Bool
  /// `nil` while the applied runtime config has not been read back yet.
  var facts: ListenerRuntimeFacts?
  /// The app's own Allow LAN setting, reported only to say what it does *not* cover.
  var allowLan: Bool

  init(isCoreRunning: Bool = true, facts: ListenerRuntimeFacts? = nil, allowLan: Bool = false) {
    self.isCoreRunning = isCoreRunning
    self.facts = facts
    self.allowLan = allowLan
  }
}

enum ListenerExposureDiagnosticsBuilder {
  static func snapshot(for input: ListenerExposureInput) -> ListenerExposureSnapshot {
    guard input.isCoreRunning else {
      return ListenerExposureSnapshot(
        status: .info,
        cause: .coreNotRunning,
        headline: String(localized: "No inbound listeners"),
        reason: String(localized: "The core is not running, so nothing is listening."),
        facts: [],
        recoveryActions: [],
        exposedListeners: []
      )
    }

    guard let facts = input.facts else {
      return ListenerExposureSnapshot(
        status: .info,
        cause: .configurationUnknown,
        headline: String(localized: "Inbound listeners unknown"),
        reason: String(localized: "ClashMax has not read the applied config back yet, so it cannot say which extra inbounds the core opened."),
        facts: [],
        recoveryActions: [],
        exposedListeners: []
      )
    }

    guard !facts.listeners.isEmpty else {
      return ListenerExposureSnapshot(
        status: .info,
        cause: .noListeners,
        headline: String(localized: "No extra inbound listeners"),
        reason: String(localized: "The applied config defines no listeners block, so only the mixed port ClashMax manages is accepting connections."),
        facts: [],
        recoveryActions: [],
        exposedListeners: []
      )
    }

    var listenerFacts = facts.listeners.map { listener in
      ListenerExposureSnapshot.Fact(key: .listener, title: listener.name, value: listener.summary)
    }

    let exposed = facts.exposedListeners
    guard !exposed.isEmpty else {
      return ListenerExposureSnapshot(
        status: .pass,
        cause: .loopbackOnly,
        headline: String(
          format: String(localized: "%lld inbound listener(s), local only"),
          Int64(facts.listeners.count)
        ),
        reason: String(localized: "Every extra inbound is bound to loopback, so only apps on this Mac can use them."),
        facts: listenerFacts,
        recoveryActions: [],
        exposedListeners: []
      )
    }

    listenerFacts.append(.init(
      key: .exposure,
      title: String(localized: "Reachable From"),
      value: exposed.map { "\($0.name) (\($0.summary))" }.joined(separator: ", ")
    ))
    listenerFacts.append(.init(
      key: .allowLan,
      title: String(localized: "Allow LAN"),
      value: input.allowLan
        ? String(localized: "On — and it does not gate these listeners either way")
        : String(localized: "Off — which does not close these listeners; it only covers the mixed port")
    ))
    let exempted = SkipAuthPrefixes.describe(facts.skipAuthPrefixesBeyondThisMac)
    let authentication = if !facts.hasInboundAuthentication {
      String(localized: "None — anyone who can reach the port can use the proxy")
    } else if facts.requiresCredentialsFromOtherMachines {
      String(localized: "Set — clients must send credentials")
    } else {
      String(format: String(localized: "Set — but skip-auth-prefixes lets %@ in without credentials"), exempted)
    }
    listenerFacts.append(.init(
      key: .authentication,
      title: String(localized: "Inbound Authentication"),
      value: authentication
    ))

    let exposureRecovery = [
      String(localized: "If this was not intended, set listen: 127.0.0.1 on the entry in your Raw YAML snippet, or remove the listeners block."),
      String(localized: "Leaving listen out binds every interface, so the address has to be written explicitly to keep an inbound local."),
    ]

    guard facts.hasInboundAuthentication else {
      return ListenerExposureSnapshot(
        status: .fail,
        cause: .openProxy,
        headline: String(localized: "Open proxy on your network"),
        reason: String(
          format: String(localized: "%lld inbound listener(s) accept connections from other machines and require no credentials. Anyone who can reach this Mac can route traffic through your proxy."),
          Int64(exposed.count)
        ),
        facts: listenerFacts,
        recoveryActions: [String(localized: "Add an authentication list to the config so these inbounds require a user and password.")] + exposureRecovery,
        exposedListeners: exposed
      )
    }

    // The list is set, but an exemption past loopback is the same open door for the devices it
    // covers (measured: `0.0.0.0/0` let a LAN source through with no credentials), so it is never
    // reported as "requires credentials".
    guard facts.requiresCredentialsFromOtherMachines else {
      return ListenerExposureSnapshot(
        status: .fail,
        cause: .authenticationSkipped,
        headline: String(format: String(localized: "Open proxy for %@"), exempted),
        reason: String(
          format: String(localized: "%lld inbound listener(s) accept connections from other machines. They ask for credentials, but skip-auth-prefixes lets devices at %@ use your proxy without them."),
          Int64(exposed.count),
          exempted
        ),
        facts: listenerFacts,
        recoveryActions: [
          String(
            format: String(localized: "Remove %@ from skip-auth-prefixes so other machines have to send credentials. A Raw YAML snippet that sets skip-auth-prefixes replaces a subscription's list, and ClashMax keeps apps on this Mac exempt on its own."),
            facts.skipAuthPrefixesBeyondThisMac.joined(separator: ", ")
          ),
        ] + exposureRecovery,
        exposedListeners: exposed
      )
    }

    return ListenerExposureSnapshot(
      status: .warn,
      cause: .lanExposed,
      headline: String(
        format: String(localized: "%lld inbound listener(s) reachable from your network"),
        Int64(exposed.count)
      ),
      reason: String(localized: "These inbounds are bound to a non-loopback address, so other machines can connect. They ask for credentials, and Allow LAN does not close them."),
      facts: listenerFacts,
      recoveryActions: exposureRecovery,
      exposedListeners: exposed
    )
  }
}
