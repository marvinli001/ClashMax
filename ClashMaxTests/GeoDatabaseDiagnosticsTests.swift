@testable import ClashMax
import XCTest
import Yams

/// One test per `GeoDatabaseDiagnosticsSnapshot.Cause`, plus the pieces the verdict is built from:
/// which rule families reference geo data, what is on disk, and what the generated runtime config
/// tells the core to do about it (roadmap B5).
///
/// The whole point of this feature is that a stale `GeoSite.dat` produces *no* user-visible signal,
/// so every branch here has to be reachable without a running core and without touching the real
/// working directory.
final class GeoDatabaseDiagnosticsTests: XCTestCase {
  // MARK: Helpers

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func inventory(
    geoSite: Date? = nil,
    geoIP: Date? = nil,
    asn: Date? = nil,
    settings: GeoDatabaseSettings = .default
  ) -> GeoDatabaseInventory {
    GeoDatabaseInventory(
      directoryPath: "/tmp/runtime",
      files: [
        GeoDatabaseFileState(
          kind: .geoSite,
          fileName: GeoDatabaseKind.geoSite.fileName(settings: settings),
          modifiedAt: geoSite,
          byteCount: geoSite == nil ? nil : 1_024
        ),
        GeoDatabaseFileState(
          kind: .geoIP,
          fileName: GeoDatabaseKind.geoIP.fileName(settings: settings),
          modifiedAt: geoIP,
          byteCount: geoIP == nil ? nil : 2_048
        ),
        GeoDatabaseFileState(
          kind: .asn,
          fileName: GeoDatabaseKind.asn.fileName(settings: settings),
          modifiedAt: asn,
          byteCount: asn == nil ? nil : 4_096
        ),
      ],
      readAt: now
    )
  }

  private func daysAgo(_ days: Double) -> Date {
    now.addingTimeInterval(-days * 24 * 60 * 60)
  }

  private let siteAndIPRules = GeoRuleRequirements(isKnown: true, geoSite: true, geoIP: true)

  // MARK: Requirements

  func testRequirementsReadHyphenatedConfigFileSpellings() {
    let requirements = GeoRuleRequirements.requirements(forRuleTypes: [
      "GEOSITE", "GEOIP", "SRC-GEOIP", "IP-ASN", "SRC-IP-ASN", "DOMAIN-SUFFIX",
    ])

    XCTAssertTrue(requirements.isKnown)
    XCTAssertTrue(requirements.geoSite)
    XCTAssertTrue(requirements.geoIP)
    XCTAssertTrue(requirements.asn)
  }

  /// A running core reports `/rules` types camelCased, which is the spelling that actually reaches
  /// this code in production. Comparing raw strings here would report "no geo rules" for every
  /// running core and disable the update button exactly when it is needed.
  func testRequirementsReadCamelCasedRunningCoreSpellings() {
    let rules = [
      RuntimeRule(index: 0, type: "GeoSite", payload: "youtube", policy: "Proxy"),
      RuntimeRule(index: 1, type: "GeoIP", payload: "CN", policy: "DIRECT"),
      RuntimeRule(index: 2, type: "Match", payload: "", policy: "Proxy"),
    ]

    let requirements = GeoRuleRequirements.requirements(for: rules)

    XCTAssertTrue(requirements.geoSite)
    XCTAssertTrue(requirements.geoIP)
    XCTAssertFalse(requirements.asn)
    XCTAssertEqual(requirements.referencedKinds, [.geoSite, .geoIP])
  }

  func testRequirementsWithoutGeoRulesAreKnownAndEmpty() {
    let requirements = GeoRuleRequirements.requirements(forRuleTypes: ["DOMAIN-SUFFIX", "MATCH"])

    XCTAssertTrue(requirements.isKnown)
    XCTAssertFalse(requirements.referencesAny)
    XCTAssertTrue(requirements.referencedKinds.isEmpty)
  }

