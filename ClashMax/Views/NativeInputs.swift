import AppKit
import SwiftUI
import SwiftUIX

/// Keep the AppKit field editor alive across SwiftUI updates, including IME composition.
struct NativeSearchField: NSViewRepresentable {
  let prompt: String
  @Binding var text: String
  var focusRequest = 0

  func makeNSView(context: Context) -> NativeSearchHost {
    NativeSearchHost(rootView: searchBar)
  }

  func updateNSView(_ host: NativeSearchHost, context: Context) {
    let field = host.searchField
    if (field?.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      host.rootView = searchBar
    }
    if host.focusRequest != focusRequest {
      host.focusRequest = focusRequest
      DispatchQueue.main.async { [weak host] in
        guard let field = host?.searchField else { return }
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
      }
    }
  }

  private var searchBar: SwiftUIX.SearchBar {
    SwiftUIX.SearchBar(prompt, text: $text)
  }
}

final class NativeSearchHost: NSHostingView<SwiftUIX.SearchBar> {
  var focusRequest = 0
  var searchField: NSSearchField? { firstDescendant(of: NSSearchField.self) }
}

struct WorkspaceSearchField: View {
  let prompt: String
  @Binding var text: String
  @State private var focusRequest = 0

  var body: some View {
    NativeSearchField(prompt: prompt, text: $text, focusRequest: focusRequest)
      .frame(minWidth: 160, idealWidth: 280, maxWidth: 400)
      .frame(height: 24)
      .accessibilityLabel(prompt)
      .focusedSceneValue(\.workspaceSearchAction) { focusRequest += 1 }
  }
}

private struct WorkspaceSearchActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var workspaceSearchAction: (() -> Void)? {
    get { self[WorkspaceSearchActionKey.self] }
    set { self[WorkspaceSearchActionKey.self] = newValue }
  }
}

struct WorkspaceFindCommands: Commands {
  @FocusedValue(\.workspaceSearchAction) private var searchAction

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      if let searchAction {
        Button(String(localized: "Find…"), action: searchAction)
          .keyboardShortcut("f", modifiers: .command)
      }
    }
  }
}

struct SnippetTextEditor: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSHostingView<AnyView> {
    NSHostingView(rootView: editor)
  }

  func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
    // Replacing the representable while the input method owns marked text cancels composition.
    guard host.firstDescendant(of: NSTextView.self)?.hasMarkedText() != true else { return }
    host.rootView = editor
  }

  private var editor: AnyView {
    AnyView(
      ScrollView {
        SwiftUIX.TextView(text: $text)
          .automaticQuoteSubstitutionDisabled(true)
          .font(.system(.body, design: .monospaced))
          .disableAutocorrection(true)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
          .accessibilityLabel(Text("Snippet YAML"))
      }
      .background(Color(nsColor: .textBackgroundColor))
    )
  }
}

extension NSView {
  func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    if let match = self as? T { return match }
    for child in subviews {
      if let match = child.firstDescendant(of: type) { return match }
    }
    return nil
  }
}

struct FunctionalGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color(nsColor: .controlBackgroundColor), in: .capsule)
        .overlay(Capsule().strokeBorder(.separator))
    } else if #available(macOS 26, *) {
      content.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      content.background(.regularMaterial, in: .capsule)
    }
  }
}

struct RuntimePrimaryActionStyle: ViewModifier {
  let canStop: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if #available(macOS 26, *), !reduceTransparency {
      if canStop { content.buttonStyle(.glass) }
      else { content.buttonStyle(.glassProminent) }
    } else {
      if canStop { content.buttonStyle(.bordered) }
      else { content.buttonStyle(.borderedProminent) }
    }
  }
}
