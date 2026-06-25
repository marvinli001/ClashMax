import Foundation

/// Pure, view-agnostic classification of "is the proxy actually taking over outbound traffic?".
///
/// This answers issue #13: the runtime can report "running" while the public IP still resolves to
/// China because the system proxy is off, TUN/NE is inactive, the run mode is Direct, the selected
/// node is DIRECT, or a rule routes the IP-check host to DIRECT. The builder distinguishes those
/// cases instead of collapsing them into a single vague status, and produces copyable diagnostics.
struct ProxyEffectDiagnosticsSnapshot: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case waiting
    case pass
    case warn
    case fail
  }

  /// Stable, locale-independent classification so views can pick icons/tints and tests can assert
  /// the chosen category without depending on localized copy.
  enum Cause: String, Equatable, Sendable {
    case notRunning
    case waitingForPublicIP
    case systemProxyDisabled
    case tunInactive
    case tunDegraded
    case networkExtensionInactive
    case networkExtensionDegraded
    case directRunMode
    case selectionUnavailable
    case currentNodeDirect
    case ruleTargetDirect
    case publicIPChina
    case proxyConfirmed
  }

  struct Fact: Equatable, Sendable {
    var title: String
    var value: String

    init(title: String, value: String) {
      self.title = title
      self.value = value
    }
  }

  var status: Status
  var cause: Cause
  var headline: String
  var reason: String
  var facts: [Fact]
  var recoveryActions: [String]
  var probeHost: String
  var currentNodeSummary: String
  var probePolicy: String?
  var ruleProbeSummary: String
  var publicIPRegion: String

  /// Stable English label used inside the shared (copyable) diagnostics report.
  var statusLabel: String {
    switch status {
    case .waiting: return "Waiting"
    case .pass: return "Pass"
    case .warn: return "Warn"
    case .fail: return "Fail"
    }
  }

  /// Proxy-effect block for the copyable Runtime Diagnostics report. Labels are kept in stable
  /// English to match the rest of `RuntimeDiagnosticsReport`.
  var plainTextLines: [String] {
    var lines = [
      "Proxy Effect: \(statusLabel) - \(reason)",
      "Probe Host: \(probeHost.isEmpty ? "—" : probeHost)",
      "Current Node: \(currentNodeSummary)",
      "Rule Policy: \(probePolicy ?? "—")",
      "Rule Probe: \(ruleProbeSummary)",
      "Public IP Region: \(publicIPRegion)",
    ]
    if !recoveryActions.isEmpty {
      lines.append("Recovery Actions:")
      lines.append(contentsOf: recoveryActions.map { "- \($0)" })
    }
    return lines
  }
}

struct ProxyEffectDiagnosticsInput: Equatable, Sendable {
  /// The default GeoIP probe host used to simulate routing when no live public-IP result is
  /// available yet (matches the first default provider, `api.ip.sb`).
  static let defaultProbeHost = "api.ip.sb"

  var publicIPInfo: PublicIPInfo?
  var isCoreRunning: Bool
  var routingMode: ProxyRoutingMode
  var runMode: RunMode
  var systemProxyEnabled: Bool
  var tunEnabled: Bool
  var networkExtensionEnabled: Bool
  var tunDiagnostics: TunDiagnosticsSnapshot
  var networkExtensionDiagnostics: NetworkExtensionDiagnosticsSnapshot
  var currentGroupName: String?
  var currentNodeName: String?
  var currentNodeType: String?
  var hasMissingSelection: Bool
  var runtimeRules: [RuntimeRule]
  var probeHost: String

  init(
    publicIPInfo: PublicIPInfo? = nil,
    isCoreRunning: Bool = true,
    routingMode: ProxyRoutingMode = .systemProxy,
    runMode: RunMode = .rule,
    systemProxyEnabled: Bool = true,
    tunEnabled: Bool = false,
    networkExtensionEnabled: Bool = false,
    tunDiagnostics: TunDiagnosticsSnapshot = .empty,
    networkExtensionDiagnostics: NetworkExtensionDiagnosticsSnapshot = .empty,
    currentGroupName: String? = nil,
    currentNodeName: String? = nil,
    currentNodeType: String? = nil,
    hasMissingSelection: Bool = false,
    runtimeRules: [RuntimeRule] = [],
    probeHost: String = ProxyEffectDiagnosticsInput.defaultProbeHost
  ) {
    self.publicIPInfo = publicIPInfo
    self.isCoreRunning = isCoreRunning
    self.routingMode = routingMode
    self.runMode = runMode
    self.systemProxyEnabled = systemProxyEnabled
    self.tunEnabled = tunEnabled
    self.networkExtensionEnabled = networkExtensionEnabled
    self.tunDiagnostics = tunDiagnostics
    self.networkExtensionDiagnostics = networkExtensionDiagnostics
    self.currentGroupName = currentGroupName
    self.currentNodeName = currentNodeName
    self.currentNodeType = currentNodeType
    self.hasMissingSelection = hasMissingSelection
    self.runtimeRules = runtimeRules
    self.probeHost = probeHost
  }
}

