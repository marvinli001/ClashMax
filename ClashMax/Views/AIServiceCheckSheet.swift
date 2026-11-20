import AppKit
import SwiftUI

struct AIServiceCheckRequest: Identifiable {
  let id = UUID()
  var node: String?
}

struct AIServiceCheckSheet: View {
  let request: AIServiceCheckRequest
  @Environment(AppModel.self) private var appModel
  @Environment(\.dismiss) private var dismiss
  @State private var results: [AIServiceResult] = []
  @State private var checking = false
  @State private var runID: UUID?
  @State private var expanded: Set<AIService> = []
  @State private var path: ConnectionSnapshot?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if path != nil { Button { path = nil } label: { Image(systemName: "chevron.backward") }.accessibilityLabel("Back") }
        Text(path == nil ? String(localized: "Check AI services") : String(localized: "Path")).font(.headline)
        Spacer()
        Button(String(localized: "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Divider()
      if let path {
        ScrollView { ConnectionPathView(connection: path).id(path.id).frame(maxWidth: .infinity, alignment: .leading) }
      } else {
        Text(request.node.map { String(format: String(localized: "Specified node · %@"), $0) } ?? String(localized: "Current rules")).font(.subheadline)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(AIService.allCases) { service in
              let result = results.first { $0.service == service }
              DisclosureGroup(isExpanded: Binding(get: { expanded.contains(service) }, set: { if $0 { expanded.insert(service) } else { expanded.remove(service) } })) {
                if let result {
                  ForEach(result.endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: 4) {
                      Text(endpoint.host).font(.caption.bold())
                      ForEach(endpoint.facts) { fact in Text(fact.text).font(.caption).textSelection(.enabled) }
                      if let connection = endpoint.connection {
                        Button("View connection path") { path = connection }
                      }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                  }
                }
              } label: {
                LabeledContent(service.rawValue) {
                  if let result {
                    Text([result.summary, result.source.title, result.date.formatted(date: .omitted, time: .standard)].joined(separator: " · "))
                  } else { Text(checking ? String(localized: "Checking…") : String(localized: "Not checked")) }
                }
              }
            }
          }.padding(.horizontal, 2)
        }
        HStack {
          Button("Copy diagnostics") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
          }.disabled(results.isEmpty)
          Spacer()
          if checking { ProgressView().controlSize(.small) }
          Button("Check AI services") { checking = true; results = []; runID = UUID() }
            .disabled(checking || !appModel.isRunning)
        }
      }
    }
    .padding(18).frame(minWidth: 530, idealWidth: 610, minHeight: 340, idealHeight: 420)
    .task(id: runID) {
      guard runID != nil else { return }
      defer { checking = false }
      for service in AIService.allCases {
        guard !Task.isCancelled, let probe = appModel.aiServiceProbe else { return }
        guard let result = try? await probe.check(service, node: request.node), !Task.isCancelled else { return }
        results.append(result)
      }
      appModel.lastAIServiceReport = report
    }
  }

  private var report: String {
    DiagnosticBundleRedactor(secrets: appModel.diagnosticSecrets()).redact(results.map(\.report).joined(separator: "\n\n")).text
  }
}
