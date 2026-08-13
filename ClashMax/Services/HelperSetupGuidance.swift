import Foundation

/// Why the app bundle's location blocks privileged helper registration.
///
/// `SMAppService.daemon` does not copy anything: it registers a LaunchDaemon
/// plist that stays *inside* the app bundle, and macOS records the approval
/// against that bundle's path and signature. So the bundle's location is part
/// of the registration, and macOS refuses outright whenever the bundle sits
/// somewhere it will not trust — a mounted disk image, a Gatekeeper
/// translocation mirror, or a folder outside /Applications. Registration then
/// fails with `SMAppServiceErrorDomain` code 1 and no explanation the user can
/// act on, which is why this is checked before asking them to install anything.
enum AppInstallLocationIssue: Equatable, Sendable {
  /// Gatekeeper is running a randomized read-only mirror of the bundle, which
  /// happens when a quarantined app is launched straight from a disk image or
  /// the Downloads folder. The real bundle cannot be reached from here, so the
  /// only way out is for the user to move it in Finder themselves.
  case translocated
  /// The bundle is reachable but lives outside /Applications.
  case outsideApplications(folderName: String)

  var allowsAutomaticRelocation: Bool {
    switch self {
    case .translocated:
      return false
    case .outsideApplications:
      return true
    }
  }

  var explanation: String {
    switch self {
    case .translocated:
      return String(
        localized: """
        macOS is running ClashMax from a temporary read-only copy, which it will not let install a \
        privileged helper. Drag ClashMax into your Applications folder in Finder, then open it from there.
        """
      )
    case let .outsideApplications(folderName):
      return String(
        localized: """
        ClashMax is running from “\(folderName)”. macOS only allows a privileged helper to be \
        installed from the Applications folder.
        """
      )
    }
  }
}

/// Pure location rules, kept free of `Bundle`/`FileManager` so the policy can be
/// tested without relocating real app bundles.
enum AppInstallLocation {
  static let applicationsDirectory = "/Applications"

  /// Gatekeeper translocation mirrors always live under a path segment named
  /// `AppTranslocation`, e.g.
  /// `/private/var/folders/…/AppTranslocation/<UUID>/d/ClashMax.app`.
  private static let translocationMarker = "/AppTranslocation/"

  static func issue(forBundlePath path: String) -> AppInstallLocationIssue? {
    if path.contains(translocationMarker) {
      return .translocated
    }
    let bundleURL = URL(fileURLWithPath: path)
    let parent = bundleURL.deletingLastPathComponent()
    let parentPath = parent.standardizedFileURL.path
    guard parentPath != applicationsDirectory else { return nil }
    let folderName = parent.lastPathComponent.isEmpty
      ? parentPath
      : parent.lastPathComponent
    return .outsideApplications(folderName: folderName)
  }
}

/// Reads the running bundle's location. Injected so tests and debug builds can
/// opt out — a development build legitimately runs from DerivedData, and every
/// unit test runs from the test runner's bundle, neither of which should be
/// nagged about moving to /Applications.
@MainActor
protocol AppInstallLocationInspecting: AnyObject {
  var locationIssue: AppInstallLocationIssue? { get }
}

@MainActor
final class BundleAppInstallLocationInspector: AppInstallLocationInspecting {
  private let bundlePath: String
  private let isEnforced: Bool

  init(bundleURL: URL = Bundle.main.bundleURL, isEnforced: Bool = BundleAppInstallLocationInspector.enforcesByDefault) {
    bundlePath = bundleURL.standardizedFileURL.path
    self.isEnforced = isEnforced
  }

  var locationIssue: AppInstallLocationIssue? {
    guard isEnforced else { return nil }
    return AppInstallLocation.issue(forBundlePath: bundlePath)
  }

  static var enforcesByDefault: Bool {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
    #if DEBUG
      return false
    #else
      return true
    #endif
  }
}

/// The single step the helper setup flow is currently waiting on.
///
/// Ordering matters: a bad bundle location makes registration fail in a way the
/// user cannot diagnose, so it outranks whatever `SMAppService` reports.
enum HelperSetupStage: Equatable, Sendable {
  case relocate(AppInstallLocationIssue)
  case install
  case approve
  case ready
  case failed(String)
}

enum HelperSetupPolicy {
  static func stage(
    locationIssue: AppInstallLocationIssue?,
    serviceStatus: TunnelHelperServiceStatus,
    failureMessage: String? = nil
  ) -> HelperSetupStage {
    if serviceStatus == .enabled {
      return .ready
    }
    if let locationIssue {
      return .relocate(locationIssue)
    }
    if let failureMessage, !failureMessage.isEmpty {
      return .failed(failureMessage)
    }
    switch serviceStatus {
    case .requiresApproval:
      return .approve
    case .notRegistered, .notFound, .unknown:
      return .install
    case .enabled:
      return .ready
    }
  }

  /// Whether the flow should keep re-reading `SMAppService.status` on a timer.
  ///
  /// The approval toggle lives in System Settings and macOS posts no
  /// notification when it flips, so polling is the only way to notice that the
  /// user finished — without it the sheet sits on "pending" forever and the
  /// user has to come back and press a button to find out it already worked.
  static func shouldPollForApproval(_ stage: HelperSetupStage) -> Bool {
    switch stage {
    case .approve:
      return true
    case .relocate, .install, .ready, .failed:
      return false
    }
  }
}