enum ProxyEffectDiagnosticsBuilder {
  static func build(_ input: ProxyEffectDiagnosticsInput) -> ProxyEffectDiagnosticsSnapshot {
    let probeHost = input.probeHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let trace = ruleProbe(host: probeHost, rules: input.runtimeRules)
    let probePolicy = trace.policy?.trimmingCharacters(in: .whitespacesAndNewlines).normalizedNonEmpty
    let ruleSummary = ruleProbeSummary(trace: trace)
    let region = regionLabel(for: input.publicIPInfo)
    let nodeSummary = currentNodeSummary(input: input)

    func make(
      status: ProxyEffectDiagnosticsSnapshot.Status,
      cause: ProxyEffectDiagnosticsSnapshot.Cause,
      headline: String,
      reason: String,
      recovery: [String],
      extraFacts: [ProxyEffectDiagnosticsSnapshot.Fact] = []
    ) -> ProxyEffectDiagnosticsSnapshot {
      ProxyEffectDiagnosticsSnapshot(
        status: status,
        cause: cause,
        headline: headline,
        reason: reason,
        facts: facts(
          input: input,
          probePolicy: probePolicy,
          region: region,
          nodeSummary: nodeSummary,
          extra: extraFacts
        ),
        recoveryActions: recovery,
        probeHost: probeHost,
        currentNodeSummary: nodeSummary,
        probePolicy: probePolicy,
        ruleProbeSummary: ruleSummary,
        publicIPRegion: region
      )
    }

    // 1. Runtime not running — never report success.
    guard input.isCoreRunning else {
      return make(
        status: .waiting,
        cause: .notRunning,
        headline: String(localized: "Runtime is not running"),
        reason: String(localized: "Start ClashMax to verify whether the proxy handles outbound traffic."),
        recovery: []
      )
    }

    // 2. Capture path not enabled for the selected routing mode.
    switch input.routingMode {
    case .systemProxy where !input.systemProxyEnabled:
      return make(
        status: .fail,
        cause: .systemProxyDisabled,
        headline: String(localized: "Proxy is not capturing traffic"),
        reason: String(localized: "System Proxy is not enabled for this runtime mode."),
        recovery: [String(localized: "Enable System Proxy, or switch to TUN mode.")]
      )
    case .tun where !input.tunEnabled:
      return make(
        status: .fail,
        cause: .tunInactive,
        headline: String(localized: "Proxy is not capturing traffic"),
        reason: String(localized: "TUN mode is selected but the TUN helper is not active."),
        recovery: [String(localized: "Start TUN mode and approve the helper, or switch to System Proxy.")]
      )
    case .neProxy where !input.networkExtensionEnabled:
      return make(
        status: .fail,
        cause: .networkExtensionInactive,
        headline: String(localized: "Proxy is not capturing traffic"),
        reason: String(localized: "Network Extension proxy is not active."),
        recovery: [String(localized: "Enable the Network Extension proxy, or switch to System Proxy or TUN.")]
      )
    default:
      break
    }

    // 3. Capture is enabled but the transport is degraded.
    if input.routingMode == .tun, input.tunEnabled, let issue = input.tunDiagnostics.primaryIssue {
      return make(
        status: .warn,
        cause: .tunDegraded,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(format: String(localized: "TUN diagnostics reported an issue: %@"), issue.message),
        recovery: [String(localized: "Open TUN Diagnostics and run repair if needed.")],
        extraFacts: [.init(title: String(localized: "TUN Issue"), value: issue.message)]
      )
    }
    if input.routingMode == .neProxy,
       input.networkExtensionEnabled,
       let neIssue = networkExtensionIssue(input.networkExtensionDiagnostics) {
      return make(
        status: .warn,
        cause: .networkExtensionDegraded,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(format: String(localized: "Network Extension reported an issue: %@"), neIssue),
        recovery: [String(localized: "Open NE Diagnostics to review transparent proxy errors.")],
        extraFacts: [.init(title: String(localized: "NE Issue"), value: neIssue)]
      )
    }

    // 4. Direct run mode bypasses every proxy.
    if input.runMode == .direct {
      return make(
        status: .warn,
        cause: .directRunMode,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(localized: "Run mode is Direct, so all traffic bypasses proxies."),
        recovery: [String(localized: "Switch run mode to Rule or Global.")]
      )
    }

    // 5. The selected node is not present in runtime data (issue #14 territory).
    if input.hasMissingSelection {
      return make(
        status: .warn,
        cause: .selectionUnavailable,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(localized: "The selected node is unavailable in runtime data, so the proxy node cannot be confirmed."),
        recovery: [String(localized: "Refresh runtime data to reload the selected node.")]
      )
    }

    // 6. The active node is DIRECT.
    if isDirect(input.currentNodeName) || isDirect(input.currentNodeType) {
      return make(
        status: .warn,
        cause: .currentNodeDirect,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(localized: "Current node is DIRECT."),
        recovery: [String(localized: "Select a non-DIRECT node in the active proxy group.")]
      )
    }

    // 7. A rule sends the GeoIP probe host to DIRECT — the IP check bypasses the proxy even if other
    //    traffic does not.
    if isDirect(probePolicy) {
      return make(
        status: .warn,
        cause: .ruleTargetDirect,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(localized: "IP check target matched a DIRECT rule."),
        recovery: [String(localized: "Review rules that send the IP-check host to DIRECT.")],
        extraFacts: [.init(title: String(localized: "Matched Rule"), value: trace.ruleSummary)]
      )
    }

    // 8. Public IP outcome.
    guard let info = input.publicIPInfo else {
      return make(
        status: .waiting,
        cause: .waitingForPublicIP,
        headline: String(localized: "Checking proxy effect"),
        reason: String(localized: "Waiting for public IP information from the GeoIP probe."),
        recovery: []
      )
    }

    if isChina(info) {
      return make(
        status: .warn,
        cause: .publicIPChina,
        headline: String(localized: "Proxy capture is not confirmed"),
        reason: String(localized: "Public IP is still China; if you selected a non-China node, proxy capture is not confirmed."),
        recovery: [String(localized: "Confirm the selected node is a non-China server and test its delay.")]
      )
    }

    return make(
      status: .pass,
      cause: .proxyConfirmed,
      headline: String(localized: "Proxy is handling outbound traffic"),
      reason: String(localized: "Public IP egress matches a proxied path."),
      recovery: []
    )
  }

