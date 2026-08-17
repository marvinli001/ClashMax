import Foundation

struct ClashMaxBackupFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var appMetadata: BackupAppMetadata
  var profilesManifest: ProfileManifest
  var outboundProxyManifest: OutboundProxyEndpointManifest
  var profileSources: [BackupProfileSource]
  var settings: BackupSettingsSnapshot
  var proxySelections: [String: [String: String]]
  var runtimeSnippets: [RuntimeSnippet]?
  var omittedSecretSummary: BackupSecretSummary
  var encryptedSecrets: BackupEncryptedSecrets?
  var encryptedProfileSources: BackupEncryptedProfileSources?
  var encryptedRuntimeSnippets: BackupEncryptedRuntimeSnippets?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case appMetadata
    case profilesManifest
    case outboundProxyManifest
    case profileSources
    case settings
    case proxySelections
    case runtimeSnippets
    case omittedSecretSummary
    case encryptedSecrets
    case encryptedProfileSources
    case encryptedRuntimeSnippets
  }

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    appMetadata: BackupAppMetadata,
    profilesManifest: ProfileManifest,
    outboundProxyManifest: OutboundProxyEndpointManifest = OutboundProxyEndpointManifest(),
    profileSources: [BackupProfileSource],
    settings: BackupSettingsSnapshot,
    proxySelections: [String: [String: String]],
    runtimeSnippets: [RuntimeSnippet]? = nil,
    omittedSecretSummary: BackupSecretSummary,
    encryptedSecrets: BackupEncryptedSecrets? = nil,
    encryptedProfileSources: BackupEncryptedProfileSources? = nil,
    encryptedRuntimeSnippets: BackupEncryptedRuntimeSnippets? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.appMetadata = appMetadata
    self.profilesManifest = profilesManifest
    self.outboundProxyManifest = outboundProxyManifest
    self.profileSources = profileSources
    self.settings = settings
    self.proxySelections = proxySelections
    self.runtimeSnippets = runtimeSnippets
    self.omittedSecretSummary = omittedSecretSummary
    self.encryptedSecrets = encryptedSecrets
    self.encryptedProfileSources = encryptedProfileSources
    self.encryptedRuntimeSnippets = encryptedRuntimeSnippets
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let outboundProxyManifest: OutboundProxyEndpointManifest
    if schemaVersion == 1 {
      outboundProxyManifest = try container.decodeIfPresent(
        OutboundProxyEndpointManifest.self,
        forKey: .outboundProxyManifest
      ) ?? OutboundProxyEndpointManifest()
    } else if schemaVersion == Self.currentSchemaVersion {
      outboundProxyManifest = try container.decode(
        OutboundProxyEndpointManifest.self,
        forKey: .outboundProxyManifest
      )
    } else {
      outboundProxyManifest = try container.decodeIfPresent(
        OutboundProxyEndpointManifest.self,
        forKey: .outboundProxyManifest
      ) ?? OutboundProxyEndpointManifest()
    }
    try self.init(
      schemaVersion: schemaVersion,
      appMetadata: container.decode(BackupAppMetadata.self, forKey: .appMetadata),
      profilesManifest: container.decode(ProfileManifest.self, forKey: .profilesManifest),
      outboundProxyManifest: outboundProxyManifest,
      profileSources: container.decode([BackupProfileSource].self, forKey: .profileSources),
      settings: container.decode(BackupSettingsSnapshot.self, forKey: .settings),
      proxySelections: container.decode([String: [String: String]].self, forKey: .proxySelections),
      runtimeSnippets: container.decodeIfPresent([RuntimeSnippet].self, forKey: .runtimeSnippets),
      omittedSecretSummary: container.decodeIfPresent(BackupSecretSummary.self, forKey: .omittedSecretSummary)
        ?? BackupSecretSummary(),
      encryptedSecrets: container.decodeIfPresent(BackupEncryptedSecrets.self, forKey: .encryptedSecrets),
      encryptedProfileSources: container.decodeIfPresent(
        BackupEncryptedProfileSources.self,
        forKey: .encryptedProfileSources
      ),
      encryptedRuntimeSnippets: container.decodeIfPresent(
        BackupEncryptedRuntimeSnippets.self,
        forKey: .encryptedRuntimeSnippets
      )
    )
  }
}

