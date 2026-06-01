import Foundation
import ServiceManagement

@MainActor
final class PersistedSettingsStore: ObservableObject {
  @Published var overrides: RuntimeOverrides {
    didSet {
      saveRuntimeSettings(overrides)
    }
  }
  @Published var proxyRoutingMode: ProxyRoutingMode = .systemProxy {
    didSet {
      saveCodable(proxyRoutingMode, forKey: Self.proxyRoutingModeDefaultsKey)
    }
  }
  @Published var systemProxySettings = SystemProxySettings.default {
    didSet {
      saveCodable(systemProxySettings, forKey: Self.systemProxySettingsDefaultsKey)
    }
  }
  @Published var ipv6Enabled = false {
    didSet {
      overrides.ipv6Enabled = ipv6Enabled
      defaults.set(ipv6Enabled, forKey: Self.ipv6EnabledDefaultsKey)
    }
  }
  @Published var tunSettings = TunSettings.default {
    didSet {
      overrides.tunSettings = tunSettings
      saveCodable(tunSettings, forKey: Self.tunSettingsDefaultsKey)
    }
  }
  @Published var networkExtensionRoutingSettings = NetworkExtensionRoutingSettings.default {
    didSet {
      saveCodable(networkExtensionRoutingSettings, forKey: Self.networkExtensionRoutingSettingsDefaultsKey)
    }
  }
  @Published var ruleOverlaySettings = RuleOverlaySettings.disabled {
    didSet {
      overrides.ruleOverlay = ruleOverlaySettings
      saveCodable(ruleOverlaySettings, forKey: Self.ruleOverlaySettingsDefaultsKey)
    }
  }
  @Published var delayTestSettings = DelayTestSettings.default {
    didSet {
      overrides.unifiedDelay = delayTestSettings.unifiedDelay
      saveCodable(delayTestSettings, forKey: Self.delayTestSettingsDefaultsKey)
    }
  }
  @Published var subscriptionFetchSettings = SubscriptionFetchSettings.default {
    didSet {
      saveCodable(subscriptionFetchSettings, forKey: Self.subscriptionFetchSettingsDefaultsKey)
    }
  }
  @Published var menuBarPinnedGroupSettings = MenuBarPinnedGroupSettings.default {
    didSet {
      saveCodable(menuBarPinnedGroupSettings, forKey: Self.menuBarPinnedGroupSettingsDefaultsKey)
    }
  }
  @Published var proxyPageSettings = ProxyPageSettings.default {
    didSet {
      saveCodable(proxyPageSettings, forKey: Self.proxyPageSettingsDefaultsKey)
    }
  }
  @Published var globalShortcutSettings = GlobalShortcutSettings.default {
    didSet {
      saveCodable(globalShortcutSettings, forKey: Self.globalShortcutSettingsDefaultsKey)
    }
  }
  @Published var externalDashboardProfiles: [ExternalDashboardProfile] = [] {
    didSet {
      saveCodable(externalDashboardProfiles, forKey: Self.externalDashboardProfilesDefaultsKey)
    }
  }
  @Published var networkPolicySettings = NetworkPolicySettings.default {
    didSet {
      saveCodable(networkPolicySettings, forKey: Self.networkPolicySettingsDefaultsKey)
    }
  }
  @Published var appTheme = AppTheme.system {
    didSet {
      saveCodable(appTheme, forKey: Self.appThemeDefaultsKey)
    }
  }
  @Published var externalControllerSettings = ExternalControllerSettings.default {
    didSet {
      syncExternalControllerSettings()
      saveExternalControllerSettings(externalControllerSettings)
    }
  }
  @Published private(set) var appliedRuntimeSettingsSnapshot: AppliedRuntimeSettingsSnapshot?
  @Published private(set) var launchSettings = LaunchSettings.default
  @Published private(set) var initialTunHelperPromptHandled: Bool
  @Published var developerMode = false {
    didSet {
      defaults.set(developerMode, forKey: Self.developerModeDefaultsKey)
    }
  }

  private let defaults: UserDefaults
  private let loginItemService: any LoginItemManaging

