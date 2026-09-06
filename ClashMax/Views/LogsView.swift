import AppKit
import SwiftUI

struct LogsView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var levelFilter: LogLevelFilter = .all
  /// The highlighted entry reads in full; every other row stays on two lines.
  @State private var selectedLogID: LogEntry.ID?

  init() {}

  /// Seeds the highlighted entry for previews and fixture renders; the app starts with none.
  init(initialSelectedLogID: LogEntry.ID?) {
    _selectedLogID = State(initialValue: initialSelectedLogID)
  }

  var body: some View {
    let retainedLogs = runtimeData.visibleLogs(
      developerMode: appModel.developerMode,
      logLevel: appModel.selectedLogLevel
    )
    let visibleLogs = filteredLogs(from: retainedLogs)

    AdaptivePage(title: "Logs") {
      // One compact menu instead of a five-segment control: the filter is rarely changed, and the
      // label always says which level is showing.
      Picker(selection: $levelFilter) {
        ForEach(LogLevelFilter.allCases) { filter in
          Text(filter.displayName).tag(filter)
        }
      } label: {
        Label("Level", systemImage: "line.3.horizontal.decrease.circle")
      }
      .pickerStyle(.menu)
      .fixedSize()
      .help("Show only entries of one level. Filtering never changes what the core records.")
    } content: {
      if showsLoadingSkeleton(retainedLogs: retainedLogs) {
        ClashMaxSkeletonTable(rows: 8)
      } else if visibleLogs.isEmpty {
        CenteredUnavailableState(
          title: emptyStateTitle,
          systemImage: "text.alignleft",
          message: emptyStateMessage
        )
      } else {
        VStack(spacing: 8) {
          List(visibleLogs, selection: $selectedLogID) { entry in
            LogEntryRow(entry: entry, isExpanded: selectedLogID == entry.id)
              .tag(entry.id)
              .contextMenu {
                Button("Copy Message") {
                  copy(entry.message)
                }
                Button("Copy Line") {
                  copy("\(DisplayFormatters.date.string(from: entry.date)) \(entry.level.uppercased()) \(entry.message)")
                }
              }
          }
          .listStyle(.inset)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityLabel("Log entries")

          PageStatusFooter(text: footerText(visibleCount: visibleLogs.count))
        }
      }
    }
    .onChange(of: visibleLogs.map(\.id)) { _, ids in
      if let selectedLogID, !ids.contains(selectedLogID) {
        self.selectedLogID = nil
      }
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func showsLoadingSkeleton(retainedLogs: [LogEntry]) -> Bool {
    retainedLogs.isEmpty
      && appModel.profileStore.activeProfile != nil
      && (appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting)
  }

  /// The Debug filter is only ever populated when the runtime log level is
  /// Debug, so an empty Debug view must say that instead of implying the core
  /// produced nothing (discussion #25).
  private var debugFilterNeedsVerboseLevel: Bool {
    levelFilter == .debug && !appModel.isVerboseLogLevelSelected
  }

  private var emptyStateTitle: String {
    if debugFilterNeedsVerboseLevel {
      return "Debug logging is off"
    }
    return runtimeData.logs.isEmpty ? "No logs yet" : "No matching logs"
  }

  private var emptyStateMessage: String {
    if debugFilterNeedsVerboseLevel {
      return "Set Log Level to Debug in Settings to capture debug output from the core."
    }
    return runtimeData.logs.isEmpty
      ? "Runtime and helper messages will be listed here."
      : "No retained logs match the selected level."
  }

  private func footerText(visibleCount: Int) -> String {
    var text = String.localizedStringWithFormat(
      NSLocalizedString("%lld visible / %lld retained", comment: ""),
      Int64(visibleCount),
      Int64(runtimeData.logs.count)
    )
    if !appModel.isVerboseLogLevelSelected {
      text += " · " + String(localized: "Debug logging is off")
    }
    return text
  }

  private func filteredLogs(from entries: [LogEntry]) -> [LogEntry] {
    switch levelFilter {
    case .all:
      return entries
    case .info:
      return entries.filter { ["info", "information"].contains($0.level.lowercased()) }
    case .warning:
      return entries.filter { ["warn", "warning"].contains($0.level.lowercased()) }
    case .error:
      return entries.filter { ["error", "fatal", "panic"].contains($0.level.lowercased()) }
    case .debug:
      return entries.filter { ["debug", "trace"].contains($0.level.lowercased()) }
    }
  }
}

/// Time, level and message on one baseline. Informational levels stay quiet; warnings and errors keep
/// their semantic color so the eye finds them without every row competing.
private struct LogEntryRow: View {
  let entry: LogEntry
  let isExpanded: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(DisplayFormatters.date.string(from: entry.date))
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      Text(entry.level.uppercased())
        .font(.callout.weight(LogLevelStyle.isNoteworthy(entry.level) ? .semibold : .regular))
        .foregroundStyle(LogLevelStyle.color(for: entry.level))
        .frame(width: 64, alignment: .leading)
      message
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(entry.level.uppercased()) \(entry.message)")
  }

  /// Only the expanded row offers text selection. A selectable text takes the click for itself, so a
  /// collapsed row whose message was selectable could not be selected (and expanded) by clicking the
  /// one thing the eye is on — the message.
  @ViewBuilder
  private var message: some View {
    let text = Text(entry.message)
      .font(.system(.body, design: .monospaced))
      .lineLimit(isExpanded ? nil : 2)
      .truncationMode(.tail)
    if isExpanded {
      text.textSelection(.enabled)
    } else {
      text
    }
  }
}

enum LogLevelStyle {
  static func color(for level: String) -> Color {
    switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "error", "fatal", "panic":
      return .red
    case "warn", "warning":
      return .orange
    case "debug", "trace":
      return .purple
    case "info", "information":
      return .secondary
    default:
      return .secondary
    }
  }

  /// Warnings and errors are the rows a reader is scanning for.
  static func isNoteworthy(_ level: String) -> Bool {
    switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "error", "fatal", "panic", "warn", "warning":
      return true
    default:
      return false
    }
  }
}

private enum LogLevelFilter: String, CaseIterable, Identifiable {
  case all
  case info
  case warning
  case error
  case debug

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .all: String(localized: "All")
    case .info: String(localized: "Info")
    case .warning: String(localized: "Warn")
    case .error: String(localized: "Error")
    case .debug: String(localized: "Debug")
    }
  }
}
