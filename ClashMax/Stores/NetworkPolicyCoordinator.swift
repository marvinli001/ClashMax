import Foundation

/// Which network the Mac is on, and the saved per-SSID policies applied when it changes: the
/// environment monitor, its debounce, the Wi-Fi/Location authorization wiring, and the
/// apply/restore tasks. Split out of `AppModel` (roadmap D1); `AppModel` keeps the same members as
/// facades over this coordinator, so views and tests read them unchanged.
///
/// The runtime changes a policy makes (routing mode, start, system proxy, stop) stay on `AppModel`
/// and are reached through `configureRuntimeHooks`, so nothing here holds a reference back to it.
@MainActor
@Observable
final class NetworkPolicyCoordinator {
  private(set) var currentNetwork: WiFiNetworkSnapshot = .notChecked
  private(set) var networkPolicyStatusMessage: String?
  private(set) var lastAppliedNetworkPolicyID: NetworkPolicyRule.ID?
  @ObservationIgnored private var networkPolicyApplyTask: Task<NetworkPolicyApplyOutcome, Never>?
  @ObservationIgnored private var networkPolicyApplyToken: UUID?
  @ObservationIgnored private(set) var networkPolicyRestoreSnapshot: NetworkPolicyRestoreSnapshot?
  @ObservationIgnored private var networkEnvironmentTask: Task<Void, Never>?
  @ObservationIgnored private var networkEnvironmentDebounceTask: Task<Void, Never>?
  private let settings: PersistedSettingsStore
  private let currentNetworkProvider: any CurrentNetworkProviding
  private let networkEnvironmentMonitor: (any NetworkEnvironmentMonitoring)?
  /// `nil` in tests, where no `CLLocationManager` should be created.
  @ObservationIgnored private let wiFiLocationAuthorization: WiFiLocationAuthorization?
  @ObservationIgnored private var hooks = NetworkPolicyRuntimeHooks()

  init(
    settings: PersistedSettingsStore,
    currentNetworkProvider: any CurrentNetworkProviding,
    networkEnvironmentMonitor: (any NetworkEnvironmentMonitoring)?,
    wiFiLocationAuthorization: WiFiLocationAuthorization?
  ) {
    self.settings = settings
    self.currentNetworkProvider = currentNetworkProvider
    self.networkEnvironmentMonitor = networkEnvironmentMonitor
    self.wiFiLocationAuthorization = wiFiLocationAuthorization
  }

  func configureRuntimeHooks(
    isRunning: @escaping () -> Bool,
    startInFlight: @escaping () -> Bool,
    canStopRuntime: @escaping () -> Bool,
    proxyRoutingMode: @escaping () -> ProxyRoutingMode,
    systemProxyEnabled: @escaping () -> Bool,
    setProxyRoutingMode: @escaping (ProxyRoutingMode, Bool) -> Void,
    startRuntimeAndWait: @escaping () async -> Void,
    applySystemProxyEnabledState: @escaping (Bool) async throws -> Void,
    stopRuntime: @escaping () async -> NetworkPolicyRuntimeStopResult,
    setLastError: @escaping (String?) -> Void,
    publishNotice: @escaping (AppNotice) -> Void,
    publishWarningNotice: @escaping (String) -> Void,
    appendAppLog: @escaping (String, String) -> Void,
    recordNetworkEnvironmentChange: @escaping () -> Void
  ) {
    hooks = NetworkPolicyRuntimeHooks(
      isRunning: isRunning,
      startInFlight: startInFlight,
      canStopRuntime: canStopRuntime,
      proxyRoutingMode: proxyRoutingMode,
      systemProxyEnabled: systemProxyEnabled,
      setProxyRoutingMode: setProxyRoutingMode,
      startRuntimeAndWait: startRuntimeAndWait,
      applySystemProxyEnabledState: applySystemProxyEnabledState,
      stopRuntime: stopRuntime,
      setLastError: setLastError,
      publishNotice: publishNotice,
      publishWarningNotice: publishWarningNotice,
      appendAppLog: appendAppLog,
      recordNetworkEnvironmentChange: recordNetworkEnvironmentChange
    )
  }

  private var networkPolicySettings: NetworkPolicySettings {
    settings.networkPolicySettings
  }

  /// Granting Location access is what makes CWInterface.ssid() readable, so the SSID has to be
  /// re-read the moment authorization flips rather than on the next network change (issue #26).
  func observeWiFiLocationAuthorization() {
    wiFiLocationAuthorization?.onStatusChange = { [weak self] _ in
      self?.handleWiFiLocationAuthorizationChange()
    }
  }

