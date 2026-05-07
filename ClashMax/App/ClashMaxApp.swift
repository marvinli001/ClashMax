import AppKit
import SwiftUI

@main
struct ClashMaxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appModel = AppModel.bootstrap()
  @StateObject private var appUpdateController = AppUpdateController()
  @StateObject private var resourceUpdateController = ResourceUpdateController()

  var body: some Scene {
    WindowGroup("ClashMax", id: "main") {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(appUpdateController)
        .environmentObject(resourceUpdateController)
        .preferredColorScheme(appModel.appTheme.preferredColorScheme)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
          appDelegate.appModel = appModel
        }
    }
    .defaultSize(width: 1180, height: 760)
    .defaultLaunchBehavior(.presented)
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesButton(updateController: appUpdateController)
        Divider()
        Button("Open Main Window") {
          AppDelegate.showMainWindow()
        }
        .keyboardShortcut("0", modifiers: [.command])
      }
    }

    MenuBarExtra {
      MenuBarView()
        .environmentObject(appModel)
        .environmentObject(appUpdateController)
        .environmentObject(resourceUpdateController)
        .preferredColorScheme(appModel.appTheme.preferredColorScheme)
        .onAppear {
          appDelegate.appModel = appModel
        }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: appModel.isRunning ? "shield.lefthalf.filled" : "shield")
        Text(appModel.trafficSample.shortLabel)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appModel)
        .environmentObject(appUpdateController)
        .environmentObject(resourceUpdateController)
        .preferredColorScheme(appModel.appTheme.preferredColorScheme)
        .onAppear {
          appDelegate.appModel = appModel
        }
    }
  }
}

private extension AppTheme {
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var appModel: AppModel?
  private var terminationCleanupInFlight = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    if UserDefaults.standard.bool(forKey: AppModel.silentStartDefaultsKey) {
      DispatchQueue.main.async {
        NSApp.windows.forEach { $0.orderOut(nil) }
      }
    } else {
      Self.showMainWindow()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let appModel, appModel.needsTerminationCleanup, !terminationCleanupInFlight else {
      return .terminateNow
    }

    terminationCleanupInFlight = true
    Task { @MainActor [weak self] in
      await appModel.prepareForTermination()
      self?.terminationCleanupInFlight = false
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  @MainActor
  static func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows where window.canBecomeMain {
      window.makeKeyAndOrderFront(nil)
    }
  }
}
