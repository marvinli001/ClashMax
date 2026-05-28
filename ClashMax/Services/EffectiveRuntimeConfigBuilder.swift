import Foundation
import Yams

enum EffectiveRuntimeConfigPreflightMode {
  case disabled
  case validate(coreURL: URL, validator: any RuntimeConfigValidating)
}

@MainActor
struct EffectiveRuntimeConfigBuilder {
  private let materializer: RuntimeConfigMaterializer
  private let now: @MainActor () -> Date

  init(
    materializer: RuntimeConfigMaterializer = RuntimeConfigMaterializer(),
    now: @escaping @MainActor () -> Date = Date.init
  ) {
    self.materializer = materializer
    self.now = now
  }

  func snapshot(
    profile: Profile,
    paths: RuntimePaths,
    overrides: RuntimeOverrides,
    selectionOverrides: [String: String],
    runtimeSnippets: [RuntimeSnippet],
    preflight: EffectiveRuntimeConfigPreflightMode
  ) async throws -> EffectiveRuntimeConfigSnapshot {
    let preflightDirectory = paths.runtime.appendingPathComponent(
      "effective-config-preview-\(UUID().uuidString)",
      isDirectory: true
    )
    try SecureFileIO.createPrivateDirectory(at: preflightDirectory)
    defer {
      try? FileManager.default.removeItem(at: preflightDirectory)
    }

    let originalSource = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    let sourceFormat = try? ProfileConfigInspector.format(of: originalSource)
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = profile.subscriptionProviderOptions
    options.runtimeSnippets = runtimeSnippets

    let materialization = try await materializer.materializeResult(
      RuntimeConfigMaterializationRequest(
        profileName: profile.name,
        sourcePath: profile.originalConfigPath,
        runtimeConfigURL: preflightDirectory.appendingPathComponent("runtime.yaml"),
        providerContentURL: preflightDirectory.appendingPathComponent("provider.txt"),
        overrides: overrides,
        selectionOverrides: selectionOverrides,
        options: options,
        retainedGenerationCount: 0
      )
    )
    let finalRuntimeYAML = try String(contentsOf: materialization.runtimeConfigURL, encoding: .utf8)
    let providerContent = materialization.providerContentURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    let providerContentPaths = materialization.providerContentURL.map { [$0.path] } ?? []
    let redactedOriginal = RuntimeConfigDisplayRedactor.redacted(
      originalSource,
      controllerSecret: overrides.secret,
      providerContentPaths: providerContentPaths
    )
    let redactedFinal = RuntimeConfigDisplayRedactor.redacted(
      finalRuntimeYAML,
      controllerSecret: overrides.secret,
      providerContentPaths: providerContentPaths
    )
    let layers = makeLayers(
      profile: profile,
      overrides: overrides,
      sourceFormat: sourceFormat,
      providerContent: providerContent,
      providerContentPaths: providerContentPaths,
      runtimeSnippets: runtimeSnippets,
      redactedOriginal: redactedOriginal,
      redactedFinal: redactedFinal
    )
    let preflightStatus = await validateIfNeeded(
      preflight,
      configURL: materialization.runtimeConfigURL,
      workDirectory: preflightDirectory
    )
    return EffectiveRuntimeConfigSnapshot(
      generatedAt: now(),
      profileID: profile.id,
      profileName: profile.name,
      layers: layers,
      diffRows: EffectiveRuntimeConfigLineDiff.diff(oldText: redactedOriginal, newText: redactedFinal),
      redactedOriginalYAML: redactedOriginal,
      redactedFinalYAML: redactedFinal,
      preflightStatus: preflightStatus
    )
  }

  private func validateIfNeeded(
    _ preflight: EffectiveRuntimeConfigPreflightMode,
    configURL: URL,
    workDirectory: URL
  ) async -> EffectiveRuntimeConfigPreflightStatus {
    switch preflight {
    case .disabled:
      return .notRun
    case let .validate(coreURL, validator):
      do {
        try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
        return .passed
      } catch {
        return .failed(UserFacingError.message(for: error))
      }
    }
  }

