import AppKit
import Foundation

enum AppRelocationError: LocalizedError, Equatable {
  case destinationOccupied(String)
  case cannotRelocateTranslocatedBundle
  case copyFailed(String)
  case verificationFailed

  var errorDescription: String? {
    switch self {
    case let .destinationOccupied(path):
      return String(
        localized: """
        Another copy of ClashMax is already at \(path). Delete or rename it first, then move this \
        copy into the Applications folder.
        """
      )
    case .cannotRelocateTranslocatedBundle:
      return String(
        localized: """
        macOS is running ClashMax from a protected temporary copy that cannot move itself. Drag \
        ClashMax into your Applications folder in Finder, then open it from there.
        """
      )
    case let .copyFailed(message):
      return String(localized: "Could not copy ClashMax into the Applications folder: \(message)")
    case .verificationFailed:
      return String(localized: "The copy in the Applications folder is incomplete. Move ClashMax there manually instead.")
    }
  }
}

/// Moves the running app into /Applications so `SMAppService` will accept the
/// bundled LaunchDaemon, then relaunches from the new location.
///
/// Copy-then-remove rather than `moveItem`: the source is often a read-only
/// disk image, where a move fails outright but a copy is exactly what the user
/// wants. Removing the original is best-effort and deliberately never fatal —
/// a leftover copy in Downloads is harmless, a half-moved app is not.
@MainActor
final class AppRelocationService {
  private let fileManager: FileManager
  private let bundleURL: URL
  private let workspace: NSWorkspace

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    fileManager: FileManager = .default,
    workspace: NSWorkspace = .shared
  ) {
    self.bundleURL = bundleURL.standardizedFileURL
    self.fileManager = fileManager
    self.workspace = workspace
  }

  var destinationURL: URL {
    URL(fileURLWithPath: AppInstallLocation.applicationsDirectory)
      .appendingPathComponent(bundleURL.lastPathComponent)
  }

  /// Copies the bundle to /Applications and returns the new location. The
  /// caller is responsible for relaunching.
  func relocateToApplications() throws -> URL {
    guard AppInstallLocation.issue(forBundlePath: bundleURL.path) != .translocated else {
      throw AppRelocationError.cannotRelocateTranslocatedBundle
    }
    let destination = destinationURL
    guard destination.standardizedFileURL != bundleURL else { return destination }
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw AppRelocationError.destinationOccupied(destination.path)
    }

    do {
      try fileManager.copyItem(at: bundleURL, to: destination)
    } catch {
      throw AppRelocationError.copyFailed(error.localizedDescription)
    }

    // A truncated copy would relaunch into a broken app, so confirm the
    // executable actually landed before we point the user at it.
    let executable = destination.appendingPathComponent("Contents/MacOS")
    guard fileManager.fileExists(atPath: executable.path) else {
      try? fileManager.removeItem(at: destination)
      throw AppRelocationError.verificationFailed
    }

    if fileManager.isWritableFile(atPath: bundleURL.path) {
      try? fileManager.removeItem(at: bundleURL)
    }
    return destination
  }

  /// Launches the relocated copy and terminates this instance.
  func relaunch(at url: URL) async {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    _ = try? await workspace.openApplication(at: url, configuration: configuration)
    NSApp.terminate(nil)
  }

  func revealInFinder() {
    workspace.activateFileViewerSelecting([bundleURL])
  }
}
