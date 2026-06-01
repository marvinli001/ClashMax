import Foundation

enum EffectiveRuntimeConfigPreflightStatus: Equatable, Sendable {
  case notRun
  case passed
  case failed(String)

  var displayName: String {
    switch self {
    case .notRun:
      return String(localized: "Not Run")
    case .passed:
      return String(localized: "Passed")
    case .failed:
      return String(localized: "Failed")
    }
  }

  var message: String? {
    switch self {
    case .notRun, .passed:
      return nil
    case let .failed(message):
      return message
    }
  }
}

enum EffectiveRuntimeConfigState: Equatable {
  case idle
  case loading
  case unavailable(String)
  case loaded(EffectiveRuntimeConfigSnapshot)
  case failed(String)
}

struct EffectiveRuntimeConfigSnapshot: Equatable, Sendable {
  var generatedAt: Date
  var profileID: Profile.ID
  var profileName: String
  var layers: [EffectiveRuntimeConfigLayer]
  var diffRows: [EffectiveRuntimeConfigDiffRow]
  var redactedOriginalYAML: String
  var redactedFinalYAML: String
  var preflightStatus: EffectiveRuntimeConfigPreflightStatus

  var redactedDiffText: String {
    diffRows.map(\.displayLine).joined(separator: "\n")
  }

  var redactedReportText: String {
    var lines: [String] = [
      "ClashMax Effective Runtime Config",
      "Generated: \(generatedAt.formatted(date: .numeric, time: .standard))",
      "Profile: \(profileName)",
      "Preflight: \(preflightStatus.displayName)"
    ]
    if let message = preflightStatus.message {
      lines.append("Preflight Detail: \(message)")
    }
    lines.append("")
    lines.append("Layers")
    for layer in layers {
      lines.append("## \(layer.title)")
      lines.append(layer.summary)
      let content = layer.redactedContent.trimmingCharacters(in: .whitespacesAndNewlines)
      if !content.isEmpty {
        lines.append(content)
      }
      lines.append("")
    }
    lines.append("Redacted Diff")
    lines.append(redactedDiffText)
    lines.append("")
    lines.append("Final Runtime YAML")
    lines.append(redactedFinalYAML)
    return lines.joined(separator: "\n")
  }
}

struct EffectiveRuntimeConfigLayer: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var summary: String
  var redactedContent: String
  var isActive: Bool

  init(id: String, title: String, summary: String, redactedContent: String = "", isActive: Bool = true) {
    self.id = id
    self.title = title
    self.summary = summary
    self.redactedContent = redactedContent
    self.isActive = isActive
  }
}

enum EffectiveRuntimeConfigDiffKind: String, Equatable, Sendable {
  case unchanged
  case removed
  case added
  case omitted
}

struct EffectiveRuntimeConfigDiffRow: Identifiable, Equatable, Sendable {
  var id: Int
  var kind: EffectiveRuntimeConfigDiffKind
  var text: String

  var displayLine: String {
    switch kind {
    case .unchanged:
      return "  \(text)"
    case .removed:
      return "- \(text)"
    case .added:
      return "+ \(text)"
    case .omitted:
      return "... \(text)"
    }
  }
}
