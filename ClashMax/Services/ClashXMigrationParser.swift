import Foundation
import SQLite3
import Yams

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

struct ClashXMigrationParser {
  private let parser: ClientMigrationParser

  init(fileManager: FileManager = .default) {
    parser = ClientMigrationParser(fileManager: fileManager)
  }

  func parse(directoryURL: URL) -> ClashXMigrationReport {
    parser.parse(directoryURL: directoryURL, preferredClient: .clashX)
  }
}

struct ClientMigrationParser {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func parse(directoryURL: URL) -> ClientMigrationReport {
    parse(directoryURL: directoryURL, preferredClient: nil)
  }

  func parse(directoryURL: URL, preferredClient: MigrationClient?) -> ClientMigrationReport {
    switch preferredClient ?? detectedClient(in: directoryURL) {
    case .clashX:
      return parseClashX(directoryURL: directoryURL)
    case .flClash:
      return parseFlClash(directoryURL: directoryURL)
    case .clashVerge:
      return parseClashVerge(directoryURL: directoryURL)
    }
  }

  private func detectedClient(in directoryURL: URL) -> MigrationClient {
    if fileManager.fileExists(atPath: directoryURL.appendingPathComponent("database.sqlite").path)
      || flClashConfigMapURL(in: directoryURL) != nil {
      return .flClash
    }
    if looksLikeClashVergeDirectory(directoryURL) {
      return .clashVerge
    }
    return .clashX
  }

  private func parseClashX(directoryURL: URL) -> ClientMigrationReport {
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
    var shortcutBindings: [MigratedShortcutBinding] = []
    var menuBarMigrationSuggested = false
    var providerPaths = Set<String>()

    let initialFiles = candidateYAMLFiles(in: directoryURL)
    guard !initialFiles.isEmpty else {
      return ClientMigrationReport(
        client: .clashX,
        configDirectory: directoryURL.path,
        warnings: ["No ClashX YAML files were found in the selected directory."]
      )
    }

    for fileURL in initialFiles {
      parseClashX(
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
        shortcutBindings: &shortcutBindings,
        menuBarMigrationSuggested: &menuBarMigrationSuggested,
        providerPaths: &providerPaths
      )
    }

    for providerPath in providerPaths.sorted() {
      let providerURL = resolvedURL(path: providerPath, relativeTo: directoryURL)
      guard !inspectedFiles.contains(providerURL.standardizedFileURL.path) else { continue }
      parseClashX(
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
        shortcutBindings: &shortcutBindings,
        menuBarMigrationSuggested: &menuBarMigrationSuggested,
        providerPaths: &providerPaths
      )
    }

    let subscriptionURLs = unique(subscriptionEntries.map(\.url))
    let duplicateSubscriptionURLs = duplicates(subscriptionEntries.map(\.url))
    conflicts.append(contentsOf: providerNameConflicts(subscriptionEntries))
    if subscriptionURLs.isEmpty {
      warnings.append("No remote provider subscription URLs were detected.")
    }

    var unsupportedMappings: [MigrationUnsupportedMapping] = []
    for value in unsupportedSettings {
      appendUnsupportedMapping(
        client: .clashX,
        source: value,
        field: value.components(separatedBy: " in ").first ?? value,
        handling: "Not imported",
        action: "report only",
        to: &unsupportedMappings
      )
    }
    for value in unknownKeys {
      appendUnsupportedMapping(
        client: .clashX,
        source: value,
        field: value.components(separatedBy: " in ").first ?? value,
        handling: "Unknown ClashX-specific field",
        action: "report only",
        to: &unsupportedMappings
      )
    }

    return ClientMigrationReport(
      client: .clashX,
      configDirectory: directoryURL.path,
      localProfiles: clashXLocalProfiles(in: directoryURL),
      subscriptions: subscriptionCandidates(
        client: .clashX,
        entries: subscriptionEntries,
        note: "Provider-content, URI, and base64 responses use ClashMax provider-backed runtime; full Clash configs are preserved."
      ),
      unsupportedMappings: uniqueUnsupportedMappings(unsupportedMappings),
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
      warnings: unique(warnings),
      shortcutBindings: uniqueShortcutBindings(shortcutBindings),
      menuBarMigrationSuggested: menuBarMigrationSuggested
    )
  }

