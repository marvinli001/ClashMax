import AppKit
@testable import ClashMax
import SwiftUI
import XCTest

/// Issue #27: sections whose height grew with their row count used to push a page past the window.
/// SwiftUI grows a flexible frame to fit an oversized child instead of clipping it, so the overflow
/// escaped the page entirely — it painted over the title bar and pushed the sidebar's rows off
/// screen, leaving a window that could only be recovered by quitting.
final class PageOverflowLayoutTests: XCTestCase {
  // MARK: - Secondary sections

  func testSecondarySectionTakesAShareOfThePage() {
    XCTAssertEqual(
      SecondarySectionHeight.maxHeight(pageHeight: 600),
      600 * SecondarySectionHeight.pageHeightShare,
      accuracy: 0.001
    )
  }

  func testSecondarySectionNeverClaimsMostOfThePage() {
    for pageHeight in stride(from: CGFloat(200), through: 2_000, by: 50) {
      let height = SecondarySectionHeight.maxHeight(pageHeight: pageHeight)
      XCTAssertLessThan(
        height,
        pageHeight,
        "A summary section must leave room for the list it summarizes at page height \(pageHeight)"
      )
    }
  }

  func testSecondarySectionStopsGrowingOnATallPage() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 4_000), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 100_000), SecondarySectionHeight.ceiling)
  }

  func testSecondarySectionKeepsAUsableFloorOnAShortPage() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 40), SecondarySectionHeight.floor)
  }

  /// The height is measured, so it is zero on the first layout pass and the section would otherwise
  /// vanish (or, worse, be treated as unbounded) before geometry reports anything.
  func testSecondarySectionFallsBackToTheCeilingBeforeTheFirstGeometryPass() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 0), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: -120), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: .infinity), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: .nan), SecondarySectionHeight.ceiling)
  }

  /// The page measures itself *after* the cap is applied, so capping shrinks the page, which shrinks
  /// the cap. That has to settle instead of oscillating: re-feeding the result must never grow it.
  func testSecondarySectionHeightConvergesWhenFedItsOwnPage() {
    var pageHeight: CGFloat = 4_000
    var previous = CGFloat.greatestFiniteMagnitude

    for _ in 0..<10 {
      let height = SecondarySectionHeight.maxHeight(pageHeight: pageHeight)
      XCTAssertLessThanOrEqual(height, previous)
      previous = height
      // A page that shrinks back towards the real window as the overflow is removed.
      pageHeight = max(600, pageHeight * 0.5)
    }

    XCTAssertEqual(previous, SecondarySectionHeight.maxHeight(pageHeight: 600), accuracy: 0.001)
  }

  // MARK: - Connections layout

  func testConnectionsUseSheetUntilTableAndInspectorBothFit() {
    for width in stride(from: CGFloat(400), to: ConnectionsLayout.splitDetailBreakpoint, by: 20) {
      XCTAssertEqual(ConnectionsLayout.mode(forWidth: width), .sheetDetail)
    }
    XCTAssertEqual(ConnectionsLayout.mode(forWidth: ConnectionsLayout.splitDetailBreakpoint), .splitDetail)
    XCTAssertGreaterThanOrEqual(ConnectionsLayout.splitDetailBreakpoint - ConnectionsLayout.detailWidth - 16, 660)
    XCTAssertEqual(ConnectionsLayout.mode(forWidth: .nan), .sheetDetail)
  }

  // MARK: - Page chrome

  /// `AdaptivePage` publishes the page height so nested sections can bound themselves against the
  /// real window; a default of zero has to mean "not measured yet", not "no room".
  func testPageHeightEnvironmentDefaultsToUnmeasured() {
    XCTAssertEqual(EnvironmentValues().pageHeight, 0)
    XCTAssertEqual(
      SecondarySectionHeight.maxHeight(pageHeight: EnvironmentValues().pageHeight),
      SecondarySectionHeight.ceiling
    )
  }
}

@MainActor
final class NativeInputInteractionTests: XCTestCase {
  private final class Draft {
    var text = "# 合成配置\nrules: []\n"
  }

  func testSearchFocusAndChineseCompositionSurviveUpdate() async throws {
    let draft = Draft()
    let binding = Binding(get: { draft.text }, set: { draft.text = $0 })
    let host = NSHostingView(rootView: NativeSearchField(prompt: "Search", text: binding))
    let window = makeWindow(host)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(120))
    host.rootView = NativeSearchField(prompt: "Search", text: binding, focusRequest: 1)
    try await Task.sleep(for: .milliseconds(120))
    let field = try XCTUnwrap(host.firstDescendant(of: NSSearchField.self))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    XCTAssertTrue(window.firstResponder === editor)
    editor.setMarkedText("中文输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    host.rootView = NativeSearchField(prompt: "Search", text: binding, focusRequest: 1)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertTrue(editor.string.contains("中文输入"))
    editor.unmarkText()
    field.selectText(nil)
    XCTAssertEqual(editor.selectedRange().length, (editor.string as NSString).length)
  }

  func testSnippetChineseCompositionSelectionUndoRedoAndLargeText() async throws {
    let draft = Draft()
    let binding = Binding(get: { draft.text }, set: { draft.text = $0 })
    let host = NSHostingView(rootView: SnippetTextEditor(text: binding))
    let window = makeWindow(host)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(180))
    let editor = try XCTUnwrap(host.firstDescendant(of: NSTextView.self))
    XCTAssertTrue(editor.allowsUndo)
    XCTAssertTrue(editor.isSelectable)
    XCTAssertNotNil(editor.enclosingScrollView)
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.setMarkedText("中文组合", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    host.rootView = SnippetTextEditor(text: binding)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(editor.hasMarkedText())
    editor.unmarkText()
    try await Task.sleep(for: .milliseconds(80))
    editor.undoManager?.removeAllActions()
    editor.breakUndoCoalescing()
    let before = editor.string
    editor.insertText("撤销测试", replacementRange: editor.selectedRange())
    editor.breakUndoCoalescing()
    let after = editor.string
    XCTAssertNotEqual(before, after)
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, before)
    editor.undoManager?.redo()
    XCTAssertEqual(editor.string, after)
    editor.setSelectedRange(NSRange(location: 0, length: 4))
    XCTAssertEqual(editor.selectedRange().length, 4)
    editor.string = String(repeating: "  - DOMAIN,example.com,DIRECT # 合成\n", count: 10_000)
    editor.didChangeText()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(draft.text, editor.string)
    XCTAssertGreaterThan(editor.string.utf8.count, 300_000)
  }

  private func makeWindow(_ content: NSView) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    return window
  }
}
