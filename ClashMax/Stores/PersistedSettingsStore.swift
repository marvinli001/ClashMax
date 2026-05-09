import Foundation
import ServiceManagement

@MainActor
final class PersistedSettingsStore: ObservableObject {
  @Published var overrides: RuntimeOverrides
  @Published var proxyRoutingMode: ProxyRoutingMode = .systemProxy
  @Published var systemProxySettings = SystemProxySettings.default {
    didSet {
      saveCodable(systemProxySettings, forKey: Self.systemProxySettingsDefaultsKey)
    }
  }
  @Published var tunSettings = TunSettings.default {
    didSet {
      overrides.tunSettings = tunSettings
      saveCodable(tunSettings, forKey: Self.tunSettingsDefaultsKey)
    }
  }
  @Published var delayTestSettings = DelayTestSettings.default {
    didSet {
      overrides.unifiedDelay = delayTestSettings.unifiedDelay
      saveCodable(delayTestSettings, forKey: Self.delayTestSettingsDefaultsKey)
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
  @Published private(set) var launchSettings = LaunchSettings.default
  @Published var developerMode = false {
    didSet {
      defaults.set(developerMode, forKey: Self.developerModeDefaultsKey)
    }
  }

  private let defaults: UserDefaults
  private let loginItemService: any LoginItemManaging

  static let silentStartDefaultsKey = "io.github.clashmax.silentStart"
  private static let developerModeDefaultsKey = "io.github.clashmax.developerMode"
  private static let systemProxySettingsDefaultsKey = "io.github.clashmax.systemProxySettings"
  private static let tunSettingsDefaultsKey = "io.github.clashmax.tunSettings"
  private static let delayTestSettingsDefaultsKey = "io.github.clashmax.delayTestSettings"
  private static let appThemeDefaultsKey = "io.github.clashmax.appTheme"
  private static let externalControllerSettingsDefaultsKey = "io.github.clashmax.externalControllerSettings"
  private static let externalControllerCORSSettingsDefaultsKey = "io.github.clashmax.externalControllerCORSSettings"
  private static let persistedSecretPlaceholder = "__clashmax_per_run_secret__"

  init(
    loginItemService: any LoginItemManaging = MainAppLoginItemService(),
    defaults: UserDefaults = .standard
  ) {
    self.loginItemService = loginItemService
    self.defaults = defaults
    overrides = RuntimeOverrides.defaultForLaunch()
    developerMode = defaults.bool(forKey: Self.developerModeDefaultsKey)
    systemProxySettings = Self.loadCodable(
      SystemProxySettings.self,
      forKey: Self.systemProxySettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    tunSettings = Self.loadCodable(
      TunSettings.self,
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    delayTestSettings = Self.loadCodable(
      DelayTestSettings.self,
      forKey: Self.delayTestSettingsDefaultsKey,
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
    )
    externalControllerSettings = Self.loadExternalControllerSettings(
      defaults: defaults,
      migratedCORSSettings: migratedCORSSettings
    )
    overrides.tunSettings = tunSettings
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

  func openLoginItemsSettings() {
    loginItemService.openSystemSettingsLoginItems()
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

  private func saveExternalControllerSettings(_ settings: ExternalControllerSettings) {
    var sanitized = settings
    sanitized.secret = Self.persistedSecretPlaceholder
    saveCodable(sanitized, forKey: Self.externalControllerSettingsDefaultsKey)
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