  func refreshCurrentNetworkPolicyState() {
    wiFiLocationAuthorization?.refresh()
    let snapshot = currentNetworkProvider.currentNetwork()
    currentNetwork = snapshot
    networkPolicyStatusMessage = NetworkPolicyStatusPresenter.message(
      for: snapshot,
      matchedRule: snapshot.ssid.flatMap(networkPolicySettings.matchingRule(ssid:))
    )
  }

  /// Runs the recovery action the Network Policies panel is currently offering.
  ///
  /// Raises the macOS location prompt when it can still appear, and otherwise deep-links into
  /// Privacy & Security → Location Services.
  func resolveCurrentNetworkSSIDAvailability() {
    guard let wiFiLocationAuthorization else { return }
    switch currentNetwork.recoveryAction {
    case .requestLocationAuthorization:
      if !wiFiLocationAuthorization.requestAuthorizationIfPossible() {
        wiFiLocationAuthorization.openLocationSettings()
      }
      hooks.appendAppLog("info", "Requested Location Services access to read the Wi-Fi SSID.")
    case .openLocationSettings:
      wiFiLocationAuthorization.openLocationSettings()
    case .none:
      refreshCurrentNetworkPolicyState()
    }
  }

  private func handleWiFiLocationAuthorizationChange() {
    let previous = currentNetwork
    refreshCurrentNetworkPolicyState()
    guard previous.isBlockedByLocationAuthorization, currentNetwork.ssid != nil else { return }
    hooks.appendAppLog(
      "info",
      "Location Services access granted; Wi-Fi SSID is now readable."
    )
    handleNetworkEnvironmentMayHaveChanged(reason: "location-authorization")
  }

  func applyMatchingNetworkPolicyForCurrentNetwork() {
    applyMatchingNetworkPolicyForCurrentNetwork(trigger: "manual")
  }

  func handleNetworkEnvironmentMayHaveChanged(reason: String) {
    guard networkPolicySettings.autoApplyEnabled else {
      networkPolicyStatusMessage = String(localized: "Automatic network policy application is off.")
      return
    }
    guard !networkPolicySettings.rules.isEmpty else { return }
    scheduleNetworkEnvironmentPolicyApply(reason: reason)
  }

  func startNetworkEnvironmentMonitoring() {
    guard networkEnvironmentTask == nil, let networkEnvironmentMonitor else { return }
    // Saved policies are keyed by SSID, so auto-apply is dead without Location access. Prompt only
    // when there is actually a policy to match, so users who never configured one are never asked.
    if networkPolicySettings.autoApplyEnabled, !networkPolicySettings.rules.isEmpty {
      wiFiLocationAuthorization?.requestAuthorizationIfPossible()
    }
    networkEnvironmentMonitor.start()
    networkEnvironmentTask = Task { @MainActor [weak self, networkEnvironmentMonitor] in
      for await event in networkEnvironmentMonitor.events {
        guard let self, !Task.isCancelled else { return }
        currentNetwork = event.network.ssid == nil && event.network.unavailableReason == nil
          ? currentNetworkProvider.currentNetwork()
          : event.network
        hooks.appendAppLog(
          "info",
          "Network environment changed via \(event.reason): path=\(event.pathStatus), ssid=\(currentNetwork.ssid ?? currentNetwork.unavailableReason?.rawValue ?? "none")"
        )
        // Stamped here rather than inside `handleNetworkEnvironmentMayHaveChanged`, which returns
        // early when auto-apply is off: the fake-ip table goes stale on a network change whether or
        // not a policy is waiting to be applied (roadmap A3).
        hooks.recordNetworkEnvironmentChange()
        handleNetworkEnvironmentMayHaveChanged(reason: event.reason)
      }
    }
  }

  func stopNetworkEnvironmentMonitoring() {
    networkEnvironmentDebounceTask?.cancel()
    networkEnvironmentDebounceTask = nil
    networkEnvironmentTask?.cancel()
    networkEnvironmentTask = nil
    networkEnvironmentMonitor?.stop()
  }

  func applyNetworkPolicy(_ rule: NetworkPolicyRule) {
    clearNetworkPolicyRestoreSnapshotForUserChange()
    applyNetworkPolicy(rule, trigger: "manual", matchedSSID: nil)
  }

  /// Applies the current network's policy and returns the outcome, awaited. The fire-and-forget
  /// `applyMatchingNetworkPolicyForCurrentNetwork()` reports through the Settings status line; a
  /// Shortcuts action has nowhere to read that from, so it waits for this instead (roadmap B3).
  func applyMatchingNetworkPolicyForCurrentNetworkAndWait() async -> NetworkPolicyApplyOutcome {
    switch applyMatchingNetworkPolicyForCurrentNetwork(trigger: "manual") {
    case let .finished(outcome):
      return outcome
    case let .pending(task):
      return await task.value
    }
  }

