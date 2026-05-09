import SwiftUI

struct RulesView: View {
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    AdaptivePage(
      title: "Rules",
      subtitle: "\(runtimeData.rules.count) loaded"
    ) {
      EmptyView()
    } content: {
      if runtimeData.rules.isEmpty {
        CenteredUnavailableState(
          title: "No rules loaded",
          systemImage: "list.bullet.rectangle",
          message: "Rules are loaded from the active profile after the runtime starts."
        )
      } else {
        List(runtimeData.rules, id: \.self) { rule in
          Text(rule)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }
}
