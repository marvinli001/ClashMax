import Foundation

/// Where the runtime lifecycle stands, as far as a Shortcuts action needs to know.
enum ClashMaxIntentLifecyclePhase: Equatable, Sendable {
  case stopped
  /// A start, stop or restart is in flight.
  case transitioning
  /// `session` changes on every successful start, which is how a restart is told apart from the
  /// run it replaced.
  case running(session: Date?)
  case crashed(String)
  /// Nothing is running, but something still needs a stop — a TUN helper that never confirmed it
  /// stopped, or a Network Extension tunnel that is still up.
  case stopIncomplete
}

struct ClashMaxIntentProfile: Equatable, Sendable {
  var id: UUID
  var name: String
  var isActive: Bool
}

/// A Shortcuts action that could not do what it was asked. The message is already localized and is
/// shown to the user verbatim, so it has to name the cause and what to do about it.
struct ClashMaxIntentError: LocalizedError, Equatable {
  var message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}

/// On, off, or flip whatever it is now.
enum ClashMaxToggleAction: String, CaseIterable, Sendable {
  case turnOn
  case turnOff
  case toggle

  func resolvedTarget(current: Bool) -> Bool {
    switch self {
    case .turnOn: true
    case .turnOff: false
    case .toggle: !current
    }
  }
}

/// The runtime as a Shortcuts action sees it: a read-mostly view of `AppModel` plus the awaited
/// entry points the actions call. A fake implementation drives every branch in tests.
@MainActor
protocol ClashMaxIntentControlling: AnyObject {
  var intentLifecyclePhase: ClashMaxIntentLifecyclePhase { get }
  var lastError: String? { get }
  /// Why the runtime cannot start, apart from the TUN helper: no active profile, no bundled core.
  var intentStartBlocker: String? { get }
  var intentTunHelperStage: HelperSetupStage { get }
  var proxyRoutingMode: ProxyRoutingMode { get }
  var systemProxyEnabled: Bool { get }
  var intentProfiles: [ClashMaxIntentProfile] { get }
  /// The running core's groups; empty whenever the core is not running.
  var intentProxyGroups: [ProxyGroup] { get }

  func start()
  func stop()
  func restart()
  /// Confirms the helper answers over XPC. `nil` when TUN can start, otherwise why it cannot.
  func prepareTunHelperForIntent() async -> String?
  func setSystemProxyEnabledForIntent(_ enabled: Bool) async throws
  func setProxyRoutingModeForIntent(_ mode: ProxyRoutingMode) async throws
  func selectProfileForIntent(id: UUID) async throws
  func selectProxyForIntent(groupName: String, nodeName: String) async throws
  func updateAllSubscriptionsForIntent() async -> SubscriptionUpdateBatchReport
  func applyCurrentNetworkPolicyForIntent() async -> NetworkPolicyApplyOutcome
}

/// Everything a Shortcuts action does, minus the App Intents types (roadmap B3). Every operation
/// either returns the sentence the action shows on success or throws a `ClashMaxIntentError` naming
/// the failure; none of them returns before the operation it started has settled.
@MainActor
struct ClashMaxIntentExecutor {
  struct Timing: Sendable {
    var pollInterval: Duration
    /// How long a start, stop or restart may take before the action gives up waiting. The start
    /// sequence has its own 22 s wall clock, and a TUN restart adds a helper round trip on top.
    var lifecycleTimeout: Duration

    static let standard = Timing(pollInterval: .milliseconds(100), lifecycleTimeout: .seconds(45))
  }

  let controller: any ClashMaxIntentControlling
  var timing: Timing = .standard
  var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  // MARK: Lifecycle

  func start() async throws -> String {
    if case .running = controller.intentLifecyclePhase {
      return String(localized: "ClashMax is already running.")
    }
    try await requireStartable(routingMode: controller.proxyRoutingMode)
    controller.start()
    try await waitUntilRunning(replacing: nil, failure: String(localized: "ClashMax did not start."))
    return String(format: String(localized: "ClashMax is running in %@ mode."), controller.proxyRoutingMode.displayName)
  }

  func stop() async throws -> String {
    if controller.intentLifecyclePhase == .stopped {
      return String(localized: "ClashMax is already stopped.")
    }
    controller.stop()
    try await waitUntilStopped()
    return String(localized: "ClashMax stopped.")
  }

  func restart() async throws -> String {
    guard case let .running(session) = controller.intentLifecyclePhase else {
      _ = try await start()
      return String(localized: "ClashMax was not running, so it was started.")
    }
    try await requireStartable(routingMode: controller.proxyRoutingMode)
    controller.restart()
    try await waitUntilRunning(replacing: session, failure: String(localized: "ClashMax did not come back after the restart."))
    return String(localized: "ClashMax restarted.")
  }

  // MARK: Routing

