import Foundation
import Yams

struct RuntimeConfigOptions: Equatable, Sendable {
  var networkExtensionRoutingSettings: NetworkExtensionRoutingSettings?
  var subscriptionProviderOptions: SubscriptionProviderOptions = .default

  static let `default` = RuntimeConfigOptions()
}

struct ConfigNormalizer {
  private static let appManagedProviderName = "clashmax-subscription-provider"

  enum NormalizerError: Error, CustomStringConvertible, Sendable {
    case yaml(String)
    case rootIsNotMapping
    case invalidProfile(String)

    var description: String {
      switch self {
      case let .yaml(message):
        return "YAML parse error: \(message)"
      case .rootIsNotMapping:
        return "YAML root must be a mapping."
      case let .invalidProfile(message):
        return message
      }
    }
  }

  func runtimeConfig(
    from source: String,
    providerContentPath: String? = nil,
    profileName: String = "Subscription",
    overrides: RuntimeOverrides,
    options: RuntimeConfigOptions = .default,
    selectionOverrides: [String: String] = [:]
  ) throws -> String {
    var root: [String: Any]
    let providerContentProxyNames: Set<String>?

    if ProfileConfigInspector.isProxyProviderContent(source) {
      guard let providerContentPath else {
        throw NormalizerError.invalidProfile("Provider subscription content requires a runtime provider file path.")
      }
      root = try providerBackedConfig(
        providerContentPath: providerContentPath,
        options: options.subscriptionProviderOptions
      )
      providerContentProxyNames = parsedProviderContentProxyNames(from: source)
    } else {
      root = try loadMapping(from: source)
      providerContentProxyNames = nil
    }

    let runtimeMergeYAML = options.subscriptionProviderOptions.runtimeMergeYAML
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !runtimeMergeYAML.isEmpty {
      root = try runtimeMergedRoot(base: root, mergeYAML: runtimeMergeYAML)
    }

    root["mixed-port"] = overrides.mixedPort
    root["external-controller"] = "\(overrides.externalControllerHost):\(overrides.externalControllerPort)"
    root["secret"] = overrides.secret
    root["allow-lan"] = overrides.allowLan
    root["ipv6"] = overrides.ipv6Enabled
    root["mode"] = overrides.mode.rawValue
    root["log-level"] = overrides.logLevel
    root["unified-delay"] = overrides.unifiedDelay

    if overrides.externalControllerCORS.enabled {
      root["external-controller-cors"] = [
        "allow-origins": overrides.externalControllerCORS.effectiveAllowedOrigins,
        "allow-private-network": overrides.externalControllerCORS.allowPrivateNetwork
      ]
    } else {
      root.removeValue(forKey: "external-controller-cors")
    }

    if let dnsEnabled = overrides.dnsEnabled {
      var dns = root["dns"] as? [String: Any] ?? [:]
      dns["enable"] = dnsEnabled
      if dnsEnabled {
        dns["ipv6"] = overrides.ipv6Enabled
      }
      root["dns"] = dns
    }
    if let networkExtensionRoutingSettings = options.networkExtensionRoutingSettings {
      var dns = root["dns"] as? [String: Any] ?? [:]
      if networkExtensionRoutingSettings.dnsCaptureEnabled || networkExtensionRoutingSettings.dnsFakeIPEnabled {
        dns["enable"] = true
        dns["listen"] = networkExtensionRoutingSettings.normalizedDNSListenAddress
        dns["ipv6"] = overrides.ipv6Enabled
      }
      if networkExtensionRoutingSettings.dnsFakeIPEnabled {
        dns["enhanced-mode"] = "fake-ip"
        dns["fake-ip-range"] = NetworkExtensionRoutingSettings.defaultFakeIPRange
      }
      if !dns.isEmpty {
        root["dns"] = dns
      }
    }

    var tun = root["tun"] as? [String: Any] ?? [:]
    tun["enable"] = overrides.tunEnabled
    tun.removeValue(forKey: "auto-redirect")
    if overrides.tunEnabled {
      let settings = overrides.tunSettings
      if let validationError = settings.validationError {
        throw NormalizerError.invalidProfile(validationError)
      }
      if settings.dnsFakeIPEnabled {
        var dns = root["dns"] as? [String: Any] ?? [:]
        dns["enable"] = true
        dns["ipv6"] = overrides.ipv6Enabled
        dns["enhanced-mode"] = "fake-ip"
        dns["fake-ip-range"] = settings.normalizedFakeIPRange
        applyTunDNSOverlay(settings.dns, to: &dns)
        root["dns"] = dns
      } else if settings.dns.hasRuntimeOverlay {
        var dns = root["dns"] as? [String: Any] ?? [:]
        dns["enable"] = true
        dns["ipv6"] = overrides.ipv6Enabled
        applyTunDNSOverlay(settings.dns, to: &dns)
        root["dns"] = dns
      }
      tun["stack"] = settings.stack.rawValue
      tun["device"] = settings.normalizedDevice
      tun["auto-route"] = settings.autoRoute
      tun["strict-route"] = settings.strictRoute
      tun["auto-detect-interface"] = settings.autoDetectInterface
      tun["dns-hijack"] = settings.normalizedDNSHijack
      tun["mtu"] = settings.normalizedMTU
      let profileRouteExcludeAddresses = try normalizedRouteExcludeCIDRs(from: tun["route-exclude-address"])
      let routeExcludeAddresses = TunSettings.normalizedRouteExcludeCIDRs(
        profileRouteExcludeAddresses + settings.normalizedRouteExcludeAddresses
      )
      if !routeExcludeAddresses.isEmpty {
        tun["route-exclude-address"] = routeExcludeAddresses
      } else {
        tun.removeValue(forKey: "route-exclude-address")
      }
    }
    root["tun"] = tun

    let ruleOverlay = overrides.ruleOverlay.combined(
      withProfileOverlay: options.subscriptionProviderOptions.ruleOverlay
    )
    if ruleOverlay.hasRuntimeOverlay {
      if let validationError = ruleOverlay.validationError {
        throw NormalizerError.invalidProfile(validationError)
      }
      root["rules"] = mergedRules(existing: root["rules"], overlay: ruleOverlay)
    }

    if !selectionOverrides.isEmpty,
       var groups = root["proxy-groups"] as? [Any] {
      for index in groups.indices {
        guard var group = groups[index] as? [String: Any],
              let groupName = group["name"] as? String,
              let selected = selectionOverrides[groupName],
              selectionOverrideIsAllowed(
                selected,
                in: group,
                providerContentProxyNames: providerContentProxyNames
              )
        else { continue }
        group["now"] = selected
        groups[index] = group
      }
      root["proxy-groups"] = groups
    }

    return try Yams.dump(object: root, sortKeys: false)
  }