struct BackupAppMetadata: Codable, Equatable, Sendable {
  var appName: String
  var bundleIdentifier: String
  var appVersion: String
  var buildVersion: String
  var exportedAt: Date
  var platform: String

  static func current(bundle: Bundle = .main, date: Date = Date()) -> BackupAppMetadata {
    BackupAppMetadata(
      appName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ClashMax",
      bundleIdentifier: bundle.bundleIdentifier ?? AppConstants.bundleIdentifier,
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      exportedAt: date,
      platform: "macOS"
    )
  }
}

struct BackupProfileSource: Codable, Equatable, Sendable {
  var profileID: UUID
  var fileName: String
  var source: String
}

struct BackupSecretSummary: Codable, Equatable, Sendable {
  var subscriptionURLCount: Int
  var requestHeaderValueCount: Int
  var runtimeMergeYAMLCount: Int
  var profileSourceCredentialCount: Int
  var runtimeSnippetCount: Int
  var outboundProxyPasswordCount: Int

  private enum CodingKeys: String, CodingKey {
    case subscriptionURLCount
    case requestHeaderValueCount
    case runtimeMergeYAMLCount
    case profileSourceCredentialCount
    case runtimeSnippetCount
    case outboundProxyPasswordCount
  }

  init(
    subscriptionURLCount: Int = 0,
    requestHeaderValueCount: Int = 0,
    runtimeMergeYAMLCount: Int = 0,
    profileSourceCredentialCount: Int = 0,
    runtimeSnippetCount: Int = 0,
    outboundProxyPasswordCount: Int = 0
  ) {
    self.subscriptionURLCount = subscriptionURLCount
    self.requestHeaderValueCount = requestHeaderValueCount
    self.runtimeMergeYAMLCount = runtimeMergeYAMLCount
    self.profileSourceCredentialCount = profileSourceCredentialCount
    self.runtimeSnippetCount = runtimeSnippetCount
    self.outboundProxyPasswordCount = outboundProxyPasswordCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      subscriptionURLCount: container.decodeIfPresent(Int.self, forKey: .subscriptionURLCount) ?? 0,
      requestHeaderValueCount: container.decodeIfPresent(Int.self, forKey: .requestHeaderValueCount) ?? 0,
      runtimeMergeYAMLCount: container.decodeIfPresent(Int.self, forKey: .runtimeMergeYAMLCount) ?? 0,
      profileSourceCredentialCount: container.decodeIfPresent(Int.self, forKey: .profileSourceCredentialCount) ?? 0,
      runtimeSnippetCount: container.decodeIfPresent(Int.self, forKey: .runtimeSnippetCount) ?? 0,
      outboundProxyPasswordCount: container.decodeIfPresent(
        Int.self,
        forKey: .outboundProxyPasswordCount
      ) ?? 0
    )
  }

  var totalCount: Int {
    subscriptionURLCount
      + requestHeaderValueCount
      + runtimeMergeYAMLCount
      + profileSourceCredentialCount
      + runtimeSnippetCount
      + outboundProxyPasswordCount
  }
}

struct BackupSecretsBundle: Codable, Equatable, Sendable {
  var subscriptions: [BackupSubscriptionSecrets]
  var outboundProxyPasswords: [BackupOutboundProxyEndpointPassword]

  private enum CodingKeys: String, CodingKey {
    case subscriptions
    case outboundProxyPasswords
  }

  init(
    subscriptions: [BackupSubscriptionSecrets],
    outboundProxyPasswords: [BackupOutboundProxyEndpointPassword] = []
  ) {
    self.subscriptions = subscriptions
    self.outboundProxyPasswords = outboundProxyPasswords
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      subscriptions: container.decode([BackupSubscriptionSecrets].self, forKey: .subscriptions),
      outboundProxyPasswords: container.decodeIfPresent(
        [BackupOutboundProxyEndpointPassword].self,
        forKey: .outboundProxyPasswords
      ) ?? []
    )
  }

  static let empty = BackupSecretsBundle(subscriptions: [], outboundProxyPasswords: [])
}

