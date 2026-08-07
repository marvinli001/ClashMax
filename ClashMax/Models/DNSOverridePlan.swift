import Foundation

/// Pure, view-agnostic answer to "is the app-managed DNS override actually in effect, which keys
/// does it change, and will Mihomo accept it?".
///
/// This answers issue #16. Rule editing and DNS configuration used to be unrelated surfaces: a DNS
/// Patch snippet wrote `dns:` keys into the generated runtime YAML, but nothing set `dns.enable`, so
/// with TUN off and the global DNS toggle untouched Mihomo started no DNS server and ignored every
/// key. The diff and the final YAML both showed the override; only the core disagreed.
///
/// The plan is built by diffing the DNS mapping of the *original* profile against the DNS mapping of
/// the *final* generated runtime YAML, so "overridden fields" is what Mihomo will really read rather
/// than what the app intended to write. The original profile on disk is never modified.
struct DNSOverridePlan: Equatable, Sendable {
  /// Why DNS is (or is not) running, in the order the generator decides it.
  enum Enablement: String, Equatable, Sendable {
    /// The profile's own `dns.enable: true` already turned DNS on.
    case profile
    /// Settings › Enable DNS Override.
    case globalToggle
    /// TUN is on and contributes DNS (fake-ip or a TUN DNS overlay).
    case tun
    /// The NE proxy captures DNS or runs fake-ip.
    case networkExtension
    /// The profile is raw subscription content, so the generated provider template authors DNS.
    case providerTemplate
    /// A typed DNS override is present, so the generator turned DNS on for it.
    case overrideAutoEnabled
    /// The user explicitly turned Enable DNS Override off; overrides stay written but inert.
    case disabledByUser
    /// Nothing enables DNS.
    case none

    var isEnabled: Bool {
      switch self {
      case .profile, .globalToggle, .tun, .networkExtension, .providerTemplate, .overrideAutoEnabled:
        return true
      case .disabledByUser, .none:
        return false
      }
    }

    var displayName: String {
      switch self {
      case .profile:
        return String(localized: "Profile DNS is enabled")
      case .globalToggle:
        return String(localized: "Enabled by DNS Override setting")
      case .tun:
        return String(localized: "Enabled by TUN")
      case .networkExtension:
        return String(localized: "Enabled by NE Proxy")
      case .providerTemplate:
        return String(localized: "Enabled by the subscription template")
      case .overrideAutoEnabled:
        return String(localized: "Enabled for the DNS override")
      case .disabledByUser:
        return String(localized: "DNS Override setting is off")
      case .none:
        return String(localized: "DNS is not enabled")
      }
    }
  }

  /// Stable, locale-independent identity for each issue so views pick tints and tests assert the
  /// category rather than localized copy.
  enum IssueCode: String, Equatable, Sendable {
    /// Mihomo refuses to start: `respect-rules` without `proxy-server-nameserver`. Mihomo checks
    /// this even when `dns.enable` is false, so it breaks the whole core, not just DNS.
    case respectRulesWithoutProxyServerNameserver
    /// Keys are written but DNS is off, so Mihomo ignores all of them.
    case overrideInert
    /// `respect-rules` is on, which is what makes DNS resolution follow the custom rules.
    case respectRulesFollowsRules
    /// Fake-ip filters are set but the enhanced mode is not fake-ip.
    case fakeIPFilterWithoutFakeIPMode
  }

  struct Issue: Equatable, Sendable, Identifiable {
    var code: IssueCode
    var message: String
    /// Blocking issues stop config generation; the rest are advisory.
    var isBlocking: Bool

    var id: String { code.rawValue }

    init(code: IssueCode, message: String, isBlocking: Bool) {
      self.code = code
      self.message = message
      self.isBlocking = isBlocking
    }
  }

  var enablement: Enablement
  /// Keys whose effective value differs from the original profile, as written in the final YAML.
  var overriddenFields: [DNSOverrideField]
  /// Human-readable names of the layers that contributed DNS keys (snippets, TUN, NE, …).
  var contributors: [String]
  var issues: [Issue]

