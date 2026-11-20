import Foundation

/// Measured with bundled Mihomo v1.19.34 on macOS, using separate main and nested helper binaries.
/// Exact name/path are case-insensitive. Regexps search anywhere, ignore case by default and
/// honor (?-i) and lookbehind. A helper's name/path belongs to its executable, not the parent.
/// The core uses regexp2; do not silently reinterpret engine-specific syntax as ICU syntax.
struct NEProcessPredicate: Hashable, Codable, Sendable {
  enum Kind: String, Codable, Sendable {
    case name = "PROCESS-NAME", path = "PROCESS-PATH", nameRegex = "PROCESS-NAME-REGEX", pathRegex = "PROCESS-PATH-REGEX"
    var isRegex: Bool { self == .nameRegex || self == .pathRegex }
    var usesPath: Bool { self == .path || self == .pathRegex }
  }

  var kind: Kind
  var value: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.value.utf8.elementsEqual(rhs.value.utf8)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(kind)
    for byte in value.utf8 { hasher.combine(byte) }
  }

  /// regexp2 lowercases a rune at a time. ICU instead folds "ß" into "ss" and "ſ" into "s".
  /// For the common literal/picker expressions, compile the lowercased literal and run it
  /// case-sensitively on the same simple-lowercase representation of the process path.
  var foldedLiteralPattern: String? {
    var result = ""
    var chars = value.unicodeScalars.makeIterator()
    while let char = chars.next() {
      if char == "\\" {
        guard let next = chars.next() else { return nil }
        if next == "x" {
          guard let a = chars.next(), let b = chars.next(),
                let byte = UInt8(String(a) + String(b), radix: 16) else { return nil }
          result += NSRegularExpression.escapedPattern(for: Self.simpleLower(String(Unicode.Scalar(byte))))
        } else {
          guard #"\.^$|?*+()[]{}"#.unicodeScalars.contains(next) else { return nil }
          result += NSRegularExpression.escapedPattern(for: String(next))
        }
      } else if char == "^" || char == "$" {
        result.unicodeScalars.append(char)
      } else {
        guard !#".|?*+()[]{}"#.unicodeScalars.contains(char) else { return nil }
        result += NSRegularExpression.escapedPattern(for: Self.simpleLower(String(char)))
      }
    }
    return result
  }

  static func simpleLower(_ text: String) -> String {
    var value = ""
    for scalar in text.unicodeScalars {
      // U+0130's full mapping has two scalars, its Unicode simple lowercase is i.
      value += scalar.value == 0x130 ? "i" : scalar.properties.lowercaseMapping
    }
    return value
  }

  static func hasDifferentCaseFolding(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      guard !scalar.isASCII else { return false }
      let folded = String(scalar).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
      return !folded.unicodeScalars.elementsEqual(simpleLower(String(scalar)).unicodeScalars)
    }
  }

  func expression() throws -> NSRegularExpression {
    // .NET balancing groups, conditionals, class subtraction and ICU set operations have no
    // common interpretation. v1.19.34 matched (?(?=H)Hel|xyz) and [a-z-[aeiou]] against
    // Helper. An unrepresentable rule stays intact in the core's own rule list.
    if ["(?(", "(?'", "(?n", "-[", "&&", "(?#"].contains(where: value.contains)
      || value.range(of: #"\(\?<[^=!>]*-"#, options: .regularExpression) != nil
    {
      throw CocoaError(.formatting)
    }
    if let foldedLiteralPattern {
      return try NSRegularExpression(pattern: foldedLiteralPattern, options: .useUnixLineSeparators)
    }
    guard !Self.hasDifferentCaseFolding(value) else { throw CocoaError(.formatting) }
    return try NSRegularExpression(pattern: value, options: [.caseInsensitive, .useUnixLineSeparators])
  }
}

struct NEProcessRoute: Equatable, Codable, Sendable {
  var predicate: NEProcessPredicate
  var inbound: String
  var port: Int
  /// The first occurrence depends on other conditions. Its policy may fall through.
  var conditional: Bool
}

struct NEProcessRoutePlan: Equatable, Sendable {
  static let limit = 64
  var routes: [NEProcessRoute] = []
  var overLimit = 0
  var unsupported = 0
}

struct NEProcessMatcher: Sendable {
  private struct Entry: Sendable {
    var route: NEProcessRoute
    var expression: NSRegularExpression?
    var usesSimpleLower: Bool
  }

  private let entries: [Entry]
  var isEmpty: Bool { entries.isEmpty }

  init(routes: [NEProcessRoute]) throws {
    entries = try routes.map { route in
      try Entry(route: route, expression: route.predicate.kind.isRegex ? route.predicate.expression() : nil,
                usesSimpleLower: route.predicate.kind.isRegex && route.predicate.foldedLiteralPattern != nil)
    }
  }

  struct Decision: Equatable {
    var route: NEProcessRoute?
    var uncertain = false
  }

  func select(path: String?, signingIdentifier: String) -> Decision {
    // File URLs normalize some names to decomposed Unicode. The core uses the raw basename.
    let name = path?.split(separator: "/").last.map(String.init) ?? signingIdentifier
    var result = Decision()
    var foldedTargets: [String: String] = [:]
    var exceptionalTargets: [String: Bool] = [:]
    let deadline = ContinuousClock.now + .milliseconds(4)
    for entry in entries {
      let predicate = entry.route.predicate
      guard let target = predicate.kind.usesPath ? path : name, !target.isEmpty else { continue }
      let matches: Bool
      if let expression = entry.expression {
        // An imported backtracking expression must not monopolize the provider's flow callback.
        let input: String
        if entry.usesSimpleLower {
          input = foldedTargets[target] ?? NEProcessPredicate.simpleLower(target)
          foldedTargets[target] = input
        } else {
          let exceptional = exceptionalTargets[target] ?? NEProcessPredicate.hasDifferentCaseFolding(target)
          exceptionalTargets[target] = exceptional
          if exceptional {
            result.uncertain = true
            break
          }
          input = target
        }
        var found = false
        var timedOut = false
        expression.enumerateMatches(in: input, options: .reportProgress, range: NSRange(input.startIndex..., in: input)) { match, _, stop in
          if match != nil {
            found = true
            stop.pointee = true
          } else if ContinuousClock.now >= deadline {
            timedOut = true
            stop.pointee = true
          }
        }
        if timedOut {
          result.uncertain = true
          break
        }
        matches = found
      } else {
        // EqualFold compares one Unicode scalar at a time; e.g. "ß" does not equal "ss".
        matches = target.unicodeScalars.elementsEqual(predicate.value.unicodeScalars) { a, b in
          a == b || String(a).caseInsensitiveCompare(String(b)) == .orderedSame
        }
      }
      guard matches else { continue }
      if result.route != nil {
        result.uncertain = true
        break
      }
      result.route = entry.route
      if !entry.route.conditional { break }
    }
    return result
  }
}
