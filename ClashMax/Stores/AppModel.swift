import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var selectedSection: AppSection = .home
  @Published var overrides = RuntimeOverrides.defaultForLaunch()
  @Published var systemProxyEnabled = false
  @Published var tunEnabled = false
  @Published var tunnelCoreRunning = false
  @Published private(set) var startInFlight = false
  @Published private(set) var sessionStartedAt: Date?
  @Published var proxyGroups: [ProxyGroup] = []
  @Published var rules: [String] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published var logs: [LogEntry] = []
  @Published var helperLogs: [String] = []
  @Published var trafficSample: TrafficSample = .zero
  @Published var trafficHistory: [TrafficSample] = []
  @Published var lastError: String?

  let profileStore: ProfileStore
  let coreController: CoreProcessController
  let systemProxyController: SystemProxyController
  let helperClient: TunnelHelperClient
  private let paths: RuntimePaths
  private let normalizer = ConfigNormalizer()
  private var apiClient: MihomoAPIClient?
  private var streamTasks: [Task<Void, Never>] = []
  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  private var connectionBuffer = BoundedBuffer<ConnectionSnapshot>(limit: AppConstants.retainedConnectionLimit)

  static func bootstrap() -> AppModel {
    do {
      let paths = try RuntimePaths.live()
      return AppModel(paths: paths)
    } catch {
      let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClashMax", isDirectory: true)
      try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      let paths = RuntimePaths(
        appSupport: fallback,
        profiles: fallback.appendingPathComponent("Profiles", isDirectory: true),
        runtime: fallback.appendingPathComponent("Runtime", isDirectory: true),
        subscriptions: fallback.appendingPathComponent("Subscriptions", isDirectory: true),
        logs: fallback.appendingPathComponent("Logs", isDirectory: true)
      )
      let model = AppModel(paths: paths)
      model.lastError = String(describing: error)
      return model
    }
  }

  init(
    paths: RuntimePaths,
    profileStore: ProfileStore? = nil,
    coreController: CoreProcessController = CoreProcessController(),
    systemProxyController: SystemProxyController = SystemProxyController(),
    helperClient: TunnelHelperClient = TunnelHelperClient()
  ) {
    self.paths = paths
    self.profileStore = profileStore ?? ProfileStore(paths: paths)
    self.coreController = coreController
    self.systemProxyController = systemProxyController
    self.helperClient = helperClient
  }

  var isRunning: Bool {
    if case .running = coreController.status { return true }
    return tunnelCoreRunning
  }

  var dashboardRuntimeState: DashboardRuntimeState {
    DashboardRuntimeState.resolve(
      startInFlight: startInFlight,
      tunnelCoreRunning: tunnelCoreRunning,
      coreStatus: coreController.status,
      readinessIssue: readinessIssue
    )
  }

  var statusSummary: String {
    if tunnelCoreRunning {
      return "Running TUN"
    }
    switch coreController.status {
    case .stopped:
      return "Stopped"
    case .starting:
      return "Starting"
    case let .running(version):
      return version.map { "Running \($0)" } ?? "Running"
    case let .crashed(message):
      return "Crashed: \(message)"
    case .restarting:
      return "Restarting"
    }
  }

  var readinessIssue: String? {
    if profileStore.activeProfile == nil {
      return "No active profile selected."
    }
    if (try? bundledCoreURL()) == nil {
      return AppError.missingBundledCore.description
    }
    return nil
  }

  func importLocalProfile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.yaml, .yml, .text]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      _ = try profileStore.importLocalConfig(from: url)
    } catch {
      lastError = String(describing: error)
    }
  }

  func addSubscription(name: String, urlString: String) {
    guard let url = URL(string: urlString) else {
      lastError = "Invalid subscription URL."
      return
    }
    Task {
      do {
        _ = try await profileStore.addSubscription(name: name, url: url)
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func updateActiveSubscription() {
    guard let profile = profileStore.activeProfile else { return }
    Task {
      do {
        try await profileStore.updateSubscription(profile)
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func renameActiveProfile(to name: String) {
    guard let profile = profileStore.activeProfile else { return }
    do {
      try profileStore.rename(profile, to: name)
    } catch {
      lastError = String(describing: error)
    }
  }

  func deleteActiveProfile() {
    guard let profile = profileStore.activeProfile else { return }
    do {
      try profileStore.delete(profile)
    } catch {
      lastError = String(describing: error)
    }
  }

  func start() {
    startInFlight = true
    lastError = nil
    Task {
      defer { startInFlight = false }
      do {
        let profile = try requireActiveProfile()
        overrides.secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        overrides.tunEnabled = tunEnabled
        let runtimeConfig = try generateRuntimeConfig(for: profile)
        let client = MihomoAPIClient(baseURL: overrides.endpoint.baseURL, secret: overrides.secret)
        apiClient = client

        if tunEnabled {
          try helperClient.register()
          let response = try await helperClient.startTunnel(
            coreURL: try bundledCoreURL(),
            configURL: runtimeConfig,
            workDirectory: paths.runtime,
            secret: overrides.secret
          )
          if !response.ok {
            throw AppError.helperResponse(response.message.isEmpty ? "Helper failed to start TUN." : response.message)
          }
          tunnelCoreRunning = response.running
          coreController.stop()
        } else {
          tunnelCoreRunning = false
          try await coreController.startUserMode(
            coreURL: try bundledCoreURL(),
            configURL: runtimeConfig,
            workDirectory: paths.runtime,
            api: overrides.endpoint
          )
        }

        if systemProxyEnabled && !tunEnabled {
          try systemProxyController.apply(host: overrides.externalControllerHost, port: overrides.mixedPort)
        }
        sessionStartedAt = Date()
        startStreams(client: client)
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func stop() {
    startInFlight = false
    Task {
      streamTasks.forEach { $0.cancel() }
      streamTasks.removeAll()
      coreController.stop()
      if tunEnabled {
        _ = try? await helperClient.stopTunnel()
      }
      tunnelCoreRunning = false
      sessionStartedAt = nil
      if systemProxyEnabled {
        try? systemProxyController.restore()
      }
    }
  }

  func restart() {
    stop()
    start()
  }

  func setMode(_ mode: RunMode) {
    overrides.mode = mode
    Task {
      do {
        try await apiClient?.updateMode(mode)
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func reloadRuntimeData() {
    guard let apiClient else { return }
    Task {
      do {
        proxyGroups = try await apiClient.proxyGroups()
        rules = try await apiClient.rules()
        connections = try await apiClient.connections()
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func refreshHelperStatus() {
    Task {
      do {
        let response = try await helperClient.status()
        helperClient.statusMessage = response.running
          ? "Helper running with pid \(response.pid)"
          : "Helper registered but not running"
      } catch {
        helperClient.statusMessage = "Helper unavailable: \(error.localizedDescription)"
      }
    }
  }

  func refreshHelperLogs() {
    Task {
      do {
        helperLogs = try await helperClient.recentLogs()
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func selectProxy(group: ProxyGroup, node: ProxyNode) {
    Task {
      do {
        try await apiClient?.selectProxy(group: group.name, proxy: node.name)
        reloadRuntimeData()
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func testDelay(for node: ProxyNode) {
    Task {
      do {
        _ = try await apiClient?.testDelay(proxy: node.name, testURL: AppConstants.defaultDelayTestURL, timeout: 5000)
        reloadRuntimeData()
      } catch {
        lastError = String(describing: error)
      }
    }
  }

  func setSystemProxyEnabled(_ enabled: Bool) {
    systemProxyEnabled = enabled
    do {
      if enabled {
        try systemProxyController.apply(host: overrides.externalControllerHost, port: overrides.mixedPort)
      } else {
        try systemProxyController.restore()
      }
    } catch {
      lastError = String(describing: error)
    }
  }

  private func requireActiveProfile() throws -> Profile {
    guard let profile = profileStore.activeProfile else {
      throw AppError.noActiveProfile
    }
    return profile
  }

  private func generateRuntimeConfig(for profile: Profile) throws -> URL {
    let source = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    let providerContentPath: String?
    if try ProfileConfigInspector.format(of: source) == .proxyProviderContent {
      let providerContentURL = paths.runtimeProviderContentURL(for: profile)
      try source.write(to: providerContentURL, atomically: true, encoding: .utf8)
      providerContentPath = providerContentURL.path
    } else {
      providerContentPath = nil
    }
    let output = try normalizer.runtimeConfig(
      from: source,
      providerContentPath: providerContentPath,
      profileName: profile.name,
      overrides: overrides
    )
    let url = paths.runtimeConfigURL(for: profile)
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func bundledCoreURL() throws -> URL {
    let architecture = ProcessInfo.processInfo.machineHardwareName.contains("x86") ? "amd64" : "arm64"
    let candidates = [
      AppConstants.bundledCoreRoot.appendingPathComponent("mihomo-darwin-\(architecture)"),
      AppConstants.bundledCoreRoot.appendingPathComponent("mihomo")
    ]
    guard let core = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw AppError.missingBundledCore
    }
    return core
  }

  private func startStreams(client: MihomoAPIClient) {
    streamTasks.forEach { $0.cancel() }
    let logLevel = overrides.logLevel
    streamTasks = [
      Task { [weak self] in
        do {
          for try await sample in client.trafficStream() {
            await MainActor.run {
              self?.trafficSample = sample
              self?.appendTrafficSample(sample)
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await entry in client.logStream(level: logLevel) {
            await MainActor.run {
              self?.logBuffer.append(entry)
              self?.logs = self?.logBuffer.elements ?? []
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await snapshot in client.connectionStream() {
            await MainActor.run {
              self?.connectionBuffer.replace(with: snapshot)
              self?.connections = self?.connectionBuffer.elements ?? []
            }
          }
        } catch {}
      }
    ]
    reloadRuntimeData()
  }

  private func appendTrafficSample(_ sample: TrafficSample) {
    trafficHistory.append(sample)
    if trafficHistory.count > 72 {
      trafficHistory.removeFirst(trafficHistory.count - 72)
    }
  }
}

private extension ProcessInfo {
  var machineHardwareName: String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce(into: "") { result, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      result.append(Character(UnicodeScalar(UInt8(value))))
    }
  }
}

extension UTType {
  static var yaml: UTType {
    UTType(filenameExtension: "yaml") ?? .text
  }

  static var yml: UTType {
    UTType(filenameExtension: "yml") ?? .text
  }
}
