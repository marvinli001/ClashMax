import XCTest
@testable import ClashMax

// Carbon key codes and modifier masks, spelled out so these expectations do not depend on
// the machine's keyboard layout the way a rendered `displayName` does.
private let keyCodeP = 35
private let keyCodeReturn = 36
private let keyCodeEscape = 53
private let keyCodeLeftArrow = 123
private let keyCodeComma = 43
private let keyCodeF13 = 105
private let modifiersShiftCommand = 768
private let modifiersOptionCommand = 2304
private let modifiersCommand = 256

@MainActor
final class GlobalShortcutSettingsTests: XCTestCase {
  func testShortcutDescriptorParsesAndFormatsClashXStyleInput() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))

    XCTAssertEqual(shortcut.carbonKeyCode, keyCodeP)
    XCTAssertEqual(shortcut.carbonModifiers, modifiersShiftCommand)
    XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    XCTAssertTrue(shortcut.displayName.hasPrefix("⇧⌘"), shortcut.displayName)
  }

  func testShortcutDescriptorRejectsMultipleNonModifierKeys() {
    XCTAssertNil(KeyboardShortcutDescriptor(string: "cmd+shift+p+q"))
  }

  func testShortcutDescriptorRejectsUnknownKeyNames() {
    XCTAssertNil(KeyboardShortcutDescriptor(string: "cmd+shift+launchpad"))
  }

  func testShortcutDescriptorAcceptsKeysTheOldKeycodeTableCouldNotExpress() throws {
    let arrow = try XCTUnwrap(KeyboardShortcutDescriptor(string: "opt+cmd+left"))
    let punctuation = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+,"))
    let functionKey = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+f13"))

    XCTAssertEqual(arrow.carbonKeyCode, keyCodeLeftArrow)
    XCTAssertEqual(arrow.carbonModifiers, modifiersOptionCommand)
    XCTAssertEqual(arrow.displayName, "⌥⌘←")
    XCTAssertEqual(punctuation.carbonKeyCode, keyCodeComma)
    XCTAssertEqual(functionKey.carbonKeyCode, keyCodeF13)

    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: arrow, enabled: true),
      GlobalShortcutBinding(action: .stop, shortcut: punctuation, enabled: true),
      GlobalShortcutBinding(action: .restart, shortcut: functionKey, enabled: true)
    ])

    XCTAssertNil(settings.validationError)
    XCTAssertEqual(settings.enabledBindings.count, 3)
  }

  func testShortcutDescriptorCanonicalizesReturnAliases() throws {
    let enter = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+enter"))
    let `return` = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+return"))

    XCTAssertEqual(enter.carbonKeyCode, keyCodeReturn)
    XCTAssertEqual(enter, `return`)
    XCTAssertEqual(enter.displayName, "⇧⌘↩")
  }

  func testShortcutDescriptorCanonicalizesEscapeAliases() throws {
    let esc = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+esc"))
    let escape = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+escape"))

    XCTAssertEqual(esc.carbonKeyCode, keyCodeEscape)
    XCTAssertEqual(esc, escape)
    XCTAssertEqual(esc.displayName, "⇧⌘⎋")
  }

  func testShortcutDescriptorRoundTripsThroughItsOwnEncoding() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "opt+cmd+left"))

    let data = try JSONEncoder().encode(shortcut)
    let decoded = try JSONDecoder().decode(KeyboardShortcutDescriptor.self, from: data)

    XCTAssertEqual(decoded, shortcut)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("carbonKeyCode"), json)
  }

  func testShortcutDescriptorDecodesSettingsWrittenBeforeKeyboardShortcuts() throws {
    let data = try XCTUnwrap(
      #"{"key":"enter","modifiers":["command","shift"]}"#.data(using: .utf8)
    )

    let shortcut = try JSONDecoder().decode(KeyboardShortcutDescriptor.self, from: data)

    XCTAssertEqual(shortcut.carbonKeyCode, keyCodeReturn)
    XCTAssertEqual(shortcut.carbonModifiers, modifiersShiftCommand)
  }

  func testLegacyBindingWithUnmappableKeyClearsOnlyThatBinding() throws {
    let data = try XCTUnwrap(
      """
      {"bindings":[
        {"action":"startStop","shortcut":{"key":"launchpad","modifiers":["command","shift"]},"enabled":true},
        {"action":"stop","shortcut":{"key":"s","modifiers":["command","shift"]},"enabled":true}
      ]}
      """.data(using: .utf8)
    )

    let settings = try JSONDecoder().decode(GlobalShortcutSettings.self, from: data)

    let startStop = try XCTUnwrap(settings.mergedBindings.first { $0.action == .startStop })
    XCTAssertNil(startStop.shortcut)
    XCTAssertFalse(startStop.enabled)
    let stop = try XCTUnwrap(settings.mergedBindings.first { $0.action == .stop })
    XCTAssertEqual(stop.shortcut?.carbonModifiers, modifiersShiftCommand)
    XCTAssertTrue(stop.enabled)
    XCTAssertNil(settings.validationError)
  }

  func testSettingsRejectCommandOnlyShortcuts() throws {
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+p"))
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    XCTAssertEqual(shortcut.carbonModifiers, modifiersCommand)
    XCTAssertEqual(
      settings.validationError,
      String(localized: "Use at least one modifier besides Command for global shortcuts.")
    )
    XCTAssertTrue(settings.enabledBindings.isEmpty)
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
    XCTAssertEqual(
      settings.conflictDescriptions[0],
      [GlobalShortcutAction.startStop, .toggleSystemProxy].map(\.displayName).joined(separator: ", ")
    )
    XCTAssertNotNil(settings.validationError)
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
    let failure = GlobalShortcutRegistrationFailure.takenBySystem(action: .startStop, shortcut: shortcut)
    let registrar = RecordingGlobalShortcutRegistrar(failuresToReturn: [failure])
    let manager = GlobalShortcutManager(registrar: registrar)
    let settings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    let failures = manager.apply(settings) { _ in }

    XCTAssertEqual(failures, [failure])
    XCTAssertEqual(registrar.registrations.map(\.action), [.startStop])
    XCTAssertTrue(failure.summary.contains(failure.reason), failure.summary)
  }

  func testRegistrarStorageNamesAreUniqueAndAcceptedByKeyboardShortcuts() {
    let names = GlobalShortcutAction.allCases.map(KeyboardShortcutsRegistrar.storageName(for:))

    XCTAssertEqual(Set(names).count, GlobalShortcutAction.allCases.count)
    // The package logs a runtime warning and misbehaves for a name containing a dot.
    XCTAssertTrue(names.allSatisfy { !$0.contains(".") }, names.joined(separator: ", "))
  }

  func testRegistrarMirrorsSettingsIntoKeyboardShortcutsStorageAndCleansUp() throws {
    let defaultsKey = "KeyboardShortcuts_" + KeyboardShortcutsRegistrar.storageName(for: .startStop)
    let previous = UserDefaults.standard.object(forKey: defaultsKey)
    defer {
      UserDefaults.standard.set(previous, forKey: defaultsKey)
    }
    let registrar = KeyboardShortcutsRegistrar()
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "ctrl+opt+cmd+f13"))

    let failures = registrar.register(
      [GlobalShortcutRegistration(action: .startStop, shortcut: shortcut)]
    ) { _ in }

    XCTAssertTrue(failures.isEmpty)
    XCTAssertNotNil(UserDefaults.standard.object(forKey: defaultsKey))

    registrar.unregisterAll()

    XCTAssertNil(UserDefaults.standard.object(forKey: defaultsKey))
  }

  func testRegistrarUnregisterIsSafeWithoutAnyRegistration() {
    let registrar = KeyboardShortcutsRegistrar()

    registrar.unregisterAll()
    registrar.unregisterAll()
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