  private func mergedRules(existing: Any?, overlay: RuleOverlaySettings) -> [String] {
    let profileRules = normalizedRuleList(from: existing).filter { !overlay.disablesRule($0) }
    return overlay.runtimePrependRules
      + profileRules
      + overlay.runtimeAppendRules
  }

  private func runtimeMergedRoot(base: [String: Any], mergeYAML: String) throws -> [String: Any] {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: mergeYAML)
    } catch {
      throw NormalizerError.invalidProfile("Runtime merge YAML parse error: \(String(describing: error))")
    }

    guard let overlay = loaded as? [String: Any] else {
      throw NormalizerError.invalidProfile("Runtime merge YAML must be a YAML mapping.")
    }
    return mergedRuntimeMapping(base: base, overlay: overlay)
  }

  private func mergedRuntimeMapping(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
    var merged = base
    for (key, overlayValue) in overlay {
      guard let baseValue = merged[key] else {
        merged[key] = overlayValue
        continue
      }
      merged[key] = mergedRuntimeValue(base: baseValue, overlay: overlayValue)
    }
    return merged
  }

  private func mergedRuntimeValue(base: Any, overlay: Any) -> Any {
    if let baseMap = base as? [String: Any],
       let overlayMap = overlay as? [String: Any] {
      return mergedRuntimeMapping(base: baseMap, overlay: overlayMap)
    }
    if let baseList = base as? [Any],
       let overlayList = overlay as? [Any] {
      return baseList + overlayList
    }
    return overlay
  }

  private func applyTunDNSOverlay(_ overlay: TunDNSSettings, to dns: inout [String: Any]) {
    if let preferH3 = overlay.preferH3 {
      dns["prefer-h3"] = preferH3
    }
    if let useHosts = overlay.useHosts {
      dns["use-hosts"] = useHosts
    }
    if let useSystemHosts = overlay.useSystemHosts {
      dns["use-system-hosts"] = useSystemHosts
    }
    if let respectRules = overlay.respectRules {
      dns["respect-rules"] = respectRules
    }
    if !overlay.fakeIPFilter.isEmpty {
      dns["fake-ip-filter"] = mergedStringList(existing: dns["fake-ip-filter"], overlay: overlay.fakeIPFilter)
    }
    if !overlay.defaultNameserver.isEmpty {
      dns["default-nameserver"] = mergedStringList(
        existing: dns["default-nameserver"],
        overlay: overlay.defaultNameserver
      )
    }
    if !overlay.nameserver.isEmpty {
      dns["nameserver"] = mergedStringList(existing: dns["nameserver"], overlay: overlay.nameserver)
    }
    if !overlay.fallback.isEmpty {
      dns["fallback"] = mergedStringList(existing: dns["fallback"], overlay: overlay.fallback)
    }
    if !overlay.proxyServerNameserver.isEmpty {
      dns["proxy-server-nameserver"] = mergedStringList(
        existing: dns["proxy-server-nameserver"],
        overlay: overlay.proxyServerNameserver
      )
    }
    if !overlay.directNameserver.isEmpty {
      dns["direct-nameserver"] = mergedStringList(existing: dns["direct-nameserver"], overlay: overlay.directNameserver)
    }
    if let directNameserverFollowPolicy = overlay.directNameserverFollowPolicy {
      dns["direct-nameserver-follow-policy"] = directNameserverFollowPolicy
    }
    if !overlay.nameserverPolicy.isEmpty {
      dns["nameserver-policy"] = mergedResolverPolicyMap(
        existing: dns["nameserver-policy"],
        overlay: overlay.nameserverPolicy
      )
    }
    if !overlay.proxyServerNameserverPolicy.isEmpty {
      dns["proxy-server-nameserver-policy"] = mergedResolverPolicyMap(
        existing: dns["proxy-server-nameserver-policy"],
        overlay: overlay.proxyServerNameserverPolicy
      )
    }
    if !overlay.hosts.isEmpty {
      dns["hosts"] = mergedStringMap(existing: dns["hosts"], overlay: overlay.hosts)
    }
    if !overlay.fallbackFilter.isEmpty {
      dns["fallback-filter"] = mergedFallbackFilter(existing: dns["fallback-filter"], overlay: overlay.fallbackFilter)
    }
  }

  private func mergedStringList(existing: Any?, overlay: [String]) -> [String] {
    TunDNSSettings.normalizedList(normalizedStringList(from: existing) + overlay)
  }

  private func mergedStringMap(existing: Any?, overlay: [String: String]) -> [String: String] {
    var merged: [String: String]
    if let existingMap = existing as? [String: String] {
      merged = TunDNSSettings.normalizedMap(existingMap)
    } else if let existingMap = existing as? [String: Any] {
      merged = TunDNSSettings.normalizedMap(existingMap.compactMapValues { $0 as? String })
    } else {
      merged = [:]
    }
    for entry in TunDNSSettings.normalizedMap(overlay) {
      merged[entry.key] = entry.value
    }
    return merged
  }

  private func mergedResolverPolicyMap(existing: Any?, overlay: [String: String]) -> [String: Any] {
    var merged: [String: Any] = [:]
    if let existingMap = existing as? [String: String] {
      for entry in TunDNSSettings.normalizedMap(existingMap) {
        merged[entry.key] = entry.value
      }
    } else if let existingMap = existing as? [String: Any] {
      for entry in existingMap {
        let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let value = normalizedResolverPolicyValue(entry.value) else { continue }
        merged[key] = value
      }
    }
    for entry in TunDNSSettings.normalizedMap(overlay) {
      merged[entry.key] = entry.value
    }
    return merged
  }

  private func normalizedResolverPolicyValue(_ value: Any) -> Any? {
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let strings = value as? [String] {
      let normalized = TunDNSSettings.normalizedList(strings)
      return normalized.isEmpty ? nil : normalized
    }
    if let values = value as? [Any] {
      let normalized = TunDNSSettings.normalizedList(values.compactMap { $0 as? String })
      return normalized.isEmpty ? nil : normalized
    }
    return nil
  }

  private func mergedFallbackFilter(existing: Any?, overlay: TunDNSFallbackFilter) -> [String: Any] {
    var merged = existing as? [String: Any] ?? [:]
    if let geoIP = overlay.geoIP {
      merged["geoip"] = geoIP
    }
    if let geoIPCode = overlay.geoIPCode {
      merged["geoip-code"] = geoIPCode
    }
    if !overlay.geoSite.isEmpty {
      merged["geosite"] = mergedStringList(existing: merged["geosite"], overlay: overlay.geoSite)
    }
    if !overlay.ipCIDR.isEmpty {
      merged["ipcidr"] = mergedStringList(existing: merged["ipcidr"], overlay: overlay.ipCIDR)
    }
    if !overlay.domain.isEmpty {
      merged["domain"] = mergedStringList(existing: merged["domain"], overlay: overlay.domain)
    }
    return merged
  }

  private func proxyNames(in group: [String: Any]) -> Set<String> {
    let entries = group["proxies"] as? [Any] ?? []
    return Set(entries.compactMap { $0 as? String })
  }

  private func selectionOverrideIsAllowed(
    _ selected: String,
    in group: [String: Any],
    providerContentProxyNames: Set<String>?
  ) -> Bool {
    guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if proxyNames(in: group).contains(selected) {
      return true
    }
    if let providerContentProxyNames {
      return providerContentProxyNames.contains(selected)
    }
    return !providerReferences(in: group).isEmpty
  }

  private func providerReferences(in group: [String: Any]) -> Set<String> {
    let entries = group["use"] as? [Any] ?? []
    return Set(
      entries
        .compactMap { $0 as? String }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
  }

  private func parsedProviderContentProxyNames(from source: String) -> Set<String> {
    let groups = (try? ProfilePreviewBuilder().groups(from: source, profileName: "")) ?? []
    return Set(
      groups
        .flatMap(\.nodes)
        .filter(\.isSelectable)
        .map(\.name)
    )
  }

  private func normalizedStringList(from value: Any?) -> [String] {
    switch value {
    case let values as [String]:
      return SystemProxySettings.normalizedBypassDomains(values)
    case let values as [Any]:
      return SystemProxySettings.normalizedBypassDomains(values.compactMap { $0 as? String })
    case let value as String:
      return SystemProxySettings.normalizedBypassDomains([value])
    default:
      return []
    }
  }

  private func normalizedRuleList(from value: Any?) -> [String] {
    switch value {
    case let values as [String]:
      return values.compactMap(Self.normalizedRuleText)
    case let values as [Any]:
      return values.compactMap { $0 as? String }.compactMap(Self.normalizedRuleText)
    case let value as String:
      return [value].compactMap(Self.normalizedRuleText)
    default:
      return []
    }
  }

  private static func normalizedRuleText(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizedRouteExcludeCIDRs(from value: Any?) throws -> [String] {
    let values = normalizedStringList(from: value)
    if let invalid = values.first(where: { !TunSettings.isValidRouteExcludeCIDR($0) }) {
      throw NormalizerError.invalidProfile("Invalid TUN route exclude CIDR: \(invalid)")
    }
    return TunSettings.normalizedRouteExcludeCIDRs(values)
  }

  private func loadMapping(from source: String) throws -> [String: Any] {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: source)
    } catch {
      throw NormalizerError.yaml(String(describing: error))
    }

    guard let root = loaded as? [String: Any] else {
      throw NormalizerError.rootIsNotMapping
    }
    return root
  }

  private func providerBackedConfig(
    providerContentPath: String,
    options: SubscriptionProviderOptions
  ) throws -> [String: Any] {
    let providerName = Self.appManagedProviderName
    let primaryGroupName = options.primaryGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Proxy"
      : options.primaryGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    let autoGroupName = options.autoGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    let finalRulePolicy = options.finalRulePolicy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? primaryGroupName
      : options.finalRulePolicy.trimmingCharacters(in: .whitespacesAndNewlines)
    var provider: [String: Any] = [
      "type": "file",
      "path": providerContentPath,
      "interval": options.intervalSeconds,
      "health-check": [
        "enable": true,
        "url": AppConstants.defaultDelayTestURL.absoluteString,
        "interval": 300,
        "timeout": 5000,
        "lazy": true
      ]
    ]
    let filter = options.filter.trimmingCharacters(in: .whitespacesAndNewlines)
    if !filter.isEmpty {
      provider["filter"] = filter
    }
    let excludeFilter = options.excludeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    if !excludeFilter.isEmpty {
      provider["exclude-filter"] = excludeFilter
    }
    let excludeType = options.excludeType.trimmingCharacters(in: .whitespacesAndNewlines)
    if !excludeType.isEmpty {
      provider["exclude-type"] = excludeType
    }
    let overrideYAML = options.overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overrideYAML.isEmpty {
      let loaded: Any?
      do {
        loaded = try Yams.load(yaml: overrideYAML)
      } catch {
        throw NormalizerError.invalidProfile("Provider override YAML parse error: \(String(describing: error))")
      }
      guard let override = loaded as? [String: Any] else {
        throw NormalizerError.invalidProfile("Provider override must be a YAML mapping.")
      }
      provider["override"] = override
    }

    var proxyGroups: [[String: Any]] = [
      [
        "name": primaryGroupName,
        "type": "select",
        "use": [providerName],
        "proxies": ([autoGroupName.isEmpty ? nil : autoGroupName, "DIRECT"] as [String?]).compactMap { $0 }
      ]
    ]
    if !autoGroupName.isEmpty {
      proxyGroups.append([
        "name": autoGroupName,
        "type": "url-test",
        "use": [providerName],
        "url": AppConstants.defaultDelayTestURL.absoluteString,
        "interval": 300,
        "lazy": true
      ])
    }

    return [
      "proxy-providers": [
        providerName: provider
      ],
      "proxy-groups": proxyGroups,
      "rules": generatedRules(template: options.generatedTemplate, finalRulePolicy: finalRulePolicy)
    ]
  }

  private func generatedRules(template: SubscriptionTemplateKind, finalRulePolicy: String) -> [String] {
    switch template {
    case .minimal, .global:
      return ["MATCH,\(finalRulePolicy)"]
    case .rule:
      return [
        "DOMAIN-SUFFIX,local,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "MATCH,\(finalRulePolicy)"
      ]
    case .cnDirect:
      return [
        "DOMAIN-SUFFIX,local,DIRECT",
        "GEOSITE,private,DIRECT",
        "GEOIP,private,DIRECT,no-resolve",
        "GEOSITE,cn,DIRECT",
        "GEOIP,CN,DIRECT,no-resolve",
        "MATCH,\(finalRulePolicy)"
      ]
    }
  }
}