  func setSystemProxy(_ action: ClashMaxToggleAction) async throws -> String {
    let current = controller.systemProxyEnabled
    let target = action.resolvedTarget(current: current)
    guard target != current else {
      return target
        ? String(localized: "System Proxy is already on.")
        : String(localized: "System Proxy is already off.")
    }
    // The app disables this switch outside System Proxy routing; the action refuses for the same
    // reason rather than quietly changing the routing mode underneath the user.
    guard controller.proxyRoutingMode == .systemProxy else {
      throw ClashMaxIntentError(String(
        format: String(localized: "System Proxy can only be changed in System Proxy routing mode. ClashMax is using %@."),
        controller.proxyRoutingMode.displayName
      ))
    }
    try await controller.setSystemProxyEnabledForIntent(target)
    guard controller.systemProxyEnabled == target else {
      throw ClashMaxIntentError(controller.lastError ?? String(localized: "ClashMax could not change the System Proxy."))
    }
    guard target else {
      return String(localized: "System Proxy is off.")
    }
    if case .running = controller.intentLifecyclePhase {
      return String(localized: "System Proxy is on.")
    }
    return String(localized: "System Proxy is on, but ClashMax is not running, so traffic will fail until you start it.")
  }

  func setRoutingMode(_ mode: ProxyRoutingMode) async throws -> String {
    guard controller.proxyRoutingMode != mode else {
      return String(format: String(localized: "Routing mode is already %@."), mode.displayName)
    }
    if mode == .tun {
      try await requireTunHelper()
    }
    let phaseBefore = controller.intentLifecyclePhase
    try await controller.setProxyRoutingModeForIntent(mode)
    guard controller.proxyRoutingMode == mode else {
      throw ClashMaxIntentError(controller.lastError ?? String(
        format: String(localized: "ClashMax could not switch to %@."),
        mode.displayName
      ))
    }
    guard case let .running(session) = phaseBefore else {
      return String(
        format: String(localized: "Routing mode set to %@. It takes effect the next time ClashMax starts."),
        mode.displayName
      )
    }
    // Into TUN, the restart only happens once the helper answers; if it never does, the old run
    // keeps going and only the helper state says why.
    try await waitUntilRunning(
      replacing: session,
      failure: String(format: String(localized: "ClashMax switched to %@ but did not come back up."), mode.displayName),
      abortsOnHelperFailure: mode == .tun
    )
    return String(format: String(localized: "Switched to %@ and restarted ClashMax."), mode.displayName)
  }

  /// TUN is a routing mode, so "off" means back to System Proxy, the mode that needs no helper.
  func setTun(_ action: ClashMaxToggleAction) async throws -> String {
    let isOn = controller.proxyRoutingMode == .tun
    let target = action.resolvedTarget(current: isOn)
    guard target != isOn else {
      return target ? String(localized: "TUN is already on.") : String(localized: "TUN is already off.")
    }
    return try await setRoutingMode(target ? .tun : .systemProxy)
  }

  // MARK: Profiles and nodes

  func profileOptions() -> [ClashMaxIntentProfile] {
    controller.intentProfiles
  }

  func selectProfile(id: UUID) async throws -> String {
    guard let profile = controller.intentProfiles.first(where: { $0.id == id }) else {
      throw ClashMaxIntentError(String(localized: "That profile no longer exists in ClashMax."))
    }
    guard !profile.isActive else {
      return String(format: String(localized: "%@ is already the active profile."), profile.name)
    }
    let phaseBefore = controller.intentLifecyclePhase
    try await controller.selectProfileForIntent(id: id)
    guard case let .running(session) = phaseBefore else {
      return String(format: String(localized: "Switched to %@."), profile.name)
    }
    try await waitUntilRunning(
      replacing: session,
      failure: String(format: String(localized: "Switched to %@, but ClashMax did not come back up."), profile.name)
    )
    return String(format: String(localized: "Switched to %@ and restarted ClashMax."), profile.name)
  }

  /// Groups a node can be picked in by hand: `select` groups on the running core.
  func selectableGroups() -> [ProxyGroup] {
    controller.intentProxyGroups.filter(\.allowsManualProxySelection)
  }

  func selectableNodes(inGroup groupName: String) -> [ProxyNode] {
    selectableGroups().first { $0.name == groupName }?.nodes.filter(\.isSelectable) ?? []
  }

  func selectNode(_ nodeName: String, inGroup groupName: String) async throws -> String {
    guard case .running = controller.intentLifecyclePhase else {
      throw ClashMaxIntentError(String(localized: "ClashMax is not running. Start it before selecting a node."))
    }
    guard let group = controller.intentProxyGroups.first(where: { $0.name == groupName }) else {
      throw ClashMaxIntentError(String(format: String(localized: "The running profile has no proxy group named %@."), groupName))
    }
    guard group.allowsManualProxySelection else {
      throw ClashMaxIntentError(String(
        format: String(localized: "%@ is a %@ group, which Mihomo manages automatically. Only select groups take a manual choice."),
        group.name,
        group.type
      ))
    }
    guard let node = group.nodes.first(where: { $0.name == nodeName }) else {
      throw ClashMaxIntentError(String(format: String(localized: "%@ has no node named %@."), group.name, nodeName))
    }
    guard node.isSelectable else {
      throw ClashMaxIntentError(String(format: String(localized: "%@ cannot be selected from the runtime."), node.name))
    }
    guard group.selected != node.name else {
      return String(format: String(localized: "%@ is already selected in %@."), node.name, group.name)
    }
    try await controller.selectProxyForIntent(groupName: group.name, nodeName: node.name)
    return String(format: String(localized: "Selected %@ in %@."), node.name, group.name)
  }

