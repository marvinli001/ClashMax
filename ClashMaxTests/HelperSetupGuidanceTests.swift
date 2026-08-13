@testable import ClashMax
import Foundation
import XCTest

@MainActor
final class HelperSetupGuidanceTests: XCTestCase {
  func testBundleInsideApplicationsHasNoLocationIssue() {
    XCTAssertNil(AppInstallLocation.issue(forBundlePath: "/Applications/ClashMax.app"))
  }

  func testTranslocatedBundleIsDetectedAndCannotRelocateItself() {
    let path = "/private/var/folders/qz/T/AppTranslocation/9A1F/d/ClashMax.app"
    let issue = AppInstallLocation.issue(forBundlePath: path)

    XCTAssertEqual(issue, .translocated)
    XCTAssertEqual(issue?.allowsAutomaticRelocation, false)
  }

  func testTranslocationOutranksBeingInsideApplications() {
    // A translocated mirror can sit under a path that ends in /Applications;
    // the read-only mirror is still the blocking problem.
    let path = "/private/var/folders/qz/T/AppTranslocation/9A1F/d/Applications/ClashMax.app"

    XCTAssertEqual(AppInstallLocation.issue(forBundlePath: path), .translocated)
  }

  func testBundleOutsideApplicationsNamesItsFolderAndCanRelocate() {
    let issue = AppInstallLocation.issue(forBundlePath: "/Users/someone/Downloads/ClashMax.app")

    XCTAssertEqual(issue, .outsideApplications(folderName: "Downloads"))
    XCTAssertEqual(issue?.allowsAutomaticRelocation, true)
    XCTAssertEqual(issue?.explanation.contains("Downloads"), true)
  }

  func testUserApplicationsFolderStillCountsAsOutsideApplications() {
    // ~/Applications is not /Applications, and SMAppService rejects it just the
    // same, so it must not be mistaken for a valid install location.
    let issue = AppInstallLocation.issue(forBundlePath: "/Users/someone/Applications/ClashMax.app")

    XCTAssertEqual(issue, .outsideApplications(folderName: "Applications"))
  }

  func testMountedDiskImageIsTreatedAsOutsideApplications() {
    let issue = AppInstallLocation.issue(forBundlePath: "/Volumes/ClashMax/ClashMax.app")

    XCTAssertEqual(issue, .outsideApplications(folderName: "ClashMax"))
  }

  func testInspectorSuppressesLocationIssueWhenNotEnforced() {
    let inspector = BundleAppInstallLocationInspector(
      bundleURL: URL(fileURLWithPath: "/Users/someone/Downloads/ClashMax.app"),
      isEnforced: false
    )

    XCTAssertNil(inspector.locationIssue)
  }

  func testInspectorReportsLocationIssueWhenEnforced() {
    let inspector = BundleAppInstallLocationInspector(
      bundleURL: URL(fileURLWithPath: "/Users/someone/Downloads/ClashMax.app"),
      isEnforced: true
    )

    XCTAssertEqual(inspector.locationIssue, .outsideApplications(folderName: "Downloads"))
  }

  func testInspectorIsDisabledUnderTests() {
    // Every unit test runs from the test runner's bundle, which is never in
    // /Applications — enforcing there would fire on every model under test.
    XCTAssertFalse(BundleAppInstallLocationInspector.enforcesByDefault)
  }

  func testEnabledHelperIsReadyEvenFromABadLocation() {
    // The registration already succeeded, so there is nothing left to fix and
    // telling the user to move the app would be pure noise.
    let stage = HelperSetupPolicy.stage(
      locationIssue: .outsideApplications(folderName: "Downloads"),
      serviceStatus: .enabled
    )

    XCTAssertEqual(stage, .ready)
  }

  func testLocationIssueOutranksRegistrationStatusAndFailures() {
    let stage = HelperSetupPolicy.stage(
      locationIssue: .translocated,
      serviceStatus: .notRegistered,
      failureMessage: "Operation not permitted"
    )

    XCTAssertEqual(stage, .relocate(.translocated))
  }

  func testFailureMessageOutranksRegistrationStatusWhenLocationIsFine() {
    let stage = HelperSetupPolicy.stage(
      locationIssue: nil,
      serviceStatus: .notRegistered,
      failureMessage: "Operation not permitted"
    )

    XCTAssertEqual(stage, .failed("Operation not permitted"))
  }

  func testEmptyFailureMessageDoesNotStrandTheSheetOnAnErrorStep() {
    let stage = HelperSetupPolicy.stage(
      locationIssue: nil,
      serviceStatus: .notRegistered,
      failureMessage: ""
    )

    XCTAssertEqual(stage, .install)
  }

  func testRegistrationStatusMapsToInstallAndApproveSteps() {
    XCTAssertEqual(HelperSetupPolicy.stage(locationIssue: nil, serviceStatus: .notRegistered), .install)
    XCTAssertEqual(HelperSetupPolicy.stage(locationIssue: nil, serviceStatus: .notFound), .install)
    XCTAssertEqual(HelperSetupPolicy.stage(locationIssue: nil, serviceStatus: .unknown), .install)
    XCTAssertEqual(HelperSetupPolicy.stage(locationIssue: nil, serviceStatus: .requiresApproval), .approve)
  }

  func testOnlyTheApprovalStepPollsForApproval() {
    // Polling exists because macOS posts nothing when the Login Items toggle
    // flips; every other step ends with an action the app itself performs.
    XCTAssertTrue(HelperSetupPolicy.shouldPollForApproval(.approve))
    XCTAssertFalse(HelperSetupPolicy.shouldPollForApproval(.install))
    XCTAssertFalse(HelperSetupPolicy.shouldPollForApproval(.ready))
    XCTAssertFalse(HelperSetupPolicy.shouldPollForApproval(.relocate(.translocated)))
    XCTAssertFalse(HelperSetupPolicy.shouldPollForApproval(.failed("boom")))
  }

  func testStaleBackgroundRegistrationErrorIsRecognized() {
    // SMAppService reports a stale BTM record as a bare "Operation not
    // permitted"; recognizing it is what lets registration retry itself
    // instead of dead-ending the user.
    let stale = NSError(domain: "SMAppServiceErrorDomain", code: 1)

    XCTAssertTrue(TunnelHelperClient.isStaleBackgroundRegistrationError(stale))
  }

  func testUnrelatedRegistrationErrorsAreNotRetried() {
    XCTAssertFalse(
      TunnelHelperClient.isStaleBackgroundRegistrationError(NSError(domain: "SMAppServiceErrorDomain", code: 108))
    )
    XCTAssertFalse(
      TunnelHelperClient.isStaleBackgroundRegistrationError(NSError(domain: NSPOSIXErrorDomain, code: 1))
    )
  }
}