  static let silentStartDefaultsKey = "io.github.clashmax.silentStart"
  static let initialTunHelperPromptHandledDefaultsKey = "io.github.clashmax.initialTunHelperPromptHandled"
  private static let proxyRoutingModeDefaultsKey = "io.github.clashmax.proxyRoutingMode"
  private static let developerModeDefaultsKey = "io.github.clashmax.developerMode"
  private static let systemProxySettingsDefaultsKey = "io.github.clashmax.systemProxySettings"
  private static let runtimeSettingsDefaultsKey = "io.github.clashmax.runtimeSettings"
  private static let ipv6EnabledDefaultsKey = "io.github.clashmax.ipv6Enabled"
  private static let tunSettingsDefaultsKey = "io.github.clashmax.tunSettings"
  private static let tunDNSDefaultsVersionKey = "io.github.clashmax.tunDNSDefaultsVersion"
  private static let currentTunDNSDefaultsVersion = 1
  private static let networkExtensionRoutingSettingsDefaultsKey = "io.github.clashmax.networkExtensionRoutingSettings"
  private static let ruleOverlaySettingsDefaultsKey = "io.github.clashmax.ruleOverlaySettings"
  private static let delayTestSettingsDefaultsKey = "io.github.clashmax.delayTestSettings"
  private static let subscriptionFetchSettingsDefaultsKey = "io.github.clashmax.subscriptionFetchSettings"
  private static let menuBarPinnedGroupSettingsDefaultsKey = "io.github.clashmax.menuBarPinnedGroupSettings"
  private static let proxyPageSettingsDefaultsKey = "io.github.clashmax.proxyPageSettings"
  private static let globalShortcutSettingsDefaultsKey = "io.github.clashmax.globalShortcutSettings"
  private static let externalDashboardProfilesDefaultsKey = "io.github.clashmax.externalDashboardProfiles"
  private static let networkPolicySettingsDefaultsKey = "io.github.clashmax.networkPolicySettings"
  private static let appThemeDefaultsKey = "io.github.clashmax.appTheme"
  private static let externalControllerSettingsDefaultsKey = "io.github.clashmax.externalControllerSettings"
  private static let externalControllerCORSSettingsDefaultsKey = "io.github.clashmax.externalControllerCORSSettings"
  private static let appliedRuntimeSettingsSnapshotDefaultsKey = "io.github.clashmax.appliedRuntimeSettingsSnapshot"
  private static let persistedSecretPlaceholder = "__clashmax_per_run_secret__"

