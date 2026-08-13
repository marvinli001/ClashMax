import AppKit
import Foundation
import KeyboardShortcuts

/// A global shortcut, stored the way Carbon addresses keys — a hardware key code plus a
/// modifier mask — which is exactly what `KeyboardShortcuts.Shortcut` carries. This type is
/// the persistable shell around it: settings, backups, and migration payloads all encode it,
/// and everything that actually records or registers a shortcut goes through ``shortcut``.
///
/// Older builds stored a key *name* checked against a hand-written table that only knew
/// a–z, 0–9, space, return, escape and F1–F12, so arrow keys, punctuation, and the keypad
/// could not be expressed at all. Key codes have no such ceiling; the name table survives
/// only to decode those old settings and to import shortcuts from other clients.
struct KeyboardShortcutDescriptor: Codable, Equatable, Hashable, Sendable {
  let carbonKeyCode: Int
  let carbonModifiers: Int

  private enum CodingKeys: String, CodingKey {
    case carbonKeyCode
    case carbonModifiers
    // Written by builds before ClashMax moved to KeyboardShortcuts.
    case key
    case modifiers
  }

  init(carbonKeyCode: Int, carbonModifiers: Int) {
    self.carbonKeyCode = carbonKeyCode
    self.carbonModifiers = carbonModifiers
  }

  init(_ shortcut: KeyboardShortcuts.Shortcut) {
    self.init(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: shortcut.carbonModifiers)
  }

  init(key: KeyboardShortcuts.Key, modifiers: NSEvent.ModifierFlags) {
    self.init(KeyboardShortcuts.Shortcut(key, modifiers: modifiers))
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let carbonKeyCode = try container.decodeIfPresent(Int.self, forKey: .carbonKeyCode) {
      self.carbonKeyCode = carbonKeyCode
      carbonModifiers = try container.decodeIfPresent(Int.self, forKey: .carbonModifiers) ?? 0
      return
    }
    // Legacy `{"key": "p", "modifiers": ["command", "shift"]}`, so upgrading keeps the
    // shortcuts a user already set.
    let keyName = try container.decode(String.self, forKey: .key)
    let modifiers = try container.decode(Set<GlobalShortcutModifier>.self, forKey: .modifiers)
    guard let descriptor = Self(keyName: keyName, modifiers: modifiers) else {
      throw DecodingError.dataCorruptedError(
        forKey: .key,
        in: container,
        debugDescription: "Unrecognized keyboard shortcut key \"\(keyName)\"."
      )
    }
    self = descriptor
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(carbonKeyCode, forKey: .carbonKeyCode)
    try container.encode(carbonModifiers, forKey: .carbonModifiers)
  }