  private func parseFlClash(directoryURL: URL) -> ClientMigrationReport {
    var inspectedFiles: [String] = []
    var warnings: [String] = []
    var unsupportedMappings: [MigrationUnsupportedMapping] = []
    var profilesByID: [String: FlClashProfileRow] = [:]
    var rulesByID: [String: String] = [:]
    var links: [FlClashRuleLinkRow] = []
    var scriptsByID: [String: String] = [:]

    let databaseURL = directoryURL.appendingPathComponent("database.sqlite")
    if fileManager.fileExists(atPath: databaseURL.path) {
      appendInspectedFile(databaseURL, to: &inspectedFiles)
      let profiles = sqliteRows(in: databaseURL, tableNames: ["profiles"], warnings: &warnings)
        .map { FlClashProfileRow(row: $0) }
      for profile in profiles {
        profilesByID[profile.id] = profile
      }
      let rules = sqliteRows(in: databaseURL, tableNames: ["rules"], warnings: &warnings)
      for rule in rules {
        guard let id = firstValue(rule, keys: ["id", "rule_id", "ruleId"]),
              let value = firstValue(rule, keys: ["value", "rule", "content"])
        else { continue }
        rulesByID[id] = value
      }
      links.append(contentsOf: sqliteRows(
        in: databaseURL,
        tableNames: ["profile_rule_mapping", "profile_rule_mappings", "profileRuleMapping"],
        warnings: &warnings
      ).map { FlClashRuleLinkRow(row: $0) })
      let scripts = sqliteRows(in: databaseURL, tableNames: ["scripts"], warnings: &warnings)
      for script in scripts {
        guard let id = firstValue(script, keys: ["id", "script_id", "scriptId"]) else { continue }
        scriptsByID[id] = firstValue(script, keys: ["label", "name", "title"]) ?? id
      }
    }

    if let configURL = flClashConfigMapURL(in: directoryURL),
       let state = parseFlClashConfigMap(fileURL: configURL, warnings: &warnings) {
      appendInspectedFile(configURL, to: &inspectedFiles)
      for profile in state.profiles {
        profilesByID[profile.id] = profilesByID[profile.id] ?? profile
      }
      for (id, value) in state.rules where rulesByID[id] == nil {
        rulesByID[id] = value
      }
      links.append(contentsOf: state.links)
      for (id, label) in state.scripts where scriptsByID[id] == nil {
        scriptsByID[id] = label
      }
    }

    if profilesByID.isEmpty, links.isEmpty, rulesByID.isEmpty {
      warnings.append("No FlClash profiles, rules, or link mappings were detected.")
    }

    var localProfiles: [MigratedProfileCandidate] = []
    var subscriptions: [MigratedSubscriptionCandidate] = []
    let profiles = profilesByID.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    for profile in profiles {
      let sourceID = flClashSourceID(profile.id)
      if let urlString = profile.url?.nilIfEmpty {
        let mapping = flClashSubscriptionMapping(for: profile)
        subscriptions.append(
          MigratedSubscriptionCandidate(
            id: sourceID,
            name: profile.displayName,
            urlString: urlString,
            source: "profiles[\(profile.id)].url",
            providerOptions: mapping.providerOptions,
            updatePolicy: mapping.updatePolicy,
            note: "Provider-content, URI, and base64 responses use ClashMax provider-backed runtime; full Clash configs are preserved."
          )
        )
      } else if let profileURL = flClashProfileFile(id: profile.id, in: directoryURL) {
        localProfiles.append(
          MigratedProfileCandidate(
            id: sourceID,
            name: profile.displayName,
            filePath: profileURL.path,
            source: relativePath(profileURL, from: directoryURL),
            note: "Original YAML is imported unchanged."
          )
        )
        appendInspectedFile(profileURL, to: &inspectedFiles)
      }

      if let scriptID = profile.scriptID?.nilIfEmpty {
        appendUnsupportedMapping(
          client: .flClash,
          source: "profiles[\(profile.id)]",
          field: "scriptId=\(scriptID)",
          handling: "Script overwrite is not imported automatically.",
          action: "manual runtime merge",
          to: &unsupportedMappings
        )
      }
      if let overwriteType = profile.overwriteType?.nilIfEmpty,
         overwriteType.localizedCaseInsensitiveContains("script") {
        appendUnsupportedMapping(
          client: .flClash,
          source: "profiles[\(profile.id)]",
          field: "overwriteType=\(overwriteType)",
          handling: "Script overwrite is not imported automatically.",
          action: "manual runtime merge",
          to: &unsupportedMappings
        )
      }
      if let selectedMap = profile.selectedMap?.nilIfEmpty, selectedMap != "{}", selectedMap != "[]" {
        appendUnsupportedMapping(
          client: .flClash,
          source: "profiles[\(profile.id)]",
          field: "selectedMap",
          handling: "Selection UI state is session-specific and is not migrated.",
          action: "report only",
          to: &unsupportedMappings
        )
      }
      if let unfoldSet = profile.unfoldSet?.nilIfEmpty, unfoldSet != "{}", unfoldSet != "[]" {
        appendUnsupportedMapping(
          client: .flClash,
          source: "profiles[\(profile.id)]",
          field: "unfoldSet",
          handling: "Unfold UI state has no ClashMax equivalent.",
          action: "report only",
          to: &unsupportedMappings
        )
      }
    }

    for (id, label) in scriptsByID.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
      appendUnsupportedMapping(
        client: .flClash,
        source: "scripts[\(id)]",
        field: label,
        handling: "Script definitions are report-only.",
        action: "manual runtime merge",
        to: &unsupportedMappings
      )
    }

    let ruleSnippets = flClashRuleSnippets(
      links: uniqueFlClashLinks(links),
      rulesByID: rulesByID,
      profilesByID: profilesByID,
      unsupportedMappings: &unsupportedMappings
    )

