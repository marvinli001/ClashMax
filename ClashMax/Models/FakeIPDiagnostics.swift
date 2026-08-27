import Foundation

/// Pure, view-agnostic answer to "are my fake-ip mappings still trustworthy, and can ClashMax do
/// anything about it?".
///
/// This is roadmap A3. In fake-ip mode the core answers every DNS query with a synthetic address
/// out of `fake-ip-range` and remembers the address → domain mapping. The mapping is what lets a
/// domain rule fire on a connection that only ever carried an IP, so it is load-bearing — and it
/// survives events that invalidate it. Joining another network, or replacing the node list under a
/// subscription update, leaves entries that still point at the old answer, and the only remedy the
/// app previously offered was restarting the core.
///
/// `POST /cache/fakeip/flush` drops the whole table, which is cheap and safe: the next query
/// re-allocates. The endpoint answers 204 whether or not the core is in fake-ip mode, so the core's
/// reply cannot be used to decide whether the action is meaningful — that decision is made here,
/// from the `dns:` block of the runtime config the core was actually handed.
///
/// Deliberately a value-in/value-out builder like `SnifferDiagnosticsBuilder` and
/// `ProxyEffectDiagnosticsBuilder`: every branch is reachable from a test without a running core.
struct FakeIPDiagnosticsSnapshot: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    /// Fake-ip is running and nothing has happened that would invalidate the table.
    case pass
    /// Fake-ip is not in play, so there is nothing to keep fresh.
    case info
    /// Fake-ip is running and something has happened since the table was last known good.
    case warn
  }

  /// Stable, locale-independent classification so views pick icons and tests assert the branch
  /// rather than localized copy.
  enum Cause: String, Equatable, Sendable {
    case coreNotRunning
    case configurationUnknown
    case dnsDisabled
    case notFakeIPMode
    case networkChanged
    case profileReloaded
    case fresh
  }

  struct Fact: Equatable, Sendable {
    enum Key: String, Hashable, Sendable {
      case enhancedMode
      case fakeIPRange
      case lastFlush
      case lastInvalidation
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
  /// Whether flushing would do anything. False for every cause where the core holds no fake-ip
  /// table, so the action is offered disabled with `reason` as the explanation rather than hidden —
  /// a hidden control cannot explain why it is not there.
  var canFlush: Bool

  /// Stable English label used inside the copyable diagnostics report.
  var statusLabel: String {
    switch status {
    case .pass: return "Pass"
    case .info: return "Info"
    case .warn: return "Warn"
    }
  }

  var plainTextLines: [String] {
    var lines = [
      "Fake IP: \(statusLabel) (\(cause.rawValue))",
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

struct FakeIPDiagnosticsInput: Equatable, Sendable {
  var isCoreRunning: Bool
  /// `nil` while the applied runtime config has not been read back yet. Reported as "unknown"
  /// rather than collapsed into "not fake-ip", which would be a guess.
  var dnsFacts: DNSRuntimeFacts?
  /// When the core last came up or hot-reloaded a config — the moment its fake-ip table was empty
  /// and therefore known good.
  var runtimeAppliedAt: Date?
  /// When ClashMax last flushed the table itself.
  var lastFlushAt: Date?
  /// When the network path or Wi-Fi network last changed.
  var networkChangedAt: Date?
  /// When the active profile's node list was last replaced by a subscription update.
  var profileUpdatedAt: Date?

  init(
    isCoreRunning: Bool = true,
    dnsFacts: DNSRuntimeFacts? = nil,
    runtimeAppliedAt: Date? = nil,
    lastFlushAt: Date? = nil,
    networkChangedAt: Date? = nil,
    profileUpdatedAt: Date? = nil
  ) {
    self.isCoreRunning = isCoreRunning
    self.dnsFacts = dnsFacts
    self.runtimeAppliedAt = runtimeAppliedAt
    self.lastFlushAt = lastFlushAt
    self.networkChangedAt = networkChangedAt
    self.profileUpdatedAt = profileUpdatedAt
  }
}

enum FakeIPDiagnosticsBuilder {
  static func snapshot(for input: FakeIPDiagnosticsInput, now: Date = Date()) -> FakeIPDiagnosticsSnapshot {
    guard input.isCoreRunning else {
      return FakeIPDiagnosticsSnapshot(
        status: .info,
        cause: .coreNotRunning,
        headline: String(localized: "No fake-ip table"),
        reason: String(localized: "The core is not running, so there is no fake-ip table to flush."),
        facts: [],
        recoveryActions: [],
        canFlush: false
      )
    }

    guard let dnsFacts = input.dnsFacts else {
      return FakeIPDiagnosticsSnapshot(
        status: .info,
        cause: .configurationUnknown,
        headline: String(localized: "Fake IP unknown"),
        reason: String(localized: "ClashMax has not read the applied config back yet, so it cannot tell whether the core is in fake-ip mode."),
        facts: [],
        recoveryActions: [String(localized: "Refresh the runtime diagnostics once the core has finished starting.")],
        canFlush: false
      )
    }

    // `dns.enable` defaults to false in Mihomo, so an absent key means DNS is off — the same
    // reading `DNSOverridePlanBuilder` uses for issue #16's "inert override" verdict.
    guard dnsFacts.enable == true else {
      return FakeIPDiagnosticsSnapshot(
        status: .info,
        cause: .dnsDisabled,
        headline: String(localized: "DNS is off"),
        reason: String(localized: "The core is not running a DNS server, so it allocates no fake-ip addresses."),
        facts: [],
        recoveryActions: [String(localized: "Enable DNS in Settings, or turn on TUN or NE Proxy, if you want rules to match on domains.")],
        canFlush: false
      )
    }

    guard dnsFacts.isFakeIPMode else {
      let mode = dnsFacts.values[.enhancedMode] ?? "normal"
      return FakeIPDiagnosticsSnapshot(
        status: .info,
        cause: .notFakeIPMode,
        headline: String(localized: "Not in fake-ip mode"),
        reason: String(
          format: String(localized: "DNS enhanced-mode is %@, so the core returns real addresses and keeps no fake-ip table."),
          mode
        ),
        facts: [FakeIPDiagnosticsSnapshot.Fact(
          key: .enhancedMode,
          title: String(localized: "Enhanced Mode"),
          value: mode
        )],
        recoveryActions: [String(localized: "Turn on Fake IP DNS in TUN or NE Proxy settings to use fake-ip.")],
        canFlush: false
      )
    }

    var facts = [
      FakeIPDiagnosticsSnapshot.Fact(
        key: .enhancedMode,
        title: String(localized: "Enhanced Mode"),
        value: "fake-ip"
      ),
    ]
    if let range = dnsFacts.values[.fakeIPRange], !range.isEmpty {
      facts.append(FakeIPDiagnosticsSnapshot.Fact(
        key: .fakeIPRange,
        title: String(localized: "Fake IP Range"),
        value: range
      ))
    }

    // The table is known good from the later of "the core started with an empty one" and "we
    // emptied it ourselves". Anything after that moment can have left entries pointing at answers
    // that are no longer right.
    let knownGoodAt = [input.runtimeAppliedAt, input.lastFlushAt].compactMap(\.self).max()
    if let lastFlushAt = input.lastFlushAt {
      facts.append(FakeIPDiagnosticsSnapshot.Fact(
        key: .lastFlush,
        title: String(localized: "Last Flush"),
        value: Self.relativeDescription(for: lastFlushAt, now: now)
      ))
    }

    func isInvalidating(_ date: Date?) -> Date? {
      guard let date else { return nil }
      guard let knownGoodAt else { return date }
      return date > knownGoodAt ? date : nil
    }

    if let profileUpdatedAt = isInvalidating(input.profileUpdatedAt) {
      facts.append(FakeIPDiagnosticsSnapshot.Fact(
        key: .lastInvalidation,
        title: String(localized: "Profile Updated"),
        value: Self.relativeDescription(for: profileUpdatedAt, now: now)
      ))
      return FakeIPDiagnosticsSnapshot(
        status: .warn,
        cause: .profileReloaded,
        headline: String(localized: "Fake-ip mappings may be stale"),
        reason: String(localized: "The profile changed after the fake-ip table was last emptied, so entries can still point at nodes and answers from the previous version."),
        facts: facts,
        recoveryActions: [String(localized: "Flush the fake-ip cache; the next query re-allocates from the current config.")],
        canFlush: true
      )
    }

    if let networkChangedAt = isInvalidating(input.networkChangedAt) {
      facts.append(FakeIPDiagnosticsSnapshot.Fact(
        key: .lastInvalidation,
        title: String(localized: "Network Changed"),
        value: Self.relativeDescription(for: networkChangedAt, now: now)
      ))
      return FakeIPDiagnosticsSnapshot(
        status: .warn,
        cause: .networkChanged,
        headline: String(localized: "Fake-ip mappings may be stale"),
        reason: String(localized: "The network changed after the fake-ip table was last emptied, so entries can still carry answers from the previous network — including a captive portal's."),
        facts: facts,
        recoveryActions: [String(localized: "Flush the fake-ip cache; the next query re-allocates on this network.")],
        canFlush: true
      )
    }

    return FakeIPDiagnosticsSnapshot(
      status: .pass,
      cause: .fresh,
      headline: String(localized: "Fake IP is active"),
      reason: String(localized: "Nothing has changed the network or the profile since the fake-ip table was last emptied."),
      facts: facts,
      recoveryActions: [],
      canFlush: true
    )
  }

  /// Relative wording keeps the fact readable at a glance; the copyable report inherits it, which is
  /// the right trade for a value nobody correlates against an absolute clock.
  private static func relativeDescription(for date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }
}
