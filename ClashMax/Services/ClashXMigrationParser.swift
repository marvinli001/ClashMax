import Foundation
import Yams

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

struct ClashXMigrationParser {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func parse(directoryURL: URL) -> ClashXMigrationReport {
    var inspectedFiles: [String] = []
    var warnings: [String] = []
    var subscriptionEntries: [(name: String?, url: String, file: String)] = []
    var bypassDomains: [String] = []
    var ports: [String: Int] = [:]
    var allowLan: Bool?
    var mode: String?
    var logLevel: String?
    var systemProxyEnabled: Bool?
    var conflicts: [String] = []
    var unsupportedSettings: [String] = []
    var unknownKeys: [String] = []
    var providerPaths = Set<String>()

    let initialFiles = candidateYAMLFiles(in: directoryURL)
    guard !initialFiles.isEmpty else {
      return ClashXMigrationReport(
        configDirectory: directoryURL.path,
        warnings: ["No ClashX YAML files were found in the selected directory."]
      )
    }

    for fileURL in initialFiles {
      parse(
        fileURL: fileURL,
        rootDirectory: directoryURL,
        inspectedFiles: &inspectedFiles,
        warnings: &warnings,
        subscriptionEntries: &subscriptionEntries,
        bypassDomains: &bypassDomains,
        ports: &ports,
        allowLan: &allowLan,
        mode: &mode,
        logLevel: &logLevel,
        systemProxyEnabled: &systemProxyEnabled,
        conflicts: &conflicts,
        unsupportedSettings: &unsupportedSettings,
        unknownKeys: &unknownKeys,
        providerPaths: &providerPaths
      )
    }

    for providerPath in providerPaths.sorted() {
      let providerURL = resolvedURL(path: providerPath, relativeTo: directoryURL)
      guard !inspectedFiles.contains(providerURL.standardizedFileURL.path) else { continue }
      parse(
        fileURL: providerURL,
        rootDirectory: directoryURL,
        inspectedFiles: &inspectedFiles,
        warnings: &warnings,
        subscriptionEntries: &subscriptionEntries,
        bypassDomains: &bypassDomains,
        ports: &ports,
        allowLan: &allowLan,
        mode: &mode,
        logLevel: &logLevel,
        systemProxyEnabled: &systemProxyEnabled,
        conflicts: &conflicts,
        unsupportedSettings: &unsupportedSettings,
        unknownKeys: &unknownKeys,
        providerPaths: &providerPaths
      )
    }

    let subscriptionURLs = unique(subscriptionEntries.map(\.url))
    let duplicateSubscriptionURLs = duplicates(subscriptionEntries.map(\.url))
    conflicts.append(contentsOf: providerNameConflicts(subscriptionEntries))
    if subscriptionURLs.isEmpty {
      warnings.append("No remote provider subscription URLs were detected.")
    }

    return ClashXMigrationReport(
      configDirectory: directoryURL.path,
      subscriptionURLs: subscriptionURLs,
      duplicateSubscriptionURLs: duplicateSubscriptionURLs,
      bypassDomains: unique(bypassDomains),
      ports: ports,
      allowLan: allowLan,
      mode: mode,
      logLevel: logLevel,
      systemProxyEnabled: systemProxyEnabled,
      conflicts: unique(conflicts),
      unsupportedSettings: unique(unsupportedSettings),
      unknownKeys: unique(unknownKeys).sorted(),
      inspectedFiles: inspectedFiles,
      warnings: unique(warnings)
    )
  }

  private func parse(
    fileURL: URL,
    rootDirectory: URL,
    inspectedFiles: inout [String],
    warnings: inout [String],
    subscriptionEntries: inout [(name: String?, url: String, file: String)],
    bypassDomains: inout [String],
    ports: inout [String: Int],
    allowLan: inout Bool?,
    mode: inout String?,
    logLevel: inout String?,
    systemProxyEnabled: inout Bool?,
    conflicts: inout [String],
    unsupportedSettings: inout [String],
    unknownKeys: inout [String],
    providerPaths: inout Set<String>
  ) {
    let standardizedPath = fileURL.standardizedFileURL.path
    guard fileManager.fileExists(atPath: standardizedPath),
          !inspectedFiles.contains(standardizedPath)
    else { return }
    inspectedFiles.append(standardizedPath)
    let fileLabel = relativePath(fileURL, from: rootDirectory)
    do {
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      guard let root = try Yams.load(yaml: source) as? [String: Any] else {
        warnings.append("\(fileLabel) is not a YAML mapping.")
        return
      }
      extractProviderEntries(from: root, fileLabel: fileLabel, subscriptionEntries: &subscriptionEntries, providerPaths: &providerPaths)
      bypassDomains.append(contentsOf: extractBypassDomains(from: root))
      for key in ["mixed-port", "port", "socks-port", "http-port", "redir-port", "tproxy-port"] {
        if let value = intValue(root[key]) {
          if let existing = ports[key], existing != value {
            conflicts.append("\(key) differs across files: \(existing) and \(value).")
          }
          ports[key] = value
        }
      }
      allowLan = boolValue(root["allow-lan"]) ?? allowLan
      mode = stringValue(root["mode"]) ?? mode
      logLevel = stringValue(root["log-level"]) ?? logLevel
      systemProxyEnabled = boolValue(root["system-proxy"])
        ?? boolValue(root["cfw-system-proxy"])
        ?? boolValue(root["enable-system-proxy"])
        ?? systemProxyEnabled
      unsupportedSettings.append(contentsOf: unsupportedKeys(from: root).map { "\($0) in \(fileLabel)" })
      unknownKeys.append(contentsOf: unknownTopLevelKeys(from: root).map { "\($0) in \(fileLabel)" })
    } catch {
      warnings.append("\(fileLabel) could not be parsed: \(String(describing: error))")
    }
  }