  static let inactive = DNSOverridePlan(
    enablement: .none,
    overriddenFields: [],
    contributors: [],
    issues: []
  )

  var isEnabled: Bool { enablement.isEnabled }

  var hasOverride: Bool { !overriddenFields.isEmpty }

  var blockingIssues: [Issue] { issues.filter(\.isBlocking) }

  /// True when the app writes DNS keys that Mihomo will silently ignore.
  var isInert: Bool { hasOverride && !isEnabled }

  var summary: String {
    guard hasOverride else {
      return String(localized: "No app-managed DNS override.")
    }
    let fieldCount = String(
      format: String(localized: "%lld DNS keys overridden"),
      Int64(overriddenFields.count)
    )
    if isInert {
      return String(
        format: String(localized: "%@, but DNS is off so Mihomo ignores them."),
        fieldCount
      )
    }
    return fieldCount
  }

  var overriddenFieldNames: [String] {
    overriddenFields.map(\.yamlKey)
  }

  /// Stable-English block for the copyable Runtime Diagnostics report.
  var plainTextLines: [String] {
    var lines = [
      "DNS Override: \(hasOverride ? "Active" : "None")",
      "DNS Enabled: \(isEnabled ? "yes" : "no") (\(enablement.rawValue))"
    ]
    if !overriddenFields.isEmpty {
      lines.append("Overridden Keys: \(overriddenFieldNames.joined(separator: ", "))")
    }
    if !contributors.isEmpty {
      lines.append("Contributors: \(contributors.joined(separator: ", "))")
    }
    for issue in issues {
      lines.append("\(issue.isBlocking ? "Blocking" : "Note") [\(issue.code.rawValue)]: \(issue.message)")
    }
    return lines
  }
}

/// The `dns:` keys ClashMax can write from its typed override layers.
enum DNSOverrideField: String, CaseIterable, Equatable, Sendable {
  case enable
  case listen
  case ipv6
  case enhancedMode
  case fakeIPRange
  case fakeIPFilter
  case preferH3
  case useHosts
  case useSystemHosts
  case respectRules
  case defaultNameserver
  case nameserver
  case fallback
  case proxyServerNameserver
  case directNameserver
  case directNameserverFollowPolicy
  case nameserverPolicy
  case proxyServerNameserverPolicy
  case hosts
  case fallbackFilter

  var yamlKey: String {
    switch self {
    case .enable: return "enable"
    case .listen: return "listen"
    case .ipv6: return "ipv6"
    case .enhancedMode: return "enhanced-mode"
    case .fakeIPRange: return "fake-ip-range"
    case .fakeIPFilter: return "fake-ip-filter"
    case .preferH3: return "prefer-h3"
    case .useHosts: return "use-hosts"
    case .useSystemHosts: return "use-system-hosts"
    case .respectRules: return "respect-rules"
    case .defaultNameserver: return "default-nameserver"
    case .nameserver: return "nameserver"
    case .fallback: return "fallback"
    case .proxyServerNameserver: return "proxy-server-nameserver"
    case .directNameserver: return "direct-nameserver"
    case .directNameserverFollowPolicy: return "direct-nameserver-follow-policy"
    case .nameserverPolicy: return "nameserver-policy"
    case .proxyServerNameserverPolicy: return "proxy-server-nameserver-policy"
    case .hosts: return "hosts"
    case .fallbackFilter: return "fallback-filter"
    }
  }
}

/// The subset of a Mihomo `dns:` mapping the plan reasons about, flattened into a comparable and
/// `Sendable` shape so the builder stays pure and testable.
struct DNSRuntimeFacts: Equatable, Sendable {
  /// Whether a `dns:` mapping existed at all. An absent mapping and an empty one differ: the first
  /// means the profile said nothing about DNS.
  var isPresent: Bool
  /// Comparable rendering of every field the app can write, keyed by field.
  var values: [DNSOverrideField: String]

