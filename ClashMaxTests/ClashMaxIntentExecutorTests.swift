@testable import ClashMax
import Foundation
import XCTest

/// Roadmap B3: every Shortcuts action reports success or a specific failure. The App Intents
/// structs are thin wrappers, so the behavior lives in `ClashMaxIntentExecutor` and is driven here
/// through a scripted controller: each poll the executor makes advances the lifecycle one step.
@MainActor
final class ClashMaxIntentExecutorTests: XCTestCase {
  private let earlier = Date(timeIntervalSince1970: 1000)
  private let later = Date(timeIntervalSince1970: 2000)

  // MARK: Start

  func testStartWaitsForTheRuntimeAndNamesTheRoutingMode() async throws {
    let fake = FakeIntentController()
    fake.afterStart = [.transitioning, .transitioning, .running(session: later)]

    let message = try await executor(fake).start()

    XCTAssertEqual(fake.calls, ["start"])
    XCTAssertEqual(message, fmt("ClashMax is running in %@ mode.", ProxyRoutingMode.systemProxy.displayName))
  }

  func testStartWhenAlreadyRunningDoesNothing() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))

    let message = try await executor(fake).start()

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, String(localized: "ClashMax is already running."))
  }

  func testStartWithoutAnActiveProfileFailsBeforeStarting() async {
    let fake = FakeIntentController()
    fake.intentStartBlocker = "No active profile selected."

    await assertFails(try await executor(fake).start(), equals: "No active profile selected.")
    XCTAssertEqual(fake.calls, [])
  }

  func testStartReportsWhyTheCoreDidNotComeUp() async {
    let fake = FakeIntentController()
    fake.afterStart = [.transitioning, .stopped]
    fake.lastErrorAfterStart = "mihomo exited with code 1"

    await assertFails(
      try await executor(fake).start(),
      equals: "\(String(localized: "ClashMax did not start.")) mihomo exited with code 1"
    )
  }

  func testStartReportsACrash() async {
    let fake = FakeIntentController()
    fake.afterStart = [.transitioning, .crashed("controller never answered")]

    await assertFails(
      try await executor(fake).start(),
      equals: "\(String(localized: "ClashMax did not start.")) controller never answered"
    )
  }

  func testStartThatNeverSettlesTimesOutInsteadOfClaimingSuccess() async {
    let fake = FakeIntentController()
    fake.afterStart = [.transitioning]

    await assertFails(
      try await executor(fake).start(),
      equals: String(localized: "ClashMax is still working on it. Open ClashMax to see where it stands.")
    )
  }

  func testStartInTunModeGivesTheHelperSetupGuidanceForEveryUnreadyStage() async {
    let stages: [HelperSetupStage] = [
      .install,
      .approve,
      .relocate(.outsideApplications(folderName: "Downloads")),
      .relocate(.translocated),
      .failed("Helper registration failed: code 1"),
    ]
    for stage in stages {
      let fake = FakeIntentController(routingMode: .tun)
      fake.intentTunHelperStage = stage

      let guidance = try? XCTUnwrap(stage.guidanceMessage)
      await assertFails(
        try await executor(fake).start(),
        equals: helperFailure(guidance ?? "")
      )
      XCTAssertEqual(fake.calls, [], "\(stage)")
    }
  }

  func testStartInTunModeFailsWhenTheHelperDoesNotAnswer() async {
    let fake = FakeIntentController(routingMode: .tun)
    fake.helperPreparationFailure = "TUN helper is registered, but launchd cannot start it."

    await assertFails(
      try await executor(fake).start(),
      equals: helperFailure("TUN helper is registered, but launchd cannot start it.")
    )
    XCTAssertEqual(fake.calls, ["prepareTunHelper"])
  }

  func testStartInTunModeStartsOnceTheHelperAnswers() async throws {
    let fake = FakeIntentController(routingMode: .tun)
    fake.afterStart = [.running(session: later)]

    let message = try await executor(fake).start()

    XCTAssertEqual(fake.calls, ["prepareTunHelper", "start"])
    XCTAssertEqual(message, fmt("ClashMax is running in %@ mode.", ProxyRoutingMode.tun.displayName))
  }

  // MARK: Stop

  func testStopWaitsUntilStopped() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterStop = [.transitioning, .stopped]

    let message = try await executor(fake).stop()

    XCTAssertEqual(fake.calls, ["stop"])
    XCTAssertEqual(message, String(localized: "ClashMax stopped."))
  }

  func testStopWhenAlreadyStoppedDoesNothing() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).stop()

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, String(localized: "ClashMax is already stopped."))
  }

  func testStopThatLeavesTheHelperUnconfirmedFails() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterStop = [.transitioning, .stopIncomplete]
    fake.lastErrorAfterStop = "The TUN helper did not confirm it stopped."

    await assertFails(try await executor(fake).stop(), equals: "The TUN helper did not confirm it stopped.")
  }

  func testStopThatLeavesTheRuntimeRunningFails() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterStop = [.running(session: earlier)]

    await assertFails(try await executor(fake).stop(), equals: String(localized: "ClashMax could not stop the runtime."))
  }

  func testStopOfACrashedRuntimeCountsAsStopped() async throws {
    let fake = FakeIntentController(phase: .crashed("exit 2"))
    fake.afterStop = [.crashed("exit 2")]

    let message = try await executor(fake).stop()

    XCTAssertEqual(message, String(localized: "ClashMax stopped."))
  }

  // MARK: Restart

  func testRestartWaitsForANewRunNotTheOneItReplaced() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterRestart = [.running(session: earlier), .transitioning, .running(session: later)]

    let message = try await executor(fake).restart()

    XCTAssertEqual(fake.calls, ["restart"])
    XCTAssertEqual(message, String(localized: "ClashMax restarted."))
    XCTAssertEqual(fake.remainingScript, [])
  }

  func testRestartThatNeverReplacesTheRunTimesOut() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterRestart = [.running(session: earlier)]

    await assertFails(
      try await executor(fake).restart(),
      equals: String(localized: "ClashMax is still working on it. Open ClashMax to see where it stands.")
    )
  }

  func testRestartWhenStoppedStartsInstead() async throws {
    let fake = FakeIntentController()
    fake.afterStart = [.running(session: later)]

    let message = try await executor(fake).restart()

    XCTAssertEqual(fake.calls, ["start"])
    XCTAssertEqual(message, String(localized: "ClashMax was not running, so it was started."))
  }

  // MARK: System Proxy

  func testSystemProxyTurnsOnAndConfirmsTheResult() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))

    let message = try await executor(fake).setSystemProxy(.turnOn)

    XCTAssertEqual(fake.calls, ["systemProxy:true"])
    XCTAssertTrue(fake.systemProxyEnabled)
    XCTAssertEqual(message, String(localized: "System Proxy is on."))
  }

  func testSystemProxyOnWhileStoppedSaysTrafficWillFail() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).setSystemProxy(.toggle)

    XCTAssertEqual(
      message,
      String(localized: "System Proxy is on, but ClashMax is not running, so traffic will fail until you start it.")
    )
  }

  func testSystemProxyAlreadyInTheRequestedStateDoesNothing() async throws {
    let fake = FakeIntentController()
    fake.systemProxyEnabled = true

    let message = try await executor(fake).setSystemProxy(.turnOn)

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, String(localized: "System Proxy is already on."))
  }

  func testSystemProxyIsRefusedOutsideSystemProxyRouting() async {
    let fake = FakeIntentController(routingMode: .tun)

    await assertFails(
      try await executor(fake).setSystemProxy(.turnOn),
      equals: fmt(
        "System Proxy can only be changed in System Proxy routing mode. ClashMax is using %@.",
        ProxyRoutingMode.tun.displayName
      )
    )
    XCTAssertEqual(fake.calls, [])
  }

  func testSystemProxyFailureFromNetworksetupIsReported() async {
    let fake = FakeIntentController()
    fake.systemProxyError = ClashMaxIntentError("networksetup exited with status 4")

    await assertFails(try await executor(fake).setSystemProxy(.turnOn), equals: "networksetup exited with status 4")
  }

  func testSystemProxyThatDidNotChangeIsReportedAsAFailure() async {
    let fake = FakeIntentController()
    fake.systemProxyChangeSticks = false
    fake.lastErrorAfterSystemProxy = "Could not verify the System Proxy."

    await assertFails(try await executor(fake).setSystemProxy(.turnOn), equals: "Could not verify the System Proxy.")
  }

  // MARK: Routing mode and TUN

  func testRoutingModeSwitchWhileStoppedTakesEffectAtNextStart() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).setRoutingMode(.neProxy)

    XCTAssertEqual(fake.calls, ["routing:networkExtensionExperimental"])
    XCTAssertEqual(message, nextStart(.neProxy))
  }

  func testRoutingModeSwitchWhileRunningWaitsForTheRestart() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterRoutingSwitch = [.transitioning, .running(session: later)]

    let message = try await executor(fake).setRoutingMode(.neProxy)

    XCTAssertEqual(message, fmt("Switched to %@ and restarted ClashMax.", ProxyRoutingMode.neProxy.displayName))
  }

  func testRoutingModeAlreadyActiveDoesNothing() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).setRoutingMode(.systemProxy)

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, fmt("Routing mode is already %@.", ProxyRoutingMode.systemProxy.displayName))
  }

  func testRoutingModeIntoTunWithoutTheHelperGivesGuidanceAndDoesNotSwitch() async {
    let fake = FakeIntentController()
    fake.intentTunHelperStage = .approve

    await assertFails(
      try await executor(fake).setRoutingMode(.tun),
      contains: TunnelHelperClient.statusMessage(for: .requiresApproval)
    )
    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(fake.proxyRoutingMode, .systemProxy)
  }

  func testRoutingModeSwitchThatWasRefusedIsReported() async {
    let fake = FakeIntentController()
    fake.systemProxyEnabled = true
    fake.routingSwitchError = ClashMaxIntentError("Could not turn off the System Proxy: networksetup failed")

    await assertFails(
      try await executor(fake).setRoutingMode(.tun),
      equals: "Could not turn off the System Proxy: networksetup failed"
    )
  }

  func testRoutingModeSwitchThatSilentlyDidNotHappenIsReported() async {
    let fake = FakeIntentController()
    fake.routingSwitchSticks = false

    await assertFails(
      try await executor(fake).setRoutingMode(.neProxy),
      equals: fmt("ClashMax could not switch to %@.", ProxyRoutingMode.neProxy.displayName)
    )
  }

  func testSwitchIntoTunStopsWaitingWhenTheHelperFailsMidway() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.afterRoutingSwitch = [.running(session: earlier), .running(session: earlier)]
    fake.helperStageAfterRoutingSwitch = .failed("Helper connection was interrupted.")

    await assertFails(
      try await executor(fake).setRoutingMode(.tun),
      equals: helperFailure("Helper connection was interrupted.")
    )
  }

  func testTunOnSwitchesToTunRouting() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).setTun(.turnOn)

    XCTAssertEqual(fake.calls, ["prepareTunHelper", "routing:tun"])
    XCTAssertEqual(message, nextStart(.tun))
  }

  func testTunOffFallsBackToSystemProxyRouting() async throws {
    let fake = FakeIntentController(routingMode: .tun)

    let message = try await executor(fake).setTun(.turnOff)

    XCTAssertEqual(fake.calls, ["routing:systemProxy"])
    XCTAssertEqual(message, nextStart(.systemProxy))
  }

  func testTunToggleFlipsTheCurrentState() async throws {
    let fake = FakeIntentController(routingMode: .tun)

    _ = try await executor(fake).setTun(.toggle)

    XCTAssertEqual(fake.proxyRoutingMode, .systemProxy)
  }

  func testTunOffInNEProxyRoutingIsAlreadyOff() async throws {
    let fake = FakeIntentController(routingMode: .neProxy)

    let message = try await executor(fake).setTun(.turnOff)

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, String(localized: "TUN is already off."))
  }

  // MARK: Profiles

  func testSelectProfileWhileStopped() async throws {
    let target = ClashMaxIntentProfile(id: UUID(), name: "Work", isActive: false)
    let fake = FakeIntentController()
    fake.intentProfiles = [ClashMaxIntentProfile(id: UUID(), name: "Home", isActive: true), target]

    let message = try await executor(fake).selectProfile(id: target.id)

    XCTAssertEqual(fake.calls, ["profile:\(target.id)"])
    XCTAssertEqual(message, fmt("Switched to %@.", "Work"))
  }

  func testSelectProfileWhileRunningWaitsForTheRestart() async throws {
    let target = ClashMaxIntentProfile(id: UUID(), name: "Work", isActive: false)
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProfiles = [target]
    fake.afterProfileSwitch = [.transitioning, .running(session: later)]

    let message = try await executor(fake).selectProfile(id: target.id)

    XCTAssertEqual(message, fmt("Switched to %@ and restarted ClashMax.", "Work"))
  }

  func testSelectProfileThatRestartsIntoAFailureIsReported() async {
    let target = ClashMaxIntentProfile(id: UUID(), name: "Work", isActive: false)
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProfiles = [target]
    fake.afterProfileSwitch = [.transitioning, .stopped]
    fake.lastErrorAfterProfileSwitch = "proxy 0: '' has unset fields: cipher"

    await assertFails(
      try await executor(fake).selectProfile(id: target.id),
      equals: "\(fmt("Switched to %@, but ClashMax did not come back up.", "Work")) proxy 0: '' has unset fields: cipher"
    )
  }

  func testSelectProfileThatIsAlreadyActiveDoesNothing() async throws {
    let active = ClashMaxIntentProfile(id: UUID(), name: "Home", isActive: true)
    let fake = FakeIntentController()
    fake.intentProfiles = [active]

    let message = try await executor(fake).selectProfile(id: active.id)

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, fmt("%@ is already the active profile.", "Home"))
  }

  func testSelectProfileThatNoLongerExistsFails() async {
    let fake = FakeIntentController()

    await assertFails(
      try await executor(fake).selectProfile(id: UUID()),
      equals: String(localized: "That profile no longer exists in ClashMax.")
    )
  }

  func testSelectProfileFailureFromTheStoreIsReported() async {
    let target = ClashMaxIntentProfile(id: UUID(), name: "Work", isActive: false)
    let fake = FakeIntentController()
    fake.intentProfiles = [target]
    fake.profileSwitchError = ClashMaxIntentError("Profile file is missing.")

    await assertFails(try await executor(fake).selectProfile(id: target.id), equals: "Profile file is missing.")
  }

  // MARK: Nodes

  func testSelectNodeRequiresARunningCore() async {
    let fake = FakeIntentController()
    fake.intentProxyGroups = [Self.selectGroup]

    await assertFails(
      try await executor(fake).selectNode("Tokyo", inGroup: "Proxy"),
      equals: String(localized: "ClashMax is not running. Start it before selecting a node.")
    )
    XCTAssertEqual(fake.calls, [])
  }

  func testSelectNodeSelectsThroughTheController() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [Self.selectGroup]

    let message = try await executor(fake).selectNode("Tokyo", inGroup: "Proxy")

    XCTAssertEqual(fake.calls, ["node:Proxy/Tokyo"])
    XCTAssertEqual(message, fmt("Selected %@ in %@.", "Tokyo", "Proxy"))
  }

  func testSelectNodeRefusesAnAutomaticGroup() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [ProxyGroup(name: "Auto", type: "URLTest", selected: "Tokyo", nodes: Self.selectGroup.nodes)]

    await assertFails(
      try await executor(fake).selectNode("Osaka", inGroup: "Auto"),
      equals: fmt(
        "%@ is a %@ group, which Mihomo manages automatically. Only select groups take a manual choice.",
        "Auto",
        "URLTest"
      )
    )
  }

  func testSelectNodeReportsAMissingGroupOrNode() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [Self.selectGroup]

    await assertFails(
      try await executor(fake).selectNode("Tokyo", inGroup: "Streaming"),
      equals: fmt("The running profile has no proxy group named %@.", "Streaming")
    )
    await assertFails(
      try await executor(fake).selectNode("Paris", inGroup: "Proxy"),
      equals: fmt("%@ has no node named %@.", "Proxy", "Paris")
    )
  }

  func testSelectNodeRefusesAnUnselectableNode() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [Self.selectGroup]

    await assertFails(
      try await executor(fake).selectNode("REJECT", inGroup: "Proxy"),
      equals: fmt("%@ cannot be selected from the runtime.", "REJECT")
    )
  }

  func testSelectNodeAlreadySelectedDoesNothing() async throws {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [Self.selectGroup]

    let message = try await executor(fake).selectNode("Osaka", inGroup: "Proxy")

    XCTAssertEqual(fake.calls, [])
    XCTAssertEqual(message, fmt("%@ is already selected in %@.", "Osaka", "Proxy"))
  }

  func testSelectNodeFailureFromTheCoreIsReported() async {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [Self.selectGroup]
    fake.nodeSelectionError = ClashMaxIntentError("Mihomo API returned 400")

    await assertFails(try await executor(fake).selectNode("Tokyo", inGroup: "Proxy"), equals: "Mihomo API returned 400")
  }

  func testNodePickerOffersOnlySelectGroupsAndSelectableNodes() {
    let fake = FakeIntentController(phase: .running(session: earlier))
    fake.intentProxyGroups = [
      Self.selectGroup,
      ProxyGroup(name: "Auto", type: "URLTest", selected: nil, nodes: Self.selectGroup.nodes),
    ]

    let executor = executor(fake)

    XCTAssertEqual(executor.selectableGroups().map(\.name), ["Proxy"])
    XCTAssertEqual(executor.selectableNodes(inGroup: "Proxy").map(\.name), ["Tokyo", "Osaka"])
    XCTAssertEqual(executor.selectableNodes(inGroup: "Auto").map(\.name), [])
  }

  // MARK: Subscriptions

  func testUpdateSubscriptionsListsWhatWasUpdated() async throws {
    let fake = FakeIntentController()
    fake.subscriptionReport = SubscriptionUpdateBatchReport(updated: ["Home", "Work"])

    let message = try await executor(fake).updateAllSubscriptions()

    XCTAssertEqual(message, fmt("Updated %@.", ListFormatter.localizedString(byJoining: ["Home", "Work"])))
  }

  func testUpdateSubscriptionsWithNothingToUpdateSaysSo() async throws {
    let fake = FakeIntentController()

    let message = try await executor(fake).updateAllSubscriptions()

    XCTAssertEqual(message, String(localized: "There are no subscription profiles to update."))
  }

  func testUpdateSubscriptionsFailsWhenAnyProfileFailed() async {
    let fake = FakeIntentController()
    fake.subscriptionReport = SubscriptionUpdateBatchReport(
      updated: ["Home"],
      skipped: ["Travel"],
      failed: [.init(profileName: "Work", message: "HTTP 403")]
    )

    await assertFails(
      try await executor(fake).updateAllSubscriptions(),
      equals: [
        fmt("Updated %@.", "Home"),
        fmt("Skipped %@: an update was already running.", "Travel"),
        fmt("%@ failed: %@", "Work", "HTTP 403"),
      ].joined(separator: " ")
    )
  }

  // MARK: Network policy

  func testNetworkPolicyOutcomesThatChangedNothingOrSucceededAreReported() async throws {
    for outcome: NetworkPolicyApplyOutcome in [
      .applied("Applied Office for corpnet."),
      .restored("Restored previous network state."),
      .nothingToApply("No saved policy matches cafe."),
    ] {
      let fake = FakeIntentController()
      fake.networkPolicyOutcome = outcome

      let message = try await executor(fake).applyCurrentNetworkPolicy()

      switch outcome {
      case let .applied(expected), let .restored(expected), let .nothingToApply(expected):
        XCTAssertEqual(message, expected)
      case .failed, .cancelled:
        XCTFail("unreachable")
      }
    }
  }

  func testNetworkPolicyFailureAndSupersessionAreErrors() async {
    let fake = FakeIntentController()
    fake.networkPolicyOutcome = .failed("ClashMax needs Location Services to read the Wi-Fi name.")
    await assertFails(
      try await executor(fake).applyCurrentNetworkPolicy(),
      equals: "ClashMax needs Location Services to read the Wi-Fi name."
    )

    fake.networkPolicyOutcome = .cancelled
    await assertFails(
      try await executor(fake).applyCurrentNetworkPolicy(),
      equals: String(localized: "A newer network change replaced this policy before it finished applying.")
    )
  }

  // MARK: Pieces shared with the App Intents layer

  func testHelperGuidanceMatchesWhatTheSetupSheetShows() {
    XCTAssertNil(HelperSetupStage.ready.guidanceMessage)
    XCTAssertEqual(HelperSetupStage.install.guidanceMessage, TunnelHelperClient.statusMessage(for: .notRegistered))
    XCTAssertEqual(HelperSetupStage.approve.guidanceMessage, TunnelHelperClient.statusMessage(for: .requiresApproval))
    XCTAssertEqual(HelperSetupStage.relocate(.translocated).guidanceMessage, AppInstallLocationIssue.translocated.explanation)
    XCTAssertEqual(HelperSetupStage.failed("boom").guidanceMessage, "boom")
  }

  func testToggleActionResolvesAgainstTheCurrentState() {
    XCTAssertTrue(ClashMaxToggleAction.turnOn.resolvedTarget(current: true))
    XCTAssertTrue(ClashMaxToggleAction.turnOn.resolvedTarget(current: false))
    XCTAssertFalse(ClashMaxToggleAction.turnOff.resolvedTarget(current: true))
    XCTAssertTrue(ClashMaxToggleAction.toggle.resolvedTarget(current: false))
    XCTAssertFalse(ClashMaxToggleAction.toggle.resolvedTarget(current: true))
  }

  func testNodeIdentifierRoundTripsNamesContainingTheSeparator() throws {
    for (group, node) in [("Proxy", "Tokyo"), ("A:B", "C:D"), ("🇯🇵 Japan", "节点 01"), ("", "x"), ("3:abc", "def")] {
      let identifier = ClashMaxProxyNodeIdentifier.encode(groupName: group, nodeName: node)
      let decoded = try XCTUnwrap(ClashMaxProxyNodeIdentifier.decode(identifier), identifier)
      XCTAssertEqual(decoded.groupName, group)
      XCTAssertEqual(decoded.nodeName, node)
    }
    XCTAssertNil(ClashMaxProxyNodeIdentifier.decode("Proxy/Tokyo"))
    XCTAssertNil(ClashMaxProxyNodeIdentifier.decode("9:short"))
    XCTAssertNil(ClashMaxProxyNodeIdentifier.decode("5:Proxy"))
  }

  // MARK: Helpers

  private static let selectGroup = ProxyGroup(
    name: "Proxy",
    type: "Selector",
    selected: "Osaka",
    nodes: [
      ProxyNode(name: "Tokyo", type: "ss", delay: nil, isSelectable: true),
      ProxyNode(name: "Osaka", type: "ss", delay: nil, isSelectable: true),
      ProxyNode(name: "REJECT", type: "Reject", delay: nil, isSelectable: false),
    ]
  )

  /// The test host can resolve translated keys to zh-Hans, so expectations go through the catalog.
  private func fmt(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
    String(format: String(localized: key), arguments: arguments)
  }

  private func helperFailure(_ detail: String) -> String {
    fmt("TUN needs the ClashMax privileged helper, which is not ready. %@ Open ClashMax to finish the setup.", detail)
  }

  private func nextStart(_ mode: ProxyRoutingMode) -> String {
    fmt("Routing mode set to %@. It takes effect the next time ClashMax starts.", mode.displayName)
  }

  private func executor(_ fake: FakeIntentController) -> ClashMaxIntentExecutor {
    ClashMaxIntentExecutor(
      controller: fake,
      timing: .init(pollInterval: .milliseconds(1), lifecycleTimeout: .milliseconds(20)),
      sleep: { _ in fake.advance() }
    )
  }

  private func assertFails(
    _ operation: @autoclosure () async throws -> String,
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let message = try await operation()
      XCTFail("Expected a failure, got success: \(message)", file: file, line: line)
    } catch let error as ClashMaxIntentError {
      XCTAssertEqual(error.message, expected, file: file, line: line)
    } catch {
      XCTFail("Unexpected error type: \(error)", file: file, line: line)
    }
  }

  private func assertFails(
    _ operation: @autoclosure () async throws -> String,
    contains fragment: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let message = try await operation()
      XCTFail("Expected a failure, got success: \(message)", file: file, line: line)
    } catch let error as ClashMaxIntentError {
      XCTAssertTrue(error.message.contains(fragment), "\(error.message)", file: file, line: line)
    } catch {
      XCTFail("Unexpected error type: \(error)", file: file, line: line)
    }
  }
}

