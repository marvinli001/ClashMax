@testable import ClashMax
import XCTest

/// Covers the process-boundary layer of structured logging: level normalization,
/// source-side credential redaction, and the byte-stream accumulator every producer
/// (Mihomo stdout, helper, network extension) feeds its output through.
final class StructuredLogProducerTests: XCTestCase {
  // MARK: - Level normalization

  func testProducerLevelNormalizesAliasesAndPreservesUnknownRawValue() {
    XCTAssertEqual(StructuredLogLevel(normalizing: "warn"), .warning)
    XCTAssertEqual(StructuredLogLevel(normalizing: "panic"), .critical)
    let normalized = StructuredLogLevel.normalized("notice")
    XCTAssertEqual(normalized.level, .info)
    XCTAssertEqual(normalized.originalValue, "notice")
  }

  func testProducerLevelNormalizationIsCaseAndWhitespaceInsensitive() {
    XCTAssertEqual(StructuredLogLevel(normalizing: "  DEBUG "), .debug)
    XCTAssertEqual(StructuredLogLevel(normalizing: "Fatal"), .critical)
    XCTAssertEqual(StructuredLogLevel(normalizing: "verbose"), .trace)
    XCTAssertNil(StructuredLogLevel(normalizing: "notice"))
    XCTAssertNil(StructuredLogLevel(normalizing: ""))
  }

  func testNormalizedLevelReportsWhetherTheTokenWasRecognized() {
    let known = StructuredLogLevel.normalized("ERROR")
    XCTAssertEqual(known.level, .error)
    XCTAssertEqual(known.originalValue, "ERROR")
    XCTAssertTrue(known.isRecognized)

    let unknown = StructuredLogLevel.normalized("chatty")
    XCTAssertEqual(unknown.level, .info)
    XCTAssertEqual(unknown.originalValue, "chatty")
    XCTAssertFalse(unknown.isRecognized)
  }

  // MARK: - Credential redaction

  func testCredentialRedactionIsComprehensiveAndIdempotent() {
    let sentinel = "CLASHMAX_SECRET_7F4B"
    let input = """
    Authorization: Bearer \(sentinel)
    Cookie: session=\(sentinel)
    https://user:\(sentinel)@example.com/sub/\(sentinel)?token=\(sentinel)
    vmess://uuid-\(sentinel)@proxy.example:443
    private-key: \(sentinel) psk=\(sentinel)
    /Users/tester/Library/Application Support/ClashMax/Runtime/\(sentinel).yaml
    errorDomain=NSURLErrorDomain errorCode=-1004
    """
    let once = StructuredLogRedactor.redactCredentials(
      in: input,
      homeDirectory: "/Users/tester"
    )
    XCTAssertFalse(once.contains(sentinel))
    XCTAssertFalse(once.contains("/Users/tester"))
    XCTAssertTrue(once.contains("NSURLErrorDomain"))
    XCTAssertTrue(once.contains("-1004"))
    XCTAssertEqual(
      StructuredLogRedactor.redactCredentials(in: once, homeDirectory: "/Users/tester"),
      once
    )
  }

  func testRedactionKeepsDiagnosticStructureWorthReading() {
    let redacted = StructuredLogRedactor.redactCredentials(
      in: """
      GET https://sub.example.com/link/abc123?token=zzz failed
      config at /Users/tester/Library/Application Support/ClashMax/Runtime/config.yaml
      listen 127.0.0.1:7890
      """,
      homeDirectory: "/Users/tester"
    )
    // Hosts, ports, and directory structure are the diagnostic payload and survive.
    XCTAssertTrue(redacted.contains("https://sub.example.com"))
    XCTAssertTrue(redacted.contains("127.0.0.1:7890"))
    XCTAssertTrue(redacted.contains("~/Library/Application Support/ClashMax/Runtime/"))
    XCTAssertTrue(redacted.contains("failed"))
    // Subscription path/query and the profile file name are not.
    XCTAssertFalse(redacted.contains("abc123"))
    XCTAssertFalse(redacted.contains("token=zzz"))
    XCTAssertFalse(redacted.contains("config.yaml"))
    XCTAssertTrue(redacted.contains(".yaml"))
  }

  func testRedactionCoversProxyShareLinksWithoutUserinfo() {
    let sentinel = "CLASHMAX_SECRET_7F4B"
    for scheme in ["ss", "ssr", "vless", "trojan", "hysteria2", "tuic"] {
      let redacted = StructuredLogRedactor.redactCredentials(in: "\(scheme)://\(sentinel)==#node")
      XCTAssertFalse(redacted.contains(sentinel), "\(scheme) share link leaked its payload")
      XCTAssertTrue(redacted.hasPrefix("\(scheme)://"), "\(scheme) scheme should survive")
    }
  }