  // MARK: - Facts

  private static func facts(
    input: ProxyEffectDiagnosticsInput,
    probePolicy: String?,
    region: String,
    nodeSummary: String,
    extra: [ProxyEffectDiagnosticsSnapshot.Fact]
  ) -> [ProxyEffectDiagnosticsSnapshot.Fact] {
    var facts: [ProxyEffectDiagnosticsSnapshot.Fact] = [
      .init(title: String(localized: "Routing"), value: input.routingMode.displayName),
      .init(title: String(localized: "Run Mode"), value: input.runMode.displayName),
      .init(title: String(localized: "Current Node"), value: nodeSummary),
      .init(title: String(localized: "Rule Policy"), value: probePolicy ?? "—"),
    ]
    facts.append(contentsOf: extra)
    return facts
  }

  // MARK: - Rule probe

  private static func ruleProbe(host: String, rules: [RuntimeRule]) -> RuleMatchSimulationTrace {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, !rules.isEmpty else { return .noMatch }
    let candidates = RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: rules)
    return RuleMatchSimulator().simulate(
      input: RuleMatchSimulationInput(destination: host, destinationPort: "443"),
      candidates: candidates
    )
  }

  private static func ruleProbeSummary(trace: RuleMatchSimulationTrace) -> String {
    switch trace.outcome {
    case let .matched(rule):
      return rule.raw
    case .mihomoOnly:
      return trace.title
    case .noMatch:
      return String(localized: "No local match")
    }
  }

  // MARK: - Classification helpers

  private static func isDirect(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return false
    }
    return value.caseInsensitiveCompare("DIRECT") == .orderedSame
  }

  private static func isChina(_ info: PublicIPInfo) -> Bool {
    if let code = info.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
      return code.caseInsensitiveCompare("CN") == .orderedSame
    }
    if let name = info.countryName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return name.caseInsensitiveCompare("China") == .orderedSame
    }
    return false
  }

  private static func regionLabel(for info: PublicIPInfo?) -> String {
    guard let info else { return String(localized: "Unavailable") }
    let name = info.countryName?.trimmingCharacters(in: .whitespacesAndNewlines).normalizedNonEmpty
    let code = info.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).normalizedNonEmpty
    switch (name, code) {
    case let (name?, code?):
      return "\(name) (\(code))"
    case let (name?, nil):
      return name
    case let (nil, code?):
      return code
    default:
      return String(localized: "Unknown")
    }
  }

  private static func currentNodeSummary(input: ProxyEffectDiagnosticsInput) -> String {
    let name = input.currentNodeName?.trimmingCharacters(in: .whitespacesAndNewlines).normalizedNonEmpty
    let group = input.currentGroupName?.trimmingCharacters(in: .whitespacesAndNewlines).normalizedNonEmpty

    guard let name else {
      if input.hasMissingSelection, let group {
        return String(format: String(localized: "Unavailable (%@)"), group)
      }
      return String(localized: "Unavailable")
    }
    if let group {
      return "\(group) / \(name)"
    }
    return name
  }

  private static func networkExtensionIssue(_ diagnostics: NetworkExtensionDiagnosticsSnapshot) -> String? {
    if let last = diagnostics.recentErrors.last {
      return last.message
    }
    if diagnostics.socksHandshakeFailureCount > 0 {
      return String(
        format: String(localized: "SOCKS handshake failures: %lld"),
        Int64(diagnostics.socksHandshakeFailureCount)
      )
    }
    return nil
  }
}

private extension String {
  var normalizedNonEmpty: String? {
    isEmpty ? nil : self
  }
}