struct BackupSubscriptionSecrets: Codable, Equatable, Sendable {
  var profileID: UUID
  var subscriptionURL: String?
  var requestHeaders: [BackupRequestHeaderSecret]
  var runtimeMergeYAML: String?

  var hasSecrets: Bool {
    subscriptionURL != nil || !requestHeaders.isEmpty || runtimeMergeYAML != nil
  }
}

struct BackupRequestHeaderSecret: Codable, Equatable, Sendable {
  var headerID: UUID
  var value: String
}

struct BackupEncryptedSecrets: Codable, Equatable, Sendable {
  var algorithm: String
  var keyDerivation: String
  var iterations: Int
  var salt: Data
  var nonce: Data
  var sealedPayload: Data
  var secretCount: Int
}

struct BackupEncryptedProfileSources: Codable, Equatable, Sendable {
  var algorithm: String
  var keyDerivation: String
  var iterations: Int
  var salt: Data
  var nonce: Data
  var sealedPayload: Data
  var profileSourceCount: Int
  var redactedCredentialCount: Int
}

struct BackupEncryptedRuntimeSnippets: Codable, Equatable, Sendable {
  var algorithm: String
  var keyDerivation: String
  var iterations: Int
  var salt: Data
  var nonce: Data
  var sealedPayload: Data
  var snippetCount: Int
}

struct BackupSettingsSnapshot: Codable, Equatable, Sendable {
  var runtimeSettings: PersistedRuntimeSettings
  var proxyRoutingMode: ProxyRoutingMode
  var systemProxySettings: SystemProxySettings
  var ipv6Enabled: Bool
  var tunSettings: TunSettings
  var networkExtensionRoutingSettings: NetworkExtensionRoutingSettings
  var ruleOverlaySettings: RuleOverlaySettings
  var delayTestSettings: DelayTestSettings
  var subscriptionFetchSettings: SubscriptionFetchSettings
  var menuBarPinnedGroupSettings: MenuBarPinnedGroupSettings
  var menuBarTrafficSpeedVisible: Bool
  var proxyPageSettings: ProxyPageSettings
  var globalShortcutSettings: GlobalShortcutSettings
  var externalDashboardProfiles: [ExternalDashboardProfile]
  var networkPolicySettings: NetworkPolicySettings
  var appTheme: AppTheme
  var externalControllerSettings: BackupExternalControllerSettings

  var validationError: String? {
    systemProxySettings.validationError
      ?? tunSettings.validationError
      ?? networkExtensionRoutingSettings.validationError
      ?? ruleOverlaySettings.validationError
      ?? globalShortcutSettings.validationError
      ?? networkPolicySettings.rules.compactMap(\.validationError).first
      ?? externalControllerSettings.validationError
  }

  private enum CodingKeys: String, CodingKey {
    case runtimeSettings
    case proxyRoutingMode
    case systemProxySettings
    case ipv6Enabled
    case tunSettings
    case networkExtensionRoutingSettings
    case ruleOverlaySettings
    case delayTestSettings
    case subscriptionFetchSettings
    case menuBarPinnedGroupSettings
    case menuBarTrafficSpeedVisible
    case proxyPageSettings
    case globalShortcutSettings
    case externalDashboardProfiles
    case networkPolicySettings
    case appTheme
    case externalControllerSettings
  }