/// Plays back a scripted lifecycle: an action installs its script, and every executor poll advances
/// it one step.
@MainActor
private final class FakeIntentController: ClashMaxIntentControlling {
  private(set) var calls: [String] = []
  private var phase: ClashMaxIntentLifecyclePhase
  private var script: [ClashMaxIntentLifecyclePhase] = []
  private var pendingLastError: String?
  private var pendingHelperStage: HelperSetupStage?

  var lastError: String?
  var intentStartBlocker: String?
  var intentTunHelperStage: HelperSetupStage = .ready
  var proxyRoutingMode: ProxyRoutingMode
  var systemProxyEnabled = false
  var intentProfiles: [ClashMaxIntentProfile] = []
  var intentProxyGroups: [ProxyGroup] = []

  var afterStart: [ClashMaxIntentLifecyclePhase] = []
  var afterStop: [ClashMaxIntentLifecyclePhase] = []
  var afterRestart: [ClashMaxIntentLifecyclePhase] = []
  var afterRoutingSwitch: [ClashMaxIntentLifecyclePhase] = []
  var afterProfileSwitch: [ClashMaxIntentLifecyclePhase] = []
  var lastErrorAfterStart: String?
  var lastErrorAfterStop: String?
  var lastErrorAfterProfileSwitch: String?
  var lastErrorAfterSystemProxy: String?
  var helperStageAfterRoutingSwitch: HelperSetupStage?
  var helperPreparationFailure: String?
  var systemProxyError: Error?
  var systemProxyChangeSticks = true
  var routingSwitchError: Error?
  var routingSwitchSticks = true
  var profileSwitchError: Error?
  var nodeSelectionError: Error?
  var subscriptionReport = SubscriptionUpdateBatchReport()
  var networkPolicyOutcome: NetworkPolicyApplyOutcome = .nothingToApply("")

