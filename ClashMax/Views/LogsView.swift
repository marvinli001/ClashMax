import SwiftUI

struct LogsView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Logs",
      subtitle: "\(appModel.logs.count) retained"
    ) {
      EmptyView()
    } content: {
      if appModel.logs.isEmpty {
        CenteredUnavailableState(
          title: "No logs yet",
          systemImage: "text.alignleft",
          message: "Runtime and helper messages will be listed here."
        )
      } else {
        List(appModel.logs) { entry in
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
}
