import Foundation
import Yams

struct RuntimeConfigOptions: Equatable, Sendable {
  var networkExtensionRoutingSettings: NetworkExtensionRoutingSettings?

  static let `default` = RuntimeConfigOptions()
}

struct ConfigNormalizer {
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
      root = providerBackedConfig(providerName: normalizedProviderName(profileName), providerContentPath: providerContentPath)
      providerContentProxyNames = parsedProviderContentProxyNames(from: source)
    } else {
      root = try loadMapping(from: source)
      providerContentProxyNames = nil
    }

    root["mixed-port"] = overrides.mixedPort
    root["external-controller"] = "\(overrides.externalControllerHost):\(overrides.externalControllerPort)"
    root["secret"] = overrides.secret
    root["allow-lan"] = overrides.allowLan
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
      root["dns"] = dns
    }
    if let networkExtensionRoutingSettings = options.networkExtensionRoutingSettings {
      var dns = root["dns"] as? [String: Any] ?? [:]
      if networkExtensionRoutingSettings.dnsCaptureEnabled || networkExtensionRoutingSettings.dnsFakeIPEnabled {
        dns["enable"] = true
        dns["listen"] = networkExtensionRoutingSettings.normalizedDNSListenAddress
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
        dns["enhanced-mode"] = "fake-ip"
        dns["fake-ip-range"] = settings.normalizedFakeIPRange
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

  private func providerBackedConfig(providerName: String, providerContentPath: String) -> [String: Any] {
    [
      "proxy-providers": [
        providerName: [
          "type": "file",
          "path": providerContentPath,
          "health-check": [
            "enable": true,
            "url": AppConstants.defaultDelayTestURL.absoluteString,
            "interval": 300,
            "timeout": 5000,
            "lazy": true
          ]
        ]
      ],
      "proxy-groups": [
        [
          "name": "Proxy",
          "type": "select",
          "use": [providerName],
          "proxies": ["Auto", "DIRECT"]
        ],
        [
          "name": "Auto",
          "type": "url-test",
          "use": [providerName],
          "url": AppConstants.defaultDelayTestURL.absoluteString,
          "interval": 300,
          "lazy": true
        ]
      ],
      "rules": ["MATCH,Proxy"]
    ]
  }

  private func normalizedProviderName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Subscription" : trimmed
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

  static func isProxyProviderContent(_ source: String) -> Bool {
    containsProviderURI(in: source) || decodedBase64ProviderContent(from: source).map(containsProviderURI(in:)) == true
  }

  private static func containsProviderURI(in source: String) -> Bool {
    source
      .components(separatedBy: .newlines)
      .contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeSeparator = trimmed.firstIndex(of: ":") else {
          return false
        }
        let scheme = String(trimmed[..<schemeSeparator]).lowercased()
        return supportedURISchemes.contains(scheme) && trimmed[schemeSeparator...].hasPrefix("://")
      }
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
    let proxyTypes = proxyEntries.reduce(into: [String: String]()) { result, proxy in
      guard let name = string(proxy["name"]) else { return }
      result[name] = string(proxy["type"]) ?? "proxy"
    }
    let proxyEndpoints = proxyEntries.reduce(into: [String: ProxyEndpoint]()) { result, proxy in
      guard let name = string(proxy["name"]) else { return }
      result[name] = ProxyEndpoint(host: string(proxy["server"]), port: int(proxy["port"]))
    }
    let groupEntries = dictionaryArray(root["proxy-groups"])
    let groupTypes = groupEntries.reduce(into: [String: String]()) { result, group in
      guard let name = string(group["name"]) else { return }
      result[name] = string(group["type"]) ?? "group"
    }

    return groupEntries.compactMap { group in
      guard let name = string(group["name"]) else { return nil }
      let groupType = string(group["type"]) ?? "Unknown"
      var nodes = stringArray(group["proxies"]).map { proxyName in
        ProxyNode(
          name: proxyName,
          type: proxyTypes[proxyName] ?? groupTypes[proxyName] ?? builtInProxyType(for: proxyName) ?? "proxy",
          delay: nil,
          isSelectable: true,
          serverHost: proxyEndpoints[proxyName]?.host,
          serverPort: proxyEndpoints[proxyName]?.port
        )
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
}

private struct ProxyEndpoint {
  var host: String?
  var port: Int?
}
