import Foundation

/// Severity of a structured log event, ordered from most to least verbose.
///
/// Producers speak different dialects — Mihomo emits `warning`/`panic`, the helper and
/// the network extension emit their own tokens — so the raw string is normalized here
/// once, at the process boundary, instead of at every reader.
enum StructuredLogLevel: String, Codable, CaseIterable, Sendable {
  case trace
  case debug
  case info
  case warning
  case error
  case critical

  /// Recognized spellings that are not the canonical raw value.
  private static let aliases: [String: StructuredLogLevel] = [
    "verbose": .trace,
    "warn": .warning,
    "err": .error,
    "fatal": .critical,
    "panic": .critical,
    "crit": .critical,
  ]

  /// Parses a producer-supplied level token. Returns `nil` for anything unrecognized so
  /// callers can decide whether an unknown token deserves a fallback or an error.
  init?(normalizing rawValue: String) {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let exact = StructuredLogLevel(rawValue: normalized) {
      self = exact
      return
    }
    guard let alias = StructuredLogLevel.aliases[normalized] else { return nil }
    self = alias
  }

  /// The result of normalizing a producer level token, keeping the token the producer
  /// actually wrote. Losing it would make a log line lie about its own source.
  struct Normalized: Equatable, Sendable {
    /// The level to filter and render by.
    var level: StructuredLogLevel
    /// The producer's original, untrimmed token.
    var originalValue: String
    /// `false` when `level` is the fallback rather than a parse of `originalValue`.
    var isRecognized: Bool
  }

  /// Normalizes a token, falling back to `.info` when it is unrecognized.
  ///
  /// An unknown severity must not silently become `error` (false alarms) or be dropped
  /// (lost diagnostics); `.info` keeps the line visible at the default filter while
  /// `originalValue` preserves the truth.
  static func normalized(_ rawValue: String, fallback: StructuredLogLevel = .info) -> Normalized {
    guard let level = StructuredLogLevel(normalizing: rawValue) else {
      return Normalized(level: fallback, originalValue: rawValue, isRecognized: false)
    }
    return Normalized(level: level, originalValue: rawValue, isRecognized: true)
  }
}

/// Who a log event is written for.
///
/// `support` events are the ones a user can be asked to copy into a bug report;
/// `developer` events are the noisy internals behind them.
enum LogAudience: String, Codable, Sendable {
  case support
  case developer
}

/// The process or subsystem that produced an event.
enum LogSource: String, Codable, CaseIterable, Sendable {
  case clashMax
  case mihomo
  case helper
  case networkExtension
  case tun
}

/// One log event as it leaves its producer, before the app enriches or projects it.
///
/// This is the wire shape that crosses XPC and lands in the on-disk JSONL, so it stays
/// `Codable`, `Sendable`, and free of app-only types.
struct ProducerLogEvent: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var timestamp: Date
  var source: LogSource
  var category: String
  var code: String
  var level: StructuredLogLevel
  var audience: LogAudience
  var message: String
  var metadata: [String: String]

  init(
    id: String = UUID().uuidString,
    timestamp: Date = Date(),
    source: LogSource,
    category: String,
    code: String,
    level: StructuredLogLevel,
    audience: LogAudience,
    message: String,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.source = source
    self.category = category
    self.code = code
    self.level = level
    self.audience = audience
    self.message = message
    self.metadata = metadata
  }
}
