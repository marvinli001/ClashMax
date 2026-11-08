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

/// AppKit autosaves the sidebar's width per window (`NSSplitView Subview Frames <window>,
/// SidebarNavigationSplitView`) and restores it ahead of `navigationSplitViewColumnWidth`'s ideal,
/// so narrowing the ideal alone never reaches a window that already saved the old, wider sidebar.
/// Forgetting the saved width once lets every existing window open at the compact width; a width
/// the user drags to afterwards is saved and kept as usual.
enum SidebarWidthReset {
  static let completedKey = "sidebarWidthReset.compact.v1"

  static func applyOnce(defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: completedKey) else { return }
    for key in defaults.dictionaryRepresentation().keys
      where key.hasPrefix("NSSplitView Subview Frames ") && key.hasSuffix("SidebarNavigationSplitView")
    {
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: completedKey)
  }
}
