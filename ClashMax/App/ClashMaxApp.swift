import AppKit
import SwiftUI

@main
struct ClashMaxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appModel = AppModel.bootstrap()

  var body: some Scene {
    WindowGroup("ClashMax", id: "main") {
      ContentView()
        .environmentObject(appModel)
        .frame(minWidth: 980, minHeight: 660)
    }
    .defaultSize(width: 1180, height: 760)
    .defaultLaunchBehavior(.presented)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Open Main Window") {
          NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: [.command])
      }
    }

    MenuBarExtra {
      MenuBarView()
        .environmentObject(appModel)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: appModel.isRunning ? "shield.lefthalf.filled" : "shield")
        Text(appModel.trafficSample.shortLabel)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appModel)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}