enum ProfileConfigFormat: Equatable, Sendable {
  case clashConfig
  case proxyProviderContent
}

enum ProfileConfigFormatError: Error, CustomStringConvertible, LocalizedError, Sendable {
  case empty
  case yaml(String)
  case rootIsNotMapping
  case missingProxyDefinitions

  var description: String {
    errorDescription ?? ""
  }

  var errorDescription: String? {
    switch self {
    case .empty:
      return String(localized: "Profile response is empty.")
    case let .yaml(message):
      return String(format: String(localized: "YAML parse error: %@"), message)
    case .rootIsNotMapping:
      return String(localized: "YAML root must be a mapping or URI/base64 proxy-provider content.")
    case .missingProxyDefinitions:
      return String(localized: "Profile must include at least one proxy or proxy provider.")
    }
  }
}

enum ProfileConfigInspector {
  static let supportedURISchemes: Set<String> = [
    "ss",
    "ssr",
    "vmess",
    "vless",
    "trojan",
    "hysteria",
    "hysteria2",
    "hy2",
    "tuic",
    "wireguard",
    "wg",
    "ssh",
    "masque",
    "anytls",
    "mieru",
    "snell",
    "http",
    "https",
    "socks",
    "socks5",
    "tailscale",
    "ts",
    "trusttunnel",
    "trust-tunnel",
    "openvpn",
    "ovpn",
    "gost",
    "sudoku",
    "hy"
  ]