  @discardableResult
  private func applyMatchingNetworkPolicyForCurrentNetwork(trigger: String) -> NetworkPolicyApplyDispatch {
    let snapshot = currentNetworkProvider.currentNetwork()
    currentNetwork = snapshot
    guard let ssid = snapshot.ssid else {
      let message = NetworkPolicyStatusPresenter.unavailableMessage(snapshot.unavailableReason)
      networkPolicyStatusMessage = message
      // A permission gap means the network is *unknown*, not that the user left the previous one.
      // Restoring here would silently undo the routing the last matched policy set up (issue #26).
      guard !snapshot.isBlockedByLocationAuthorization else {
        hooks.appendAppLog(
          "warn",
          "Skipped network policy matching via \(trigger): \(snapshot.unavailableReason?.rawValue ?? "unknown")."
        )
        if trigger == "manual" {
          hooks.publishWarningNotice(message)
        }
        return .finished(.failed(message))
      }
      if let restore = restoreNetworkPolicyStateIfNeeded(reason: message) {
        return .pending(restore)
      }
      if trigger == "manual" {
        hooks.publishNotice(AppNotice(message: message, tone: .info))
      }
      return .finished(.nothingToApply(message))
    }
    guard let rule = networkPolicySettings.matchingRule(ssid: ssid) else {
      let message = String(format: String(localized: "No saved policy matches %@."), ssid)
      networkPolicyStatusMessage = message
      if let restore = restoreNetworkPolicyStateIfNeeded(reason: message) {
        return .pending(restore)
      }
      if trigger == "manual" {
        hooks.publishNotice(AppNotice(message: message, tone: .info))
      }
      return .finished(.nothingToApply(message))
    }
    return .pending(applyNetworkPolicy(rule, trigger: trigger, matchedSSID: ssid))
  }

