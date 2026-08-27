import Foundation

/// The three geo databases Mihomo keeps in its working directory, keyed by the rule family that
/// needs each one.
///
/// File names are the core's own, read out of the bundled binary (v1.19.30): `GeoSite.dat`,
/// `ASN.mmdb`, and — depending on `geodata-mode` — `geoip.metadb` or `GeoIP.dat`. They are stable
/// on-disk names, not the download URLs, which is why `fileName` takes the settings.
enum GeoDatabaseKind: String, CaseIterable, Equatable, Sendable {
  case geoSite
  case geoIP
  case asn

  func fileName(settings: GeoDatabaseSettings) -> String {
    switch self {
    case .geoSite: return "GeoSite.dat"
    case .geoIP: return settings.effectiveGeoIPFileName
    case .asn: return "ASN.mmdb"
    }
  }

  var title: String {
    switch self {
    case .geoSite: return String(localized: "GeoSite")
    case .geoIP: return String(localized: "GeoIP")
    case .asn: return String(localized: "ASN")
    }
  }
}

/// One database as it exists on disk right now. `modifiedAt == nil` means the file is absent, which
/// is a normal state: the core downloads each database the first time a rule asks for it.
struct GeoDatabaseFileState: Equatable, Sendable {
  var kind: GeoDatabaseKind
  var fileName: String
  var modifiedAt: Date?
  var byteCount: Int64?

  init(kind: GeoDatabaseKind, fileName: String, modifiedAt: Date? = nil, byteCount: Int64? = nil) {
    self.kind = kind
    self.fileName = fileName
    self.modifiedAt = modifiedAt
    self.byteCount = byteCount
  }

  var exists: Bool { modifiedAt != nil }
}

struct GeoDatabaseInventory: Equatable, Sendable {
  var directoryPath: String
  var files: [GeoDatabaseFileState]
  var readAt: Date

  init(directoryPath: String = "", files: [GeoDatabaseFileState] = [], readAt: Date = Date()) {
    self.directoryPath = directoryPath
    self.files = files
    self.readAt = readAt
  }

  func state(for kind: GeoDatabaseKind) -> GeoDatabaseFileState? {
    files.first { $0.kind == kind }
  }
}

/// Which databases the rules in play actually reference.
///
/// This is the guard against reporting a refresh that did nothing. `POST /configs/geo` returns 204
/// whether it downloaded four files or zero: the core only fetches a database whose rule family was
/// seen while parsing the config. A profile with no `GEOSITE`/`GEOIP`/ASN rule therefore gets a
/// completely silent no-op, and a UI that trusted the status code would report "updated" every time.
struct GeoRuleRequirements: Equatable, Sendable {
  /// `false` while no rule snapshot has been read, so "nothing references geo data" is never
  /// inferred from an empty list ClashMax simply has not filled in yet.
  var isKnown: Bool
  var geoSite: Bool
  var geoIP: Bool
  var asn: Bool

  init(isKnown: Bool = false, geoSite: Bool = false, geoIP: Bool = false, asn: Bool = false) {
    self.isKnown = isKnown
    self.geoSite = geoSite
    self.geoIP = geoIP
    self.asn = asn
  }

  static let unknown = GeoRuleRequirements()

  var referencesAny: Bool { geoSite || geoIP || asn }

  var referencedKinds: [GeoDatabaseKind] {
    var kinds: [GeoDatabaseKind] = []
    if geoSite { kinds.append(.geoSite) }
    if geoIP { kinds.append(.geoIP) }
    if asn { kinds.append(.asn) }
    return kinds
  }

  /// Rule types are folded through `RuntimeRuleTypeName.normalized` because the same rule arrives
  /// under two spellings — `GEOSITE` from a config file, `GeoSite` from a running core's `/rules`.
  /// Comparing raw strings would report "no geo rules" for every running core.
  static func requirements(forRuleTypes types: some Sequence<String>) -> GeoRuleRequirements {
    var requirements = GeoRuleRequirements(isKnown: true)
    for type in types {
      switch RuntimeRuleTypeName.normalized(type) {
      case "GEOSITE":
        requirements.geoSite = true
      case "GEOIP", "SRCGEOIP":
        requirements.geoIP = true
      case "IPASN", "SRCIPASN":
        requirements.asn = true
      default:
        continue
      }
    }
    return requirements
  }

