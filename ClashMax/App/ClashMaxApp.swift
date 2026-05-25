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
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.startNetworkEnvironmentMonitoring()
          appModel.warmTunHelperRegistrationOnLaunch()
          appModel.warmPreviewRuntimeOnLaunch()
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

      CommandMenu("Config") {
        Button("Rule Mode") {
          appModel.requestMode(.rule)
        }
        .keyboardShortcut("1", modifiers: [.command, .option])

        Button("Global Mode") {
          appModel.requestMode(.global)
        }
        .keyboardShortcut("2", modifiers: [.command, .option])

        Button("Direct Mode") {
          appModel.requestMode(.direct)
        }
        .keyboardShortcut("3", modifiers: [.command, .option])

        Divider()

        Button("System Proxy Routing") {
          appModel.requestProxyRoutingMode(.systemProxy)
        }

        Button("TUN Routing") {
          appModel.requestProxyRoutingMode(.tun)
        }

        Button("NE Proxy Routing") {
          appModel.requestProxyRoutingMode(.neProxy)
        }

        Divider()

        Button(appModel.systemProxyEnabled ? "Disable System Proxy" : "Enable System Proxy") {
          appModel.setSystemProxyEnabled(!appModel.systemProxyEnabled)
        }
        .keyboardShortcut("s", modifiers: [.command, .option])

        Button("Profiles") {
          AppDelegate.showMainWindow()
          appModel.selectedSection = .profiles
        }
        .keyboardShortcut("p", modifiers: [.command, .option])

        Button("Update All") {
          AppDelegate.showMainWindow()
          appModel.selectedSection = .profiles
          appModel.updateAllSubscriptions()
        }

        Button("Import ClashX") {
          AppDelegate.showMainWindow()
          appModel.selectedSection = .profiles
          NotificationCenter.default.post(name: .clashMaxImportClashXRequested, object: nil)
        }
      }
    }

    MenuBarExtra {
      MenuBarView()
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.startNetworkEnvironmentMonitoring()
          appModel.warmTunHelperRegistrationOnLaunch()
          appModel.warmPreviewRuntimeOnLaunch()
        }
    } label: {
      MenuBarStatusLabel(appModel: appModel)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(bundledCoreInfo: bundledCoreInfo)
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environmentObject(appModel.runtimeData)
        .environmentObject(appModel.publicIP)
        .environmentObject(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appModel.startNetworkEnvironmentMonitoring()
          appModel.warmTunHelperRegistrationOnLaunch()
          appModel.warmPreviewRuntimeOnLaunch()
        }
    }
  }
}

private struct MenuBarStatusLabel: View {
  @ObservedObject var appModel: AppModel

  var body: some View {
    let runtime = MenuBarRuntimePresentation(appModel: appModel)

    Image("ClashMaxMenuBarLogo")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 16, height: 16)
      .foregroundStyle(runtime.tint)
      .accessibilityLabel(Text("ClashMax \(runtime.title)"))
      .help(runtime.detail ?? runtime.title)
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
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    NSApp.setActivationPolicy(.regular)
    if UserDefaults.standard.bool(forKey: AppModel.silentStartDefaultsKey) {
      DispatchQueue.main.async {
        NSApp.windows.forEach { $0.orderOut(nil) }
      }
    } else {
      Self.showMainWindow()
    }
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
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

  @objc private func workspaceDidWake(_ notification: Notification) {
    appModel?.handleNetworkEnvironmentMayHaveChanged(reason: "wake")
  }

  @objc func applicationDidBecomeActive(_ notification: Notification) {
    appModel?.handleNetworkEnvironmentMayHaveChanged(reason: "activation")
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

extension Notification.Name {
  static let clashMaxImportClashXRequested = Notification.Name("io.github.clashmax.import-clashx-requested")
}
