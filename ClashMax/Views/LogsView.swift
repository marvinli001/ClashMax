import SwiftUI

struct LogsView: View {
  @EnvironmentObject private var appModel: AppModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var levelFilter: LogLevelFilter = .all

  var body: some View {
    let retainedLogs = runtimeData.visibleLogs(developerMode: appModel.developerMode)
    let visibleLogs = filteredLogs(from: retainedLogs)

    AdaptivePage(
      title: "Logs",
      subtitle: String.localizedStringWithFormat(
        NSLocalizedString("%lld visible / %lld retained", comment: ""),
        Int64(visibleLogs.count),
        Int64(runtimeData.logs.count)
      )
    ) {
      Picker("Level", selection: $levelFilter) {
        ForEach(LogLevelFilter.allCases) { filter in
          Text(filter.displayName).tag(filter)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 320)
    } content: {
      if showsLoadingSkeleton(retainedLogs: retainedLogs) {
        ClashMaxSkeletonTable(rows: 8)
      } else if visibleLogs.isEmpty {
        CenteredUnavailableState(
          title: runtimeData.logs.isEmpty ? "No logs yet" : "No matching logs",
          systemImage: "text.alignleft",
          message: runtimeData.logs.isEmpty
            ? "Runtime and helper messages will be listed here."
            : "No retained logs match the selected level."
        )
      } else {
        List(visibleLogs) { entry in
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DisplayFormatters.date.string(from: entry.date))
              .foregroundStyle(.secondary)
              .frame(width: 80, alignment: .leading)
            Text(entry.level.uppercased())
              .fontWeight(.semibold)
              .frame(width: 70, alignment: .leading)
            Text(entry.message)
              .font(.system(.body, design: .monospaced))
              .lineLimit(2)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }

  private func showsLoadingSkeleton(retainedLogs: [LogEntry]) -> Bool {
    retainedLogs.isEmpty
      && appModel.profileStore.activeProfile != nil
      && (appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting)
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
      return entries.filter { ["error", "fatal"].contains($0.level.lowercased()) }
    case .debug:
      return entries.filter { ["debug", "trace"].contains($0.level.lowercased()) }
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