  static func requirements(for rules: [RuntimeRule]) -> GeoRuleRequirements {
    requirements(forRuleTypes: rules.map(\.type))
  }
}

/// Pure, view-agnostic answer to "is the geo data the rules match against still current, and would
/// refreshing it do anything?" (roadmap B5).
///
/// Written as a value-in/value-out builder like `SnifferDiagnosticsBuilder` and
/// `FakeIPDiagnosticsBuilder`, so every branch is reachable from a test with no core running and no
/// files on disk.
struct GeoDatabaseDiagnosticsSnapshot: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    case pass
    case info
    case warn
  }

  enum Cause: String, Equatable, Sendable {
    /// No rule matches on geo data, so a refresh would download nothing at all.
    case notReferenced
    /// The last refresh ClashMax ran came back with an error from the core.
    case updateFailed
    /// The working directory has not been inspected yet.
    case inventoryUnknown
    /// A referenced database is not on disk; the core fetches it the first time a rule needs it.
    case missing
    case stale
    case fresh
  }

  struct Fact: Equatable, Sendable {
    enum Key: String, Hashable, Sendable {
      case database
      case autoUpdate
      case geodataMode
      case lastRefresh
      case failure
    }

    var key: Key
    var title: String
    var value: String
  }

  var status: Status
  var cause: Cause
  var headline: String
  var reason: String
  var facts: [Fact]
  var recoveryActions: [String]
  /// Whether `POST /configs/geo` would actually fetch anything. False when no rule references geo
  /// data or the core is down, so the action is offered disabled with `reason` as the explanation
  /// rather than firing and reporting a success the core never performed.
  var canUpdate: Bool

  var statusLabel: String {
    switch status {
    case .pass: return "Pass"
    case .info: return "Info"
    case .warn: return "Warn"
    }
  }

  var plainTextLines: [String] {
    var lines = [
      "Geo Databases: \(statusLabel) (\(cause.rawValue))",
      "Reason: \(reason)",
    ]
    for fact in facts {
      lines.append("\(fact.title): \(fact.value)")
    }
    if !recoveryActions.isEmpty {
      lines.append("Recovery Actions:")
      lines.append(contentsOf: recoveryActions.map { "- \($0)" })
    }
    return lines
  }
}

struct GeoDatabaseDiagnosticsInput: Equatable, Sendable {
  var isCoreRunning: Bool
  var settings: GeoDatabaseSettings
  /// `nil` until the working directory has been read.
  var inventory: GeoDatabaseInventory?
  var requirements: GeoRuleRequirements
  /// When ClashMax last completed `POST /configs/geo` without an error.
  var lastUpdateAt: Date?
  /// The message from the last refresh that failed, cleared by the next success.
  var lastUpdateFailure: String?

  init(
    isCoreRunning: Bool = true,
    settings: GeoDatabaseSettings = .default,
    inventory: GeoDatabaseInventory? = nil,
    requirements: GeoRuleRequirements = .unknown,
    lastUpdateAt: Date? = nil,
    lastUpdateFailure: String? = nil
  ) {
    self.isCoreRunning = isCoreRunning
    self.settings = settings
    self.inventory = inventory
    self.requirements = requirements
    self.lastUpdateAt = lastUpdateAt
    self.lastUpdateFailure = lastUpdateFailure
  }
}

enum GeoDatabaseDiagnosticsBuilder {
  /// How long a database may go untouched before it is called stale.
  ///
  /// With `geo-auto-update` on the core refreshes on its own `geo-update-interval`, so anything
  /// inside two intervals is simply the schedule working; only a longer gap means the schedule is
  /// not running. With auto-update off nothing will ever refresh it, and the threshold answers a
  /// different question — "how old is old enough to matter?". A month is the point where the
  /// upstream `meta-rules-dat` snapshots have visibly diverged, and it is loose enough not to nag;
  /// the per-database ages are always shown, so a user who wants to act sooner can.
  static let manualStaleAfter: TimeInterval = 30 * 24 * 60 * 60
  static let minimumAutomaticStaleAfter: TimeInterval = 24 * 60 * 60

