import AppKit
import SwiftUI

/// Shows the exact, already-redacted bytes of the diagnostic bundle before anything leaves the
/// app, then copies or saves those same bytes (roadmap A5).
struct DiagnosticBundleSheet: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.dismiss) private var dismiss
  @State private var bundle: DiagnosticBundle?
  @State private var outcome: Outcome?

  private enum Outcome: Equatable {
    case copied
    case saved(String)
    case failed(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Diagnostic Bundle")
          .font(.headline)
        Text(
          "This is exactly what will be copied or saved. The controller secret, subscription URLs, node credentials, Wi-Fi names and your public IP address are already removed. Logs still name domains this Mac connected to — review before you share."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Group {
        if let bundle {
          DiagnosticBundleTextView(text: bundle.contents.text)
        } else {
          ProgressView("Collecting diagnostics…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.background.secondary, in: .rect(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

      HStack(spacing: 8) {
        footerStatus
        Spacer()
        Button("Close") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Copy") {
          copy()
        }
        .disabled(bundle == nil)
        Button("Save…") {
          save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(bundle == nil)
      }
    }
    .padding(20)
    .frame(minWidth: 680, idealWidth: 860, minHeight: 480, idealHeight: 640)
    .task {
      bundle = await appModel.makeDiagnosticBundle()
    }
  }

  @ViewBuilder
  private var footerStatus: some View {
    switch outcome {
    case .copied:
      Label("Copied to the clipboard.", systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
    case let .saved(name):
      Label(String(format: String(localized: "Saved %@."), name), systemImage: "checkmark.circle")
        .foregroundStyle(.secondary)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.red)
        .lineLimit(2)
    case nil:
      if let bundle {
        Text(ByteCountFormatter.string(fromByteCount: Int64(bundle.data.count), countStyle: .file))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  private func copy() {
    guard let bundle else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(bundle.contents.text, forType: .string)
    outcome = .copied
  }

  private func save() {
    guard let bundle else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = bundle.suggestedFileName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try DiagnosticBundleWriter.write(bundle, to: url)
      outcome = .saved(url.lastPathComponent)
    } catch {
      outcome = .failed(UserFacingError.message(for: error))
    }
  }
}

/// Read-only, selectable, monospaced. A SwiftUI `Text` lays out the whole string at once, which
/// stalls on the runtime YAML of a large subscription; `NSTextView` lays out lazily.
private struct DiagnosticBundleTextView: NSViewRepresentable {
  let text: String

  func makeNSView(context _: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    if let textView = scrollView.documentView as? NSTextView {
      textView.isEditable = false
      textView.isSelectable = true
      textView.drawsBackground = false
      textView.isRichText = false
      textView.usesFindBar = true
      textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      textView.textColor = .labelColor
      textView.textContainerInset = NSSize(width: 6, height: 6)
      // Long YAML and log lines scroll sideways instead of wrapping into an unreadable column.
      textView.isHorizontallyResizable = true
      textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.textContainer?.widthTracksTextView = false
      textView.textContainer?.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      textView.string = text
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context _: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
    textView.string = text
  }
}
