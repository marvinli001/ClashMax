import Foundation
import XCTest
@testable import ClashMax

final class SubscriptionPreflightDiagnosticFormatterTests: XCTestCase {
  // Real bundled Mihomo v1.19.27 `-t` output: info/warn lines, then the real
  // cause as a logfmt `level=error` line, then a generic trailer last.
  private let realMihomoFailureOutput = """
  time="2026-06-19T18:47:40.751333000+12:00" level=info msg="Start initial configuration in progress"
  time="2026-06-19T18:47:40.751727000+12:00" level=error msg="proxy 0: '' has unset fields: cipher, password"
  configuration file /tmp/runtime.yaml test failed
  """

  func testSummaryExtractsLogfmtErrorMessageNotTheTrailer() {
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: realMihomoFailureOutput)
    XCTAssertEqual(summary, "proxy 0: '' has unset fields: cipher, password")
  }

  func testSummaryDoesNotReturnBenignInfoLineOrTrailer() {
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: realMihomoFailureOutput)
    XCTAssertNotNil(summary)
    XCTAssertFalse(summary?.contains("Start initial configuration in progress") ?? true)
    XCTAssertFalse(summary?.contains("test failed") ?? true)
  }

  func testSummaryHandlesYamlSyntaxErrorWithEmbeddedColonQuotes() {
    let output = """
    time="2026-06-19T18:47:40.740384000+12:00" level=error msg="yaml: line 4: could not find expected ':'"
    configuration file /tmp/bad.yaml test failed
    """
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "yaml: line 4: could not find expected ':'")
  }

  func testSummaryPrefersLastFailureLineWhenMultipleErrors() {
    let output = """
    time="t1" level=error msg="first problem"
    time="t2" level=info msg="recovering"
    time="t3" level=fatal msg="final fatal cause"
    configuration file /tmp/x.yaml test failed
    """
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "final fatal cause")
  }

  func testSummaryUnescapesQuotedMessageValue() {
    let output = #"time="t1" level=error msg="bad value \"abc\" rejected""#
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "bad value \"abc\" rejected")
  }

  func testSummarySupportsLegacyBracketedPrefixFormat() {
    let output = """
    INFO[0000] Start initial configuration in progress
    FATA[0001] Parse config error: yaml: line 87: did not find expected '-' indicator
    """
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "FATA[0001] Parse config error: yaml: line 87: did not find expected '-' indicator")
  }

  func testSummaryFallsBackToLastMeaningfulLineWhenNoErrorPrefixPresent() {
    let output = """
    Loading config
    Validating proxies
    Finished
    """
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "Finished")
  }

  func testSummaryDropsTrailerWhenOnlyTrailerAndInfoPresent() {
    let output = """
    time="t1" level=info msg="doing work"
    configuration file /tmp/x.yaml test failed
    """
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: output)
    XCTAssertEqual(summary, "doing work")
  }

  func testSummaryClampsOverlongSingleLineOutput() {
    let line = String(repeating: "A", count: 400)
    let summary = SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: line)
    XCTAssertEqual(summary?.count, SubscriptionPreflightDiagnosticFormatter.summaryCharacterLimit)
    XCTAssertTrue(summary?.hasSuffix("...") ?? false)
  }

  func testSummaryReturnsNilForEmptyOrWhitespaceOnlyInput() {
    XCTAssertNil(SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: ""))
    XCTAssertNil(SubscriptionPreflightDiagnosticFormatter.summary(fromFullMessage: "   \n\t\n  "))
  }

  func testFullDiagnosticTrimsButPreservesInternalNewlines() {
    let full = SubscriptionPreflightDiagnosticFormatter.fullDiagnostic(fromFullMessage: "\n\nINFO line 1\nFATA crash here\n\n")
    XCTAssertEqual(full, "INFO line 1\nFATA crash here")
  }

  func testFullDiagnosticReturnsNilForEmptyInput() {
    XCTAssertNil(SubscriptionPreflightDiagnosticFormatter.fullDiagnostic(fromFullMessage: "   "))
  }

  func testSubscriptionPreflightDiagnosticsDecodesLegacyPayloadWithoutFullMessage() throws {
    let legacyJSON = """
    { "checkedAt": 700000000, "result": "failed", "message": "Parse config error" }
    """.data(using: .utf8)!
    let diagnostics = try JSONDecoder().decode(SubscriptionPreflightDiagnostics.self, from: legacyJSON)
    XCTAssertEqual(diagnostics.result, .failed)
    XCTAssertEqual(diagnostics.message, "Parse config error")
    XCTAssertNil(diagnostics.fullMessage, "Legacy payloads (no fullMessage) should decode with nil fullMessage")
  }

  func testSubscriptionPreflightDiagnosticsKeepsFullMessageThroughEncodeDecodeRoundTrip() throws {
    let original = SubscriptionPreflightDiagnostics(
      result: .failed,
      message: "proxy 0: '' has unset fields: cipher, password",
      fullMessage: realMihomoFailureOutput
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SubscriptionPreflightDiagnostics.self, from: data)
    XCTAssertEqual(decoded.result, original.result)
    XCTAssertEqual(decoded.message, original.message)
    XCTAssertEqual(decoded.fullMessage, original.fullMessage)
  }
}