  private func makeLayers(
    profile: Profile,
    overrides: RuntimeOverrides,
    sourceFormat: ProfileConfigFormat?,
    providerContent: String?,
    providerContentPaths: [String],
    runtimeSnippets: [RuntimeSnippet],
    redactedOriginal: String,
    redactedFinal: String
  ) -> [EffectiveRuntimeConfigLayer] {
    [
      EffectiveRuntimeConfigLayer(
        id: "original",
        title: "Original profile",
        summary: sourceFormat == .proxyProviderContent
          ? String(localized: "Original provider content is kept unchanged and wrapped at runtime.")
          : String(localized: "Original Clash YAML is kept unchanged on disk."),
        redactedContent: redactedOriginal
      ),
      EffectiveRuntimeConfigLayer(
        id: "provider-materialization",
        title: "Provider materialization",
        summary: providerContent == nil
          ? String(localized: "No provider content wrapping is required.")
          : String(localized: "Provider content is materialized as the app-managed clashmax-subscription-provider."),
        redactedContent: providerMaterializationContent(
          providerContent,
          controllerSecret: overrides.secret,
          providerContentPaths: providerContentPaths
        ),
        isActive: providerContent != nil
      ),
      EffectiveRuntimeConfigLayer(
        id: "global-overlay",
        title: "Global overlay",
        summary: overrides.ruleOverlay.summary,
        redactedContent: renderRuleOverlay(overrides.ruleOverlay),
        isActive: overrides.ruleOverlay.hasRuntimeOverlay
      ),
      EffectiveRuntimeConfigLayer(
        id: "profile-overlay",
        title: "Profile overlay",
        summary: profile.subscriptionProviderOptions.ruleOverlay.summary,
        redactedContent: renderProfileOverlay(
          profile.subscriptionProviderOptions,
          controllerSecret: overrides.secret,
          providerContentPaths: providerContentPaths
        ),
        isActive: profile.subscriptionProviderOptions.ruleOverlay.hasRuntimeOverlay
          || profile.subscriptionProviderOptions.hasRuntimeMergeYAML
          || !profile.subscriptionProviderOptions.overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ),
      EffectiveRuntimeConfigLayer(
        id: "snippets",
        title: "Snippets",
        summary: String(format: String(localized: "%lld active snippets"), Int64(runtimeSnippets.count)),
        redactedContent: renderSnippets(runtimeSnippets),
        isActive: !runtimeSnippets.isEmpty
      ),
      EffectiveRuntimeConfigLayer(
        id: "final-runtime-yaml",
        title: "Final runtime YAML",
        summary: String(localized: "Final generated YAML used by Mihomo after app-managed overlays."),
        redactedContent: redactedFinal
      )
    ]
  }

  private func providerMaterializationContent(
    _ providerContent: String?,
    controllerSecret: String,
    providerContentPaths: [String]
  ) -> String {
    guard let providerContent else {
      return String(localized: "Original profile already contains Clash runtime YAML.")
    }
    return RuntimeConfigDisplayRedactor.redacted(
      providerContent,
      controllerSecret: controllerSecret,
      providerContentPaths: providerContentPaths
    )
  }

  private func renderProfileOverlay(
    _ options: SubscriptionProviderOptions,
    controllerSecret: String,
    providerContentPaths: [String]
  ) -> String {
    var sections: [String] = [
      "Generated Template: \(options.generatedTemplate.displayName) v\(options.generatedTemplateVersion)",
      "Provider Interval: \(options.intervalSeconds)s",
      "Custom Headers: \(options.normalizedHeaders.count)",
      "Provider Rule Overlay:",
      renderRuleOverlay(options.ruleOverlay)
    ]
    let overrideYAML = options.overrideYAML.trimmingCharacters(in: .whitespacesAndNewlines)
    if !overrideYAML.isEmpty {
      sections.append("Provider Override YAML:")
      sections.append(RuntimeConfigDisplayRedactor.redacted(
        overrideYAML,
        controllerSecret: controllerSecret,
        providerContentPaths: providerContentPaths
      ))
    }
    let runtimeMergeYAML = options.runtimeMergeYAML.trimmingCharacters(in: .whitespacesAndNewlines)
    if !runtimeMergeYAML.isEmpty {
      sections.append("Runtime Merge YAML:")
      sections.append(RuntimeConfigDisplayRedactor.redacted(
        runtimeMergeYAML,
        controllerSecret: controllerSecret,
        providerContentPaths: providerContentPaths
      ))
    }
    return sections.joined(separator: "\n")
  }

