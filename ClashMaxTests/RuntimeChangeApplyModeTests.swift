@testable import ClashMax
import XCTest

final class RuntimeChangeApplyModeTests: XCTestCase {
  func testRuleAndDNSEditsHotReloadForEveryRunningOwner() {
    for owner in [RuntimeOwner.user, .tunnel, .networkExtension] {
      let context = RuntimeApplyContext(runtimeOwner: owner)
      for change in [RuntimeChangeKind.rules, .dns, .snippetOrder, .profileOptions] {
        XCTAssertEqual(
          RuntimeChangeApplyMode.resolve(change, in: context),
          .hotReload,
          "\(change) under \(owner) should reload in place"
        )
      }
    }
  }

  func testNothingRunningMeansEveryChangeWaitsForTheNextStart() {
    for change in [
      RuntimeChangeKind.rules,
      .dns,
      .snippetOrder,
      .profileOptions,
      .inboundPort,
      .controllerEndpoint,
      .networkExtensionRouting,
    ] {
      XCTAssertEqual(RuntimeChangeApplyMode.resolve(change, in: .stopped), .appliesOnNextStart)
    }
  }

  func testPreviewRuntimeDoesNotCountAsARunningRuntime() {
    // The preview core serves the Proxies preview, not the user's traffic, so an edit made while it
    // is up has not reached anything the user is actually browsing through.
    let context = RuntimeApplyContext(runtimeOwner: .user, previewRuntimeActive: true)
    XCTAssertFalse(context.servesUserTraffic)
    XCTAssertEqual(RuntimeChangeApplyMode.resolve(.rules, in: context), .appliesOnNextStart)
  }

  func testEndpointChangesOnlyRestartUnderNetworkExtension() {
    for change in [RuntimeChangeKind.inboundPort, .controllerEndpoint] {
      XCTAssertEqual(
        RuntimeChangeApplyMode.resolve(change, in: RuntimeApplyContext(runtimeOwner: .networkExtension)),
        .requiresRestart(.networkExtensionEndpointPinned)
      )
      XCTAssertEqual(RuntimeChangeApplyMode.resolve(change, in: RuntimeApplyContext(runtimeOwner: .user)), .hotReload)
      XCTAssertEqual(RuntimeChangeApplyMode.resolve(change, in: RuntimeApplyContext(runtimeOwner: .tunnel)), .hotReload)
    }
  }

  func testNetworkExtensionRoutingRestartsOnlyWhileTheTunnelOwnsTheRuntime() {
    XCTAssertEqual(
      RuntimeChangeApplyMode.resolve(.networkExtensionRouting, in: RuntimeApplyContext(runtimeOwner: .networkExtension)),
      .requiresRestart(.networkExtensionRoutingPinned)
    )
    // Under any other owner the setting is not read at all until an NE start picks it up.
    XCTAssertEqual(
      RuntimeChangeApplyMode.resolve(.networkExtensionRouting, in: RuntimeApplyContext(runtimeOwner: .user)),
      .appliesOnNextStart
    )
  }

  func testRequiresRestartFlagMatchesTheCase() {
    XCTAssertTrue(RuntimeChangeApplyMode.requiresRestart(.networkExtensionEndpointPinned).requiresRestart)
    XCTAssertFalse(RuntimeChangeApplyMode.hotReload.requiresRestart)
    XCTAssertFalse(RuntimeChangeApplyMode.appliesOnNextStart.requiresRestart)
  }

  func testEveryApplyModeStatesTheBoundaryBeforeApply() {
    XCTAssertFalse(RuntimeChangeApplyMode.hotReload.pendingSummary.isEmpty)
    XCTAssertFalse(RuntimeChangeApplyMode.appliesOnNextStart.pendingSummary.isEmpty)
    let restartSummary = RuntimeChangeApplyMode.requiresRestart(.networkExtensionEndpointPinned).pendingSummary
    XCTAssertTrue(restartSummary.contains(RuntimeRestartReason.networkExtensionEndpointPinned.explanation))
  }

  func testRolledBackOutcomeIsTheOnlyFailureAndCarriesTheReason() {
    let rolledBack = RuntimeApplyOutcome.rolledBack(.rules, message: "reload rejected")
    XCTAssertTrue(rolledBack.isFailure)
    XCTAssertEqual(rolledBack.change, .rules)
    XCTAssertTrue(rolledBack.detail.contains("reload rejected"))

    for outcome: RuntimeApplyOutcome in [
      .applied(.rules),
      .restartNeeded(.inboundPort, .networkExtensionEndpointPinned),
      .savedForNextStart(.dns),
    ] {
      XCTAssertFalse(outcome.isFailure)
      XCTAssertFalse(outcome.title.isEmpty)
      XCTAssertFalse(outcome.detail.isEmpty)
      XCTAssertFalse(outcome.systemImage.isEmpty)
    }
  }

  func testSnippetPayloadKindMapsToTheEditedChangeKind() {
    XCTAssertEqual(RuntimeChangeKind(RuntimeSnippetPayloadKind.rules), .rules)
    XCTAssertEqual(RuntimeChangeKind(RuntimeSnippetPayloadKind.dnsPatch), .dns)
  }

  func testPendingChangeCountCountsEveryUnappliedEdit() {
    let baseline = RuleOverlaySettings(
      enabled: true,
      prependRules: [ManagedRuleOverlayRule(kind: .domainSuffix, value: "a.example", policy: "DIRECT")]
    )
    XCTAssertEqual(baseline.pendingChangeCount(comparedTo: baseline), 0)

    var draft = baseline
    draft.prependRules.append(ManagedRuleOverlayRule(kind: .domainSuffix, value: "b.example", policy: "DIRECT"))
    XCTAssertEqual(draft.pendingChangeCount(comparedTo: baseline), 1)

    draft.appendRules = [ManagedRuleOverlayRule(kind: .domain, value: "c.example", policy: "Proxy")]
    XCTAssertEqual(draft.pendingChangeCount(comparedTo: baseline), 2)

    draft.enabled = false
    XCTAssertEqual(draft.pendingChangeCount(comparedTo: baseline), 3)

    // Removing everything the baseline had counts too, so "Apply" is never offered for a no-op.
    let cleared = RuleOverlaySettings(enabled: true)
    XCTAssertEqual(cleared.pendingChangeCount(comparedTo: baseline), 1)
  }
}
