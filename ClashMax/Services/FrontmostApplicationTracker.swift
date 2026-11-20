import AppKit
import Observation

/// The last app other than ClashMax that was frontmost.
///
/// Opening the menu bar panel can activate ClashMax itself, so by the time the panel asks
/// `NSWorkspace.frontmostApplication` the answer may be ClashMax. Activation notifications are
/// recorded from launch instead, and ClashMax's own activations are ignored. No permission is
/// involved: `NSWorkspace` reports these to every app.
@MainActor
@Observable
final class FrontmostApplicationTracker {
  static let shared = FrontmostApplicationTracker()

  private(set) var lastApp: FrontmostAppSnapshot?
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {}

  /// Idempotent; called from `applicationDidFinishLaunching`.
  func start() {
    guard observer == nil else { return }
    record(NSWorkspace.shared.frontmostApplication)
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let snapshot = app.flatMap(Self.snapshot(of:))
      MainActor.assumeIsolated {
        if let snapshot { FrontmostApplicationTracker.shared.lastApp = snapshot }
      }
    }
  }

  private func record(_ app: NSRunningApplication?) {
    if let snapshot = app.flatMap(Self.snapshot(of:)) {
      lastApp = snapshot
    }
  }

  /// `nil` for ClashMax itself and for background agents, which never are "the app in front".
  nonisolated static func snapshot(of app: NSRunningApplication) -> FrontmostAppSnapshot? {
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
          app.activationPolicy == .regular
    else { return nil }
    let name = app.localizedName
      ?? app.bundleURL?.deletingPathExtension().lastPathComponent
      ?? app.executableURL?.lastPathComponent
    guard let name, !name.isEmpty else { return nil }
    return FrontmostAppSnapshot(
      name: name,
      bundleIdentifier: app.bundleIdentifier,
      bundleURL: app.bundleURL,
      executableURL: app.executableURL
    )
  }
}