  static let absent = DNSRuntimeFacts(isPresent: false, values: [:])

  init(isPresent: Bool, values: [DNSOverrideField: String]) {
    self.isPresent = isPresent
    self.values = values
  }

  var enable: Bool? {
    values[.enable].map { $0 == "true" }
  }

  var respectRules: Bool {
    values[.respectRules] == "true"
  }

  var hasProxyServerNameserver: Bool {
    !(values[.proxyServerNameserver] ?? "").isEmpty
  }

  var isFakeIPMode: Bool {
    values[.enhancedMode] == "fake-ip"
  }

  var hasFakeIPFilter: Bool {
    !(values[.fakeIPFilter] ?? "").isEmpty
  }

  /// Flattens a decoded YAML `dns:` mapping. Values are rendered as stable strings purely so two
  /// mappings can be compared field by field; the rendering is never written back to YAML.
  static func facts(from dns: Any?) -> DNSRuntimeFacts {
    guard let mapping = dns as? [String: Any] else { return .absent }
    var values: [DNSOverrideField: String] = [:]
    for field in DNSOverrideField.allCases {
      guard let raw = mapping[field.yamlKey] else { continue }
      let rendered = render(raw)
      guard !rendered.isEmpty else { continue }
      values[field] = rendered
    }
    return DNSRuntimeFacts(isPresent: true, values: values)
  }

  private static func render(_ value: Any) -> String {
    switch value {
    case let value as Bool:
      return value ? "true" : "false"
    case let value as String:
      return value
    case let values as [Any]:
      return values.map { render($0) }.filter { !$0.isEmpty }.joined(separator: ",")
    case let mapping as [String: Any]:
      return mapping.keys.sorted()
        .map { "\($0)=\(render(mapping[$0] ?? ""))" }
        .joined(separator: ",")
    default:
      return String(describing: value)
    }
  }
}

/// Which app layers asked for DNS changes, so the plan can name them and explain the enablement.
struct DNSOverrideSources: Equatable, Sendable {
  /// Settings › Enable DNS Override. `nil` means "leave the profile alone".
  var globalDNSEnabled: Bool?
  var tunEnabled: Bool
  var tunContributesDNS: Bool
  var networkExtensionContributesDNS: Bool
  /// The profile is raw subscription content and the generated template authors its whole `dns:`
  /// block. Without this the baseline looks DNS-less and every template key reads as a user override.
  var providerTemplateContributesDNS: Bool
  /// Display names of enabled DNS Patch snippets that apply to this profile.
  var dnsPatchSnippetNames: [String]

  init(
    globalDNSEnabled: Bool? = nil,
    tunEnabled: Bool = false,
    tunContributesDNS: Bool = false,
    networkExtensionContributesDNS: Bool = false,
    providerTemplateContributesDNS: Bool = false,
    dnsPatchSnippetNames: [String] = []
  ) {
    self.globalDNSEnabled = globalDNSEnabled
    self.tunEnabled = tunEnabled
    self.tunContributesDNS = tunContributesDNS
    self.networkExtensionContributesDNS = networkExtensionContributesDNS
    self.providerTemplateContributesDNS = providerTemplateContributesDNS
    self.dnsPatchSnippetNames = dnsPatchSnippetNames
  }
}

enum DNSOverridePlanBuilder {
  /// Message Mihomo itself prints when `respect-rules` has no `proxy-server-nameserver`. Kept close
  /// to the core's wording so a user searching the error finds the same explanation.
  static let respectRulesRequirement = String(
    localized: "DNS \"respect-rules\" requires at least one \"proxy-server-nameserver\" resolver, otherwise Mihomo refuses to start."
  )