  init(
    runtimeSettings: PersistedRuntimeSettings,
    proxyRoutingMode: ProxyRoutingMode,
    systemProxySettings: SystemProxySettings,
    ipv6Enabled: Bool,
    tunSettings: TunSettings,
    networkExtensionRoutingSettings: NetworkExtensionRoutingSettings,
    ruleOverlaySettings: RuleOverlaySettings,
    delayTestSettings: DelayTestSettings,
    subscriptionFetchSettings: SubscriptionFetchSettings,
    menuBarPinnedGroupSettings: MenuBarPinnedGroupSettings,
    menuBarTrafficSpeedVisible: Bool = true,
    proxyPageSettings: ProxyPageSettings = .default,
    globalShortcutSettings: GlobalShortcutSettings,
    externalDashboardProfiles: [ExternalDashboardProfile],
    networkPolicySettings: NetworkPolicySettings,
    appTheme: AppTheme,
    externalControllerSettings: BackupExternalControllerSettings
  ) {
    self.runtimeSettings = runtimeSettings
    self.proxyRoutingMode = proxyRoutingMode
    self.systemProxySettings = systemProxySettings
    self.ipv6Enabled = ipv6Enabled
    self.tunSettings = tunSettings
    self.networkExtensionRoutingSettings = networkExtensionRoutingSettings
    self.ruleOverlaySettings = ruleOverlaySettings
    self.delayTestSettings = delayTestSettings
    self.subscriptionFetchSettings = subscriptionFetchSettings
    self.menuBarPinnedGroupSettings = menuBarPinnedGroupSettings
    self.menuBarTrafficSpeedVisible = menuBarTrafficSpeedVisible
    self.proxyPageSettings = proxyPageSettings
    self.globalShortcutSettings = globalShortcutSettings
    self.externalDashboardProfiles = externalDashboardProfiles
    self.networkPolicySettings = networkPolicySettings
    self.appTheme = appTheme
    self.externalControllerSettings = externalControllerSettings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      runtimeSettings: container.decode(PersistedRuntimeSettings.self, forKey: .runtimeSettings),
      proxyRoutingMode: container.decode(ProxyRoutingMode.self, forKey: .proxyRoutingMode),
      systemProxySettings: container.decode(SystemProxySettings.self, forKey: .systemProxySettings),
      ipv6Enabled: container.decode(Bool.self, forKey: .ipv6Enabled),
      tunSettings: container.decode(TunSettings.self, forKey: .tunSettings),
      networkExtensionRoutingSettings: container.decode(
        NetworkExtensionRoutingSettings.self,
        forKey: .networkExtensionRoutingSettings
      ),
      ruleOverlaySettings: container.decode(RuleOverlaySettings.self, forKey: .ruleOverlaySettings),
      delayTestSettings: container.decode(DelayTestSettings.self, forKey: .delayTestSettings),
      subscriptionFetchSettings: container.decode(
        SubscriptionFetchSettings.self,
        forKey: .subscriptionFetchSettings
      ),
      menuBarPinnedGroupSettings: container.decode(
        MenuBarPinnedGroupSettings.self,
        forKey: .menuBarPinnedGroupSettings
      ),
      menuBarTrafficSpeedVisible: container.decodeIfPresent(Bool.self, forKey: .menuBarTrafficSpeedVisible) ?? true,
      proxyPageSettings: container.decodeIfPresent(ProxyPageSettings.self, forKey: .proxyPageSettings) ?? .default,
      globalShortcutSettings: container.decode(GlobalShortcutSettings.self, forKey: .globalShortcutSettings),
      externalDashboardProfiles: container.decode(
        [ExternalDashboardProfile].self,
        forKey: .externalDashboardProfiles
      ),
      networkPolicySettings: container.decode(NetworkPolicySettings.self, forKey: .networkPolicySettings),
      appTheme: container.decode(AppTheme.self, forKey: .appTheme),
      externalControllerSettings: container.decode(
        BackupExternalControllerSettings.self,
        forKey: .externalControllerSettings
      )
    )
  }
}

struct BackupExternalControllerSettings: Codable, Equatable, Sendable {
  var enabled: Bool
  var host: String
  var port: Int
  var cors: ExternalControllerCORSSettings

  init(settings: ExternalControllerSettings) {
    enabled = settings.enabled
    host = settings.normalizedHost
    port = settings.normalizedPort
    cors = settings.cors
  }

  func restoredSettings() -> ExternalControllerSettings {
    ExternalControllerSettings(
      enabled: enabled,
      host: host,
      port: port,
      secret: ExternalControllerSettings.generateSecret(),
      cors: cors
    )
  }

  var validationError: String? {
    restoredSettings().validationError
  }
}

struct BackupProfileExport: Sendable {
  var manifest: ProfileManifest
  var profileSources: [BackupProfileSource]
  var secrets: BackupSecretsBundle
  var omittedSecretSummary: BackupSecretSummary
}

struct BackupOutboundProxyEndpointPassword: Codable, Equatable, Sendable {
  var endpointID: UUID
  var password: String
}

struct BackupOutboundProxyEndpointExport: Equatable, Sendable {
  var manifest: OutboundProxyEndpointManifest
  var passwords: [BackupOutboundProxyEndpointPassword]
  var omittedPasswordCount: Int
}