  private func candidateYAMLFiles(in directoryURL: URL) -> [URL] {
    let commonFiles = [
      "config.yaml",
      "config.yml",
      "profiles.yaml",
      "profiles.yml",
      "proxy-providers.yaml",
      "proxy-providers.yml"
    ]
    var result: [URL] = commonFiles
      .map { directoryURL.appendingPathComponent($0) }
      .filter { fileManager.fileExists(atPath: $0.path) }

    let commonSubfolders: Set<String> = [
      "profiles",
      "providers",
      "proxy-providers",
      "rule-providers",
      "clash",
      "config"
    ]
    guard let enumerator = fileManager.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return result
    }
    for case let fileURL as URL in enumerator {
      let relative = relativePath(fileURL, from: directoryURL)
      let components = relative.split(separator: "/").map(String.init)
      guard components.count >= 2,
            components.dropLast().contains(where: { commonSubfolders.contains($0.lowercased()) }),
            ["yaml", "yml"].contains(fileURL.pathExtension.lowercased())
      else {
        continue
      }
      result.append(fileURL)
    }
    return uniqueURLs(result)
  }

  private func extractProviderEntries(
    from root: [String: Any],
    fileLabel: String,
    subscriptionEntries: inout [(name: String?, url: String, file: String)],
    providerPaths: inout Set<String>
  ) {
    if let providers = root["proxy-providers"] as? [String: Any] {
      for entry in providers.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
        guard let provider = entry.value as? [String: Any] else { continue }
        if let url = stringValue(provider["url"]) {
          subscriptionEntries.append((name: entry.key, url: url, file: fileLabel))
        }
        if let path = stringValue(provider["path"]) {
          providerPaths.insert(path)
        }
      }
    }
    for key in ["subscriptions", "subscribes", "remote-profiles", "profiles"] {
      if let values = root[key] as? [[String: Any]] {
        for (index, value) in values.enumerated() {
          if let url = stringValue(value["url"]) ?? stringValue(value["uri"]) {
            subscriptionEntries.append((name: stringValue(value["name"]) ?? "\(key)[\(index)]", url: url, file: fileLabel))
          }
        }
      } else if let values = root[key] as? [String: Any] {
        for entry in values {
          if let value = entry.value as? [String: Any],
             let url = stringValue(value["url"]) ?? stringValue(value["uri"]) {
            subscriptionEntries.append((name: entry.key, url: url, file: fileLabel))
          } else if let url = stringValue(entry.value) {
            subscriptionEntries.append((name: entry.key, url: url, file: fileLabel))
          }
        }
      }
    }
  }

  private func extractBypassDomains(from root: [String: Any]) -> [String] {
    ["cfw-bypass", "bypass", "proxy-bypass", "bypass-domain", "bypass-domains"].flatMap { key in
      stringListValue(root[key])
    }
  }

  private func unsupportedKeys(from root: [String: Any]) -> [String] {
    root.keys.filter { key in
      let normalized = key.lowercased()
      return normalized.contains("shortcut")
        || normalized.contains("hotkey")
        || normalized.contains("menu")
        || normalized.contains("tray")
    }
    .sorted()
  }

  private func unknownTopLevelKeys(from root: [String: Any]) -> [String] {
    let known: Set<String> = [
      "allow-lan",
      "authentication",
      "bypass",
      "bypass-domain",
      "bypass-domains",
      "cfw-bypass",
      "cfw-system-proxy",
      "dns",
      "enable-system-proxy",
      "external-controller",
      "external-ui",
      "geodata-mode",
      "geo-auto-update",
      "geox-url",
      "hosts",
      "ipv6",
      "log-level",
      "mixed-port",
      "mode",
      "port",
      "profile",
      "profiles",
      "proxy-bypass",
      "proxy-groups",
      "proxy-providers",
      "proxies",
      "redir-port",
      "rule-providers",
      "rules",
      "secret",
      "socks-port",
      "subscriptions",
      "subscribes",
      "system-proxy",
      "tproxy-port",
      "tun"
    ]
    return root.keys.filter { !known.contains($0.lowercased()) }.sorted()
  }

  private func providerNameConflicts(_ entries: [(name: String?, url: String, file: String)]) -> [String] {
    let byName = Dictionary(grouping: entries.filter { $0.name?.isEmpty == false }, by: { $0.name ?? "" })
    return byName.compactMap { name, values in
      let urls = unique(values.map(\.url))
      guard urls.count > 1 else { return nil }
      return "Provider \(name) uses multiple URLs: \(urls.joined(separator: ", "))."
    }
  }

  private func duplicates(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var duplicates = Set<String>()
    for value in values {
      let key = value.lowercased()
      if seen.contains(key) {
        duplicates.insert(value)
      } else {
        seen.insert(key)
      }
    }
    return unique(values.filter { duplicates.contains($0) })
  }

  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      guard seen.insert(key).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }

  private func uniqueURLs(_ values: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for value in values {
      guard seen.insert(value.standardizedFileURL.path).inserted else { continue }
      result.append(value)
    }
    return result
  }

  private func resolvedURL(path: String, relativeTo directoryURL: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    return directoryURL.appendingPathComponent(path)
  }

  private func relativePath(_ fileURL: URL, from rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return filePath }
    return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return nil
  }

  private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "yes", "1", "on":
        return true
      case "false", "no", "0", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  private func stringListValue(_ value: Any?) -> [String] {
    if let values = value as? [String] {
      return values
    }
    if let values = value as? [Any] {
      return values.compactMap { stringValue($0) }
    }
    if let value = stringValue(value) {
      return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return []
  }
}
