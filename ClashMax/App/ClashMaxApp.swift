import AppKit
import SwiftUI

@main
struct ClashMaxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appModel = AppModel.bootstrap()
  @StateObject private var appUpdateController = AppUpdateController()
  private let bundledCoreInfo = BundledCoreInfo()

  var body: some Scene {
    WindowGroup("ClashMax", id: "main") {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.profileOperations)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.warmTunHelperRegistrationOnLaunch()
        }
        .onOpenURL { url in
          AppDelegate.showMainWindow()
          appModel.handleIncomingURL(url)
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
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.profileOperations)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.warmTunHelperRegistrationOnLaunch()
        }
    } label: {
      MenuBarStatusLabel(appModel: appModel, runtimeData: appModel.runtimeData)
    }

    Settings {
      SettingsView(bundledCoreInfo: bundledCoreInfo)
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.profileOperations)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.warmTunHelperRegistrationOnLaunch()
        }
    }
  }
}

private struct MenuBarStatusLabel: View {
  @ObservedObject var appModel: AppModel
  @ObservedObject var runtimeData: RuntimeDataStore

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: appModel.isRunning ? "shield.lefthalf.filled" : "shield")
      Text(runtimeData.trafficSample.shortLabel)
    }
  }
}

@MainActor
enum AppThemeAppearance {
  static func apply(_ theme: AppTheme, to application: NSApplication = .shared) {
    let appearance = theme.nsAppearanceName.flatMap(NSAppearance.init(named:))
    application.appearance = appearance

    for window in application.windows {
      window.appearance = appearance
      window.contentView?.appearance = appearance
      window.contentView?.needsDisplay = true
    }
  }
}

extension View {
  func appThemeAppearance(_ theme: AppTheme) -> some View {
    modifier(AppThemeAppearanceModifier(theme: theme))
  }
}

private struct AppThemeAppearanceModifier: ViewModifier {
  let theme: AppTheme

  func body(content: Content) -> some View {
    content
      .preferredColorScheme(theme.preferredColorScheme)
      .onAppear {
        AppThemeAppearance.apply(theme)
      }
      .onChange(of: theme) { _, newTheme in
        AppThemeAppearance.apply(newTheme)
      }
  }
}

extension AppTheme {
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

  var nsAppearanceName: NSAppearance.Name? {
    switch self {
    case .system:
      return nil
    case .light:
      return .aqua
    case .dark:
      return .darkAqua
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
      let shouldTerminate = await appModel.prepareForTermination()
      self?.terminationCleanupInFlight = false
      sender.reply(toApplicationShouldTerminate: shouldTerminate)
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
