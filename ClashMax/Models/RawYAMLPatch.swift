import Foundation
import Yams

/// How a raw YAML patch folds a list into a list the generated config already has.
enum RawYAMLPatchListStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
  /// The patch's list *is* the list. What an override normally means, and the only strategy that
  /// can shorten one — `nameserver: [1.1.1.1]` means exactly that resolver, not one more of them.
  case replace
  /// The patch's entries are appended to whatever is already there. These are the semantics of the
  /// legacy per-profile "Runtime Merge YAML" field, kept so a patch moved off it behaves the same.
  case append

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .replace:
      return String(localized: "Replace Lists")
    case .append:
      return String(localized: "Append To Lists")
    }
  }

  var explanation: String {
    switch self {
    case .replace:
      return String(localized: "A list in the patch replaces the generated one outright.")
    case .append:
      return String(localized: "A list in the patch is added after the generated entries.")
    }
  }
}

/// The generic escape hatch, as a first-class snippet payload: a raw Mihomo YAML fragment merged
/// into the generated runtime config **after** every app-managed key.
///
/// ROADMAP INV-2 promises that any key can be overridden by a user snippet, including keys ClashMax
/// has no UI for. The legacy per-profile "Runtime Merge YAML" field could not keep that promise:
/// it merges before `ConfigNormalizer` writes its managed keys, so `mode`, `tun.*`, `dns.enable`
/// and the geo keys always won over it. This payload runs last, so `tcp-concurrent`, `ntp`,
/// `keep-alive-interval`, `global-client-fingerprint` and every key Mihomo ships tomorrow are
/// reachable without the app growing a switch for each one (§2.4).
struct RawYAMLPatchSettings: Codable, Equatable, Sendable {
  var yaml: String
  var listStrategy: RawYAMLPatchListStrategy

  private enum CodingKeys: String, CodingKey {
    case yaml
    case listStrategy
  }

  init(yaml: String = "", listStrategy: RawYAMLPatchListStrategy = .replace) {
    self.yaml = yaml
    self.listStrategy = listStrategy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A strategy written by a newer build decodes as nil rather than failing the whole library.
    let listStrategy = try? container.decodeIfPresent(RawYAMLPatchListStrategy.self, forKey: .listStrategy)
    let yaml = try container.decodeIfPresent(String.self, forKey: .yaml) ?? ""
    self.init(yaml: yaml, listStrategy: listStrategy ?? .replace)
  }

  static let empty = RawYAMLPatchSettings()

  var normalizedYAML: String {
    yaml.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasRuntimeOverlay: Bool {
    !normalizedYAML.isEmpty
  }

  /// The mapping the merge actually applies. A document that holds nothing but comments loads as
  /// `nil` and is an empty patch, not an error.
  func parsedMapping() throws -> [String: Any] {
    guard hasRuntimeOverlay else { return [:] }
    let loaded: Any?
    do {
      loaded = try Yams.load(yaml: yaml)
    } catch {
      throw RawYAMLPatchError.parse(String(describing: error))
    }
    guard let loaded else { return [:] }
    guard let mapping = loaded as? [String: Any] else {
      throw RawYAMLPatchError.rootIsNotMapping
    }
    try RawYAMLPatchPolicy.validateReservedKeys(in: mapping)
    return mapping
  }

  var validationError: String? {
    do {
      _ = try parsedMapping()
      return nil
    } catch {
      return (error as? RawYAMLPatchError)?.message ?? String(describing: error)
    }
  }

  /// Top-level keys the patch sets, in the order a reader expects to scan them.
  var topLevelKeys: [String] {
    guard let mapping = try? parsedMapping() else { return [] }
    return mapping.keys.sorted()
  }

  /// The app-managed key paths this patch takes over, so the editor can say which ClashMax setting
  /// stops deciding. Best effort by design: it names the keys `ConfigNormalizer` writes itself, not
  /// every key some other snippet might also touch.
  var overriddenManagedKeyPaths: [String] {
    guard let mapping = try? parsedMapping() else { return [] }
    return RawYAMLPatchPolicy.managedKeyPaths(overriddenBy: mapping)
  }

  var summary: String {
    guard hasRuntimeOverlay else {
      return String(localized: "No YAML")
    }
    guard let mapping = try? parsedMapping() else {
      return String(localized: "Invalid YAML")
    }
    let keys = mapping.keys.sorted()
    guard !keys.isEmpty else {
      return String(localized: "No YAML")
    }
    let shown = keys.prefix(4).joined(separator: ", ")
    return keys.count > 4 ? "\(shown)…" : shown
  }
}

enum RawYAMLPatchError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
  case parse(String)
  case rootIsNotMapping
  case reservedControlChannelKey(String)
  case reservedInboundPortKey