  /// The false-success guard: an empty rule list ClashMax has not filled in yet must never read as
  /// "no rule needs geo data".
  func testUnknownRequirementsAreNotAnEmptyRuleList() {
    XCTAssertFalse(GeoRuleRequirements.unknown.isKnown)
    XCTAssertFalse(GeoRuleRequirements.unknown.referencesAny)
    XCTAssertNotEqual(GeoRuleRequirements.unknown, GeoRuleRequirements.requirements(forRuleTypes: []))
  }

  // MARK: Causes

  func testProfileWithNoGeoRulesReportsNothingToUpdate() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(400)),
        requirements: GeoRuleRequirements.requirements(forRuleTypes: ["DOMAIN-SUFFIX", "MATCH"])
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .notReferenced)
    XCTAssertEqual(snapshot.status, .info)
    // A four-hundred-day-old file that nothing matches against is not a problem, and offering a
    // refresh that downloads nothing would report a success the core never performed.
    XCTAssertFalse(snapshot.canUpdate)
  }

  func testFailedUpdateKeepsTheCoreMessageAndStillOffersARetry() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(1), geoIP: daysAgo(1)),
        requirements: siteAndIPRules,
        lastUpdateFailure: "can't download GeoSite database file: 500 Internal Server Error"
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .updateFailed)
    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertTrue(snapshot.canUpdate)
    XCTAssertTrue(snapshot.reason.contains("500 Internal Server Error"))
    XCTAssertEqual(
      snapshot.facts.first { $0.key == .failure }?.value,
      "can't download GeoSite database file: 500 Internal Server Error"
    )
  }

  func testBlankFailureMessageIsNotTreatedAsAFailure() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(1), geoIP: daysAgo(1)),
        requirements: siteAndIPRules,
        lastUpdateFailure: "   \n "
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
  }

  func testUnreadWorkingDirectoryReportsUnknownRatherThanCurrent() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(inventory: nil, requirements: siteAndIPRules),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .inventoryUnknown)
    XCTAssertEqual(snapshot.status, .info)
    XCTAssertTrue(snapshot.canUpdate)
    XCTAssertFalse(snapshot.facts.contains { $0.key == .database })
  }

  func testReferencedDatabaseMissingFromDiskIsReportedByFileName() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(1), geoIP: nil),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .missing)
    XCTAssertEqual(snapshot.status, .info)
    XCTAssertTrue(snapshot.reason.contains("geoip.metadb"))
    XCTAssertFalse(snapshot.reason.contains("ASN.mmdb"), "ASN is not referenced by these rules")
  }

  /// `ASN.mmdb` is absent on nearly every install because almost nobody writes ASN rules. With an
  /// unknown requirement set that absence must not be reported as a missing database, or the panel
  /// would open on a warning for a perfectly healthy core.
  func testUnknownRequirementsDoNotReportPartiallyPopulatedDirectoryAsMissing() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(1), geoIP: daysAgo(1), asn: nil),
        requirements: .unknown
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
  }

  func testUnknownRequirementsReportACompletelyEmptyDirectoryAsMissing() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(inventory: inventory(), requirements: .unknown),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .missing)
  }

  func testMissingWithTheCoreDownTellsTheUserToStartItRatherThanOfferingAnUpdate() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        isCoreRunning: false,
        inventory: inventory(),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .missing)
    XCTAssertFalse(snapshot.canUpdate)
    XCTAssertEqual(snapshot.recoveryActions.count, 1)
  }

  /// The live bug this feature exists for: a working directory whose `GeoSite.dat` was last written
  /// two months ago while `GEOIP,CN` rules keep matching against it.
  func testManualModeCallsATwoMonthOldDatabaseStale() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(68), geoIP: daysAgo(115)),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .stale)
    XCTAssertEqual(snapshot.status, .warn)
    XCTAssertTrue(snapshot.canUpdate)
    // Auto-update off gets the extra "turn it on" action; auto-update on does not.
    XCTAssertEqual(snapshot.recoveryActions.count, 2)
  }

  func testManualModeToleratesADatabaseInsideTheMonthWindow() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(20), geoIP: daysAgo(25)),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertEqual(snapshot.status, .pass)
  }

  /// With `geo-auto-update` on, an age beyond two intervals is evidence the schedule is not running
  /// — which is a different and more actionable statement than "this file is old".
  func testAutomaticModeFlagsAGapLongerThanTwoIntervals() {
    var settings = GeoDatabaseSettings.default
    settings.autoUpdateEnabled = true
    settings.updateIntervalHours = 24

    let stale = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        settings: settings,
        inventory: inventory(geoSite: daysAgo(3), settings: settings),
        requirements: GeoRuleRequirements(isKnown: true, geoSite: true)
      ),
      now: now
    )
    let fresh = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        settings: settings,
        inventory: inventory(geoSite: daysAgo(1.5), settings: settings),
        requirements: GeoRuleRequirements(isKnown: true, geoSite: true)
      ),
      now: now
    )

    XCTAssertEqual(stale.cause, .stale)
    XCTAssertEqual(stale.recoveryActions.count, 1, "Auto-update is already on; do not suggest turning it on")
    XCTAssertEqual(fresh.cause, .fresh)
  }

  func testStaleThresholdNeverDropsBelowADayForVeryShortIntervals() {
    var settings = GeoDatabaseSettings.default
    settings.autoUpdateEnabled = true
    settings.updateIntervalHours = 1

    XCTAssertEqual(
      GeoDatabaseDiagnosticsBuilder.staleThreshold(for: settings),
      GeoDatabaseDiagnosticsBuilder.minimumAutomaticStaleAfter
    )
    XCTAssertEqual(
      GeoDatabaseDiagnosticsBuilder.staleThreshold(for: .default),
      GeoDatabaseDiagnosticsBuilder.manualStaleAfter
    )
  }

  /// A stale ASN database nobody matches against must not drag the verdict down.
  func testAgeIsMeasuredOnlyOverTheDatabasesTheRulesReference() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(2), geoIP: daysAgo(3), asn: daysAgo(400)),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertEqual(snapshot.facts.filter { $0.key == .database }.count, 2)
  }

  func testCoreDownWithFreshFilesStillReportsTheAgeButOffersNoUpdate() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        isCoreRunning: false,
        inventory: inventory(geoSite: daysAgo(1), geoIP: daysAgo(1)),
        requirements: siteAndIPRules
      ),
      now: now
    )

    XCTAssertEqual(snapshot.cause, .fresh)
    XCTAssertFalse(snapshot.canUpdate)
  }

  // MARK: Report

  func testPlainTextLinesCarryTheCauseFactsAndActions() {
    let snapshot = GeoDatabaseDiagnosticsBuilder.snapshot(
      for: GeoDatabaseDiagnosticsInput(
        inventory: inventory(geoSite: daysAgo(90), geoIP: daysAgo(90)),
        requirements: siteAndIPRules,
        lastUpdateAt: daysAgo(90)
      ),
      now: now
    )

    let lines = snapshot.plainTextLines

    XCTAssertEqual(lines.first, "Geo Databases: Warn (stale)")
    XCTAssertTrue(lines.contains { $0.hasPrefix("Reason: ") })
    XCTAssertTrue(lines.contains("Recovery Actions:"))
    XCTAssertTrue(lines.contains { $0.contains("GeoSite.dat") })
  }

  // MARK: Settings

  func testGeodataModeSelectsBothTheLiveURLAndTheOnDiskFileName() {
    var settings = GeoDatabaseSettings.default

    XCTAssertEqual(settings.effectiveGeoIPURL, GeoDatabaseSettings.defaultMMDBURL)
    XCTAssertEqual(settings.effectiveGeoIPFileName, "geoip.metadb")

    settings.geodataMode = true

    XCTAssertEqual(settings.effectiveGeoIPURL, GeoDatabaseSettings.defaultGeoIPURL)
    XCTAssertEqual(settings.effectiveGeoIPFileName, "GeoIP.dat")
    XCTAssertEqual(GeoDatabaseKind.geoIP.fileName(settings: settings), "GeoIP.dat")
  }

  func testDefaultSettingsValidateAndUseTheCoresOwnSources() {
    XCTAssertNil(GeoDatabaseSettings.default.validationError)
    XCTAssertTrue(GeoDatabaseSettings.default.usesDefaultURLs)
    XCTAssertTrue(GeoDatabaseSettings.default.isDefault)
  }

  func testValidationRejectsOutOfRangeIntervalsAndNonHTTPSources() {
    var interval = GeoDatabaseSettings.default
    interval.updateIntervalHours = 0
    var scheme = GeoDatabaseSettings.default
    scheme.geoSiteURL = "file:///etc/passwd"
    var empty = GeoDatabaseSettings.default
    empty.asnURL = ""

    XCTAssertNotNil(interval.validationError)
    XCTAssertNotNil(scheme.validationError)
    XCTAssertNotNil(empty.validationError)
  }

  func testCustomSourcesAreVisibleInTheSettingsSummary() {
    var settings = GeoDatabaseSettings.default
    settings.geoSiteURL = "https://mirror.example/geosite.dat"

    XCTAssertFalse(settings.usesDefaultURLs)
    XCTAssertNil(settings.validationError)
    XCTAssertEqual(settings.summary.components(separatedBy: " · ").count, 3)
    XCTAssertEqual(GeoDatabaseSettings.default.summary.components(separatedBy: " · ").count, 2)
  }

  /// A stored blob written before a field existed must not drop the whole settings object.
  func testDecodingToleratesMissingAndMistypedFields() throws {
    let json = Data(#"{"autoUpdateEnabled":true,"updateIntervalHours":"nonsense"}"#.utf8)

    let decoded = try JSONDecoder().decode(GeoDatabaseSettings.self, from: json)

    XCTAssertTrue(decoded.autoUpdateEnabled)
    XCTAssertEqual(decoded.updateIntervalHours, GeoDatabaseSettings.defaultUpdateIntervalHours)
    XCTAssertEqual(decoded.geoSiteURL, GeoDatabaseSettings.defaultGeoSiteURL)
  }

  func testIntervalIsClampedRatherThanTrustedWhenRendered() {
    var settings = GeoDatabaseSettings.default
    settings.updateIntervalHours = 100_000

    XCTAssertEqual(settings.normalizedUpdateIntervalHours, GeoDatabaseSettings.maximumUpdateIntervalHours)
  }

  // MARK: Inventory reader

  func testInventoryReaderReportsAgeForPresentFilesAndAbsenceForTheRest() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("geo-inventory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let geoSite = directory.appendingPathComponent("GeoSite.dat")
    try Data(repeating: 0, count: 32).write(to: geoSite)

    let inventory = await GeoDatabaseInventoryReader.inventory(at: directory, settings: .default)

    XCTAssertEqual(inventory.directoryPath, directory.path)
    XCTAssertEqual(inventory.files.count, GeoDatabaseKind.allCases.count)
    let site = try XCTUnwrap(inventory.state(for: .geoSite))
    XCTAssertTrue(site.exists)
    XCTAssertEqual(site.byteCount, 32)
    XCTAssertFalse(try XCTUnwrap(inventory.state(for: .geoIP)).exists)
    XCTAssertFalse(try XCTUnwrap(inventory.state(for: .asn)).exists)
  }

  func testInventoryReaderFollowsGeodataModeToTheOtherGeoIPFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("geo-inventory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(repeating: 0, count: 8).write(to: directory.appendingPathComponent("geoip.metadb"))
    var settings = GeoDatabaseSettings.default
    settings.geodataMode = true

    let mmdbMode = await GeoDatabaseInventoryReader.inventory(at: directory, settings: .default)
    let datMode = await GeoDatabaseInventoryReader.inventory(at: directory, settings: settings)

    XCTAssertTrue(try XCTUnwrap(mmdbMode.state(for: .geoIP)).exists)
    XCTAssertEqual(try XCTUnwrap(datMode.state(for: .geoIP)).fileName, "GeoIP.dat")
    XCTAssertFalse(try XCTUnwrap(datMode.state(for: .geoIP)).exists)
  }

  func testInventoryReaderReportsAnAbsentDirectoryAsAllMissingRatherThanFailing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("geo-inventory-missing-\(UUID().uuidString)", isDirectory: true)

    let inventory = await GeoDatabaseInventoryReader.inventory(at: directory, settings: .default)

    XCTAssertEqual(inventory.files.count, GeoDatabaseKind.allCases.count)
    XCTAssertTrue(inventory.files.allSatisfy { !$0.exists })
  }

  // MARK: Generated runtime config

  /// The keys are the whole feature: before B5 none of these were ever written, so the core ran on
  /// its built-in defaults with `geo-auto-update` off and never refreshed anything.
  func testRuntimeConfigCarriesTheGeoKeysTheCoreReads() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "controller-secret")
    overrides.geoDatabase.autoUpdateEnabled = true
    overrides.geoDatabase.updateIntervalHours = 12

    let output = try ConfigNormalizer().runtimeConfig(
      from: "mixed-port: 7890\n",
      overrides: overrides,
      options: .default
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])

    XCTAssertEqual(yaml["geo-auto-update"] as? Bool, true)
    XCTAssertEqual(yaml["geo-update-interval"] as? Int, 12)
    XCTAssertEqual(yaml["geodata-mode"] as? Bool, false)
  }

  /// `GET /configs` echoes these back as `geo-ip`/`geo-site`, but a config *file* must spell them
  /// `geoip`/`geosite` — the hyphenated forms are silently ignored, which would leave a user's
  /// custom mirror unused with no error anywhere.
  func testGeoxURLUsesTheConfigFileKeyNamesNotTheOnesTheAPIReportsBack() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "controller-secret")
    overrides.geoDatabase.geoSiteURL = "https://mirror.example/geosite.dat"

    let output = try ConfigNormalizer().runtimeConfig(
      from: "mixed-port: 7890\n",
      overrides: overrides,
      options: .default
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let geox = try XCTUnwrap(yaml["geox-url"] as? [String: String])

    XCTAssertEqual(Set(geox.keys), ["geoip", "geosite", "mmdb", "asn"])
    XCTAssertEqual(geox["geosite"], "https://mirror.example/geosite.dat")
    XCTAssertEqual(geox["mmdb"], GeoDatabaseSettings.defaultMMDBURL)
  }

  func testProfileSourceGeoKeysAreReplacedRatherThanLeftInPlace() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "controller-secret")
    overrides.geoDatabase.autoUpdateEnabled = true

    let output = try ConfigNormalizer().runtimeConfig(
      from: """
      mixed-port: 7890
      geo-auto-update: false
      geodata-mode: true
      geox-url:
        geosite: https://profile.example/geosite.dat
      """,
      overrides: overrides,
      options: .default
    )
    let yaml = try XCTUnwrap(Yams.load(yaml: output) as? [String: Any])
    let geox = try XCTUnwrap(yaml["geox-url"] as? [String: String])

    XCTAssertEqual(yaml["geo-auto-update"] as? Bool, true)
    XCTAssertEqual(yaml["geodata-mode"] as? Bool, false)
    XCTAssertEqual(geox["geosite"], GeoDatabaseSettings.defaultGeoSiteURL)
  }

  func testInvalidGeoSettingsFailNormalizationInsteadOfWritingAConfigTheCoreRejects() throws {
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "controller-secret")
    overrides.geoDatabase.geoSiteURL = "not a url at all"

    XCTAssertThrowsError(
      try ConfigNormalizer().runtimeConfig(
        from: "mixed-port: 7890\n",
        overrides: overrides,
        options: .default
      )
    )
  }
}