  static func plan(
    baseline: DNSRuntimeFacts,
    final: DNSRuntimeFacts,
    sources: DNSOverrideSources
  ) -> DNSOverridePlan {
    let overriddenFields = DNSOverrideField.allCases.filter { field in
      baseline.values[field] != final.values[field]
    }
    let enablement = enablement(baseline: baseline, final: final, sources: sources)
    return DNSOverridePlan(
      enablement: enablement,
      overriddenFields: overriddenFields,
      contributors: contributors(sources: sources),
      issues: issues(
        final: final,
        sources: sources,
        enablement: enablement,
        overriddenFields: overriddenFields
      )
    )
  }

  private static func enablement(
    baseline: DNSRuntimeFacts,
    final: DNSRuntimeFacts,
    sources: DNSOverrideSources
  ) -> DNSOverridePlan.Enablement {
    guard final.enable == true else {
      // An explicit "off" is the user's decision, and worth distinguishing from "nothing turned it on".
      return sources.globalDNSEnabled == false ? .disabledByUser : .none
    }
    if baseline.enable == true {
      return .profile
    }
    // The generated template is written before any app-managed layer, so when it authors `dns:` it
    // is what turned DNS on — crediting the override would blame a setting the user never touched.
    if sources.providerTemplateContributesDNS {
      return .providerTemplate
    }
    if sources.globalDNSEnabled == true {
      return .globalToggle
    }
    if sources.tunEnabled, sources.tunContributesDNS {
      return .tun
    }
    if sources.networkExtensionContributesDNS {
      return .networkExtension
    }
    return .overrideAutoEnabled
  }

  private static func contributors(sources: DNSOverrideSources) -> [String] {
    var contributors: [String] = []
    if sources.providerTemplateContributesDNS {
      contributors.append(String(localized: "Subscription template"))
    }
    if sources.globalDNSEnabled == true {
      contributors.append(String(localized: "DNS Override setting"))
    }
    if sources.tunEnabled, sources.tunContributesDNS {
      contributors.append(String(localized: "TUN DNS"))
    }
    if sources.networkExtensionContributesDNS {
      contributors.append(String(localized: "NE Proxy DNS"))
    }
    contributors.append(contentsOf: sources.dnsPatchSnippetNames)
    return contributors
  }

  private static func issues(
    final: DNSRuntimeFacts,
    sources: DNSOverrideSources,
    enablement: DNSOverridePlan.Enablement,
    overriddenFields: [DNSOverrideField]
  ) -> [DNSOverridePlan.Issue] {
    var issues: [DNSOverridePlan.Issue] = []

    // Mihomo validates respect-rules whether or not DNS is enabled, so this blocks the whole core.
    if final.respectRules, !final.hasProxyServerNameserver {
      issues.append(
        DNSOverridePlan.Issue(
          code: .respectRulesWithoutProxyServerNameserver,
          message: respectRulesRequirement,
          isBlocking: true
        )
      )
    }

    if !overriddenFields.isEmpty, !enablement.isEnabled {
      issues.append(
        DNSOverridePlan.Issue(
          code: .overrideInert,
          message: enablement == .disabledByUser
            ? String(localized: "DNS keys are written but Enable DNS Override is off, so Mihomo ignores them.")
            : String(localized: "DNS keys are written but nothing enables DNS, so Mihomo ignores them."),
          isBlocking: false
        )
      )
    }

    if final.respectRules, final.hasProxyServerNameserver, enablement.isEnabled {
      issues.append(
        DNSOverridePlan.Issue(
          code: .respectRulesFollowsRules,
          message: String(
            localized: "DNS queries follow the rule list, so custom rules also decide how names resolve."
          ),
          isBlocking: false
        )
      )
    }

    if final.hasFakeIPFilter, !final.isFakeIPMode, enablement.isEnabled {
      issues.append(
        DNSOverridePlan.Issue(
          code: .fakeIPFilterWithoutFakeIPMode,
          message: String(
            localized: "Fake-IP filters only apply in fake-ip mode; enable Fake IP DNS in TUN or NE Proxy to use them."
          ),
          isBlocking: false
        )
      )
    }

    return issues
  }
}
