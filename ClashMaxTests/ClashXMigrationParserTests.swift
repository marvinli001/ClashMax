@testable import ClashMax
import SQLite3
import XCTest

final class ClashXMigrationParserTests: XCTestCase {
  func testParserExtractsProviderURLsDuplicatesPortsBypassSystemProxyAndUnsupportedKeys() throws {
    let root = try makeTemporaryDirectory()
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try """
    mixed-port: 7890
    socks-port: "7891"
    allow-lan: true
    mode: global
    log-level: debug
    system-proxy: true
    cfw-bypass:
      - localhost
      - "*.local"
    shortcut:
      toggleProxy: cmd+shift+p
      restartCore: cmd+shift+r
      unknownAction: cmd+shift+u
    hotkeys:
      systemProxy: ctrl+option+s
    tray: true
    unknown-clashx-key: value
    proxy-providers:
      Main:
        type: http
        url: https://example.com/sub.yaml
        path: providers/main.yaml
      Backup:
        type: http
        url: https://example.com/sub.yaml
        path: providers/backup.yaml
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    try """
    proxy-providers:
      Main:
        type: http
        url: https://mirror.example.com/sub.yaml
    subscriptions:
      - name: Airport
        url: https://airport.example.com/api
    """.write(to: providers.appendingPathComponent("main.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(
      report.subscriptionURLs,
      [
        "https://example.com/sub.yaml",
        "https://mirror.example.com/sub.yaml",
        "https://airport.example.com/api",
      ]
    )
    XCTAssertEqual(report.duplicateSubscriptionURLs, ["https://example.com/sub.yaml"])
    XCTAssertEqual(report.ports["mixed-port"], 7890)
    XCTAssertEqual(report.ports["socks-port"], 7891)
    XCTAssertEqual(report.bypassDomains, ["localhost", "*.local"])
    XCTAssertEqual(report.allowLan, true)
    XCTAssertEqual(report.mode, "global")
    XCTAssertEqual(report.logLevel, "debug")
    XCTAssertEqual(report.systemProxyEnabled, true)
    XCTAssertFalse(report.unsupportedSettings.contains { $0.contains("shortcut") })
    XCTAssertEqual(
      report.shortcutBindings.map { "\($0.sourceKey):\($0.action.rawValue):\($0.shortcut.identity)" },
      [
        // identity is "<carbon modifier mask>-<carbon key code>": ⇧⌘R, ⇧⌘P, ⌃⌥S.
        "restartCore:restart:768-15",
        "toggleProxy:startStop:768-35",
        "systemProxy:toggleSystemProxy:6144-1",
      ]
    )
    XCTAssertTrue(report.warnings.contains { $0.contains("unknownAction") })
    XCTAssertTrue(report.menuBarMigrationSuggested)
    XCTAssertTrue(report.unknownKeys.contains { $0.contains("unknown-clashx-key") })
    XCTAssertTrue(report.conflicts.contains { $0.contains("Provider Main uses multiple URLs") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("config.yaml") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("providers/main.yaml") })
  }

  func testParserImportsGeoDatabaseSettingsFromClashXConfig() throws {
    let root = try makeTemporaryDirectory()
    try """
    geo-auto-update: true
    geo-update-interval: 12
    geodata-mode: true
    geox-url:
      geoip: https://mirror.example.com/geoip.dat
      geosite: https://mirror.example.com/geosite.dat
      mmdb: https://mirror.example.com/geoip.metadb
      asn: https://mirror.example.com/GeoLite2-ASN.mmdb
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    let geo = try XCTUnwrap(report.geoDatabase)
    XCTAssertEqual(geo.autoUpdateEnabled, true)
    XCTAssertEqual(geo.updateIntervalHours, 12)
    XCTAssertEqual(geo.geodataMode, true)
    XCTAssertEqual(geo.geoIPURL, "https://mirror.example.com/geoip.dat")
    XCTAssertEqual(geo.geoSiteURL, "https://mirror.example.com/geosite.dat")
    XCTAssertEqual(geo.mmdbURL, "https://mirror.example.com/geoip.metadb")
    XCTAssertEqual(geo.asnURL, "https://mirror.example.com/GeoLite2-ASN.mmdb")
    XCTAssertFalse(geo.usesDefaultURLs)
    // The whole point of validating per field is that what the report carries can actually be
    // applied; `AppModel.updateGeoDatabaseSettings` refuses an invalid struct whole.
    XCTAssertNil(geo.validationError)
    // `geo-update-interval` used to fall outside the allow-list and be reported as an unknown key.
    XCTAssertFalse(report.unknownKeys.contains { $0.contains("geo") })
  }