  var message: String {
    switch self {
    case let .parse(detail):
      return String(format: String(localized: "Raw YAML parse error: %@"), detail)
    case .rootIsNotMapping:
      return String(localized: "Raw YAML must be a mapping of Mihomo keys.")
    case let .reservedControlChannelKey(key):
      return String(
        format: String(localized: "A raw YAML snippet cannot set \"%@\". ClashMax reaches the running core through that key, so moving it would leave the app unable to apply, verify or roll back this very change."),
        key
      )
    case .reservedInboundPortKey:
      return String(localized: "A raw YAML snippet cannot set \"mixed-port\". ClashMax points the system proxy and NE Proxy at that port; change it in Settings so all three stay in agreement.")
    }
  }

  var description: String { message }

  var errorDescription: String? { message }
}

/// Which keys a raw patch may set, and which ones it is quietly taking away from a ClashMax
/// control. Pure and testable: both the editor and `ConfigNormalizer` ask the same question here.
enum RawYAMLPatchPolicy {
  /// Keys the escape hatch does not open.
  ///
  /// This is not a ceiling: INV-2 is about keys ClashMax has **no UI for**, and every key below
  /// already has an owning control in Settings. What it protects is the promise around the edit —
  /// `external-controller` and `secret` are the channel every apply, preflight and rollback runs
  /// through, and `mixed-port` is the port the app hands to the system proxy and to NE Proxy. A
  /// patch that moved either would break the app's ability to keep its side of INV-2.
  static let reservedControlChannelKeys: Set<String> = [
    "external-controller",
    "external-controller-tls",
    "external-controller-unix",
    "external-controller-pipe",
    "secret",
  ]

  static let reservedInboundPortKey = "mixed-port"

  static var reservedKeys: Set<String> {
    reservedControlChannelKeys.union([reservedInboundPortKey])
  }

  static func validateReservedKeys(in mapping: [String: Any]) throws {
    for key in mapping.keys.sorted() {
      let normalized = normalizedKey(key)
      if normalized == reservedInboundPortKey {
        throw RawYAMLPatchError.reservedInboundPortKey
      }
      if reservedControlChannelKeys.contains(normalized) {
        throw RawYAMLPatchError.reservedControlChannelKey(key)
      }
    }
  }

  /// Top-level keys `ConfigNormalizer` writes unconditionally or from an app-owned setting.
  private static let managedTopLevelKeys: Set<String> = [
    "allow-lan",
    "external-controller-cors",
    "geo-auto-update",
    "geo-update-interval",
    "geodata-mode",
    "geox-url",
    "ipv6",
    "log-level",
    "mode",
    "rules",
    "sniffer",
    "unified-delay",
  ]

  /// Nested keys the app writes inside a block the profile otherwise owns. Only these subkeys are
  /// reported: a patch that sets `dns.nameserver` is overriding the *profile*, not ClashMax.
  private static let managedNestedKeys: [String: Set<String>] = [
    "dns": [
      "enable",
      "enhanced-mode",
      "fake-ip-range",
      "ipv6",
      "listen",
    ],
    "tun": [
      "auto-detect-interface",
      "auto-route",
      "device",
      "dns-hijack",
      "enable",
      "mtu",
      "route-exclude-address",
      "stack",
      "strict-route",
    ],
  ]

  static func managedKeyPaths(overriddenBy mapping: [String: Any]) -> [String] {
    var paths: [String] = []
    for key in mapping.keys.sorted() {
      let normalized = normalizedKey(key)
      if managedTopLevelKeys.contains(normalized) {
        paths.append(normalized)
        continue
      }
      guard let managedSubkeys = managedNestedKeys[normalized] else { continue }
      guard let nested = mapping[key] as? [String: Any] else {
        // Replacing the whole block replaces every managed key inside it.
        paths.append(normalized)
        continue
      }
      for subkey in nested.keys.sorted() where managedSubkeys.contains(normalizedKey(subkey)) {
        paths.append("\(normalized).\(normalizedKey(subkey))")
      }
    }
    return paths
  }

  private static func normalizedKey(_ key: String) -> String {
    key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
