import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lists installed applications so a process rule can be written for an app instead of a process
/// name typed from memory (roadmap B1). The scan runs off the main thread; "Choose…" covers an app
/// that lives anywhere else.
struct AppPickerSheet: View {
  let onPick: (InstalledApp) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var apps: [InstalledApp]?
  @State private var searchText = ""
  @State private var selection: InstalledApp.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Choose an App")
          .font(.headline)
        Text("The rule matches every process launched from inside the app, including its helpers.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      TextField("Search", text: $searchText)
        .textFieldStyle(.roundedBorder)

      Group {
        if let apps {
          if apps.isEmpty {
            ContentUnavailableView(
              "No Applications Found",
              systemImage: "app.dashed",
              description: Text("Use Choose… to pick an app from another folder.")
            )
          } else if filteredApps(apps).isEmpty {
            ContentUnavailableView.search(text: searchText)
          } else {
            List(filteredApps(apps), selection: $selection) { app in
              AppPickerRow(app: app)
                .tag(app.id)
            }
            .listStyle(.bordered)
          }
        } else {
          ProgressView("Looking for applications…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(minHeight: 280)

      HStack {
        Button("Choose…") {
          chooseFromDisk()
        }
        Spacer()
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Use App") {
          if let app = apps?.first(where: { $0.id == selection }) {
            pick(app)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selection == nil)
      }
    }
    .padding(18)
    .frame(width: 460, height: 520)
    .task {
      apps = await Task.detached(priority: .userInitiated) {
        InstalledAppScanner.scan(directories: InstalledAppScanner.standardDirectories)
      }.value
    }
  }

  private func filteredApps(_ apps: [InstalledApp]) -> [InstalledApp] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return apps }
    return apps.filter { app in
      app.name.localizedCaseInsensitiveContains(query)
        || (app.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private func chooseFromDisk() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url, let app = InstalledAppScanner.app(at: url) else { return }
    pick(app)
  }

  private func pick(_ app: InstalledApp) {
    onPick(app)
    dismiss()
  }
}

private struct AppPickerRow: View {
  let app: InstalledApp

  var body: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
        .resizable()
        .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(app.name)
          .lineLimit(1)
        Text(app.bundleIdentifier ?? app.bundleURL.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.vertical, 2)
  }
}

/// What can keep a process rule from matching, shown wherever one is being written.
struct ProcessRuleCoverageNotes: View {
  let notes: [ProcessRuleCoverage.Note]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(notes, id: \.text) { note in
        Label {
          Text(note.text)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: note.severity == .blocking ? "exclamationmark.triangle.fill" : "info.circle")
            .foregroundStyle(note.severity == .blocking ? Color.orange : Color.secondary)
        }
        .font(.caption)
        .foregroundStyle(note.severity == .blocking ? Color.primary : Color.secondary)
      }
    }
  }
}

/// "Choose App…" next to a process rule, plus what can keep that rule from matching. Picking an
/// app always writes the bundle pattern, whichever process kind was selected before.
struct ProcessRuleAppChooser: View {
  let onPick: (InstalledApp) -> Void

  @Environment(AppModel.self) private var appModel
  @State private var isPicking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        isPicking = true
      } label: {
        Label("Choose App…", systemImage: "app.badge.checkmark")
      }
      ProcessRuleCoverageNotes(notes: appModel.processRuleCoverageNotes)
    }
    .sheet(isPresented: $isPicking) {
      AppPickerSheet(onPick: onPick)
    }
  }
}

extension ManagedRuleOverlayRule.Kind {
  var isProcessRule: Bool {
    self == .processName || self == .processPath || self == .processPathRegex
  }
}
