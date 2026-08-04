import Foundation

/// Turns an arbitrary byte stream (Mihomo stdout/stderr, helper pipes, extension output)
/// into complete, redacted log lines.
///
/// Producers hand us whatever the kernel happened to deliver: a line split across two
/// reads, several lines in one read, invalid UTF-8, or a single line that never ends.
/// Only completed lines are returned, and every returned line has already been through
/// `StructuredLogRedactor` — a secret split across two chunks is joined *before*
/// redaction runs, so it can never slip past on a chunk boundary.
///
/// Retention is bounded: the pending buffer never holds more than `maximumLineBytes + 1`
/// bytes, so a producer that emits an endless line cannot grow this into memory pressure.
struct SanitizedLineAccumulator {

  /// Appended to a line that had to be cut short.
  static let truncationMarker = " <truncated>"

  private let maximumLineBytes: Int
  private let homeDirectory: String?
  private var pending: [UInt8] = []
  /// Set after a truncation: the rest of that line is dropped until the next delimiter.
  private var isDiscardingOverflow = false

  /// How many lines were cut short because they exceeded `maximumLineBytes`.
  private(set) var truncatedLineCount = 0

  /// Bytes currently buffered for an incomplete line. Exposed so callers (and tests) can
  /// prove nothing unbounded is being retained.
  var pendingByteCount: Int { pending.count }

  init(maximumLineBytes: Int = 16_384, homeDirectory: String? = nil) {
    self.maximumLineBytes = max(1, maximumLineBytes)
    self.homeDirectory = homeDirectory
  }

  /// Consumes a chunk and returns every line it completed.
  mutating func append(_ data: Data) -> [String] {
    guard !data.isEmpty else { return [] }
    var lines: [String] = []
    var index = data.startIndex

    while index < data.endIndex {
      let newlineIndex = data[index...].firstIndex(of: UInt8(ascii: "\n"))
      let chunkEnd = newlineIndex ?? data.endIndex
      let chunk = data[index..<chunkEnd]
      index = newlineIndex.map { data.index(after: $0) } ?? data.endIndex

      if isDiscardingOverflow {
        // Still inside the tail of a truncated line; a delimiter ends it.
        if newlineIndex != nil { isDiscardingOverflow = false }
        continue
      }

      // Never buffer more than one byte past the cap: that single byte is what proves
      // the line overflowed, and nothing beyond it is ever retained.
      let room = maximumLineBytes + 1 - pending.count
      pending.append(contentsOf: chunk.prefix(room))

      if pending.count > maximumLineBytes {
        lines.append(truncatedLine())
        truncatedLineCount += 1
        pending.removeAll(keepingCapacity: true)
        isDiscardingOverflow = (newlineIndex == nil)
        continue
      }

      if newlineIndex != nil {
        lines.append(sanitizedLine(pending))
        pending.removeAll(keepingCapacity: true)
      }
    }

    return lines
  }

  /// Flushes a trailing line that never got its delimiter, e.g. at process exit.
  mutating func finish() -> [String] {
    defer {
      pending.removeAll(keepingCapacity: false)
      isDiscardingOverflow = false
    }
    guard !isDiscardingOverflow, !pending.isEmpty else { return [] }
    return [sanitizedLine(pending)]
  }

  // MARK: - Line construction

  private func sanitizedLine(_ bytes: [UInt8]) -> String {
    var slice = bytes[...]
    if slice.last == UInt8(ascii: "\r") { slice = slice.dropLast() }
    // Lossy by construction: a producer emitting invalid UTF-8 must not lose the line.
    let text = String(decoding: slice, as: UTF8.self)
    return StructuredLogRedactor.redactCredentials(in: text, homeDirectory: homeDirectory)
  }

  private func truncatedLine() -> String {
    sanitizedLine(Array(pending.prefix(maximumLineBytes))) + Self.truncationMarker
  }
}