  func testRedactionRemovesAnyUserHomeEvenWhenHomeDirectoryIsUnknown() {
    let redacted = StructuredLogRedactor.redactCredentials(
      in: "read /Users/someone.else/Library/Logs/ClashMax/core.log failed"
    )
    XCTAssertFalse(redacted.contains("someone.else"))
    XCTAssertTrue(redacted.contains("~/Library/Logs/ClashMax/"))
  }

  func testMetadataRedactionRedactsValuesAndKeepsKeys() {
    let sentinel = "CLASHMAX_SECRET_7F4B"
    let redacted = StructuredLogRedactor.redactCredentials(
      in: [
        "subscription": "https://example.com/link?token=\(sentinel)",
        "profilePath": "/Users/tester/Library/Application Support/ClashMax/\(sentinel).yaml",
        "errorCode": "-1004",
      ],
      homeDirectory: "/Users/tester"
    )
    XCTAssertEqual(Set(redacted.keys), ["subscription", "profilePath", "errorCode"])
    XCTAssertEqual(redacted["errorCode"], "-1004")
    for value in redacted.values {
      XCTAssertFalse(value.contains(sentinel))
      XCTAssertFalse(value.contains("/Users/tester"))
    }
  }

  // MARK: - Event encoding

  func testProducerEventRoundTripsThroughJSON() throws {
    let event = ProducerLogEvent(
      id: "0BD4B6E2-8B4B-4E2F-9E42-6A2F1B3C4D5E",
      timestamp: Date(timeIntervalSince1970: 1_753_660_800),
      source: .mihomo,
      category: "core",
      code: "core.start.failed",
      level: .error,
      audience: .support,
      message: "listen tcp 127.0.0.1:7890: bind: address already in use",
      metadata: ["port": "7890"]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
      ProducerLogEvent.self,
      from: encoder.encode(event)
    )
    XCTAssertEqual(decoded, event)
  }

  // MARK: - Sanitized line accumulator

  func testAccumulatorJoinsSecretsSplitAcrossChunks() {
    var accumulator = SanitizedLineAccumulator(homeDirectory: "/Users/tester")
    let sentinel = "CLASHMAX_SECRET_7F4B"
    XCTAssertTrue(accumulator.append(Data("Authorization: Bearer CLASHMAX".utf8)).isEmpty)
    let lines = accumulator.append(Data("_SECRET_7F4B\n".utf8))
    XCTAssertEqual(lines.count, 1)
    XCTAssertFalse(lines[0].contains(sentinel))
    XCTAssertTrue(lines[0].hasPrefix("Authorization:"))
  }

  func testAccumulatorReturnsOnlyCompletedLines() {
    var accumulator = SanitizedLineAccumulator()
    let lines = accumulator.append(Data("first\r\nsecond\nthird-without-newline".utf8))
    XCTAssertEqual(lines, ["first", "second"])
    XCTAssertEqual(accumulator.finish(), ["third-without-newline"])
    XCTAssertEqual(accumulator.finish(), [])
  }

  func testAccumulatorDropsEmptyTrailingFlush() {
    var accumulator = SanitizedLineAccumulator()
    XCTAssertEqual(accumulator.append(Data("only\n".utf8)), ["only"])
    XCTAssertEqual(accumulator.finish(), [])
  }

  func testAccumulatorSurvivesInvalidUTF8() {
    var accumulator = SanitizedLineAccumulator()
    var data = Data("ok ".utf8)
    data.append(contentsOf: [0xff, 0xfe, 0xc3])
    data.append(contentsOf: Array("\n".utf8))
    let lines = accumulator.append(data)
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].hasPrefix("ok "))
  }

  func testAccumulatorTruncatesOverlongLinesWithoutUnboundedRetention() {
    var accumulator = SanitizedLineAccumulator(maximumLineBytes: 64)
    let flood = String(repeating: "x", count: 5_000)
    let emitted = accumulator.append(Data(flood.utf8))
    XCTAssertEqual(emitted.count, 1)
    XCTAssertLessThanOrEqual(emitted[0].utf8.count, 128)
    XCTAssertEqual(accumulator.truncatedLineCount, 1)

    // The rest of the overlong line is discarded, not buffered.
    XCTAssertTrue(accumulator.append(Data(flood.utf8)).isEmpty)
    XCTAssertEqual(accumulator.truncatedLineCount, 1)
    XCTAssertEqual(accumulator.pendingByteCount, 0)

    // The next delimiter resumes normal line handling.
    XCTAssertEqual(accumulator.append(Data("\nback to normal\n".utf8)), ["back to normal"])
    XCTAssertEqual(accumulator.finish(), [])
  }

  func testAccumulatorRedactsTruncatedLines() {
    var accumulator = SanitizedLineAccumulator(
      maximumLineBytes: 512,
      homeDirectory: "/Users/tester"
    )
    let sentinel = "CLASHMAX_SECRET_7F4B"
    let line = "password=\(sentinel) " + String(repeating: "y", count: 4_000)
    let emitted = accumulator.append(Data(line.utf8))
    XCTAssertEqual(emitted.count, 1)
    XCTAssertFalse(emitted[0].contains(sentinel))
  }
}