  // MARK: Subscriptions and network policy

  func updateAllSubscriptions() async throws -> String {
    let report = await controller.updateAllSubscriptionsForIntent()
    if report.isEmpty {
      return String(localized: "There are no subscription profiles to update.")
    }
    var parts: [String] = []
    if !report.updated.isEmpty {
      parts.append(String(format: String(localized: "Updated %@."), Self.list(report.updated)))
    }
    if !report.skipped.isEmpty {
      parts.append(String(format: String(localized: "Skipped %@: an update was already running."), Self.list(report.skipped)))
    }
    for failure in report.failed {
      parts.append(String(format: String(localized: "%@ failed: %@"), failure.profileName, failure.message))
    }
    let summary = parts.joined(separator: " ")
    guard report.failed.isEmpty else {
      throw ClashMaxIntentError(summary)
    }
    return summary
  }

  func applyCurrentNetworkPolicy() async throws -> String {
    switch await controller.applyCurrentNetworkPolicyForIntent() {
    case let .applied(message), let .restored(message), let .nothingToApply(message):
      return message
    case let .failed(message):
      throw ClashMaxIntentError(message)
    case .cancelled:
      throw ClashMaxIntentError(String(localized: "A newer network change replaced this policy before it finished applying."))
    }
  }

  // MARK: Preconditions and waiting

  private func requireStartable(routingMode: ProxyRoutingMode) async throws {
    if let blocker = controller.intentStartBlocker {
      throw ClashMaxIntentError(blocker)
    }
    if routingMode == .tun {
      try await requireTunHelper()
    }
  }

  /// The same guidance the helper setup sheet shows for the step it is waiting on, then a live XPC
  /// check once macOS reports the helper enabled.
  private func requireTunHelper() async throws {
    if let guidance = controller.intentTunHelperStage.guidanceMessage {
      throw ClashMaxIntentError(Self.helperFailure(guidance))
    }
    if let failure = await controller.prepareTunHelperForIntent() {
      throw ClashMaxIntentError(Self.helperFailure(failure))
    }
  }

  private static func helperFailure(_ detail: String) -> String {
    String(
      format: String(localized: "TUN needs the ClashMax privileged helper, which is not ready. %@ Open ClashMax to finish the setup."),
      detail
    )
  }

  private var maximumPolls: Int {
    max(1, Int(timing.lifecycleTimeout / timing.pollInterval))
  }

  /// Waits for a run that is not `replaced` — any run when `replaced` is nil. The first reading is
  /// never taken as a failure: it can predate the request the caller just made.
  private func waitUntilRunning(
    replacing replaced: Date?,
    failure: String,
    abortsOnHelperFailure: Bool = false
  ) async throws {
    for poll in 0...maximumPolls {
      if poll > 0, abortsOnHelperFailure, let guidance = controller.intentTunHelperStage.guidanceMessage {
        throw ClashMaxIntentError(Self.helperFailure(guidance))
      }
      switch controller.intentLifecyclePhase {
      case let .running(session):
        if replaced == nil || session != replaced {
          return
        }
      case let .crashed(message):
        throw ClashMaxIntentError("\(failure) \(message)")
      case .stopped, .stopIncomplete:
        if poll > 0 {
          throw ClashMaxIntentError(controller.lastError.map { "\(failure) \($0)" } ?? failure)
        }
      case .transitioning:
        break
      }
      if poll < maximumPolls {
        try await sleep(timing.pollInterval)
      }
    }
    throw ClashMaxIntentError(Self.timeoutMessage)
  }

  private func waitUntilStopped() async throws {
    for poll in 0...maximumPolls {
      switch controller.intentLifecyclePhase {
      case .stopped, .crashed:
        return
      case .running, .stopIncomplete:
        if poll > 0 {
          throw ClashMaxIntentError(controller.lastError ?? String(localized: "ClashMax could not stop the runtime."))
        }
      case .transitioning:
        break
      }
      if poll < maximumPolls {
        try await sleep(timing.pollInterval)
      }
    }
    throw ClashMaxIntentError(Self.timeoutMessage)
  }

  private static var timeoutMessage: String {
    String(localized: "ClashMax is still working on it. Open ClashMax to see where it stands.")
  }

  private static func list(_ names: [String]) -> String {
    ListFormatter.localizedString(byJoining: names)
  }
}