struct OutboundProxyEndpointPasswordSnapshot: Equatable, Sendable {
  var endpointID: UUID
  var password: String?
}

struct OutboundProxyEndpointStoreRollbackSnapshot: Equatable, Sendable {
  var manifest: OutboundProxyEndpointManifest
  var passwords: [OutboundProxyEndpointPasswordSnapshot]
}

struct BackupOutboundProxyEndpointRestoreResult: Equatable, Sendable {
  var importedEndpointCount: Int
  var idMap: [UUID: UUID]
  var restoredSecretCount: Int
  var rollbackSnapshot: OutboundProxyEndpointStoreRollbackSnapshot
}

struct ProfileStoreRollbackSnapshot: Sendable {
  var manifest: ProfileManifest
  var profileSources: [Profile.ID: String]
  var subscriptionSecrets: [Profile.ID: BackupSubscriptionSecrets]
  var subscriptionURLCache: [Profile.ID: String]
}

struct ProxyPreviewRollbackSnapshot: Sendable {
  var storedSelections: [String: [String: String]]
  var previewSelections: [String: String]
}

struct BackupProfileRestoreResult: Sendable {
  var importedProfileCount: Int
  var activeProfileID: Profile.ID?
  var idMap: [Profile.ID: Profile.ID]
  var restoredSecretCount: Int
}

struct BackupRestorePreview: Identifiable, Equatable, Sendable {
  var id = UUID()
  var url: URL
  var fileName: String
  var profileCount: Int
  var endpointCount: Int
  var hasSettings: Bool
  var proxySelectionProfileCount: Int
  var hasEncryptedSecrets: Bool
  var omittedSecretSummary: BackupSecretSummary

  init(
    id: UUID = UUID(),
    url: URL,
    fileName: String,
    profileCount: Int,
    endpointCount: Int = 0,
    hasSettings: Bool,
    proxySelectionProfileCount: Int,
    hasEncryptedSecrets: Bool,
    omittedSecretSummary: BackupSecretSummary
  ) {
    self.id = id
    self.url = url
    self.fileName = fileName
    self.profileCount = profileCount
    self.endpointCount = endpointCount
    self.hasSettings = hasSettings
    self.proxySelectionProfileCount = proxySelectionProfileCount
    self.hasEncryptedSecrets = hasEncryptedSecrets
    self.omittedSecretSummary = omittedSecretSummary
  }
}

struct BackupRestoreSummary: Equatable, Sendable {
  var importedProfileCount: Int
  var importedEndpointCount: Int
  var restoredSecretCount: Int
  var skippedSecretCount: Int

  init(
    importedProfileCount: Int,
    importedEndpointCount: Int = 0,
    restoredSecretCount: Int,
    skippedSecretCount: Int
  ) {
    self.importedProfileCount = importedProfileCount
    self.importedEndpointCount = importedEndpointCount
    self.restoredSecretCount = restoredSecretCount
    self.skippedSecretCount = skippedSecretCount
  }
}

enum BackupRestoreError: LocalizedError, Equatable {
  case unsupportedSchema(Int)
  case missingProfileSource(UUID)
  case invalidBackup(String)
  case passwordRequired
  case passwordConfirmationMismatch
  case invalidPassword
  case cannotRestoreWhileRunning
  case rollbackFailed

  var errorDescription: String? {
    switch self {
    case let .unsupportedSchema(version):
      return "Unsupported ClashMax backup schema version \(version)."
    case let .missingProfileSource(id):
      return "Backup is missing YAML source for profile \(id.uuidString)."
    case let .invalidBackup(message):
      return "Invalid ClashMax backup: \(message)"
    case .passwordRequired:
      return "Enter the backup password to include or restore encrypted secrets."
    case .passwordConfirmationMismatch:
      return "Backup passwords do not match."
    case .invalidPassword:
      return "The backup password is incorrect or the encrypted secret payload is damaged."
    case .cannotRestoreWhileRunning:
      return "Stop the core before restoring a ClashMax backup."
    case .rollbackFailed:
      return "Backup restore failed and the previous outbound proxy endpoint state could not be fully restored."
    }
  }
}