  func testParserKeepsGeoDefaultsForKeysTheConfigDoesNotSet() throws {
    let root = try makeTemporaryDirectory()
    try """
    geo-auto-update: true
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    let geo = try XCTUnwrap(report.geoDatabase)
    XCTAssertEqual(geo.autoUpdateEnabled, true)
    XCTAssertEqual(geo.updateIntervalHours, GeoDatabaseSettings.defaultUpdateIntervalHours)
    XCTAssertEqual(geo.geodataMode, GeoDatabaseSettings.default.geodataMode)
    XCTAssertTrue(geo.usesDefaultURLs)
  }

  func testParserReportsGeoDatabaseSettingsAsAbsentWhenTheConfigNamesNoGeoKeys() throws {
    let root = try makeTemporaryDirectory()
    try """
    mixed-port: 7890
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertNil(report.geoDatabase)
  }

  func testParserDropsOnlyTheInvalidGeoFieldsAndSaysWhy() throws {
    let root = try makeTemporaryDirectory()
    try """
    geo-update-interval: 0
    geox-url:
      geoip: not-a-url
      geosite: https://mirror.example.com/geosite.dat
      geo-site: https://wrong.example.com/geosite.dat
      nonsense: https://mirror.example.com/other.dat
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    let geo = try XCTUnwrap(report.geoDatabase)
    XCTAssertEqual(geo.geoSiteURL, "https://mirror.example.com/geosite.dat")
    XCTAssertEqual(geo.updateIntervalHours, GeoDatabaseSettings.defaultUpdateIntervalHours)
    XCTAssertEqual(geo.geoIPURL, GeoDatabaseSettings.defaultGeoIPURL)
    XCTAssertNil(geo.validationError)
    XCTAssertTrue(report.warnings.contains { $0.contains("geo-update-interval") && $0.contains("0 hours") })
    XCTAssertTrue(report.warnings.contains { $0.contains("geox-url.geoip") && $0.contains("http") })
    // The `/configs` spelling is silently ignored by the core, so the migration names it.
    XCTAssertTrue(report.warnings.contains { $0.contains("geox-url.geo-site") && $0.contains("\"geosite\"") })
    XCTAssertTrue(report.warnings.contains { $0.contains("geox-url.nonsense") })
  }

  /// `candidateYAMLFiles` sweeps `profiles/` and `providers/` too, and `FileManager.enumerator`
  /// promises no order, so a last-write-wins accumulator let an arbitrary inactive fragment decide
  /// which mirror ClashMax downloads from — and Apply then wrote it straight into the runtime.
  /// Only the file ClashX actually runs contributes; a fragment that names the keys is reported.
  func testParserImportsGeoSettingsFromTheMainConfigOnly() throws {
    let root = try makeTemporaryDirectory()
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try """
    geo-update-interval: 12
    geodata-mode: true
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    try """
    geo-update-interval: 6
    geodata-mode: false
    geox-url:
      geoip: https://fragment.example/geoip.dat
    """.write(to: providers.appendingPathComponent("main.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    let geo = try XCTUnwrap(report.geoDatabase)
    XCTAssertEqual(geo.updateIntervalHours, 12)
    XCTAssertTrue(geo.geodataMode)
    XCTAssertEqual(geo.geoIPURL, GeoDatabaseSettings.defaultGeoIPURL)
    XCTAssertTrue(report.warnings.contains {
      $0.contains("main.yaml") && $0.contains("geo-update-interval")
        && $0.contains("geodata-mode") && $0.contains("geox-url")
        && $0.contains("main ClashX config only")
    })
    // The declined fragment is a warning, not a conflict: there is nothing left to reconcile.
    XCTAssertFalse(report.conflicts.contains { $0.contains("geo-update-interval") })
  }

  /// A fragment that says nothing about geo must stay silent, or every provider file in a normal
  /// ClashX directory would produce a warning nobody can act on.
  func testParserDoesNotWarnAboutFragmentsWithoutGeoKeys() throws {
    let root = try makeTemporaryDirectory()
    let providers = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
    try """
    geo-auto-update: true
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    try """
    proxies:
      - name: Node
        type: direct
    """.write(to: providers.appendingPathComponent("main.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(try XCTUnwrap(report.geoDatabase).autoUpdateEnabled, true)
    XCTAssertFalse(report.warnings.contains { $0.contains("main ClashX config only") })
  }

  func testParserDeduplicatesShortcutAliasesByCanonicalStorage() throws {
    let root = try makeTemporaryDirectory()
    try """
    shortcut:
      toggleProxy: cmd+shift+enter
    hotkeys:
      toggleProxyAgain: cmd+shift+return
    """.write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

    let report = ClashXMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(report.shortcutBindings.count, 1)
    XCTAssertEqual(report.shortcutBindings.first?.action, .startStop)
    XCTAssertEqual(report.shortcutBindings.first?.shortcut.identity, "768-36")
  }

  func testParserReadsFlClashSQLiteProfilesRulesLinksAndUnsupportedMappings() throws {
    let root = try makeTemporaryDirectory()
    let profiles = root.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: profiles.appendingPathComponent("202.yaml"), atomically: true, encoding: .utf8)

    try writeSQLiteDatabase(at: root.appendingPathComponent("database.sqlite")) { exec in
      try exec("""
      CREATE TABLE profiles (
        id TEXT PRIMARY KEY,
        label TEXT,
        url TEXT,
        auto_update_duration_millis INTEGER,
        auto_update INTEGER,
        overwrite_type TEXT,
        script_id TEXT,
        selected_map TEXT,
        unfold_set TEXT
      );
      """)
      try exec("""
      INSERT INTO profiles VALUES
        ('101', 'Airport', 'https://sub.example/sub', 3600000, 0, 'script', '7', '{"Proxy":"Node"}', '[]'),
        ('202', 'Local', '', NULL, 1, NULL, NULL, NULL, NULL);
      """)
      try exec("CREATE TABLE rules (id TEXT PRIMARY KEY, value TEXT);")
      try exec("""
      INSERT INTO rules VALUES
        ('1', 'DOMAIN-SUFFIX,global.example,DIRECT'),
        ('2', 'DOMAIN-SUFFIX,profile.example,Proxy'),
        ('3', 'DOMAIN-SUFFIX,ads.example,REJECT'),
        ('4', 'AND,unsupported');
      """)
      try exec("CREATE TABLE profile_rule_mapping (id TEXT PRIMARY KEY, profile_id TEXT, rule_id TEXT, scene TEXT);")
      try exec("""
      INSERT INTO profile_rule_mapping VALUES
        ('g1', NULL, '1', 'added'),
        ('p1', '202', '2', 'added'),
        ('p2', '202', '3', 'disabled'),
        ('p3', '202', '4', 'added');
      """)
      try exec("CREATE TABLE scripts (id TEXT PRIMARY KEY, label TEXT);")
      try exec("INSERT INTO scripts VALUES ('7', 'Rewrite Script');")
    }

    let report = ClientMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(report.client, .flClash)
    XCTAssertEqual(report.subscriptions.map(\.urlString), ["https://sub.example/sub"])
    XCTAssertEqual(report.subscriptions.first?.id, "flclash-profile-101")
    XCTAssertEqual(report.subscriptions.first?.providerOptions.intervalSeconds, 3600)
    XCTAssertEqual(report.subscriptions.first?.updatePolicy.intervalOverrideMinutes, 60)
    XCTAssertEqual(report.subscriptions.first?.updatePolicy.automaticUpdatesEnabled, false)
    XCTAssertEqual(report.localProfiles.first?.id, "flclash-profile-202")
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("database.sqlite") })
    XCTAssertTrue(report.inspectedFiles.contains { $0.hasSuffix("profiles/202.yaml") })

    let globalSnippet = try XCTUnwrap(report.ruleSnippets.first { $0.profileSourceID == nil })
    XCTAssertEqual(globalSnippet.settings.prependRules.map(\.runtimeRule), ["DOMAIN-SUFFIX,global.example,DIRECT"])

    let boundSnippet = try XCTUnwrap(report.ruleSnippets.first { $0.profileSourceID == "flclash-profile-202" })
    XCTAssertEqual(boundSnippet.settings.prependRules.map(\.runtimeRule), ["DOMAIN-SUFFIX,profile.example,Proxy"])
    XCTAssertEqual(boundSnippet.settings.disabledRuleMatchers.map(\.pattern), ["DOMAIN-SUFFIX,ads.example,REJECT"])
    XCTAssertTrue(report.unsupportedMappings.contains { $0.field.contains("scriptId") || $0.field.contains("script") })
    XCTAssertTrue(report.unsupportedMappings.contains { $0.field == "AND,unsupported" })
  }

  func testParserReadsClashVergeRemoteLocalRulesAndUnsupportedMappings() throws {
    let root = try makeTemporaryDirectory()
    let profiles = root.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    items:
      - uid: remote-1
        type: remote
        name: Airport
        url: https://sub.example/verge
        option:
          update_interval: 7200
          allow_auto_update: false
          user_agent: Clash Verge/2.0.0
          self_proxy: true
          rules: rule-chain
          merge: merge-chain
          danger_accept_invalid_certs: true
          selected: Proxy
      - uid: local-1
        type: local
        name: Local
        file: local.yaml
        option:
          rules: rule-chain
      - uid: rule-chain
        type: rules
        file: rules.yaml
      - uid: merge-chain
        type: merge
        file: merge.yaml
    """.write(to: root.appendingPathComponent("profiles.yaml"), atomically: true, encoding: .utf8)
    try "proxies: []\n".write(to: profiles.appendingPathComponent("local.yaml"), atomically: true, encoding: .utf8)
    try """
    prepend:
      - DOMAIN-SUFFIX,front.example,DIRECT
    append:
      - MATCH,Proxy
    delete:
      - DOMAIN-SUFFIX,ads.example,REJECT
    """.write(to: profiles.appendingPathComponent("rules.yaml"), atomically: true, encoding: .utf8)

    let report = ClientMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(report.client, .clashVerge)
    let subscription = try XCTUnwrap(report.subscriptions.first)
    XCTAssertEqual(subscription.id, "clashverge-profile-remote-1")
    XCTAssertEqual(subscription.urlString, "https://sub.example/verge")
    XCTAssertEqual(subscription.providerOptions.intervalSeconds, 7200)
    XCTAssertEqual(subscription.updatePolicy.intervalOverrideMinutes, 120)
    XCTAssertEqual(subscription.updatePolicy.automaticUpdatesEnabled, false)
    XCTAssertEqual(subscription.providerOptions.fetchProxy, .localClashProxy)
    XCTAssertEqual(subscription.providerOptions.requestHeaders.first?.name, "User-Agent")
    XCTAssertEqual(subscription.providerOptions.requestHeaders.first?.value, "Clash Verge/2.0.0")
    XCTAssertEqual(report.localProfiles.first?.id, "clashverge-profile-local-1")

    let remoteRules = try XCTUnwrap(report.ruleSnippets.first { $0.profileSourceID == "clashverge-profile-remote-1" })
    XCTAssertEqual(remoteRules.settings.prependRules.map(\.runtimeRule), ["DOMAIN-SUFFIX,front.example,DIRECT"])
    XCTAssertEqual(remoteRules.settings.appendRules.map(\.runtimeRule), ["MATCH,Proxy"])
    XCTAssertEqual(remoteRules.settings.disabledRuleMatchers.map(\.pattern), ["DOMAIN-SUFFIX,ads.example,REJECT"])
    XCTAssertTrue(report.unsupportedMappings.contains { $0.field == "merge" })
    XCTAssertTrue(report.unsupportedMappings.contains { $0.field == "danger_accept_invalid_certs" })
    XCTAssertTrue(report.unsupportedMappings.contains { $0.source == "items[merge-chain]" })
  }

  func testParserReportsDuplicateClashVergeItemIDsWithoutCrashing() throws {
    let root = try makeTemporaryDirectory()
    try """
    items:
      - uid: duplicate
        type: remote
        name: Airport
        url: https://sub.example/verge
      - uid: duplicate
        type: local
        name: Local
        file: local.yaml
    """.write(to: root.appendingPathComponent("profiles.yaml"), atomically: true, encoding: .utf8)

    let report = ClientMigrationParser().parse(directoryURL: root)

    XCTAssertEqual(report.subscriptions.map(\.id), ["clashverge-profile-duplicate"])
    XCTAssertTrue(report.localProfiles.isEmpty)
    XCTAssertTrue(report.warnings.contains { $0.contains("Duplicate Clash Verge item id duplicate") })
    XCTAssertTrue(report.unsupportedMappings.contains { $0.source == "items[1]" && $0.field == "uid/id/name" })
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxClashXMigrationParserTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeSQLiteDatabase(
    at url: URL,
    body: (_ exec: (String) throws -> Void) throws -> Void
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    guard let database else {
      throw NSError(domain: "ClashMaxTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    try body { sql in
      var errorMessage: UnsafeMutablePointer<CChar>?
      if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown SQLite error"
        sqlite3_free(errorMessage)
        throw NSError(domain: "ClashMaxTests.SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
      }
    }
  }
}