  static func format(of source: String) throws -> ProfileConfigFormat {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProfileConfigFormatError.empty
    }

    do {
      let loaded = try Yams.load(yaml: source)
      if let root = loaded as? [String: Any] {
        let proxies = root["proxies"] as? [[String: Any]] ?? []
        let providers = root["proxy-providers"] as? [String: Any] ?? [:]
        guard !proxies.isEmpty || !providers.isEmpty else {
          throw ProfileConfigFormatError.missingProxyDefinitions
        }
        return .clashConfig
      }

      if isProxyProviderContent(source) {
        return .proxyProviderContent
      }

      throw ProfileConfigFormatError.rootIsNotMapping
    } catch let error as ProfileConfigFormatError {
      throw error
    } catch {
      if isProxyProviderContent(source) {
        return .proxyProviderContent
      }
      throw ProfileConfigFormatError.yaml(String(describing: error))
    }
  }

  static func contentKind(of source: String) throws -> SubscriptionContentKind {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ProfileConfigFormatError.empty
    }
    if let decoded = decodedBase64ProviderContent(from: source),
       isProviderContentText(decoded) {
      return .base64ShareLinkList
    }
    do {
      let loaded = try Yams.load(yaml: source)
      if let root = loaded as? [String: Any] {
        let proxies = root["proxies"] as? [[String: Any]] ?? []
        let providers = root["proxy-providers"] as? [String: Any] ?? [:]
        let payload = root["payload"] as? [[String: Any]] ?? []
        if !payload.isEmpty || (!proxies.isEmpty && providers.isEmpty && !hasRuntimeConfigKeys(root)) {
          return .proxyProviderContent
        }
        guard !proxies.isEmpty || !providers.isEmpty else {
          throw ProfileConfigFormatError.missingProxyDefinitions
        }
        return .clashConfig
      }
    } catch let error as ProfileConfigFormatError {
      throw error
    } catch {
      if !isProxyProviderContent(source) {
        throw ProfileConfigFormatError.yaml(String(describing: error))
      }
    }
    if containsOnlyProviderURIs(in: source) {
      return .shareLinkList
    }
    if isProviderContentText(source) {
      return .proxyProviderContent
    }
    throw ProfileConfigFormatError.rootIsNotMapping
  }

  static func isProxyProviderContent(_ source: String) -> Bool {
    isProviderContentText(source)
      || decodedBase64ProviderContent(from: source).map { isProviderContentText($0) } == true
  }

  private static func isProviderContentText(_ source: String) -> Bool {
    containsSupportedProviderURI(in: source) || containsOnlyProviderURIs(in: source)
  }

  private static func containsSupportedProviderURI(in source: String) -> Bool {
    nonEmptyLines(in: source)
      .contains { line in
        guard let uri = providerURI(in: line) else {
          return false
        }
        return supportedURISchemes.contains(uri.scheme)
      }
  }

  private static func containsOnlyProviderURIs(in source: String) -> Bool {
    let lines = nonEmptyLines(in: source)
    guard !lines.isEmpty else { return false }
    return lines.allSatisfy { providerURI(in: $0) != nil }
  }

  private static func hasRuntimeConfigKeys(_ root: [String: Any]) -> Bool {
    [
      "proxy-groups",
      "rules",
      "mixed-port",
      "port",
      "socks-port",
      "redir-port",
      "tproxy-port",
      "tun",
      "dns",
      "mode"
    ].contains { root[$0] != nil }
  }

  private static func nonEmptyLines(in source: String) -> [String] {
    source
      .components(separatedBy: .newlines)
      .compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
  }

  private static func providerURI(in line: String) -> (scheme: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schemeSeparator = trimmed.firstIndex(of: ":"),
          trimmed[schemeSeparator...].hasPrefix("://")
    else {
      return nil
    }
    let scheme = String(trimmed[..<schemeSeparator]).lowercased()
    guard scheme.range(of: #"^[a-z][a-z0-9+\-.]*$"#, options: .regularExpression) != nil else {
      return nil
    }
    return (scheme, trimmed)
  }

  static func decodedBase64ProviderContent(from source: String) -> String? {
    let compact = source
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard !compact.isEmpty else { return nil }

    var normalized = compact
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized.append(String(repeating: "=", count: 4 - remainder))
    }

    guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

