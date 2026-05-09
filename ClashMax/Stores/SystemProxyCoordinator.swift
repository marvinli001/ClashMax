import Foundation

@MainActor
final class SystemProxyCoordinator: ObservableObject {
  @Published var enabled = false

  let controller: SystemProxyController

  private let defaults: UserDefaults
  private var guardTask: Task<Void, Never>?

  static let managedDefaultsKey = "io.github.clashmax.systemProxyManaged"

  init(
    controller: SystemProxyController,
    defaults: UserDefaults = .standard
  ) {
    self.controller = controller
    self.defaults = defaults
  }

  var hasManagedSystemProxyState: Bool {
    controller.hasManagedSystemProxyState
  }

  var needsTerminationCleanup: Bool {
    enabled || controller.hasManagedSystemProxyState || defaults.bool(forKey: Self.managedDefaultsKey)
  }

  func apply(settings: SystemProxySettings, mixedPort: Int) async throws {
    if let validationError = settings.validationError {
      throw AppError.invalidProfileConfig(validationError)
    }
    markManaged(true)
    do {
      try await controller.apply(
        host: settings.normalizedProxyHost,
        port: mixedPort,
        bypassDomains: settings.effectiveBypassDomains
      )
      enabled = true
    } catch {
      if !controller.hasManagedSystemProxyState {
        markManaged(false)
      }
      throw error
    }
  }

  func activateGuardIfNeeded(
    settings: SystemProxySettings,
    mixedPort: Int,
    onWarning: @escaping @MainActor (String) -> Void,
    onError: @escaping @MainActor (Error) -> Void
  ) async throws {
    stopGuard()
    guard settings.guardEnabled else { return }
    try await controller.enableGuard(
      host: settings.normalizedProxyHost,
      port: mixedPort,
      bypassDomains: settings.effectiveBypassDomains
    )
    startGuardLoop(
      intervalSeconds: settings.normalizedGuardIntervalSeconds,
      onWarning: onWarning,
      onError: onError
    )
  }

  func stopGuard() {
    guardTask?.cancel()
    guardTask = nil
    controller.disableGuard()
  }

  @discardableResult
  func restore(
    settings: SystemProxySettings,
    mixedPort: Int,
    disableWhenNoSnapshot: Bool
  ) async throws -> SystemProxyRestoreResult {
    stopGuard()
    let result = try await controller.restoreAndVerify(
      hosts: Self.localProxyHosts(for: settings),
      ports: [mixedPort],
      disableWhenNoSnapshot: disableWhenNoSnapshot
    )
    if !controller.hasManagedSystemProxyState {
      markManaged(false)
    }
    enabled = false
    return result
  }

  func recoverDanglingIfNeeded(
    settingsProvider: @escaping @MainActor () -> (settings: SystemProxySettings, mixedPort: Int),
    onRecovered: @escaping @MainActor () -> Void,
    onError: @escaping @MainActor (Error) -> Void
  ) {
    guard defaults.bool(forKey: Self.managedDefaultsKey) else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let values = settingsProvider()
        let result = try await restore(
          settings: values.settings,
          mixedPort: values.mixedPort,
          disableWhenNoSnapshot: false
        )
        if result.didFallbackDisable {
          onRecovered()
        }
      } catch {
        onError(error)
      }
    }
  }

  private func startGuardLoop(
    intervalSeconds: Int,
    onWarning: @escaping @MainActor (String) -> Void,
    onError: @escaping @MainActor (Error) -> Void
  ) {
    guardTask?.cancel()
    guardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let result = try await controller.verifyGuardOnceDetailed()
          for warning in result.warnings {
            onWarning(warning)
          }
        } catch is CancellationError {
          return
        } catch {
          onError(error)
        }
        let delay = UInt64(intervalSeconds) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private func markManaged(_ isManaged: Bool) {
    defaults.set(isManaged, forKey: Self.managedDefaultsKey)
  }

  private static func localProxyHosts(for settings: SystemProxySettings) -> Set<String> {
    let rawProxyHost = settings.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
    var hosts = [settings.normalizedProxyHost, "127.0.0.1", "localhost", "::1"]
    if !rawProxyHost.isEmpty, !SystemProxySettings.isUnspecifiedBindHost(rawProxyHost) {
      hosts.append(rawProxyHost)
    }
    return Set(hosts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }
}
