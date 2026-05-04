import Foundation
import Yams

struct ConfigNormalizer {
  enum NormalizerError: Error, CustomStringConvertible {
    case yaml(String)
    case rootIsNotMapping

    var description: String {
      switch self {
      case let .yaml(message):
        return "YAML parse error: \(message)"
      case .rootIsNotMapping:
        return "YAML root must be a mapping."
      }
    }
  }

  func runtimeConfig(from source: String, overrides: RuntimeOverrides) throws -> String {
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: source)
    } catch {
      throw NormalizerError.yaml(String(describing: error))
    }

    guard var root = loaded as? [String: Any] else {
      throw NormalizerError.rootIsNotMapping
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
}

