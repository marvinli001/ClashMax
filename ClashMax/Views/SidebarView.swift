import SwiftUI

struct SidebarView: View {
  @Binding var selection: AppSection

  var body: some View {
    List(selection: $selection) {
      ForEach(AppSection.allCases) { section in
        Label(section.title, systemImage: section.symbolName)
          .tag(section)
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("ClashMax")
  }
}