  /// Parses the textual shortcuts other clients store, such as ClashX's `⌘⇧R` or a
  /// `cmd+shift+r` string. Returns `nil` unless exactly one key and at least one modifier
  /// are present.
  init?(string: String) {
    let normalized = string
      .replacingOccurrences(of: "⌘", with: "+cmd+")
      .replacingOccurrences(of: "⌥", with: "+option+")
      .replacingOccurrences(of: "⌃", with: "+control+")
      .replacingOccurrences(of: "⇧", with: "+shift+")
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: " ", with: "+")
    let parts = normalized
      .split(separator: "+")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var modifiers: Set<GlobalShortcutModifier> = []
    var keyName: String?
    for part in parts {
      switch part.lowercased() {
      case "cmd", "command", "meta":
        modifiers.insert(.command)
      case "opt", "option", "alt":
        modifiers.insert(.option)
      case "ctrl", "control", "ctl":
        modifiers.insert(.control)
      case "shift", "shft":
        modifiers.insert(.shift)
      default:
        guard keyName == nil else { return nil }
        keyName = part
      }
    }
    guard let keyName, let descriptor = Self(keyName: keyName, modifiers: modifiers) else {
      return nil
    }
    self = descriptor
  }

  private init?(keyName: String, modifiers: Set<GlobalShortcutModifier>) {
    let normalized = keyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !modifiers.isEmpty, let key = Self.keysByName[normalized] else { return nil }
    var flags: NSEvent.ModifierFlags = []
    for modifier in modifiers {
      flags.insert(modifier.eventModifierFlag)
    }
    self.init(key: key, modifiers: flags)
  }

  var shortcut: KeyboardShortcuts.Shortcut {
    .init(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers)
  }

  var modifiers: Set<GlobalShortcutModifier> {
    let flags = shortcut.modifiers
    return Set(GlobalShortcutModifier.allCases.filter { flags.contains($0.eventModifierFlag) })
  }

  /// Stable, layout-independent identity for grouping and de-duplication. Not user-facing:
  /// ``displayName`` is what a person should read.
  var identity: String {
    "\(carbonModifiers)-\(carbonKeyCode)"
  }

  /// `⇧⌘P`. Main-actor because rendering a key code as a character asks the current keyboard
  /// layout what that key types.
  @MainActor
  var displayName: String {
    shortcut.description
  }

  /// Key names ClashMax still has to read: settings written before the move to
  /// KeyboardShortcuts, and shortcut strings imported from ClashX, Clash Verge, and FlClash.
  /// The recorder never comes through here — it hands over a key code directly.
  private static let keysByName: [String: KeyboardShortcuts.Key] = {
    var table: [String: KeyboardShortcuts.Key] = [:]
    let letters: [KeyboardShortcuts.Key] = [
      .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
      .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z
    ]
    for (character, key) in zip("abcdefghijklmnopqrstuvwxyz", letters) {
      table[String(character)] = key
    }
    let digits: [KeyboardShortcuts.Key] = [
      .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine
    ]
    for (digit, key) in digits.enumerated() {
      table[String(digit)] = key
    }
    let functionKeys: [KeyboardShortcuts.Key] = [
      .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
      .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20
    ]
    for (index, key) in functionKeys.enumerated() {
      table["f\(index + 1)"] = key
    }
    let named: [String: KeyboardShortcuts.Key] = [
      "space": .space,
      "return": .return,
      "enter": .return,
      "escape": .escape,
      "esc": .escape,
      "tab": .tab,
      "delete": .delete,
      "backspace": .delete,
      "forwarddelete": .deleteForward,
      "home": .home,
      "end": .end,
      "pageup": .pageUp,
      "pagedown": .pageDown,
      "help": .help
    ]
    let arrows: [String: KeyboardShortcuts.Key] = [
      "up": .upArrow,
      "uparrow": .upArrow,
      "↑": .upArrow,
      "down": .downArrow,
      "downarrow": .downArrow,
      "↓": .downArrow,
      "left": .leftArrow,
      "leftarrow": .leftArrow,
      "←": .leftArrow,
      "right": .rightArrow,
      "rightarrow": .rightArrow,
      "→": .rightArrow
    ]
    let punctuation: [String: KeyboardShortcuts.Key] = [
      "minus": .minus,
      "equal": .equal,
      "=": .equal,
      "comma": .comma,
      ",": .comma,
      "period": .period,
      ".": .period,
      "slash": .slash,
      "/": .slash,
      "backslash": .backslash,
      "\\": .backslash,
      "semicolon": .semicolon,
      ";": .semicolon,
      "quote": .quote,
      "'": .quote,
      "backtick": .backtick,
      "`": .backtick,
      "leftbracket": .leftBracket,
      "[": .leftBracket,
      "rightbracket": .rightBracket,
      "]": .rightBracket
    ]
    for group in [named, arrows, punctuation] {
      table.merge(group) { current, _ in current }
    }
    return table
  }()
}

extension GlobalShortcutModifier {
  var eventModifierFlag: NSEvent.ModifierFlags {
    switch self {
    case .command: .command
    case .option: .option
    case .control: .control
    case .shift: .shift
    }
  }
}