  init(
    loginItemService: any LoginItemManaging = MainAppLoginItemService(),
    defaults: UserDefaults = .standard
  ) {
    self.loginItemService = loginItemService
    self.defaults = defaults
    var launchOverrides = RuntimeOverrides.defaultForLaunch()
    if let runtimeSettings = Self.loadCodable(
      PersistedRuntimeSettings.self,
      forKey: Self.runtimeSettingsDefaultsKey,
      defaults: defaults
    ) {
      runtimeSettings.apply(to: &launchOverrides)
    }
    overrides = launchOverrides
    developerMode = defaults.bool(forKey: Self.developerModeDefaultsKey)
    initialTunHelperPromptHandled = defaults.bool(forKey: Self.initialTunHelperPromptHandledDefaultsKey)
    let storedProxyRoutingMode = Self.loadCodable(
      ProxyRoutingMode.self,
      forKey: Self.proxyRoutingModeDefaultsKey,
      defaults: defaults
    ) ?? .systemProxy
    proxyRoutingMode = storedProxyRoutingMode
    systemProxySettings = Self.loadCodable(
      SystemProxySettings.self,
      forKey: Self.systemProxySettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    ipv6Enabled = defaults.bool(forKey: Self.ipv6EnabledDefaultsKey)
    let loadedTunSettings = Self.loadCodable(
      TunSettings.self,
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    tunSettings = Self.migrateTunDNSDefaultsIfNeeded(loadedTunSettings, defaults: defaults)
    networkExtensionRoutingSettings = Self.loadCodable(
      NetworkExtensionRoutingSettings.self,
      forKey: Self.networkExtensionRoutingSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    ruleOverlaySettings = Self.loadCodable(
      RuleOverlaySettings.self,
      forKey: Self.ruleOverlaySettingsDefaultsKey,
      defaults: defaults
    ) ?? .disabled
    delayTestSettings = Self.loadCodable(
      DelayTestSettings.self,
      forKey: Self.delayTestSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    subscriptionFetchSettings = Self.loadCodable(
      SubscriptionFetchSettings.self,
      forKey: Self.subscriptionFetchSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    menuBarPinnedGroupSettings = Self.loadCodable(
      MenuBarPinnedGroupSettings.self,
      forKey: Self.menuBarPinnedGroupSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    proxyPageSettings = Self.loadCodable(
      ProxyPageSettings.self,
      forKey: Self.proxyPageSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    globalShortcutSettings = Self.loadCodable(
      GlobalShortcutSettings.self,
      forKey: Self.globalShortcutSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    externalDashboardProfiles = Self.loadCodable(
      [ExternalDashboardProfile].self,
      forKey: Self.externalDashboardProfilesDefaultsKey,
      defaults: defaults
    ) ?? [
      ExternalDashboardProfile(name: "YACD", url: URL(string: "https://yacd.metacubex.one")!, readOnly: true),
      ExternalDashboardProfile(name: "MetaCubeX", url: URL(string: "https://metacubex.github.io/metacubexd")!, readOnly: true)
    ]
    networkPolicySettings = Self.loadCodable(
      NetworkPolicySettings.self,
      forKey: Self.networkPolicySettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    appTheme = Self.loadCodable(
      AppTheme.self,
      forKey: Self.appThemeDefaultsKey,
      defaults: defaults
    ) ?? .system
    let migratedCORSSettings = Self.loadCodable(
      ExternalControllerCORSSettings.self,
      forKey: Self.externalControllerCORSSettingsDefaultsKey,
      defaults: defaults
    ).map(ExternalControllerCORSSettings.removingLegacyDefaultPanelOrigins)
    externalControllerSettings = Self.loadExternalControllerSettings(
      defaults: defaults,
      migratedCORSSettings: migratedCORSSettings
    )
    appliedRuntimeSettingsSnapshot = Self.loadCodable(
      AppliedRuntimeSettingsSnapshot.self,
      forKey: Self.appliedRuntimeSettingsSnapshotDefaultsKey,
      defaults: defaults
    )
    overrides.tunSettings = tunSettings
    overrides.ruleOverlay = ruleOverlaySettings
    overrides.ipv6Enabled = ipv6Enabled
    overrides.unifiedDelay = delayTestSettings.unifiedDelay
    syncExternalControllerSettings()
    refreshLaunchSettings()
  }

  func refreshLaunchSettings() {
    launchSettings = LaunchSettings(
      launchAtLogin: Self.isLoginItemRegistered(loginItemService.status),
      silentStart: defaults.bool(forKey: Self.silentStartDefaultsKey),
      statusMessage: Self.loginItemStatusMessage(for: loginItemService.status)
    )
  }

  @discardableResult
  func updateLaunchAtLogin(_ enabled: Bool) async throws -> Bool {
    if enabled {
      try loginItemService.register()
    } else {
      try await loginItemService.unregister()
    }
    refreshLaunchSettings()
    if loginItemService.status == .requiresApproval {
      loginItemService.openSystemSettingsLoginItems()
    }
    return true
  }

  func setSilentStart(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.silentStartDefaultsKey)
    refreshLaunchSettings()
  }

  func markInitialTunHelperPromptHandled() {
    initialTunHelperPromptHandled = true
    defaults.set(true, forKey: Self.initialTunHelperPromptHandledDefaultsKey)
  }

  func openLoginItemsSettings() {
    loginItemService.openSystemSettingsLoginItems()
  }

  func backupSnapshot() -> BackupSettingsSnapshot {
    BackupSettingsSnapshot(
      runtimeSettings: PersistedRuntimeSettings(overrides: overrides),
      proxyRoutingMode: proxyRoutingMode,
      systemProxySettings: systemProxySettings,
      ipv6Enabled: ipv6Enabled,
      tunSettings: tunSettings,
      networkExtensionRoutingSettings: networkExtensionRoutingSettings,
      ruleOverlaySettings: ruleOverlaySettings,
      delayTestSettings: delayTestSettings,
      subscriptionFetchSettings: subscriptionFetchSettings,
      menuBarPinnedGroupSettings: menuBarPinnedGroupSettings,
      proxyPageSettings: proxyPageSettings,
      globalShortcutSettings: globalShortcutSettings,
      externalDashboardProfiles: externalDashboardProfiles,
      networkPolicySettings: networkPolicySettings,
      appTheme: appTheme,
      externalControllerSettings: BackupExternalControllerSettings(settings: externalControllerSettings)
    )
  }

  func applyBackupSnapshot(_ snapshot: BackupSettingsSnapshot) {
    proxyRoutingMode = snapshot.proxyRoutingMode
    systemProxySettings = snapshot.systemProxySettings
    ipv6Enabled = snapshot.ipv6Enabled
    tunSettings = snapshot.tunSettings
    networkExtensionRoutingSettings = snapshot.networkExtensionRoutingSettings
    ruleOverlaySettings = snapshot.ruleOverlaySettings
    delayTestSettings = snapshot.delayTestSettings
    subscriptionFetchSettings = snapshot.subscriptionFetchSettings
    menuBarPinnedGroupSettings = snapshot.menuBarPinnedGroupSettings
    proxyPageSettings = snapshot.proxyPageSettings
    globalShortcutSettings = snapshot.globalShortcutSettings
    externalDashboardProfiles = snapshot.externalDashboardProfiles
    networkPolicySettings = snapshot.networkPolicySettings
    appTheme = snapshot.appTheme
    externalControllerSettings = snapshot.externalControllerSettings.restoredSettings()

    var restoredOverrides = overrides
    snapshot.runtimeSettings.apply(to: &restoredOverrides)
    restoredOverrides.ipv6Enabled = ipv6Enabled
    restoredOverrides.tunSettings = tunSettings
    restoredOverrides.ruleOverlay = ruleOverlaySettings
    restoredOverrides.unifiedDelay = delayTestSettings.unifiedDelay
    restoredOverrides.externalControllerHost = externalControllerSettings.normalizedHost
    restoredOverrides.externalControllerPort = externalControllerSettings.normalizedPort
    restoredOverrides.secret = externalControllerSettings.normalizedSecret
    restoredOverrides.externalControllerCORS = externalControllerSettings.runtimeCORS
    overrides = restoredOverrides
    clearAppliedRuntimeSettingsSnapshot()
    refreshLaunchSettings()
  }

  func updateTunSettings(_ settings: TunSettings) {
    tunSettings = settings
  }

  func syncExternalControllerSettings() {
    let settings = externalControllerSettings
    overrides.externalControllerHost = settings.normalizedHost
    overrides.externalControllerPort = settings.normalizedPort
    overrides.secret = settings.normalizedSecret
    overrides.externalControllerCORS = settings.runtimeCORS
  }

  func recordAppliedRuntimeSettingsSnapshot(_ snapshot: AppliedRuntimeSettingsSnapshot) {
    appliedRuntimeSettingsSnapshot = snapshot
    saveCodable(
      sanitizedAppliedRuntimeSettingsSnapshot(snapshot),
      forKey: Self.appliedRuntimeSettingsSnapshotDefaultsKey
    )
  }

  func clearAppliedRuntimeSettingsSnapshot() {
    appliedRuntimeSettingsSnapshot = nil
    defaults.removeObject(forKey: Self.appliedRuntimeSettingsSnapshotDefaultsKey)
  }

  private func saveExternalControllerSettings(_ settings: ExternalControllerSettings) {
    var sanitized = settings
    sanitized.secret = Self.persistedSecretPlaceholder
    saveCodable(sanitized, forKey: Self.externalControllerSettingsDefaultsKey)
  }

  private func saveRuntimeSettings(_ overrides: RuntimeOverrides) {
    saveCodable(PersistedRuntimeSettings(overrides: overrides), forKey: Self.runtimeSettingsDefaultsKey)
  }

  private func sanitizedAppliedRuntimeSettingsSnapshot(
    _ snapshot: AppliedRuntimeSettingsSnapshot
  ) -> AppliedRuntimeSettingsSnapshot {
    var sanitized = snapshot
    sanitized.overrides.secret = Self.persistedSecretPlaceholder
    return sanitized
  }

  private static func loadExternalControllerSettings(
    defaults: UserDefaults,
    migratedCORSSettings: ExternalControllerCORSSettings?
  ) -> ExternalControllerSettings {
    var settings = loadCodable(
      ExternalControllerSettings.self,
      forKey: Self.externalControllerSettingsDefaultsKey,
      defaults: defaults
    ) ?? ExternalControllerSettings(cors: migratedCORSSettings ?? .default)
    settings.secret = ExternalControllerSettings.generateSecret()
    settings.cors = ExternalControllerCORSSettings.removingLegacyDefaultPanelOrigins(settings.cors)
    return settings
  }

  private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  private static func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String, defaults: UserDefaults) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func migrateTunDNSDefaultsIfNeeded(_ settings: TunSettings, defaults: UserDefaults) -> TunSettings {
    let storedVersion = defaults.integer(forKey: tunDNSDefaultsVersionKey)
    guard storedVersion < currentTunDNSDefaultsVersion else {
      return settings
    }
    defaults.set(currentTunDNSDefaultsVersion, forKey: tunDNSDefaultsVersionKey)
    guard settings.dns == .legacyEmpty else {
      return settings
    }
    var migrated = settings
    migrated.dns = .default
    saveCodable(migrated, forKey: tunSettingsDefaultsKey, defaults: defaults)
    return migrated
  }

  private static func saveCodable<T: Encodable>(_ value: T, forKey key: String, defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  private static func isLoginItemRegistered(_ status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval:
      return true
    case .notRegistered, .notFound:
      return false
    @unknown default:
      return false
    }
  }

  private static func loginItemStatusMessage(for status: SMAppService.Status) -> String {
    switch status {
    case .enabled:
      return String(localized: "ClashMax will launch when you log in.")
    case .requiresApproval:
      return String(localized: "Approve ClashMax in System Settings > General > Login Items & Extensions.")
    case .notRegistered:
      return String(localized: "Launch at login is not registered.")
    case .notFound:
      return String(localized: "macOS could not find the ClashMax login item service.")
    @unknown default:
      return String(localized: "macOS reported an unknown login item state.")
    }
  }
}