  init(phase: ClashMaxIntentLifecyclePhase = .stopped, routingMode: ProxyRoutingMode = .systemProxy) {
    self.phase = phase
    proxyRoutingMode = routingMode
  }

  var intentLifecyclePhase: ClashMaxIntentLifecyclePhase {
    phase
  }

  var remainingScript: [ClashMaxIntentLifecyclePhase] {
    script
  }

  func advance() {
    if !script.isEmpty {
      phase = script.removeFirst()
    }
    if let pendingLastError, phase != .transitioning {
      lastError = pendingLastError
      self.pendingLastError = nil
    }
    if let pendingHelperStage {
      intentTunHelperStage = pendingHelperStage
      self.pendingHelperStage = nil
    }
  }

  private func play(_ steps: [ClashMaxIntentLifecyclePhase], lastError: String? = nil) {
    if !steps.isEmpty {
      phase = .transitioning
      script = steps
    }
    pendingLastError = lastError
  }

  func start() {
    calls.append("start")
    play(afterStart, lastError: lastErrorAfterStart)
  }

  func stop() {
    calls.append("stop")
    play(afterStop, lastError: lastErrorAfterStop)
  }

  func restart() {
    calls.append("restart")
    // A restart is only observable once the stop begins, so keep the old run on screen for the
    // first step instead of jumping straight to `.transitioning`.
    script = afterRestart
  }

