import Carbon
import Foundation

struct GlobalShortcutRegistration: Equatable {
  var action: GlobalShortcutAction
  var shortcut: KeyboardShortcutDescriptor
}

struct GlobalShortcutRegistrationFailure: Equatable, Sendable {
  var action: GlobalShortcutAction
  var shortcut: KeyboardShortcutDescriptor
  var osStatus: OSStatus

  var summary: String {
    "\(action.displayName) \(shortcut.displayName), OSStatus \(osStatus)"
  }
}

struct GlobalShortcutRegistrationStatus: Equatable, Sendable {
  var registeredCount: Int
  var failures: [GlobalShortcutRegistrationFailure]

  var errorMessage: String? {
    guard !failures.isEmpty else { return nil }
    return String(
      format: String(localized: "Global shortcut registration failed: %@"),
      failures.map(\.summary).joined(separator: ", ")
    )
  }
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
  func register(
    _ registrations: [GlobalShortcutRegistration],
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure]
  func unregisterAll()
}

@MainActor
final class GlobalShortcutManager {
  private let registrar: any GlobalShortcutRegistering

  init(registrar: any GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar()) {
    self.registrar = registrar
  }

  @discardableResult
  func apply(
    _ settings: GlobalShortcutSettings,
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure] {
    guard settings.validationError == nil else {
      registrar.unregisterAll()
      return []
    }
    let registrations = settings.enabledBindings.compactMap { binding -> GlobalShortcutRegistration? in
      guard let shortcut = binding.shortcut else { return nil }
      return GlobalShortcutRegistration(action: binding.action, shortcut: shortcut)
    }
    return registrar.register(registrations, handler: handler)
  }

  func stop() {
    registrar.unregisterAll()
  }
}

@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
  private static let signature: OSType = 0x436C4D78 // ClMx
  nonisolated(unsafe) private static var handlers: [UInt32: @MainActor () -> Void] = [:]
  nonisolated(unsafe) private static var nextID: UInt32 = 1
  nonisolated(unsafe) private static var eventHandlerInstalled = false

  private var hotKeyRefs: [EventHotKeyRef?] = []

  func register(
    _ registrations: [GlobalShortcutRegistration],
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure] {
    unregisterAll()
    guard !registrations.isEmpty else { return [] }
    let handlerStatus = installEventHandlerIfNeeded()
    guard handlerStatus == noErr else {
      return registrations.map {
        GlobalShortcutRegistrationFailure(
          action: $0.action,
          shortcut: $0.shortcut,
          osStatus: handlerStatus
        )
      }
    }
    var failures: [GlobalShortcutRegistrationFailure] = []
    for registration in registrations {
      guard let keyCode = Self.keyCode(for: registration.shortcut.key) else {
        failures.append(
          GlobalShortcutRegistrationFailure(
            action: registration.action,
            shortcut: registration.shortcut,
            osStatus: OSStatus(paramErr)
          )
        )
        continue
      }
      let modifiers = Self.carbonModifiers(for: registration.shortcut.modifiers)
      guard modifiers != 0 else {
        failures.append(
          GlobalShortcutRegistrationFailure(
            action: registration.action,
            shortcut: registration.shortcut,
            osStatus: OSStatus(paramErr)
          )
        )
        continue
      }

      let id = Self.nextID
      Self.nextID += 1
      Self.handlers[id] = { handler(registration.action) }
      let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        UInt32(keyCode),
        modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &ref
      )
      if status == noErr {
        hotKeyRefs.append(ref)
      } else {
        Self.handlers[id] = nil
        failures.append(
          GlobalShortcutRegistrationFailure(
            action: registration.action,
            shortcut: registration.shortcut,
            osStatus: status
          )
        )
      }
    }
    return failures
  }

  func unregisterAll() {
    for ref in hotKeyRefs {
      if let ref {
        UnregisterEventHotKey(ref)
      }
    }
    hotKeyRefs.removeAll()
    Self.handlers.removeAll()
  }

  private func installEventHandlerIfNeeded() -> OSStatus {
    guard !Self.eventHandlerInstalled else { return noErr }
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == CarbonGlobalShortcutRegistrar.signature else {
          return noErr
        }
        DispatchQueue.main.async {
          Task { @MainActor in
            CarbonGlobalShortcutRegistrar.handlers[hotKeyID.id]?()
          }
        }
        return noErr
      },
      1,
      &eventType,
      nil,
      nil
    )
    guard status == noErr else { return status }
    Self.eventHandlerInstalled = true
    return noErr
  }

  private static func carbonModifiers(for modifiers: Set<GlobalShortcutModifier>) -> UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) {
      result |= UInt32(cmdKey)
    }
    if modifiers.contains(.option) {
      result |= UInt32(optionKey)
    }
    if modifiers.contains(.control) {
      result |= UInt32(controlKey)
    }
    if modifiers.contains(.shift) {
      result |= UInt32(shiftKey)
    }
    return result
  }

  private static func keyCode(for key: String) -> Int? {
    let normalized = key.lowercased()
    if let letter = normalized.unicodeScalars.first,
       normalized.count == 1,
       ("a"..."z").contains(String(letter)) {
      let base = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z
      ]
      return base[normalized]
    }
    let digits = [
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
      "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
      "8": kVK_ANSI_8, "9": kVK_ANSI_9
    ]
    if let digit = digits[normalized] {
      return digit
    }
    switch normalized {
    case "space":
      return kVK_Space
    case "return", "enter":
      return kVK_Return
    case "escape", "esc":
      return kVK_Escape
    case "f1":
      return kVK_F1
    case "f2":
      return kVK_F2
    case "f3":
      return kVK_F3
    case "f4":
      return kVK_F4
    case "f5":
      return kVK_F5
    case "f6":
      return kVK_F6
    case "f7":
      return kVK_F7
    case "f8":
      return kVK_F8
    case "f9":
      return kVK_F9
    case "f10":
      return kVK_F10
    case "f11":
      return kVK_F11
    case "f12":
      return kVK_F12
    default:
      return nil
    }
  }
}