  private func renderSnippets(_ snippets: [RuntimeSnippet]) -> String {
    guard !snippets.isEmpty else {
      return String(localized: "No active snippets apply to this profile.")
    }
    return snippets.map { snippet in
      [
        "Snippet: \(snippet.normalizedName.isEmpty ? String(localized: "Untitled Snippet") : snippet.normalizedName)",
        "Binding: \(snippet.binding.displayName)",
        "Payload: \(snippet.payload.summary)",
        renderSnippetPayload(snippet.payload)
      ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
    .joined(separator: "\n\n")
  }

  private func renderSnippetPayload(_ payload: RuntimeSnippetPayload) -> String {
    switch payload {
    case let .rules(settings):
      return renderRuleOverlay(settings)
    case let .dnsPatch(settings):
      return renderDNSPatch(settings)
    }
  }

  private func renderRuleOverlay(_ overlay: RuleOverlaySettings) -> String {
    var lines: [String] = ["Enabled: \(overlay.enabled ? "yes" : "no")"]
    if !overlay.runtimePrependRules.isEmpty {
      lines.append("Before:")
      lines.append(contentsOf: overlay.runtimePrependRules.map { "- \($0)" })
    }
    if !overlay.runtimeDisabledRuleMatchers.isEmpty {
      lines.append("Disabled:")
      lines.append(contentsOf: overlay.runtimeDisabledRuleMatchers.map { "- \($0.mode.displayName): \($0.normalizedPattern)" })
    }
    if !overlay.runtimeAppendRules.isEmpty {
      lines.append("After:")
      lines.append(contentsOf: overlay.runtimeAppendRules.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  private func renderDNSPatch(_ settings: TunDNSSettings) -> String {
    var lines: [String] = []
    appendOptional(settings.respectRules, title: "respect-rules", to: &lines)
    appendOptional(settings.useSystemHosts, title: "use-system-hosts", to: &lines)
    appendOptional(settings.useHosts, title: "use-hosts", to: &lines)
    appendOptional(settings.preferH3, title: "prefer-h3", to: &lines)
    appendOptional(settings.directNameserverFollowPolicy, title: "direct-nameserver-follow-policy", to: &lines)
    appendList(settings.fakeIPFilter, title: "fake-ip-filter", to: &lines)
    appendList(settings.defaultNameserver, title: "default-nameserver", to: &lines)
    appendList(settings.nameserver, title: "nameserver", to: &lines)
    appendList(settings.fallback, title: "fallback", to: &lines)
    appendList(settings.proxyServerNameserver, title: "proxy-server-nameserver", to: &lines)
    appendList(settings.directNameserver, title: "direct-nameserver", to: &lines)
    return lines.isEmpty ? String(localized: "No DNS changes") : lines.joined(separator: "\n")
  }

  private func appendOptional(_ value: Bool?, title: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(title): \(value)")
  }

  private func appendList(_ values: [String], title: String, to lines: inout [String]) {
    guard !values.isEmpty else { return }
    lines.append("\(title): \(values.joined(separator: ", "))")
  }
}

enum RuntimeConfigDisplayRedactor {
  static let redactedValue = "<redacted>"

  static func redacted(
    _ text: String,
    controllerSecret: String,
    providerContentPaths: [String] = []
  ) -> String {
    if let loaded = try? Yams.load(yaml: text),
       (loaded is [String: Any] || loaded is [Any]),
       let redactedObject = redactedYAMLValue(
        loaded,
        path: [],
        controllerSecret: controllerSecret,
        providerContentPaths: providerContentPaths
       ),
       let dumped = try? Yams.dump(object: redactedObject, sortKeys: false) {
      return redactScalarSecrets(dumped, controllerSecret: controllerSecret, providerContentPaths: providerContentPaths)
    }
    if ProfileConfigInspector.isProxyProviderContent(text) {
      return "\(redactedValue) provider content\n"
    }
    return redactScalarSecrets(text, controllerSecret: controllerSecret, providerContentPaths: providerContentPaths)
  }

  private static func redactedYAMLValue(
    _ value: Any,
    path: [String],
    controllerSecret: String,
    providerContentPaths: [String]
  ) -> Any? {
    if let map = value as? [String: Any] {
      return map.reduce(into: [String: Any]()) { result, entry in
        let key = entry.key
        let nextPath = path + [key]
        if shouldRedactValue(forKey: key, path: path) {
          result[key] = redactedValue
        } else if shouldRedactProviderPath(entry.value, key: key, path: path, providerContentPaths: providerContentPaths) {
          result[key] = redactedValue
        } else {
          result[key] = redactedYAMLValue(
            entry.value,
            path: nextPath,
            controllerSecret: controllerSecret,
            providerContentPaths: providerContentPaths
          )
        }
      }
    }
    if let list = value as? [Any] {
      return list.map {
        redactedYAMLValue(
          $0,
          path: path,
          controllerSecret: controllerSecret,
          providerContentPaths: providerContentPaths
        ) ?? redactedValue
      }
    }
    if let string = value as? String {
      return redactScalarSecrets(string, controllerSecret: controllerSecret, providerContentPaths: providerContentPaths)
    }
    return value
  }

  private static func shouldRedactValue(forKey key: String, path: [String]) -> Bool {
    let normalized = key
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    if normalized == "url", path.contains(where: { $0.caseInsensitiveCompare("proxy-providers") == .orderedSame }) {
      return true
    }
    if normalized.contains("password")
      || normalized.contains("token")
      || normalized.contains("secret") {
      return true
    }
    return [
      "uuid",
      "private-key",
      "auth",
      "auth-str",
      "authorization",
      "proxy-authorization",
      "credential",
      "credentials",
      "psk"
    ].contains(normalized)
  }

  private static func shouldRedactProviderPath(
    _ value: Any,
    key: String,
    path: [String],
    providerContentPaths: [String]
  ) -> Bool {
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized == "path", let string = value as? String else { return false }
    if providerContentPaths.contains(string) {
      return true
    }
    return path.contains(where: { $0.caseInsensitiveCompare("proxy-providers") == .orderedSame })
      && string.contains("/Runtime/")
  }

  private static func redactScalarSecrets(
    _ value: String,
    controllerSecret: String,
    providerContentPaths: [String]
  ) -> String {
    var redacted = value
    let trimmedSecret = controllerSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSecret.isEmpty {
      redacted = redacted
        .replacingOccurrences(of: "Bearer \(trimmedSecret)", with: "Bearer \(redactedValue)")
        .replacingOccurrences(of: trimmedSecret, with: redactedValue)
    }
    for path in providerContentPaths where !path.isEmpty {
      redacted = redacted.replacingOccurrences(of: path, with: redactedValue)
    }
    redacted = redactProviderURIs(redacted)
    return redacted
  }

  private static func redactProviderURIs(_ value: String) -> String {
    var redacted = value
    for scheme in ProfileConfigInspector.supportedURISchemes {
      let pattern = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: scheme) + #"://[^\s'"\]\)>,]+"#
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
      redacted = regex.stringByReplacingMatches(
        in: redacted,
        range: range,
        withTemplate: "\(scheme)://\(redactedValue)"
      )
    }
    return redacted
  }
}

enum EffectiveRuntimeConfigLineDiff {
  static func diff(oldText: String, newText: String) -> [EffectiveRuntimeConfigDiffRow] {
    let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let cellCount = oldLines.count * newLines.count
    let rows: [(EffectiveRuntimeConfigDiffKind, String)]
    if cellCount > 400_000 {
      rows = oldLines.map { (.removed, $0) } + newLines.map { (.added, $0) }
    } else {
      rows = lcsDiff(oldLines: oldLines, newLines: newLines)
    }
    return rows.enumerated().map { offset, row in
      EffectiveRuntimeConfigDiffRow(id: offset, kind: row.0, text: row.1)
    }
  }

  private static func lcsDiff(oldLines: [String], newLines: [String]) -> [(EffectiveRuntimeConfigDiffKind, String)] {
    let oldCount = oldLines.count
    let newCount = newLines.count
    var table = Array(repeating: Array(repeating: 0, count: newCount + 1), count: oldCount + 1)
    if oldCount > 0, newCount > 0 {
      for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
        for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
          if oldLines[oldIndex] == newLines[newIndex] {
            table[oldIndex][newIndex] = table[oldIndex + 1][newIndex + 1] + 1
          } else {
            table[oldIndex][newIndex] = max(table[oldIndex + 1][newIndex], table[oldIndex][newIndex + 1])
          }
        }
      }
    }

    var result: [(EffectiveRuntimeConfigDiffKind, String)] = []
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < oldCount, newIndex < newCount {
      if oldLines[oldIndex] == newLines[newIndex] {
        result.append((.unchanged, oldLines[oldIndex]))
        oldIndex += 1
        newIndex += 1
      } else if table[oldIndex + 1][newIndex] >= table[oldIndex][newIndex + 1] {
        result.append((.removed, oldLines[oldIndex]))
        oldIndex += 1
      } else {
        result.append((.added, newLines[newIndex]))
        newIndex += 1
      }
    }
    while oldIndex < oldCount {
      result.append((.removed, oldLines[oldIndex]))
      oldIndex += 1
    }
    while newIndex < newCount {
      result.append((.added, newLines[newIndex]))
      newIndex += 1
    }
    return result
  }
}
