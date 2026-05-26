import XCTest
@testable import ClashMax

@MainActor
final class GlobalShortcutSettingsTests: XCTestCase {
  func testShortcutDescriptorParsesAndFormatsClashXStyleInput() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))

    XCTAssertEqual(shortcut.key, "p")
    XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    XCTAssertEqual(shortcut.storageString, "shift+command+p")
    XCTAssertEqual(shortcut.displayName, "⇧⌘P")
  }

  func testShortcutDescriptorRejectsMultipleNonModifierKeys() {
    XCTAssertNil(KeyboardShortcutDescriptor(string: "cmd+shift+p+q"))
  }

  func testShortcutDescriptorCanonicalizesReturnAliases() throws {
    let enter = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+enter"))
    let `return` = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+return"))

    XCTAssertEqual(enter.key, "return")
    XCTAssertEqual(enter.storageString, "shift+command+return")
    XCTAssertEqual(enter.storageString, `return`.storageString)
  }

  func testShortcutDescriptorCanonicalizesEscapeAliases() throws {
    let esc = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+esc"))
    let escape = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+escape"))

    XCTAssertEqual(esc.key, "escape")
    XCTAssertEqual(esc.storageString, "shift+command+escape")
    XCTAssertEqual(esc.storageString, escape.storageString)
  }

  func testDecodedShortcutDescriptorCanonicalizesPersistedAliases() throws {
    let data = try XCTUnwrap(
      #"{"key":"enter","modifiers":["command","shift"]}"#.data(using: .utf8)
    )

    let shortcut = try JSONDecoder().decode(KeyboardShortcutDescriptor.self, from: data)

    XCTAssertEqual(shortcut.key, "return")
    XCTAssertEqual(shortcut.storageString, "shift+command+return")
  }

  func testSettingsDetectShortcutConflicts() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true),
      GlobalShortcutBinding(action: .toggleSystemProxy, shortcut: shortcut, enabled: true)
    ])

    XCTAssertNotNil(settings.validationError)
    XCTAssertEqual(settings.enabledBindings.count, 2)
  }

  func testAliasPairsConflictBeforeRegistration() throws {
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(
        action: .startStop,
        shortcut: try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+enter")),
        enabled: true
      ),
      GlobalShortcutBinding(
        action: .toggleSystemProxy,
        shortcut: try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+return")),
        enabled: true
      )
    ])

    XCTAssertEqual(settings.conflictDescriptions.count, 1)
    XCTAssertTrue(settings.conflictDescriptions[0].contains("shift+command+return"))
    XCTAssertNotNil(settings.validationError)
  }

  func testSettingsRejectUnsupportedShortcutKeysBeforeRegistration() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+launchpad"))
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    XCTAssertEqual(
      settings.validationError,
      String(format: String(localized: "Unsupported global shortcut key: %@"), "LAUNCHPAD")
    )
    XCTAssertTrue(settings.enabledBindings.isEmpty)
  }

  func testManagerRegistersOnlyEnabledValidBindings() throws {
    let registrar = RecordingGlobalShortcutRegistrar()
    let manager = GlobalShortcutManager(registrar: registrar)
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(
        action: .startStop,
        shortcut: try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p")),
        enabled: true
      ),
      GlobalShortcutBinding(
        action: .stop,
        shortcut: try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+s")),
        enabled: false
      )
    ])

    let failures = manager.apply(settings) { _ in }

    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(registrar.registrations.map(\.action), [.startStop])
  }

  func testManagerReturnsRegistrarFailures() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))
    let failure = GlobalShortcutRegistrationFailure(
      action: .startStop,
      shortcut: shortcut,
      osStatus: -9876
    )
    let registrar = RecordingGlobalShortcutRegistrar(failuresToReturn: [failure])
    let manager = GlobalShortcutManager(registrar: registrar)
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    let failures = manager.apply(settings) { _ in }

    XCTAssertEqual(failures, [failure])
    XCTAssertEqual(registrar.registrations.map(\.action), [.startStop])
  }
}

@MainActor
private final class RecordingGlobalShortcutRegistrar: GlobalShortcutRegistering {
  let failuresToReturn: [GlobalShortcutRegistrationFailure]
  private(set) var registrations: [GlobalShortcutRegistration] = []
  private(set) var unregisterCount = 0

  init(failuresToReturn: [GlobalShortcutRegistrationFailure] = []) {
    self.failuresToReturn = failuresToReturn
  }

  func register(
    _ registrations: [GlobalShortcutRegistration],
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure] {
    self.registrations = registrations
    return failuresToReturn
  }

  func unregisterAll() {
    unregisterCount += 1
    registrations = []
  }
}