  static func staleThreshold(for settings: GeoDatabaseSettings) -> TimeInterval {
    guard settings.autoUpdateEnabled else { return manualStaleAfter }
    let interval = TimeInterval(settings.normalizedUpdateIntervalHours) * 60 * 60
    return max(interval * 2, minimumAutomaticStaleAfter)
  }

  static func snapshot(for input: GeoDatabaseDiagnosticsInput, now: Date = Date()) -> GeoDatabaseDiagnosticsSnapshot {
    let settings = input.settings
    let referencesGeoData = !input.requirements.isKnown || input.requirements.referencesAny
    let canUpdate = input.isCoreRunning && referencesGeoData

    if input.requirements.isKnown, !input.requirements.referencesAny {
      return GeoDatabaseDiagnosticsSnapshot(
        status: .info,
        cause: .notReferenced,
        headline: String(localized: "No geo data in use"),
        reason: String(localized: "No rule in the running config matches on GEOSITE, GEOIP, or ASN data, so the core downloads none of these databases and refreshing them would do nothing."),
        facts: settingsFacts(settings: settings, lastUpdateAt: input.lastUpdateAt, now: now),
        recoveryActions: [],
        canUpdate: false
      )
    }

    if let failure = input.lastUpdateFailure?.trimmingCharacters(in: .whitespacesAndNewlines),
       !failure.isEmpty
    {
      var facts = databaseFacts(input: input, now: now)
      facts.append(GeoDatabaseDiagnosticsSnapshot.Fact(
        key: .failure,
        title: String(localized: "Last Error"),
        value: failure
      ))
      facts.append(contentsOf: settingsFacts(settings: settings, lastUpdateAt: input.lastUpdateAt, now: now))
      return GeoDatabaseDiagnosticsSnapshot(
        status: .warn,
        cause: .updateFailed,
        headline: String(localized: "Geo database update failed"),
        reason: String(
          format: String(localized: "The core could not refresh the geo databases: %@. The existing files are untouched, so rules keep matching against the previous snapshot."),
          failure
        ),
        facts: facts,
        recoveryActions: [
          String(localized: "Check that the geo database URLs are reachable, then try updating again."),
          String(localized: "The core downloads through its own rules, so a rule that sends the download host to a dead node will fail this update."),
        ],
        canUpdate: canUpdate
      )
    }

    guard let inventory = input.inventory else {
      return GeoDatabaseDiagnosticsSnapshot(
        status: .info,
        cause: .inventoryUnknown,
        headline: String(localized: "Geo database age unknown"),
        reason: String(localized: "ClashMax has not inspected the core's working directory yet, so it cannot tell how old the geo databases are."),
        facts: settingsFacts(settings: settings, lastUpdateAt: input.lastUpdateAt, now: now),
        recoveryActions: [],
        canUpdate: canUpdate
      )
    }

    // Only the databases the rules actually reference matter. When the requirement set is unknown
    // every kind is considered, because "unknown" must not silently narrow the check.
    let relevantKinds = input.requirements.isKnown ? input.requirements.referencedKinds : GeoDatabaseKind.allCases
    let relevant = relevantKinds.compactMap { inventory.state(for: $0) }
    var facts = databaseFacts(input: input, now: now)
    facts.append(contentsOf: settingsFacts(settings: settings, lastUpdateAt: input.lastUpdateAt, now: now))

    // With a known requirement set every referenced database has to be there. With an unknown one
    // only a completely empty working directory is reportable: `ASN.mmdb` is absent on almost every
    // install because almost nobody writes ASN rules, and calling that "missing" would be noise.
    let missing = relevant.filter { !$0.exists }
    if !missing.isEmpty, input.requirements.isKnown || missing.count == relevant.count {
      return GeoDatabaseDiagnosticsSnapshot(
        status: .info,
        cause: .missing,
        headline: String(localized: "Geo databases not downloaded yet"),
        reason: String(
          format: String(localized: "%@ is not in the core's working directory yet. The core fetches each database the first time a rule needs it."),
          missing.map(\.fileName).joined(separator: ", ")
        ),
        facts: facts,
        recoveryActions: canUpdate
          ? [String(localized: "Update the geo databases now, or start the core and let it download them on demand.")]
          : [String(localized: "Start the core; it downloads the databases the first time a geo rule needs them.")],
        canUpdate: canUpdate
      )
    }

    let threshold = staleThreshold(for: settings)
    let oldest = relevant.compactMap(\.modifiedAt).min()
    if let oldest, now.timeIntervalSince(oldest) > threshold {
      return GeoDatabaseDiagnosticsSnapshot(
        status: .warn,
        cause: .stale,
        headline: String(localized: "Geo databases are out of date"),
        reason: settings.autoUpdateEnabled
          ? String(
            format: String(localized: "The oldest geo database was last written %@, which is more than two update intervals ago, so automatic updates do not appear to be running. GEOIP and GEOSITE rules are matching against that snapshot."),
            relativeDescription(for: oldest, now: now)
          )
          : String(
            format: String(localized: "The oldest geo database was last written %@ and automatic updates are off, so GEOIP and GEOSITE rules are matching against that snapshot."),
            relativeDescription(for: oldest, now: now)
          ),
        facts: facts,
        recoveryActions: settings.autoUpdateEnabled
          ? [String(localized: "Update the geo databases now.")]
          : [
            String(localized: "Update the geo databases now."),
            String(localized: "Turn on automatic geo updates so the core refreshes them on its own."),
          ],
        canUpdate: canUpdate
      )
    }

    return GeoDatabaseDiagnosticsSnapshot(
      status: .pass,
      cause: .fresh,
      headline: String(localized: "Geo databases are current"),
      reason: oldest.map {
        String(
          format: String(localized: "The oldest geo database in use was last written %@."),
          relativeDescription(for: $0, now: now)
        )
      } ?? String(localized: "The geo databases in use are current."),
      facts: facts,
      recoveryActions: [],
      canUpdate: canUpdate
    )
  }