  func prepareTunHelperForIntent() async -> String? {
    calls.append("prepareTunHelper")
    return helperPreparationFailure
  }

  func setSystemProxyEnabledForIntent(_ enabled: Bool) async throws {
    calls.append("systemProxy:\(enabled)")
    if let systemProxyError {
      throw systemProxyError
    }
    if systemProxyChangeSticks {
      systemProxyEnabled = enabled
    } else {
      lastError = lastErrorAfterSystemProxy
    }
  }

  func setProxyRoutingModeForIntent(_ mode: ProxyRoutingMode) async throws {
    calls.append("routing:\(mode.rawValue)")
    if let routingSwitchError {
      throw routingSwitchError
    }
    guard routingSwitchSticks else { return }
    proxyRoutingMode = mode
    script = afterRoutingSwitch
    pendingHelperStage = helperStageAfterRoutingSwitch
  }

  func selectProfileForIntent(id: UUID) async throws {
    calls.append("profile:\(id)")
    if let profileSwitchError {
      throw profileSwitchError
    }
    play(afterProfileSwitch, lastError: lastErrorAfterProfileSwitch)
  }

  func selectProxyForIntent(groupName: String, nodeName: String) async throws {
    calls.append("node:\(groupName)/\(nodeName)")
    if let nodeSelectionError {
      throw nodeSelectionError
    }
  }

  func updateAllSubscriptionsForIntent() async -> SubscriptionUpdateBatchReport {
    subscriptionReport
  }

  func applyCurrentNetworkPolicyForIntent() async -> NetworkPolicyApplyOutcome {
    networkPolicyOutcome
  }
}