    return ClientMigrationReport(
      client: .flClash,
      configDirectory: directoryURL.path,
      localProfiles: localProfiles,
      subscriptions: subscriptions,
      ruleSnippets: ruleSnippets,
      unsupportedMappings: uniqueUnsupportedMappings(unsupportedMappings),
      subscriptionURLs: unique(subscriptions.map(\.urlString)),
      inspectedFiles: inspectedFiles,
      warnings: unique(warnings)
    )
  }

  private func parseClashVerge(directoryURL: URL) -> ClientMigrationReport {
    var inspectedFiles: [String] = []
    var warnings: [String] = []
    var unsupportedMappings: [MigrationUnsupportedMapping] = []
    let profilesURL = ["profiles.yaml", "profiles.yml"]
      .map { directoryURL.appendingPathComponent($0) }
      .first { fileManager.fileExists(atPath: $0.path) }

    guard let profilesURL else {
      return ClientMigrationReport(
        client: .clashVerge,
        configDirectory: directoryURL.path,
        warnings: ["No Clash Verge profiles.yaml was found in the selected directory."]
      )
    }

    appendInspectedFile(profilesURL, to: &inspectedFiles)
    guard let root = loadMapping(from: profilesURL, warnings: &warnings),
          let rawItems = root["items"] as? [[String: Any]]
    else {
      return ClientMigrationReport(
        client: .clashVerge,
        configDirectory: directoryURL.path,
        inspectedFiles: inspectedFiles,
        warnings: warnings + ["profiles.yaml does not contain a Clash Verge items list."]
      )
    }

    let parsedItems = rawItems.enumerated().map { index, raw in
      ClashVergeItem(index: index, raw: raw)
    }
    var items: [ClashVergeItem] = []
    var itemsByID: [String: ClashVergeItem] = [:]
    for item in parsedItems {
      if let existing = itemsByID[item.id] {
        warnings.append("Duplicate Clash Verge item id \(item.id) at items[\(item.index)]; using items[\(existing.index)] and skipping the duplicate.")
        appendUnsupportedMapping(
          client: .clashVerge,
          source: "items[\(item.index)]",
          field: "uid/id/name",
          handling: "Duplicate Clash Verge item id \(item.id) conflicts with items[\(existing.index)].",
          action: "rename duplicate item ids before migrating",
          to: &unsupportedMappings
        )
        continue
      }
      itemsByID[item.id] = item
      items.append(item)
    }
    var localProfiles: [MigratedProfileCandidate] = []
    var subscriptions: [MigratedSubscriptionCandidate] = []
    var ruleSnippets: [MigratedRuleSnippetCandidate] = []

    for item in items {
      let option = item.option
      appendClashVergeUnsupportedOptions(
        item: item,
        option: option,
        unsupportedMappings: &unsupportedMappings
      )

      switch item.type {
      case "remote":
        guard let urlString = item.url?.nilIfEmpty else {
          warnings.append("Remote profile \(item.displayName) has no URL.")
          continue
        }
        let mapping = clashVergeSubscriptionMapping(option: option)
        subscriptions.append(
          MigratedSubscriptionCandidate(
            id: clashVergeSourceID(item.id),
            name: item.displayName,
            urlString: urlString,
            source: "items[\(item.id)].url",
            providerOptions: mapping.providerOptions,
            updatePolicy: mapping.updatePolicy,
            note: "Provider-content, URI, and base64 responses use ClashMax provider-backed runtime; full Clash configs are preserved."
          )
        )
      case "local":
        guard let file = item.file?.nilIfEmpty else {
          warnings.append("Local profile \(item.displayName) has no file.")
          continue
        }
        let fileURL = directoryURL.appendingPathComponent("profiles").appendingPathComponent(file)
        if fileManager.fileExists(atPath: fileURL.path) {
          localProfiles.append(
            MigratedProfileCandidate(
              id: clashVergeSourceID(item.id),
              name: item.displayName,
              filePath: fileURL.path,
              source: relativePath(fileURL, from: directoryURL),
              note: "Original YAML is imported unchanged."
            )
          )
          appendInspectedFile(fileURL, to: &inspectedFiles)
        } else {
          warnings.append("Local profile file \(file) for \(item.displayName) was not found.")
        }
      case "merge", "script", "proxies", "groups":
        appendUnsupportedMapping(
          client: .clashVerge,
          source: "items[\(item.id)]",
          field: item.type,
          handling: "Chain item has no safe one-to-one ClashMax import.",
          action: "manual runtime merge",
          to: &unsupportedMappings
        )
      default:
        break
      }

      let snippets = clashVergeRuleSnippets(
        item: item,
        itemsByID: itemsByID,
        directoryURL: directoryURL,
        inspectedFiles: &inspectedFiles,
        unsupportedMappings: &unsupportedMappings,
        warnings: &warnings
      )
      ruleSnippets.append(contentsOf: snippets)
    }

    if subscriptions.isEmpty, localProfiles.isEmpty, ruleSnippets.isEmpty {
      warnings.append("No Clash Verge local profiles, remote subscriptions, or rule chains were detected.")
    }

    return ClientMigrationReport(
      client: .clashVerge,
      configDirectory: directoryURL.path,
      localProfiles: localProfiles,
      subscriptions: subscriptions,
      ruleSnippets: ruleSnippets,
      unsupportedMappings: uniqueUnsupportedMappings(unsupportedMappings),
      subscriptionURLs: unique(subscriptions.map(\.urlString)),
      inspectedFiles: inspectedFiles,
      warnings: unique(warnings)
    )
  }

  private func parseClashX(
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
    shortcutBindings: inout [MigratedShortcutBinding],
    menuBarMigrationSuggested: inout Bool,
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
      extractShortcutBindings(
        from: root,
        fileLabel: fileLabel,
        shortcutBindings: &shortcutBindings,
        warnings: &warnings
      )
      if hasMenuBarMigrationHint(in: root) {
        menuBarMigrationSuggested = true
      }
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

  private func clashXLocalProfiles(in directoryURL: URL) -> [MigratedProfileCandidate] {
    for fileName in ["config.yaml", "config.yml"] {
      let fileURL = directoryURL.appendingPathComponent(fileName)
      guard fileManager.fileExists(atPath: fileURL.path) else { continue }
      return [
        MigratedProfileCandidate(
          id: "clashx-local-config",
          name: "ClashX config",
          filePath: fileURL.path,
          source: fileName,
          note: "Original YAML is imported unchanged."
        )
      ]
    }
    return []
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

  private func extractShortcutBindings(
    from root: [String: Any],
    fileLabel: String,
    shortcutBindings: inout [MigratedShortcutBinding],
    warnings: inout [String]
  ) {
    for key in ["shortcut", "shortcuts", "hotkey", "hotkeys"] {
      guard let value = root[key] else { continue }
      if let values = value as? [String: Any] {
        for entry in values.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
          addShortcutBinding(
            sourceKey: entry.key,
            value: entry.value,
            fileLabel: fileLabel,
            shortcutBindings: &shortcutBindings,
            warnings: &warnings
          )
        }
      } else if let values = value as? [[String: Any]] {
        for (index, entry) in values.enumerated() {
          let sourceKey = stringValue(entry["name"]) ?? stringValue(entry["action"]) ?? "\(key)[\(index)]"
          let shortcutValue: Any
          if let keyValue = stringValue(entry["key"]) ?? stringValue(entry["shortcut"]) ?? stringValue(entry["hotkey"]) {
            shortcutValue = keyValue
          } else {
            shortcutValue = entry
          }
          addShortcutBinding(
            sourceKey: sourceKey,
            value: shortcutValue,
            fileLabel: fileLabel,
            shortcutBindings: &shortcutBindings,
            warnings: &warnings
          )
        }
      }
    }
  }

  private func addShortcutBinding(
    sourceKey: String,
    value: Any,
    fileLabel: String,
    shortcutBindings: inout [MigratedShortcutBinding],
    warnings: inout [String]
  ) {
    guard let shortcutString = stringValue(value),
          let shortcut = KeyboardShortcutDescriptor(string: shortcutString)
    else {
      warnings.append("Shortcut \(sourceKey) in \(fileLabel) could not be parsed.")
      return
    }
    guard let action = GlobalShortcutAction.clashXAction(for: sourceKey) else {
      warnings.append("Shortcut \(sourceKey) in \(fileLabel) has no matching ClashMax action.")
      return
    }
    shortcutBindings.append(
      MigratedShortcutBinding(sourceKey: sourceKey, action: action, shortcut: shortcut)
    )
  }

  private func hasMenuBarMigrationHint(in root: [String: Any]) -> Bool {
    root.contains { key, value in
      let normalized = key.lowercased()
      guard normalized.contains("menu") || normalized.contains("tray") else { return false }
      if let bool = boolValue(value) {
        return bool
      }
      return true
    }
  }

  private func unsupportedKeys(from root: [String: Any]) -> [String] {
    root.keys.filter { key in
      let normalized = key.lowercased()
      return normalized.contains("applescript")
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
      "hotkey",
      "hotkeys",
      "hosts",
      "ipv6",
      "log-level",
      "menu",
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
      "shortcut",
      "shortcuts",
      "socks-port",
      "subscriptions",
      "subscribes",
      "system-proxy",
      "tproxy-port",
      "tray",
      "tun"
    ]
    return root.keys.filter { !known.contains($0.lowercased()) }.sorted()
  }

  private func flClashSubscriptionMapping(
    for profile: FlClashProfileRow
  ) -> (providerOptions: SubscriptionProviderOptions, updatePolicy: SubscriptionUpdatePolicy) {
    let intervalSeconds = profile.autoUpdateDurationMillis.map { max(1, $0 / 1_000) }
    let intervalMinutes = profile.autoUpdateDurationMillis.map { max(1, Int(ceil(Double($0) / 60_000.0))) }
    return (
      SubscriptionProviderOptions(intervalSeconds: intervalSeconds ?? SubscriptionProviderOptions.default.intervalSeconds),
      SubscriptionUpdatePolicy(
        automaticUpdatesEnabled: profile.autoUpdate ?? true,
        intervalOverrideMinutes: intervalMinutes,
        prefersRemoteInterval: intervalMinutes == nil
      )
    )
  }

  private func clashVergeSubscriptionMapping(
    option: [String: Any]
  ) -> (providerOptions: SubscriptionProviderOptions, updatePolicy: SubscriptionUpdatePolicy) {
    let intervalSeconds = intValue(option["update_interval"])
      ?? intValue(option["updateInterval"])
      ?? intValue(option["interval"])
    let intervalMinutes = intervalSeconds.map { max(1, Int(ceil(Double($0) / 60.0))) }
    let automaticUpdatesEnabled = boolValue(option["allow_auto_update"])
      ?? boolValue(option["allowAutoUpdate"])
      ?? true
    let userAgent = stringValue(option["user_agent"]) ?? stringValue(option["userAgent"])
    var headers: [SubscriptionRequestHeader] = []
    if let userAgent {
      headers.append(SubscriptionRequestHeader(name: "User-Agent", value: userAgent))
    }
    let fetchProxy: SubscriptionProviderFetchProxy
    if boolValue(option["self_proxy"]) == true || boolValue(option["selfProxy"]) == true {
      fetchProxy = .localClashProxy
    } else if boolValue(option["with_proxy"]) == true || boolValue(option["withProxy"]) == true {
      fetchProxy = .systemProxy
    } else {
      fetchProxy = .defaultOrder
    }
    return (
      SubscriptionProviderOptions(
        intervalSeconds: intervalSeconds ?? SubscriptionProviderOptions.default.intervalSeconds,
        requestHeaders: headers,
        fetchProxy: fetchProxy
      ),
      SubscriptionUpdatePolicy(
        automaticUpdatesEnabled: automaticUpdatesEnabled,
        intervalOverrideMinutes: intervalMinutes,
        prefersRemoteInterval: intervalMinutes == nil
      )
    )
  }

  private func flClashRuleSnippets(
    links: [FlClashRuleLinkRow],
    rulesByID: [String: String],
    profilesByID: [String: FlClashProfileRow],
    unsupportedMappings: inout [MigrationUnsupportedMapping]
  ) -> [MigratedRuleSnippetCandidate] {
    var grouped: [String: MigratedRuleSnippetAccumulator] = [:]
    for link in links {
      guard let ruleValue = rulesByID[link.ruleID] else {
        appendUnsupportedMapping(
          client: .flClash,
          source: "profile_rule_mapping[\(link.id)]",
          field: "ruleId=\(link.ruleID)",
          handling: "Rule value was not found.",
          action: "manual routing snippet",
          to: &unsupportedMappings
        )
        continue
      }
      let profileID = link.profileID?.nilIfEmpty
      let sourceKey = profileID.map(flClashSourceID) ?? "flclash-global-rules"
      var accumulator = grouped[sourceKey] ?? MigratedRuleSnippetAccumulator()
      let scene = link.scene?.lowercased() ?? ""
      if ["disabled", "disable", "deleted", "delete"].contains(scene) {
        accumulator.disabledRuleMatchers.append(ManagedRuleDisableMatcher(mode: .exact, pattern: ruleValue))
      } else if let rule = managedRule(
        from: ruleValue,
        client: .flClash,
        source: "rules[\(link.ruleID)]",
        unsupportedMappings: &unsupportedMappings
      ) {
        if ["append", "end", "tail"].contains(scene) {
          accumulator.appendRules.append(rule)
        } else {
          accumulator.prependRules.append(rule)
        }
      }
      grouped[sourceKey] = accumulator
    }

    return grouped
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .compactMap { key, accumulator in
        let settings = accumulator.settings
        guard settings.hasRuntimeOverlay else { return nil }
        let profileID = key == "flclash-global-rules" ? nil : key
        let name: String
        if let profileID,
           let rawProfileID = profileID.replacingOccurrences(of: "flclash-profile-", with: "").nilIfEmpty,
           let profile = profilesByID[rawProfileID] {
          name = "FlClash \(profile.displayName) Rules"
        } else {
          name = "FlClash Global Rules"
        }
        return MigratedRuleSnippetCandidate(
          id: key,
          name: name,
          profileSourceID: profileID,
          settings: settings,
          source: profileID == nil ? "global rules" : "profile rule mapping",
          note: profileID == nil ? "Applies to all ClashMax profiles." : "Bound to the imported profile or subscription when applied."
        )
      }
  }

  private func clashVergeRuleSnippets(
    item: ClashVergeItem,
    itemsByID: [String: ClashVergeItem],
    directoryURL: URL,
    inspectedFiles: inout [String],
    unsupportedMappings: inout [MigrationUnsupportedMapping],
    warnings: inout [String]
  ) -> [MigratedRuleSnippetCandidate] {
    let ruleIDs = stringListValue(item.option["rules"])
    guard !ruleIDs.isEmpty else { return [] }
    var snippets: [MigratedRuleSnippetCandidate] = []
    for ruleID in ruleIDs {
      guard let ruleItem = itemsByID[ruleID] else {
        appendUnsupportedMapping(
          client: .clashVerge,
          source: "items[\(item.id)].option.rules",
          field: ruleID,
          handling: "Referenced rules chain was not found.",
          action: "manual routing snippet",
          to: &unsupportedMappings
        )
        continue
      }
      guard let file = ruleItem.file?.nilIfEmpty else {
        appendUnsupportedMapping(
          client: .clashVerge,
          source: "items[\(ruleItem.id)]",
          field: "file",
          handling: "Rules chain has no readable file.",
          action: "manual routing snippet",
          to: &unsupportedMappings
        )
        continue
      }
      let fileURL = directoryURL.appendingPathComponent("profiles").appendingPathComponent(file)
      guard fileManager.fileExists(atPath: fileURL.path) else {
        warnings.append("Rules chain file \(file) for \(item.displayName) was not found.")
        continue
      }
      appendInspectedFile(fileURL, to: &inspectedFiles)
      guard let root = loadMapping(from: fileURL, warnings: &warnings) else { continue }
      var accumulator = MigratedRuleSnippetAccumulator()
      for raw in stringListValue(root["prepend"]) {
        if let rule = managedRule(
          from: raw,
          client: .clashVerge,
          source: "\(relativePath(fileURL, from: directoryURL)):prepend",
          unsupportedMappings: &unsupportedMappings
        ) {
          accumulator.prependRules.append(rule)
        }
      }
      for raw in stringListValue(root["append"]) {
        if let rule = managedRule(
          from: raw,
          client: .clashVerge,
          source: "\(relativePath(fileURL, from: directoryURL)):append",
          unsupportedMappings: &unsupportedMappings
        ) {
          accumulator.appendRules.append(rule)
        }
      }
      for raw in stringListValue(root["delete"]) {
        accumulator.disabledRuleMatchers.append(ManagedRuleDisableMatcher(mode: .exact, pattern: raw))
      }
      let settings = accumulator.settings
      guard settings.hasRuntimeOverlay else { continue }
      snippets.append(
        MigratedRuleSnippetCandidate(
          id: "\(clashVergeSourceID(item.id))-rules-\(ruleItem.id)",
          name: "Clash Verge \(item.displayName) Rules",
          profileSourceID: clashVergeSourceID(item.id),
          settings: settings,
          source: relativePath(fileURL, from: directoryURL),
          note: "prepend, append, and delete are mapped to ClashMax rule overlays."
        )
      )
    }
    return snippets
  }

  private func appendClashVergeUnsupportedOptions(
    item: ClashVergeItem,
    option: [String: Any],
    unsupportedMappings: inout [MigrationUnsupportedMapping]
  ) {
    let unsupportedFields = [
      "merge": "manual runtime merge",
      "script": "manual runtime merge",
      "proxies": "manual runtime merge",
      "groups": "manual runtime merge",
      "danger_accept_invalid_certs": "report only",
      "dangerAcceptInvalidCerts": "report only",
      "selected": "report only",
      "extra": "report only",
      "home": "report only"
    ]
    for (field, action) in unsupportedFields.sorted(by: { $0.key < $1.key }) where option[field] != nil {
      appendUnsupportedMapping(
        client: .clashVerge,
        source: "items[\(item.id)].option",
        field: field,
        handling: handlingForClashVergeUnsupportedField(field),
        action: action,
        to: &unsupportedMappings
      )
    }
  }

  private func handlingForClashVergeUnsupportedField(_ field: String) -> String {
    switch field {
    case "danger_accept_invalid_certs", "dangerAcceptInvalidCerts":
      return "Unsafe TLS behavior is not enabled by migration."
    case "selected", "extra", "home":
      return "UI/session metadata has no ClashMax equivalent."
    case "merge", "script", "proxies", "groups":
      return "Chain item has no safe one-to-one ClashMax import."
    default:
      return "Not imported automatically."
    }
  }

  private func managedRule(
    from rawRule: String,
    client: MigrationClient,
    source: String,
    unsupportedMappings: inout [MigrationUnsupportedMapping]
  ) -> ManagedRuleOverlayRule? {
    let parts = splitRule(rawRule)
    guard let kindRaw = parts.first?.uppercased(),
          let kind = ManagedRuleOverlayRule.Kind(rawValue: kindRaw)
    else {
      appendUnsupportedMapping(
        client: client,
        source: source,
        field: rawRule,
        handling: "Rule kind is not supported by ClashMax rule overlays.",
        action: "manual routing snippet",
        to: &unsupportedMappings
      )
      return nil
    }

    let noResolve = parts.dropFirst().contains { $0.caseInsensitiveCompare("no-resolve") == .orderedSame }
    let rule: ManagedRuleOverlayRule
    switch kind {
    case .match:
      guard parts.count >= 2 else {
        appendUnsupportedRule(rawRule, client: client, source: source, to: &unsupportedMappings)
        return nil
      }
      rule = ManagedRuleOverlayRule(kind: kind, policy: parts[1], noResolve: false)
    case .subRule:
      guard parts.count >= 3 else {
        appendUnsupportedRule(rawRule, client: client, source: source, to: &unsupportedMappings)
        return nil
      }
      rule = ManagedRuleOverlayRule(
        kind: kind,
        value: strippedParentheses(parts[1]),
        policy: parts[2],
        noResolve: false
      )
    default:
      guard parts.count >= 3 else {
        appendUnsupportedRule(rawRule, client: client, source: source, to: &unsupportedMappings)
        return nil
      }
      rule = ManagedRuleOverlayRule(
        kind: kind,
        value: parts[1],
        policy: parts[2],
        noResolve: noResolve
      )
    }

    if rule.validationError != nil {
      appendUnsupportedRule(rawRule, client: client, source: source, to: &unsupportedMappings)
      return nil
    }
    return rule
  }

  private func appendUnsupportedRule(
    _ rawRule: String,
    client: MigrationClient,
    source: String,
    to unsupportedMappings: inout [MigrationUnsupportedMapping]
  ) {
    appendUnsupportedMapping(
      client: client,
      source: source,
      field: rawRule,
      handling: "Rule value cannot be converted without changing behavior.",
      action: "manual routing snippet",
      to: &unsupportedMappings
    )
  }

  private func splitRule(_ rawRule: String) -> [String] {
    var parts: [String] = []
    var buffer = ""
    var depth = 0
    for character in rawRule {
      if character == "," && depth == 0 {
        parts.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        buffer = ""
        continue
      }
      if character == "(" {
        depth += 1
      } else if character == ")" {
        depth = max(0, depth - 1)
      }
      buffer.append(character)
    }
    parts.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
    return parts.filter { !$0.isEmpty }
  }

  private func strippedParentheses(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
  }

  private func subscriptionCandidates(
    client: MigrationClient,
    entries: [(name: String?, url: String, file: String)],
    note: String
  ) -> [MigratedSubscriptionCandidate] {
    var seen = Set<String>()
    var result: [MigratedSubscriptionCandidate] = []
    for entry in entries {
      let normalized = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else { continue }
      result.append(
        MigratedSubscriptionCandidate(
          id: "\(client.rawValue)-subscription-\(result.count + 1)",
          name: entry.name ?? "",
          urlString: normalized,
          source: entry.file,
          note: note
        )
      )
    }
    return result
  }

  private func parseFlClashConfigMap(fileURL: URL, warnings: inout [String]) -> FlClashConfigMapState? {
    guard let root = loadMapping(from: fileURL, warnings: &warnings) else { return nil }
    let config = root["configMap"] as? [String: Any] ?? root
    let profiles = arrayOfMappings(config["profiles"]).map(FlClashProfileRow.init)
    let rules = arrayOfMappings(config["rules"]).reduce(into: [String: String]()) { result, rule in
      guard let id = firstValue(rule, keys: ["id", "rule_id", "ruleId"]),
            let value = firstValue(rule, keys: ["value", "rule", "content"])
      else { return }
      result[id] = value
    }
    let linkValues = config["links"] ?? config["profile_rule_mapping"] ?? config["profileRuleMapping"]
    let links = arrayOfMappings(linkValues).map(FlClashRuleLinkRow.init)
    let scripts = arrayOfMappings(config["scripts"]).reduce(into: [String: String]()) { result, script in
      guard let id = firstValue(script, keys: ["id", "script_id", "scriptId"]) else { return }
      result[id] = firstValue(script, keys: ["label", "name", "title"]) ?? id
    }
    guard !profiles.isEmpty || !rules.isEmpty || !links.isEmpty || !scripts.isEmpty else { return nil }
    return FlClashConfigMapState(profiles: profiles, rules: rules, links: links, scripts: scripts)
  }

  private func flClashConfigMapURL(in directoryURL: URL) -> URL? {
    let candidateNames = [
      "backup.json",
      "backup.yaml",
      "backup.yml",
      "config.json",
      "config.yaml",
      "config.yml",
      "shared_preferences.json"
    ]
    for name in candidateNames {
      let url = directoryURL.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: url.path),
            let root = loadMapping(from: url)
      else { continue }
      if root["configMap"] != nil
        || (root["profiles"] != nil && (root["links"] != nil || root["profile_rule_mapping"] != nil || root["profileRuleMapping"] != nil)) {
        return url
      }
    }
    return nil
  }

  private func looksLikeClashVergeDirectory(_ directoryURL: URL) -> Bool {
    for name in ["profiles.yaml", "profiles.yml"] {
      let url = directoryURL.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: url.path),
            let root = loadMapping(from: url),
            let items = root["items"] as? [[String: Any]]
      else { continue }
      if items.contains(where: { stringValue($0["type"]) != nil || stringValue($0["uid"]) != nil || stringValue($0["id"]) != nil }) {
        return true
      }
    }
    return false
  }

  private func loadMapping(from fileURL: URL) -> [String: Any]? {
    var warnings: [String] = []
    return loadMapping(from: fileURL, warnings: &warnings)
  }

  private func loadMapping(from fileURL: URL, warnings: inout [String]) -> [String: Any]? {
    do {
      let data = try Data(contentsOf: fileURL)
      if fileURL.pathExtension.lowercased() == "json" {
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
      }
      let source = String(data: data, encoding: .utf8) ?? ""
      return try Yams.load(yaml: source) as? [String: Any]
    } catch {
      warnings.append("\(fileURL.lastPathComponent) could not be parsed: \(String(describing: error))")
      return nil
    }
  }

  private func sqliteRows(in databaseURL: URL, tableNames: [String], warnings: inout [String]) -> [[String: String]] {
    for tableName in tableNames {
      if let rows = try? sqliteRows(in: databaseURL, tableName: tableName) {
        return rows
      }
    }
    return []
  }

  private func sqliteRows(in databaseURL: URL, tableName: String) throws -> [[String: String]] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database
    else {
      throw SQLiteReadError.open
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    let sql = "SELECT * FROM \(tableName)"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
      throw SQLiteReadError.prepare
    }
    defer { sqlite3_finalize(statement) }

    let columnCount = sqlite3_column_count(statement)
    var rows: [[String: String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      var row: [String: String] = [:]
      for index in 0..<columnCount {
        guard let namePointer = sqlite3_column_name(statement, index) else { continue }
        let name = String(cString: namePointer)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
          row[name] = String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
          row[name] = String(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
          if let textPointer = sqlite3_column_text(statement, index) {
            row[name] = String(cString: textPointer)
          }
        default:
          break
        }
      }
      rows.append(row)
    }
    return rows
  }

  private func arrayOfMappings(_ value: Any?) -> [[String: Any]] {
    if let values = value as? [[String: Any]] {
      return values
    }
    if let values = value as? [Any] {
      return values.compactMap { $0 as? [String: Any] }
    }
    if let values = value as? [String: Any] {
      return values.map { key, value in
        if var mapping = value as? [String: Any] {
          mapping["id"] = mapping["id"] ?? key
          return mapping
        }
        return ["id": key, "value": value]
      }
    }
    return []
  }

  private func flClashProfileFile(id: String, in directoryURL: URL) -> URL? {
    for fileName in ["\(id).yaml", "\(id).yml"] {
      let url = directoryURL.appendingPathComponent("profiles").appendingPathComponent(fileName)
      if fileManager.fileExists(atPath: url.path) {
        return url
      }
    }
    return nil
  }

  private func flClashSourceID(_ id: String) -> String {
    "flclash-profile-\(stableIdentifier(id))"
  }

  private func clashVergeSourceID(_ id: String) -> String {
    "clashverge-profile-\(stableIdentifier(id))"
  }

  private func stableIdentifier(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let id = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return id.nilIfEmpty ?? "item"
  }

  private func uniqueShortcutBindings(_ values: [MigratedShortcutBinding]) -> [MigratedShortcutBinding] {
    var seen = Set<String>()
    var result: [MigratedShortcutBinding] = []
    for value in values {
      let key = "\(value.action.rawValue):\(value.shortcut.storageString)".lowercased()
      guard seen.insert(key).inserted else { continue }
      result.append(value)
    }
    return result
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

  private func uniqueFlClashLinks(_ values: [FlClashRuleLinkRow]) -> [FlClashRuleLinkRow] {
    var seen = Set<String>()
    var result: [FlClashRuleLinkRow] = []
    for value in values {
      let key = "\(value.profileID ?? "")|\(value.ruleID)|\(value.scene ?? "")"
      guard seen.insert(key).inserted else { continue }
      result.append(value)
    }
    return result
  }

  private func uniqueUnsupportedMappings(_ values: [MigrationUnsupportedMapping]) -> [MigrationUnsupportedMapping] {
    var seen = Set<String>()
    var result: [MigrationUnsupportedMapping] = []
    for value in values {
      let key = "\(value.source)|\(value.field)|\(value.handling)|\(value.action)"
      guard seen.insert(key).inserted else { continue }
      result.append(value)
    }
    return result
  }

  private func appendUnsupportedMapping(
    client: MigrationClient,
    source: String,
    field: String,
    handling: String,
    action: String,
    to unsupportedMappings: inout [MigrationUnsupportedMapping]
  ) {
    unsupportedMappings.append(
      MigrationUnsupportedMapping(
        id: "\(client.rawValue)-unsupported-\(unsupportedMappings.count + 1)",
        source: source,
        field: field,
        handling: handling,
        action: action
      )
    )
  }

  private func appendInspectedFile(_ fileURL: URL, to inspectedFiles: inout [String]) {
    let path = fileURL.standardizedFileURL.path
    guard !inspectedFiles.contains(path) else { return }
    inspectedFiles.append(path)
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

  private func firstValue(_ row: [String: String], keys: [String]) -> String? {
    for key in keys {
      if let value = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    let normalized = row.reduce(into: [String: String]()) { result, entry in
      result[entry.key.replacingOccurrences(of: "_", with: "").lowercased()] = entry.value
    }
    for key in keys {
      let lookupKey = key.replacingOccurrences(of: "_", with: "").lowercased()
      if let value = normalized[lookupKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private func firstValue(_ row: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = stringValue(row[key]) {
        return value
      }
    }
    let normalized = row.reduce(into: [String: Any]()) { result, entry in
      result[entry.key.replacingOccurrences(of: "_", with: "").lowercased()] = entry.value
    }
    for key in keys {
      let lookupKey = key.replacingOccurrences(of: "_", with: "").lowercased()
      if let value = stringValue(normalized[lookupKey]) {
        return value
      }
    }
    return nil
  }

  private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let value = value as? NSNumber {
      return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let value {
      return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return nil
  }

  private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? Int64 {
      return Int(value)
    }
    if let value = value as? NSNumber {
      return value.intValue
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
    if let value = value as? NSNumber {
      return value.boolValue
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
      return values.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }
    if let values = value as? [Any] {
      return values.compactMap { stringValue($0) }
    }
    if let value = stringValue(value) {
      return value.split(separator: ",").compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }
    return []
  }
}

private struct FlClashProfileRow {
  var id: String
  var label: String?
  var url: String?
  var autoUpdateDurationMillis: Int?
  var autoUpdate: Bool?
  var overwriteType: String?
  var scriptID: String?
  var selectedMap: String?
  var unfoldSet: String?

  init(row: [String: String]) {
    id = ClientMigrationParserStatic.firstValue(row, keys: ["id", "profile_id", "profileId"]) ?? UUID().uuidString
    label = ClientMigrationParserStatic.firstValue(row, keys: ["label", "name", "title"])
    url = ClientMigrationParserStatic.firstValue(row, keys: ["url", "uri", "subscription_url", "subscriptionUrl"])
    autoUpdateDurationMillis = ClientMigrationParserStatic.intValue(
      ClientMigrationParserStatic.firstValue(row, keys: ["auto_update_duration_millis", "autoUpdateDurationMillis"])
    )
    autoUpdate = ClientMigrationParserStatic.boolValue(
      ClientMigrationParserStatic.firstValue(row, keys: ["auto_update", "autoUpdate"])
    )
    overwriteType = ClientMigrationParserStatic.firstValue(row, keys: ["overwrite_type", "overwriteType"])
    scriptID = ClientMigrationParserStatic.firstValue(row, keys: ["script_id", "scriptId"])
    selectedMap = ClientMigrationParserStatic.firstValue(row, keys: ["selected_map", "selectedMap"])
    unfoldSet = ClientMigrationParserStatic.firstValue(row, keys: ["unfold_set", "unfoldSet"])
  }

  init(_ row: [String: Any]) {
    id = ClientMigrationParserStatic.firstValue(row, keys: ["id", "profile_id", "profileId"]) ?? UUID().uuidString
    label = ClientMigrationParserStatic.firstValue(row, keys: ["label", "name", "title"])
    url = ClientMigrationParserStatic.firstValue(row, keys: ["url", "uri", "subscription_url", "subscriptionUrl"])
    autoUpdateDurationMillis = ClientMigrationParserStatic.intValue(
      ClientMigrationParserStatic.firstValue(row, keys: ["auto_update_duration_millis", "autoUpdateDurationMillis"])
    )
    autoUpdate = ClientMigrationParserStatic.boolValue(
      ClientMigrationParserStatic.firstValue(row, keys: ["auto_update", "autoUpdate"])
    )
    overwriteType = ClientMigrationParserStatic.firstValue(row, keys: ["overwrite_type", "overwriteType"])
    scriptID = ClientMigrationParserStatic.firstValue(row, keys: ["script_id", "scriptId"])
    selectedMap = ClientMigrationParserStatic.firstValue(row, keys: ["selected_map", "selectedMap"])
    unfoldSet = ClientMigrationParserStatic.firstValue(row, keys: ["unfold_set", "unfoldSet"])
  }

  var displayName: String {
    label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "FlClash \(id)"
  }
}

private struct FlClashRuleLinkRow {
  var id: String
  var profileID: String?
  var ruleID: String
  var scene: String?

  init(row: [String: String]) {
    id = ClientMigrationParserStatic.firstValue(row, keys: ["id"]) ?? UUID().uuidString
    profileID = ClientMigrationParserStatic.firstValue(row, keys: ["profile_id", "profileId"])
    ruleID = ClientMigrationParserStatic.firstValue(row, keys: ["rule_id", "ruleId"]) ?? ""
    scene = ClientMigrationParserStatic.firstValue(row, keys: ["scene", "type", "action"])
  }

  init(_ row: [String: Any]) {
    id = ClientMigrationParserStatic.firstValue(row, keys: ["id"]) ?? UUID().uuidString
    profileID = ClientMigrationParserStatic.firstValue(row, keys: ["profile_id", "profileId"])
    ruleID = ClientMigrationParserStatic.firstValue(row, keys: ["rule_id", "ruleId"]) ?? ""
    scene = ClientMigrationParserStatic.firstValue(row, keys: ["scene", "type", "action"])
  }
}

private struct FlClashConfigMapState {
  var profiles: [FlClashProfileRow]
  var rules: [String: String]
  var links: [FlClashRuleLinkRow]
  var scripts: [String: String]
}

private struct ClashVergeItem {
  var index: Int
  var id: String
  var type: String
  var name: String?
  var url: String?
  var file: String?
  var option: [String: Any]

  init(index: Int, raw: [String: Any]) {
    self.index = index
    id = ClientMigrationParserStatic.firstValue(raw, keys: ["uid", "id", "name"]) ?? "item-\(index)"
    type = ClientMigrationParserStatic.firstValue(raw, keys: ["type"])?.lowercased() ?? ""
    name = ClientMigrationParserStatic.firstValue(raw, keys: ["name", "label", "title"])
    url = ClientMigrationParserStatic.firstValue(raw, keys: ["url", "uri"])
    file = ClientMigrationParserStatic.firstValue(raw, keys: ["file", "path"])
    option = raw["option"] as? [String: Any] ?? [:]
  }

  var displayName: String {
    name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? id
  }
}

private struct MigratedRuleSnippetAccumulator {
  var prependRules: [ManagedRuleOverlayRule] = []
  var appendRules: [ManagedRuleOverlayRule] = []
  var disabledRuleMatchers: [ManagedRuleDisableMatcher] = []

  var settings: RuleOverlaySettings {
    RuleOverlaySettings(
      enabled: !prependRules.isEmpty || !appendRules.isEmpty || !disabledRuleMatchers.isEmpty,
      prependRules: prependRules,
      appendRules: appendRules,
      disabledRuleMatchers: disabledRuleMatchers
    )
  }
}

private enum SQLiteReadError: Error {
  case open
  case prepare
}

private enum ClientMigrationParserStatic {
  static func firstValue(_ row: [String: String], keys: [String]) -> String? {
    for key in keys {
      if let value = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    let normalized = row.reduce(into: [String: String]()) { result, entry in
      result[entry.key.replacingOccurrences(of: "_", with: "").lowercased()] = entry.value
    }
    for key in keys {
      let lookupKey = key.replacingOccurrences(of: "_", with: "").lowercased()
      if let value = normalized[lookupKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  static func firstValue(_ row: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = stringValue(row[key]) {
        return value
      }
    }
    let normalized = row.reduce(into: [String: Any]()) { result, entry in
      result[entry.key.replacingOccurrences(of: "_", with: "").lowercased()] = entry.value
    }
    for key in keys {
      let lookupKey = key.replacingOccurrences(of: "_", with: "").lowercased()
      if let value = stringValue(normalized[lookupKey]) {
        return value
      }
    }
    return nil
  }

  static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let value = value as? NSNumber {
      return value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let value {
      return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return nil
  }

  static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
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
}
