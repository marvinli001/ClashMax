import Foundation
import KeyboardShortcuts

struct GlobalShortcutRegistration: Equatable {
  var action: GlobalShortcutAction
  var shortcut: KeyboardShortcutDescriptor
}

struct GlobalShortcutRegistrationFailure: Equatable, Sendable {
  var action: GlobalShortcutAction
  var shortcut: KeyboardShortcutDescriptor
  /// Why this shortcut will not reach ClashMax, in the user's language.
  var reason: String

  @MainActor
  var summary: String {
    "\(action.displayName) \(shortcut.displayName): \(reason)"
  }

  static func takenBySystem(
    action: GlobalShortcutAction,
    shortcut: KeyboardShortcutDescriptor
  ) -> Self {
    .init(
      action: action,
      shortcut: shortcut,
      reason: String(localized: "macOS already uses this shortcut.")
    )
  }
}

struct GlobalShortcutRegistrationStatus: Equatable, Sendable {
  var registeredCount: Int
  var failures: [GlobalShortcutRegistrationFailure]

  @MainActor
  var errorMessage: String? {
    guard !failures.isEmpty else { return nil }
    return String(
      format: String(localized: "Some global shortcuts will not work: %@"),
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

  init(registrar: any GlobalShortcutRegistering = KeyboardShortcutsRegistrar()) {
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

/// Installs ClashMax's global shortcuts through the KeyboardShortcuts package, which owns the
/// Carbon `RegisterEventHotKey` plumbing this file used to hand-roll.
///
/// `GlobalShortcutSettings` stays the single source of truth — it is what ClashMax persists,
/// backs up, and imports from other clients. The package keeps its own `UserDefaults` copy,
/// because that is what it consults when deciding which hot key a name owns, so `register`
/// mirrors settings into it one way and never reads back.
@MainActor
final class KeyboardShortcutsRegistrar: GlobalShortcutRegistering {
  /// The names currently holding a hot key, so `unregisterAll` can be exact and a repeated
  /// `register` does not stack duplicate handlers on the same name.
  private var installedActions: Set<GlobalShortcutAction> = []
  private var handler: (@MainActor (GlobalShortcutAction) -> Void)?

  func register(
    _ registrations: [GlobalShortcutRegistration],
    handler: @escaping @MainActor (GlobalShortcutAction) -> Void
  ) -> [GlobalShortcutRegistrationFailure] {
    self.handler = handler
    var shortcutsByAction: [GlobalShortcutAction: KeyboardShortcutDescriptor] = [:]
    for registration in registrations {
      shortcutsByAction[registration.action] = registration.shortcut
    }

    var failures: [GlobalShortcutRegistrationFailure] = []
    for action in GlobalShortcutAction.allCases {
      let name = Self.name(for: action)
      guard let descriptor = shortcutsByAction[action] else {
        if installedActions.remove(action) != nil {
          KeyboardShortcuts.removeHandler(for: name)
          KeyboardShortcuts.setShortcut(nil, for: name)
        }
        continue
      }
      KeyboardShortcuts.setShortcut(descriptor.shortcut, for: name)
      if installedActions.insert(action).inserted {
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
          self?.handler?(action)
        }
      }
      // The hot key still registers, but macOS consumes the key press first, so saying it
      // worked would be a lie. The recorder warns about this too; settings restored from a
      // backup or imported from another client never went through the recorder.
      if descriptor.shortcut.isTakenBySystem {
        failures.append(.takenBySystem(action: action, shortcut: descriptor))
      }
    }
    return failures
  }

  func unregisterAll() {
    for action in installedActions {
      let name = Self.name(for: action)
      KeyboardShortcuts.removeHandler(for: name)
      KeyboardShortcuts.setShortcut(nil, for: name)
    }
    installedActions.removeAll()
    handler = nil
  }

  /// The package keys both its storage and its hot-key registry by name, and rejects a name
  /// containing a dot, so actions get their own prefixed namespace.
  static func name(for action: GlobalShortcutAction) -> KeyboardShortcuts.Name {
    .init(storageName(for: action))
  }

  static func storageName(for action: GlobalShortcutAction) -> String {
    "clashmax_\(action.rawValue)"
  }
}