struct ProfilePreviewBuilder {
  func groups(from source: String, profileName: String) throws -> [ProxyGroup] {
    if ProfileConfigInspector.isProxyProviderContent(source) {
      return providerContentGroups(from: source)
    }

    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: source)
    } catch {
      throw ConfigNormalizer.NormalizerError.yaml(String(describing: error))
    }

    guard let root = loaded as? [String: Any] else {
      throw ConfigNormalizer.NormalizerError.rootIsNotMapping
    }
    return clashConfigGroups(from: root)
  }

  private func clashConfigGroups(from root: [String: Any]) -> [ProxyGroup] {
    let proxyEntries = dictionaryArray(root["proxies"])
    let proxyNodes = proxyEntries.reduce(into: [String: ProxyNode]()) { result, proxy in
      guard let node = proxyNode(from: proxy) else { return }
      result[node.name] = node
    }
    let providerNodes = providerPayloadNodes(from: root["proxy-providers"])
    let groupEntries = dictionaryArray(root["proxy-groups"])
    let groupTypes = groupEntries.reduce(into: [String: String]()) { result, group in
      guard let name = string(group["name"]) else { return }
      result[name] = string(group["type"]) ?? "group"
    }

    return groupEntries.compactMap { group in
      guard let name = string(group["name"]) else { return nil }
      let groupType = string(group["type"]) ?? "Unknown"
      var nodes = stringArray(group["proxies"]).map { proxyName in
        proxyNodes[proxyName]
          ?? ProxyNode(
            name: proxyName,
            type: groupTypes[proxyName] ?? builtInProxyType(for: proxyName) ?? "proxy",
            delay: nil,
            isSelectable: true
          )
      }

      let usedProviderNodes = stringArray(group["use"]).flatMap { providerName in
        if let nodes = providerNodes[providerName], !nodes.isEmpty {
          return nodes
        }
        return [
          ProxyNode(
            name: "Provider: \(providerName)",
            type: "provider",
            delay: nil,
            isSelectable: false,
            providerName: providerName
          )
        ]
      }
      if nodes.isEmpty {
        nodes = usedProviderNodes
      } else {
        nodes.append(contentsOf: usedProviderNodes)
      }

      if nodes.isEmpty {
        nodes = stringArray(group["use"]).map { providerName in
          ProxyNode(name: "Provider: \(providerName)", type: "provider", delay: nil, isSelectable: false)
        }
      }

      return ProxyGroup(
        name: name,
        type: groupType,
        selected: string(group["now"]),
        nodes: nodes
      )
    }
  }

  private func providerPayloadNodes(from value: Any?) -> [String: [ProxyNode]] {
    guard let providers = value as? [String: Any] else { return [:] }
    return providers.reduce(into: [String: [ProxyNode]]()) { result, entry in
      guard let provider = entry.value as? [String: Any] else { return }
      let nodes = dictionaryArray(provider["payload"]).compactMap { proxyNode(from: $0, providerName: entry.key) }
      if !nodes.isEmpty {
        result[entry.key] = nodes
      }
    }
  }

  private func proxyNode(from proxy: [String: Any], providerName: String? = nil) -> ProxyNode? {
    guard let name = string(proxy["name"])?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    return ProxyNode(
      name: name,
      type: string(proxy["type"]) ?? "proxy",
      delay: nil,
      isSelectable: true,
      serverHost: string(proxy["server"]),
      serverPort: int(proxy["port"]),
      providerName: providerName,
      udpSupported: bool(proxy["udp"]),
      tfoSupported: bool(proxy["tfo"]),
      xudpSupported: bool(proxy["xudp"])
    )
  }

  private func providerContentGroups(from source: String) -> [ProxyGroup] {
    let providerNodes = providerURINodes(from: source)
    guard !providerNodes.isEmpty else { return [] }

    let autoNode = ProxyNode(name: "Auto", type: "url-test", delay: nil, isSelectable: true)
    let directNode = ProxyNode(name: "DIRECT", type: "direct", delay: nil, isSelectable: true)
    return [
      ProxyGroup(
        name: "Proxy",
        type: "select",
        selected: nil,
        nodes: [autoNode] + providerNodes + [directNode]
      ),
      ProxyGroup(
        name: "Auto",
        type: "url-test",
        selected: nil,
        nodes: providerNodes
      )
    ]
  }

  private func providerURINodes(from source: String) -> [ProxyNode] {
    let candidates = [
      source,
      ProfileConfigInspector.decodedBase64ProviderContent(from: source)
    ].compactMap { $0 }

    for candidate in candidates {
      let nodes = candidate
        .components(separatedBy: .newlines)
        .compactMap(providerURINode)
      if !nodes.isEmpty {
        return nodes
      }
    }
    return []
  }

  private func providerURINode(from line: String) -> ProxyNode? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schemeSeparator = trimmed.firstIndex(of: ":") else {
      return nil
    }
    let scheme = String(trimmed[..<schemeSeparator]).lowercased()
    guard ProfileConfigInspector.supportedURISchemes.contains(scheme),
          trimmed[schemeSeparator...].hasPrefix("://")
    else {
      return nil
    }

    let type = normalizedProxyType(for: scheme)
    let endpoint = providerURIEndpoint(from: trimmed)
    return ProxyNode(
      name: providerURIName(from: trimmed, scheme: type),
      type: type,
      delay: nil,
      isSelectable: true,
      serverHost: endpoint.host,
      serverPort: endpoint.port
    )
  }

  private func providerURIName(from uri: String, scheme: String) -> String {
    if let fragmentStart = uri.firstIndex(of: "#") {
      let encodedName = String(uri[uri.index(after: fragmentStart)...])
      if let decoded = encodedName.removingPercentEncoding,
         !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return decoded
      }
    }

    let host = providerURIHost(from: uri)
    return host.map { "\(scheme.uppercased()) \($0)" } ?? scheme.uppercased()
  }

  private func providerURIHost(from uri: String) -> String? {
    providerURIEndpoint(from: uri).host
  }

  private func providerURIEndpoint(from uri: String) -> ProxyEndpoint {
    guard let schemeRange = uri.range(of: "://") else { return ProxyEndpoint(host: nil, port: nil) }
    var remainder = String(uri[schemeRange.upperBound...])
    if let fragmentStart = remainder.firstIndex(of: "#") {
      remainder = String(remainder[..<fragmentStart])
    }
    if let queryStart = remainder.firstIndex(of: "?") {
      remainder = String(remainder[..<queryStart])
    }
    if let at = remainder.lastIndex(of: "@") {
      remainder = String(remainder[remainder.index(after: at)...])
    }
    var port: Int?
    if let colon = remainder.lastIndex(of: ":") {
      let portText = String(remainder[remainder.index(after: colon)...])
      port = Int(portText)
      remainder = String(remainder[..<colon])
    }
    let decoded = remainder.removingPercentEncoding ?? remainder
    let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    return ProxyEndpoint(host: trimmed.isEmpty ? nil : trimmed, port: port)
  }

  private func normalizedProxyType(for scheme: String) -> String {
    switch scheme {
    case "hy2":
      return "hysteria2"
    case "hy":
      return "hysteria"
    case "wg":
      return "wireguard"
    default:
      return scheme
    }
  }

  private func builtInProxyType(for name: String) -> String? {
    switch name.uppercased() {
    case "DIRECT":
      return "direct"
    case "REJECT", "REJECT-DROP":
      return "reject"
    default:
      return nil
    }
  }

  private func dictionaryArray(_ value: Any?) -> [[String: Any]] {
    (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
  }

  private func stringArray(_ value: Any?) -> [String] {
    (value as? [Any])?.compactMap(string) ?? []
  }

  private func string(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      return value
    case let value as CustomStringConvertible:
      return String(describing: value)
    default:
      return nil
    }
  }

  private func int(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
      return value
    case let value as String:
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    case let value as CustomStringConvertible:
      return Int(String(describing: value))
    default:
      return nil
    }
  }

  private func bool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let value as String:
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "yes", "1":
        return true
      case "false", "no", "0":
        return false
      default:
        return nil
      }
    case let value as CustomStringConvertible:
      return bool(String(describing: value))
    default:
      return nil
    }
  }
}

private struct ProxyEndpoint {
  var host: String?
  var port: Int?
}
