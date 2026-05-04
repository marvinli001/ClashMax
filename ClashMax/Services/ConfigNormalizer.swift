import Foundation
import Yams

struct ConfigNormalizer {
  enum NormalizerError: Error, CustomStringConvertible {
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
    overrides: RuntimeOverrides
  ) throws -> String {
    var root: [String: Any]

    if ProfileConfigInspector.isProxyProviderContent(source) {
      guard let providerContentPath else {
        throw NormalizerError.invalidProfile("Provider subscription content requires a runtime provider file path.")
      }
      root = providerBackedConfig(providerName: normalizedProviderName(profileName), providerContentPath: providerContentPath)
    } else {
      root = try loadMapping(from: source)
    }

    root["mixed-port"] = overrides.mixedPort
    root["external-controller"] = "\(overrides.externalControllerHost):\(overrides.externalControllerPort)"
    root["secret"] = overrides.secret
    root["allow-lan"] = overrides.allowLan
    root["mode"] = overrides.mode.rawValue
    root["log-level"] = overrides.logLevel

    if let dnsEnabled = overrides.dnsEnabled {
      var dns = root["dns"] as? [String: Any] ?? [:]
      dns["enable"] = dnsEnabled
      root["dns"] = dns
    }

    var tun = root["tun"] as? [String: Any] ?? [:]
    tun["enable"] = overrides.tunEnabled
    tun.removeValue(forKey: "auto-redirect")
    if overrides.tunEnabled {
      tun["stack"] = "mixed"
      tun["auto-route"] = true
      tun["auto-detect-interface"] = true
      if tun["dns-hijack"] == nil {
        tun["dns-hijack"] = ["any:53", "tcp://any:53"]
      }
    }
    root["tun"] = tun

    return try Yams.dump(object: root, sortKeys: false)
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

enum ProfileConfigFormat: Equatable {
  case clashConfig
  case proxyProviderContent
}

enum ProfileConfigFormatError: Error, CustomStringConvertible {
  case empty
  case yaml(String)
  case rootIsNotMapping
  case missingProxyDefinitions

  var description: String {
    switch self {
    case .empty:
      return "Profile response is empty."
    case let .yaml(message):
      return "YAML parse error: \(message)"
    case .rootIsNotMapping:
      return "YAML root must be a mapping or URI/base64 proxy-provider content."
    case .missingProxyDefinitions:
      return "Profile must include at least one proxy or proxy provider."
    }
  }
}

enum ProfileConfigInspector {
  private static let supportedURISchemes: Set<String> = [
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

  private static func decodedBase64ProviderContent(from source: String) -> String? {
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
