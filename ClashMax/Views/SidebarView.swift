import SwiftUI

struct SidebarView: View {
  @Binding var selection: AppSection
  var hasRuntimeIssue = false

  var body: some View {
    List(selection: $selection) {
      Section("Daily") {
        rows([.home, .profiles, .proxies])
      }
      Section("Observe") {
        rows([.connections, .rules, .logs])
      }
      Section("Manage") {
        rows([.routing, .status, .settings])
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("ClashMax")
  }

  private func rows(_ sections: [AppSection]) -> some View {
    ForEach(sections) { section in
      HStack {
        Label(section.title, systemImage: section.symbolName)
        if section == .status, hasRuntimeIssue {
          Spacer(minLength: 4)
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("Needs attention")
        }
      }
      .tag(section)
    }
  }
}
