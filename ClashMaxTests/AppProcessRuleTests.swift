@testable import ClashMax
import Foundation
import XCTest
import Yams

/// Roadmap B1: the app picker, the rule it writes, and the app a connection is traced back to.
final class AppProcessRuleTests: XCTestCase {
  // MARK: Scanning

  func testScannerListsAppsAtTheTopAndOneFolderDownButNeverInsideABundle() throws {
    let root = try makeTemporaryDirectory()
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let userApplications = root.appendingPathComponent("User/Applications", isDirectory: true)
    try makeApp(at: applications.appendingPathComponent("Alpha.app"), identifier: "com.example.alpha", executable: "Alpha")
    try makeApp(at: applications.appendingPathComponent("Utilities/Beta.app"), identifier: "com.example.beta", executable: "beta-bin")
    let gamma = applications.appendingPathComponent("Gamma.app")
    try makeApp(at: gamma, identifier: "com.example.gamma", executable: "Gamma")
    try makeApp(at: gamma.appendingPathComponent("Contents/Frameworks/Gamma Helper.app"), identifier: "com.example.gamma.helper", executable: "Gamma Helper")
    try makeApp(at: applications.appendingPathComponent("Deep/Deeper/Delta.app"), identifier: "com.example.delta", executable: "Delta")
    try "not an app".write(to: applications.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try makeApp(at: userApplications.appendingPathComponent("Epsilon.app"), identifier: nil, executable: nil)

    let apps = InstalledAppScanner.scan(directories: [
      applications,
      userApplications,
      root.appendingPathComponent("Missing", isDirectory: true),
    ])

    XCTAssertEqual(apps.map(\.name), ["Alpha", "Beta", "Epsilon", "Gamma"])
    XCTAssertEqual(apps.map(\.bundleIdentifier), ["com.example.alpha", "com.example.beta", nil, "com.example.gamma"])
    XCTAssertEqual(apps[1].executableURL?.lastPathComponent, "beta-bin")
    XCTAssertEqual(apps[1].executableURL?.deletingLastPathComponent().lastPathComponent, "MacOS")
    XCTAssertNil(apps[2].executableURL)
  }

  func testScannerListsABundleReachedTwiceOnce() throws {
    let root = try makeTemporaryDirectory()
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    try makeApp(at: applications.appendingPathComponent("Alpha.app"), identifier: "com.example.alpha", executable: "Alpha")

    let apps = InstalledAppScanner.scan(directories: [applications, applications])

    XCTAssertEqual(apps.count, 1)
  }

  // MARK: The rule

  func testBundlePatternEscapesMetacharactersAndEncodesCommas() {
    XCTAssertEqual(
      AppProcessRule.bundlePathPattern(for: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
      #"^/Applications/Google Chrome\.app/"#
    )
    // The exact payload the bundled core accepted and matched in the probe recorded in ROADMAP B1.
    XCTAssertEqual(
      AppProcessRule.bundlePathPattern(for: URL(fileURLWithPath: "/Applications/Probe+ (Beta), Inc.app")),
      #"^/Applications/Probe\+ \(Beta\)\x2C Inc\.app/"#
    )
    XCTAssertEqual(AppProcessRule.escapedRegexLiteral(#"a\b[c]{d}|e*f?g^h$i"#), #"a\\b\[c\]\{d\}\|e\*f\?g\^h\$i"#)
  }

  func testAppDraftIsAValidRuleWithExactlyThreeFields() throws {
    let app = InstalledApp(
      bundleURL: URL(fileURLWithPath: "/Applications/Probe+ (Beta), Inc.app"),
      name: "Probe+ (Beta), Inc",
      bundleIdentifier: "com.example.probe",
      executableURL: URL(fileURLWithPath: "/Applications/Probe+ (Beta), Inc.app/Contents/MacOS/Probe")
    )

    let draft = AppProcessRule.draft(for: app, policy: "Proxy")

    XCTAssertNil(draft.validationError)
    XCTAssertEqual(draft.rule.kind, .processPathRegex)
    XCTAssertEqual(draft.runtimeRule, #"PROCESS-PATH-REGEX,^/Applications/Probe\+ \(Beta\)\x2C Inc\.app/,Proxy"#)
    XCTAssertEqual(draft.runtimeRule.split(separator: ",", omittingEmptySubsequences: false).count, 3)
    XCTAssertEqual(draft.verificationInput?.process, "/Applications/Probe+ (Beta), Inc.app/Contents/MacOS/Probe")
  }

  func testAnUncompilablePatternIsRefusedBeforeItReachesTheCore() {
    let rule = ManagedRuleOverlayRule(kind: .processPathRegex, value: "^/Applications/Bad(.app/", policy: "DIRECT")

    XCTAssertEqual(rule.validationError, String(localized: "Process path pattern must be a valid regular expression."))
  }

  // MARK: Matching (the simulator behind the post-apply verdict)

  func testBundlePatternMatchesTheAppAndItsHelpersButNotASiblingApp() {
    let pattern = AppProcessRule.bundlePathPattern(for: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    let simulator = RuleMatchSimulator()
    // The core reports the type camel-cased once running; the config spells it with hyphens.
    for type in ["ProcessPathRegex", "PROCESS-PATH-REGEX"] {
      let rules = RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: [
        RuntimeRule(index: 1, type: type, payload: pattern, policy: "Proxy"),
        RuntimeRule(index: 2, type: "MATCH", payload: "", policy: "DIRECT"),
      ])
      func policy(_ process: String) -> String? {
        let trace = simulator.simulate(input: RuleMatchSimulationInput(process: process), candidates: rules)
        guard case let .matched(rule) = trace.outcome else { return nil }
        return rule.policy
      }

      XCTAssertEqual(policy("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), "Proxy", type)
      XCTAssertEqual(
        policy("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/140/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
        "Proxy",
        type
      )
      // Measured: the core matched this pattern case-insensitively.
      XCTAssertEqual(policy("/applications/google chrome.app/Contents/MacOS/Google Chrome"), "Proxy", type)
      XCTAssertEqual(policy("/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"), "DIRECT", type)
      XCTAssertEqual(policy("/usr/bin/curl"), "DIRECT", type)
    }
  }

  // MARK: Tracing a connection back to its app

  func testOwningAppIsTheOutermostBundle() {
    XCTAssertEqual(
      AppProcessRule.owningAppBundle(ofProcessPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")?.path,
      "/Applications/Google Chrome.app"
    )
    XCTAssertEqual(
      AppProcessRule.owningAppBundle(ofProcessPath: "/Users/me/Applications/Slack.APP/Contents/MacOS/Slack")?.path,
      "/Users/me/Applications/Slack.APP"
    )
    XCTAssertNil(AppProcessRule.owningAppBundle(ofProcessPath: "/usr/bin/curl"))
    XCTAssertNil(AppProcessRule.owningAppBundle(ofProcessPath: "/opt/.app/tool"))
    XCTAssertNil(AppProcessRule.owningAppBundle(ofProcessPath: "Slack.app/Contents/MacOS/Slack"))
    XCTAssertEqual(
      AppProcessRule.appName(forProcessPath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
      "Google Chrome"
    )
  }

  func testConnectionDraftCoversTheOwningAppOrFallsBackToTheExecutable() throws {
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    let appDraft = try XCTUnwrap(AppProcessRule.draft(forProcessPath: helper))
    XCTAssertEqual(appDraft.rule.kind, .processPathRegex)
    XCTAssertEqual(appDraft.rule.value, #"^/Applications/Google Chrome\.app/"#)
    XCTAssertEqual(appDraft.verificationInput?.process, helper, "the process actually seen is the probe")

    let plain = try XCTUnwrap(AppProcessRule.draft(forProcessPath: "/opt/homebrew/bin/aria2c"))
    XCTAssertEqual(plain.rule.kind, .processPath)
    XCTAssertEqual(plain.rule.value, "/opt/homebrew/bin/aria2c")

    let withComma = try XCTUnwrap(AppProcessRule.draft(forProcessPath: "/opt/tools/a,b"))
    XCTAssertEqual(withComma.rule.kind, .processPathRegex)
    XCTAssertEqual(withComma.rule.value, #"^/opt/tools/a\x2Cb$"#)
    // The policy is left for the user to choose, as for every quick rule opened from a row.
    var chosen = withComma
    chosen.rule.policy = "DIRECT"
    XCTAssertNil(chosen.validationError)

    XCTAssertNil(AppProcessRule.draft(forProcessPath: nil))
    XCTAssertNil(AppProcessRule.draft(forProcessPath: "curl"))
  }

  // MARK: One store (INV-1)

  func testAnAppRuleLandsInTheSameQuickRulesSnippetAsEveryOtherQuickRule() {
    let profileID = UUID()
    let app = InstalledApp(bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack")

    let first = QuickRuleLibrary.adding(
      AppProcessRule.draft(for: app, policy: "Proxy"),
      to: QuickRuleLibrary.targetSnippet(in: [], activeProfileID: profileID)
    )
    let second = QuickRuleLibrary.adding(
      .targeting(host: "example.com", policy: "DIRECT"),
      to: QuickRuleLibrary.targetSnippet(in: [first], activeProfileID: profileID)
    )

    XCTAssertEqual(first.id, QuickRuleLibrary.snippetID)
    XCTAssertEqual(second.id, QuickRuleLibrary.snippetID)
    guard case let .rules(settings) = second.payload else {
      return XCTFail("Quick Rules must stay a rules snippet")
    }
    XCTAssertEqual(settings.prependRules.map(\.kind), [.domainSuffix, .processPathRegex])
    XCTAssertTrue(second.enabled)
    XCTAssertTrue(second.binding.applies(to: profileID))
  }

  func testTheGeneratedRuntimeConfigCarriesThePatternUnchanged() throws {
    let rule = ManagedRuleOverlayRule(
      kind: .processPathRegex,
      value: AppProcessRule.bundlePathPattern(for: URL(fileURLWithPath: "/Applications/Probe+ (Beta), Inc.app")),
      policy: "DIRECT"
    )
    var options = RuntimeConfigOptions()
    options.runtimeSnippets = [
      RuntimeSnippet(name: "Quick Rules", payload: .rules(RuleOverlaySettings(enabled: true, prependRules: [rule]))),
    ]

    let yaml = try ConfigNormalizer().runtimeConfig(
      from: Self.minimalProfile,
      overrides: .defaultForLaunch(secret: "app-rule-secret"),
      options: options
    )

    let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
    let rules = try XCTUnwrap(root["rules"] as? [String])
    XCTAssertEqual(rules.first, #"PROCESS-PATH-REGEX,^/Applications/Probe\+ \(Beta\)\x2C Inc\.app/,DIRECT"#)
  }

  // MARK: Coverage notes

  func testCoverageNotesNameWhatStopsAProcessRuleFromMatching() {
    let off = ProcessRuleCoverage.notes(routingMode: .tun, findProcessMode: "OFF")
    XCTAssertEqual(off.first?.severity, .blocking)
    XCTAssertTrue(off.first?.text.contains("find-process-mode: off") == true)

    let ne = ProcessRuleCoverage.notes(routingMode: .neProxy, findProcessMode: nil)
    XCTAssertEqual(ne.filter { $0.severity == .blocking }.count, 1)

    let systemProxy = ProcessRuleCoverage.notes(routingMode: .systemProxy, findProcessMode: "strict")
    XCTAssertTrue(systemProxy.allSatisfy { $0.severity == .partial })
    XCTAssertEqual(systemProxy.count, 2)

    // The system-process caveat is true in every mode.
    let tun = ProcessRuleCoverage.notes(routingMode: .tun, findProcessMode: nil)
    XCTAssertEqual(tun.count, 1)
    XCTAssertTrue(tun[0].text.contains("nsurlsessiond"))
  }

  // MARK: Fixtures

  static let minimalProfile = """
  proxies:
    - name: DIRECT-NODE
      type: direct
  proxy-groups:
    - name: Proxy
      type: select
      proxies: [DIRECT-NODE, DIRECT]
  rules:
    - MATCH,Proxy
  """

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppProcessRuleTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func makeApp(at url: URL, identifier: String?, executable: String?) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    var info: [String: Any] = [:]
    info["CFBundleIdentifier"] = identifier
    info["CFBundleExecutable"] = executable
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
  }
}