  private static func databaseFacts(
    input: GeoDatabaseDiagnosticsInput,
    now: Date
  ) -> [GeoDatabaseDiagnosticsSnapshot.Fact] {
    guard let inventory = input.inventory else { return [] }
    let kinds = input.requirements.isKnown && input.requirements.referencesAny
      ? input.requirements.referencedKinds
      : GeoDatabaseKind.allCases
    return kinds.compactMap { kind -> GeoDatabaseDiagnosticsSnapshot.Fact? in
      guard let state = inventory.state(for: kind) else { return nil }
      let value: String
      if let modifiedAt = state.modifiedAt {
        value = String(
          format: String(localized: "%1$@ — updated %2$@"),
          state.fileName,
          relativeDescription(for: modifiedAt, now: now)
        )
      } else {
        value = String(format: String(localized: "%@ — not downloaded"), state.fileName)
      }
      return GeoDatabaseDiagnosticsSnapshot.Fact(key: .database, title: kind.title, value: value)
    }
  }

  private static func settingsFacts(
    settings: GeoDatabaseSettings,
    lastUpdateAt: Date?,
    now: Date
  ) -> [GeoDatabaseDiagnosticsSnapshot.Fact] {
    var facts = [
      GeoDatabaseDiagnosticsSnapshot.Fact(
        key: .autoUpdate,
        title: String(localized: "Automatic Updates"),
        value: settings.autoUpdateEnabled
          ? String(
            format: String(localized: "On, every %lld h"),
            Int64(settings.normalizedUpdateIntervalHours)
          )
          : String(localized: "Off")
      ),
      GeoDatabaseDiagnosticsSnapshot.Fact(
        key: .geodataMode,
        title: String(localized: "GeoIP Format"),
        value: settings.geodataMode
          ? String(localized: "dat (geodata-mode on)")
          : String(localized: "mmdb (geodata-mode off)")
      ),
    ]
    if let lastUpdateAt {
      facts.append(GeoDatabaseDiagnosticsSnapshot.Fact(
        key: .lastRefresh,
        title: String(localized: "Last Refresh"),
        value: relativeDescription(for: lastUpdateAt, now: now)
      ))
    }
    return facts
  }

  private static func relativeDescription(for date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
  }
}