  private func scheduleNetworkEnvironmentPolicyApply(reason: String) {
    networkEnvironmentDebounceTask?.cancel()
    networkEnvironmentDebounceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: 650_000_000)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      applyMatchingNetworkPolicyForCurrentNetwork(trigger: reason)
    }
  }

  @discardableResult
  private func applyNetworkPolicy(
    _ rule: NetworkPolicyRule,
    trigger: String,
    matchedSSID: String?
  ) -> Task<NetworkPolicyApplyOutcome, Never> {
    networkPolicyApplyTask?.cancel()
    let token = UUID()
    networkPolicyApplyToken = token
    let task = Task { @MainActor [weak self] () -> NetworkPolicyApplyOutcome in
      guard let self else { return .cancelled }
      defer {
        if self.networkPolicyApplyToken == token {
          self.networkPolicyApplyTask = nil
          self.networkPolicyApplyToken = nil
        }
      }
      guard !Task.isCancelled else { return .cancelled }
      return await applyNetworkPolicyRule(rule, trigger: trigger, matchedSSID: matchedSSID)
    }
    networkPolicyApplyTask = task
    return task
  }

  private func applyNetworkPolicyRule(
    _ rule: NetworkPolicyRule,
    trigger: String,
    matchedSSID: String?
  ) async -> NetworkPolicyApplyOutcome {
    if let validationError = rule.validationError {
      networkPolicyStatusMessage = validationError
      hooks.publishWarningNotice(validationError)
      return .failed(validationError)
    }

    let automatic = trigger != "manual"
    let policyStartedRuntime = rule.autoStartRuntime && !hooks.isRunning() && !hooks.startInFlight()
    if automatic, networkPolicySettings.unmatchedBehavior == .restorePreviousState, networkPolicyRestoreSnapshot == nil {
      networkPolicyRestoreSnapshot = NetworkPolicyRestoreSnapshot(
        policyID: rule.id,
        ssid: matchedSSID ?? rule.ssid,
        proxyRoutingMode: hooks.proxyRoutingMode(),
        systemProxyEnabled: hooks.systemProxyEnabled(),
        runtimeWasRunning: hooks.isRunning() || hooks.startInFlight() || hooks.canStopRuntime(),
        policyStartedRuntime: policyStartedRuntime
      )
    }

    hooks.setProxyRoutingMode(rule.proxyRoutingMode, automatic)
    if rule.autoStartRuntime, !hooks.isRunning(), !hooks.startInFlight() {
      await hooks.startRuntimeAndWait()
    }
    if rule.proxyRoutingMode == .systemProxy, rule.enableSystemProxy {
      do {
        try await hooks.applySystemProxyEnabledState(true)
      } catch {
        let message = UserFacingError.message(for: error)
        networkPolicyStatusMessage = message
        hooks.setLastError(message)
        return .failed(message)
      }
    }
    guard !Task.isCancelled else { return .cancelled }

    lastAppliedNetworkPolicyID = rule.id
    let message: String
    if let matchedSSID {
      message = String(
        format: String(localized: "Applied %@ for %@."),
        rule.name,
        matchedSSID
      )
    } else {
      message = String(format: String(localized: "Applied %@."), rule.name)
    }
    networkPolicyStatusMessage = message
    hooks.publishNotice(AppNotice(message: message, tone: .success))
    hooks.appendAppLog(
      "info",
      "Applied network policy \(rule.name) via \(trigger): \(rule.proxyRoutingMode.rawValue), autoStart=\(rule.autoStartRuntime)"
    )
    return .applied(message)
  }

  /// Schedules the restore of the state a matched policy replaced, or returns `nil` when there is
  /// nothing to restore.
  @discardableResult
  private func restoreNetworkPolicyStateIfNeeded(reason: String) -> Task<NetworkPolicyApplyOutcome, Never>? {
    guard networkPolicySettings.unmatchedBehavior == .restorePreviousState,
          let snapshot = networkPolicyRestoreSnapshot
    else { return nil }
    networkPolicyApplyTask?.cancel()
    let token = UUID()
    networkPolicyApplyToken = token
    let task = Task { @MainActor [weak self] () -> NetworkPolicyApplyOutcome in
      guard let self else { return .cancelled }
      defer {
        if self.networkPolicyApplyToken == token {
          self.networkPolicyApplyTask = nil
          self.networkPolicyApplyToken = nil
        }
      }
      return await restoreNetworkPolicyState(snapshot, reason: reason)
    }
    networkPolicyApplyTask = task
    return task
  }

  private func restoreNetworkPolicyState(
    _ snapshot: NetworkPolicyRestoreSnapshot,
    reason: String
  ) async -> NetworkPolicyApplyOutcome {
    hooks.setProxyRoutingMode(snapshot.proxyRoutingMode, true)
    do {
      if hooks.systemProxyEnabled() != snapshot.systemProxyEnabled {
        try await hooks.applySystemProxyEnabledState(snapshot.systemProxyEnabled)
      }
      if snapshot.policyStartedRuntime, !snapshot.runtimeWasRunning, hooks.canStopRuntime() {
        let result = await hooks.stopRuntime()
        guard result.succeeded else {
          networkPolicyStatusMessage = result.userFacingMessage
          hooks.setLastError(result.userFacingMessage)
          return .failed(result.userFacingMessage ?? String(localized: "ClashMax could not stop the runtime."))
        }
      }
      networkPolicyRestoreSnapshot = nil
      lastAppliedNetworkPolicyID = nil
      let message = String(
        format: String(localized: "%@ Restored previous network state after leaving %@."),
        reason,
        snapshot.ssid
      )
      networkPolicyStatusMessage = message
      hooks.publishNotice(AppNotice(message: message, tone: .info))
      hooks.appendAppLog("info", "Restored network policy state after leaving \(snapshot.ssid).")
      return .restored(message)
    } catch {
      let message = UserFacingError.message(for: error)
      networkPolicyStatusMessage = message
      hooks.setLastError(message)
      return .failed(message)
    }
  }

  func clearNetworkPolicyRestoreSnapshotForUserChange() {
    networkPolicyRestoreSnapshot = nil
  }
}

/// What a coordinated runtime stop reported, reduced to what the restore path branches on.
struct NetworkPolicyRuntimeStopResult {
  var succeeded: Bool
  var userFacingMessage: String?
}

private struct NetworkPolicyRuntimeHooks {
  var isRunning: () -> Bool = { false }
  var startInFlight: () -> Bool = { false }
  var canStopRuntime: () -> Bool = { false }
  var proxyRoutingMode: () -> ProxyRoutingMode = { .systemProxy }
  var systemProxyEnabled: () -> Bool = { false }
  /// The `Bool` is `preserveNetworkPolicyRestoreSnapshotOnRestart`.
  var setProxyRoutingMode: (ProxyRoutingMode, Bool) -> Void = { _, _ in }
  var startRuntimeAndWait: () async -> Void = {}
  var applySystemProxyEnabledState: (Bool) async throws -> Void = { _ in }
  var stopRuntime: () async -> NetworkPolicyRuntimeStopResult = {
    NetworkPolicyRuntimeStopResult(succeeded: true)
  }

  var setLastError: (String?) -> Void = { _ in }
  var publishNotice: (AppNotice) -> Void = { _ in }
  var publishWarningNotice: (String) -> Void = { _ in }
  var appendAppLog: (String, String) -> Void = { _, _ in }
  var recordNetworkEnvironmentChange: () -> Void = {}
}
