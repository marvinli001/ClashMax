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

/// One choice in a `PopUpSelectionButton`.
struct PopUpSelectionItem<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var systemImage: String?

  var id: Value { value }
}

/// A one-of-many choice whose menu opens the way a native pop-up button's does: over the control,
/// with the current choice checked and placed under the pointer. A SwiftUI `Menu` is a pull-down —
/// it always drops below its label — which reads as a list of actions rather than a value.
///
/// The label stays SwiftUI, so a headline or a capsule keeps its own look (a `Picker` would replace
/// it with a stock bezel). The menu is an `NSPopUpButtonCell`'s, so its placement, check mark and
/// keyboard handling are AppKit's own. `items` is read only when the menu opens, so a 1600-node
/// group costs nothing while the control just sits on screen, and the label always shows the
/// model's value — a choice the model turns down never lingers as if it had been applied.
struct PopUpSelectionButton<Value: Hashable, Label: View>: View {
  let selection: Value?
  let items: () -> [PopUpSelectionItem<Value>]
  let onSelect: (Value) -> Void
  @ViewBuilder let label: () -> Label
  @State private var presenter = PopUpMenuPresenter()

  var body: some View {
    Button {
      let items = items()
      presenter.present(
        entries: items.map { ($0.title, $0.systemImage) },
        selectedIndex: selection.flatMap { selection in items.firstIndex { $0.value == selection } }
      ) { index in
        guard items.indices.contains(index) else { return }
        onSelect(items[index].value)
      }
    } label: {
      label()
    }
    .background(PopUpMenuAnchor(presenter: presenter))
  }
}

@MainActor
private final class PopUpMenuPresenter: NSObject {
  weak var anchorView: NSView?
  private var onChoose: ((Int) -> Void)?

  func present(entries: [(title: String, systemImage: String?)], selectedIndex: Int?, onChoose: @escaping (Int) -> Void) {
    guard let anchorView, anchorView.window != nil, !entries.isEmpty else { return }
    let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
    cell.isBordered = false
    cell.autoenablesItems = false
    cell.font = NSFont.menuFont(ofSize: 0)
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (index, entry) in entries.enumerated() {
      let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      if let symbol = entry.systemImage {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      }
      menu.addItem(item)
    }
    cell.menu = menu
    cell.selectItem(at: selectedIndex ?? -1)
    self.onChoose = onChoose
    // Tracks the menu modally, positioned as a pop-up button occupying the label's frame would.
    cell.performClick(withFrame: anchorView.bounds, in: anchorView)
  }

  @objc private func choose(_ sender: NSMenuItem) {
    onChoose?(sender.tag)
  }
}

/// The AppKit view the menu is positioned against: it sits behind the label at the label's frame
/// and never takes a click, so the SwiftUI button above it still receives them.
private struct PopUpMenuAnchor: NSViewRepresentable {
  let presenter: PopUpMenuPresenter

  func makeNSView(context _: Context) -> PassThroughView {
    let view = PassThroughView()
    presenter.anchorView = view
    return view
  }

  func updateNSView(_ view: PassThroughView, context _: Context) {
    presenter.anchorView = view
  }

  final class PassThroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
  }
}
