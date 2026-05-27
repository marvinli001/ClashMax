import Foundation

struct ClashMaxBackupFile: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var appMetadata: BackupAppMetadata
  var profilesManifest: ProfileManifest
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
    self.init(
      schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
      appMetadata: try container.decode(BackupAppMetadata.self, forKey: .appMetadata),
      profilesManifest: try container.decode(ProfileManifest.self, forKey: .profilesManifest),
      profileSources: try container.decode([BackupProfileSource].self, forKey: .profileSources),
      settings: try container.decode(BackupSettingsSnapshot.self, forKey: .settings),
      proxySelections: try container.decode([String: [String: String]].self, forKey: .proxySelections),
      runtimeSnippets: try container.decodeIfPresent([RuntimeSnippet].self, forKey: .runtimeSnippets),
      omittedSecretSummary: try container.decodeIfPresent(BackupSecretSummary.self, forKey: .omittedSecretSummary)
        ?? BackupSecretSummary(),
      encryptedSecrets: try container.decodeIfPresent(BackupEncryptedSecrets.self, forKey: .encryptedSecrets),
      encryptedProfileSources: try container.decodeIfPresent(
        BackupEncryptedProfileSources.self,
        forKey: .encryptedProfileSources
      ),
      encryptedRuntimeSnippets: try container.decodeIfPresent(
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

  private enum CodingKeys: String, CodingKey {
    case subscriptionURLCount
    case requestHeaderValueCount
    case runtimeMergeYAMLCount
    case profileSourceCredentialCount
    case runtimeSnippetCount
  }

  init(
    subscriptionURLCount: Int = 0,
    requestHeaderValueCount: Int = 0,
    runtimeMergeYAMLCount: Int = 0,
    profileSourceCredentialCount: Int = 0,
    runtimeSnippetCount: Int = 0
  ) {
    self.subscriptionURLCount = subscriptionURLCount
    self.requestHeaderValueCount = requestHeaderValueCount
    self.runtimeMergeYAMLCount = runtimeMergeYAMLCount
    self.profileSourceCredentialCount = profileSourceCredentialCount
    self.runtimeSnippetCount = runtimeSnippetCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      subscriptionURLCount: try container.decodeIfPresent(Int.self, forKey: .subscriptionURLCount) ?? 0,
      requestHeaderValueCount: try container.decodeIfPresent(Int.self, forKey: .requestHeaderValueCount) ?? 0,
      runtimeMergeYAMLCount: try container.decodeIfPresent(Int.self, forKey: .runtimeMergeYAMLCount) ?? 0,
      profileSourceCredentialCount: try container.decodeIfPresent(Int.self, forKey: .profileSourceCredentialCount) ?? 0,
      runtimeSnippetCount: try container.decodeIfPresent(Int.self, forKey: .runtimeSnippetCount) ?? 0
    )
  }

  var totalCount: Int {
    subscriptionURLCount
      + requestHeaderValueCount
      + runtimeMergeYAMLCount
      + profileSourceCredentialCount
      + runtimeSnippetCount
  }
}

struct BackupSecretsBundle: Codable, Equatable, Sendable {
  var subscriptions: [BackupSubscriptionSecrets]

  static let empty = BackupSecretsBundle(subscriptions: [])
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
    self.proxyPageSettings = proxyPageSettings
    self.globalShortcutSettings = globalShortcutSettings
    self.externalDashboardProfiles = externalDashboardProfiles
    self.networkPolicySettings = networkPolicySettings
    self.appTheme = appTheme
    self.externalControllerSettings = externalControllerSettings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      runtimeSettings: try container.decode(PersistedRuntimeSettings.self, forKey: .runtimeSettings),
      proxyRoutingMode: try container.decode(ProxyRoutingMode.self, forKey: .proxyRoutingMode),
      systemProxySettings: try container.decode(SystemProxySettings.self, forKey: .systemProxySettings),
      ipv6Enabled: try container.decode(Bool.self, forKey: .ipv6Enabled),
      tunSettings: try container.decode(TunSettings.self, forKey: .tunSettings),
      networkExtensionRoutingSettings: try container.decode(
        NetworkExtensionRoutingSettings.self,
        forKey: .networkExtensionRoutingSettings
      ),
      ruleOverlaySettings: try container.decode(RuleOverlaySettings.self, forKey: .ruleOverlaySettings),
      delayTestSettings: try container.decode(DelayTestSettings.self, forKey: .delayTestSettings),
      subscriptionFetchSettings: try container.decode(
        SubscriptionFetchSettings.self,
        forKey: .subscriptionFetchSettings
      ),
      menuBarPinnedGroupSettings: try container.decode(
        MenuBarPinnedGroupSettings.self,
        forKey: .menuBarPinnedGroupSettings
      ),
      proxyPageSettings: try container.decodeIfPresent(ProxyPageSettings.self, forKey: .proxyPageSettings) ?? .default,
      globalShortcutSettings: try container.decode(GlobalShortcutSettings.self, forKey: .globalShortcutSettings),
      externalDashboardProfiles: try container.decode(
        [ExternalDashboardProfile].self,
        forKey: .externalDashboardProfiles
      ),
      networkPolicySettings: try container.decode(NetworkPolicySettings.self, forKey: .networkPolicySettings),
      appTheme: try container.decode(AppTheme.self, forKey: .appTheme),
      externalControllerSettings: try container.decode(
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
  var hasSettings: Bool
  var proxySelectionProfileCount: Int
  var hasEncryptedSecrets: Bool
  var omittedSecretSummary: BackupSecretSummary
}

struct BackupRestoreSummary: Equatable, Sendable {
  var importedProfileCount: Int
  var restoredSecretCount: Int
  var skippedSecretCount: Int
}

enum BackupRestoreError: LocalizedError, Equatable {
  case unsupportedSchema(Int)
  case missingProfileSource(UUID)
  case invalidBackup(String)
  case passwordRequired
  case passwordConfirmationMismatch
  case invalidPassword
  case cannotRestoreWhileRunning

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
    }
  }
}
