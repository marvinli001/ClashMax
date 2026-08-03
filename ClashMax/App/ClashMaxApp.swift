import AppKit
import SwiftUI

@main
struct ClashMaxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appModel = AppModel.bootstrap()
  @State private var appUpdateController = AppUpdateController()
  @Environment(\.openWindow) private var openWindow
  private let bundledCoreInfo = BundledCoreInfo()
  // Read once at process start: launch behavior is a scene-construction decision,
  // and the toggle only affects the NEXT launch anyway.
  private let silentStartRequested = UserDefaults.standard.bool(forKey: AppModel.silentStartDefaultsKey)

  var body: some Scene {
    WindowGroup("ClashMax", id: "main") {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.providerAnalytics)
        .environmentObject(appModel.runtimeSnippetLibrary)
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environment(appModel.runtimeData)
        .environment(appModel.publicIP)
        .environment(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
          appDelegate.appModel = appModel
          appDelegate.setMainWindowOpener { openWindow(id: "main") }
          if AppLaunchWarmupPolicy.shouldRunForCurrentProcess {
            appModel.startNetworkEnvironmentMonitoring()
            appModel.warmTunHelperRegistrationOnLaunch()
            appModel.warmPreviewRuntimeOnLaunch()
            if LaunchAtLoginRepairLaunchGate.shouldRun {
              appModel.repairLaunchAtLoginRegistrationOnLaunch()
            }
          }
        }
        .onOpenURL { url in
          AppDelegate.showMainWindow()
          appModel.handleIncomingURL(url)
        }
    }
    .defaultSize(width: 1180, height: 760)
    // .suppressed keeps the window from ever being created during a silent
    // launch, instead of racing to orderOut windows after AppKit presents them
    // (the AppDelegate orderOut pass stays as a fallback for restored windows).
    .defaultLaunchBehavior(silentStartRequested ? .suppressed : .presented)
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

        Button("Import Client") {
          AppDelegate.showMainWindow()
          appModel.selectedSection = .profiles
          NotificationCenter.default.post(name: .clashMaxImportClashXRequested, object: nil)
        }
      }
    }

    MenuBarExtra {
      MenuBarView()
        .menuBarPanelChrome()
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.providerAnalytics)
        .environmentObject(appModel.runtimeSnippetLibrary)
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environment(appModel.runtimeData)
        .environment(appModel.publicIP)
        .environment(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appDelegate.setMainWindowOpener { openWindow(id: "main") }
          if AppLaunchWarmupPolicy.shouldRunForCurrentProcess {
            appModel.startNetworkEnvironmentMonitoring()
            appModel.warmTunHelperRegistrationOnLaunch()
            appModel.warmPreviewRuntimeOnLaunch()
            if LaunchAtLoginRepairLaunchGate.shouldRun {
              appModel.repairLaunchAtLoginRegistrationOnLaunch()
            }
          }
        }
    } label: {
      MenuBarStatusLabel(appModel: appModel)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(bundledCoreInfo: bundledCoreInfo)
        // The Settings scene has no window toolbar to publish into, so this page
        // keeps its inline header instead of the title-bar chrome the main window uses.
        .environment(\.pageChromePlacement, .inline)
        .environmentObject(appModel)
        .environmentObject(appModel.settings)
        .environmentObject(appModel.profileStore)
        .environmentObject(appModel.providerAnalytics)
        .environmentObject(appModel.runtimeSnippetLibrary)
        .environmentObject(appModel.profileCoordinator)
        .environmentObject(appModel.systemProxy)
        .environment(appModel.runtimeData)
        .environment(appModel.publicIP)
        .environment(appUpdateController)
        .appThemeAppearance(appModel.settings.appTheme)
        .onAppear {
          appDelegate.appModel = appModel
          appDelegate.setMainWindowOpener { openWindow(id: "main") }
          if AppLaunchWarmupPolicy.shouldRunForCurrentProcess {
            appModel.startNetworkEnvironmentMonitoring()
            appModel.warmTunHelperRegistrationOnLaunch()
            appModel.warmPreviewRuntimeOnLaunch()
            if LaunchAtLoginRepairLaunchGate.shouldRun {
              appModel.repairLaunchAtLoginRegistrationOnLaunch()
            }
          }
        }
    }
  }
}

private struct MenuBarStatusLabel: View {
  @ObservedObject var appModel: AppModel
  // RuntimeDataStore is @Observable, so SwiftUI tracks the `trafficSample` /
  // `trafficHistory` reads in `body` directly off this plain reference — no
  // property wrapper needed. appModel stays @ObservedObject for now (its broad
  // ObservableObject migration is out of scope for this change).
  let runtimeData: RuntimeDataStore

  init(appModel: AppModel) {
    self.appModel = appModel
    self.runtimeData = appModel.runtimeData
  }

  var body: some View {
    let runtime = MenuBarRuntimePresentation(appModel: appModel)
    let trafficLines = MenuBarTrafficStatusLabel.lines(
      showsTraffic: runtime.showsTraffic,
      hasTrafficData: !runtimeData.trafficHistory.isEmpty,
      sample: runtimeData.trafficSample
    )

    Group {
      if let trafficLines {
        Image(nsImage: MenuBarStatusItemImage.render(
          lines: trafficLines,
          logo: NSImage(named: "ClashMaxMenuBarLogo")
        ))
      } else {
        Image("ClashMaxMenuBarLogo")
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
          .foregroundStyle(runtime.tint)
      }
    }
    .accessibilityLabel(Text("ClashMax \(runtime.title)"))
    .help(runtime.detail ?? runtime.title)
  }
}

// MenuBarExtra renders its label through two different paths: a label that
// resolves to a single Image reaches the status item's native image slot, where
// any NSImage renders at full menu-bar height and templates tint automatically.
// A composite label (e.g. HStack of logo + traffic) instead goes through a
// flattening pass that silently DROPS dynamically created Image(nsImage:) and
// Canvas content and clamps Text to a single line. So the logo and both traffic
// rows must be composited into one template NSImage and returned as the label's
// only view. (Verified on macOS 26.5 with a status-bar window probe, 2026-08-03.)
enum MenuBarStatusItemImage {
  static var textFont: NSFont { .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium) }
  static let rowHeight: CGFloat = 9
  static let logoPointSize: CGFloat = 16
  static let logoTextGap: CGFloat = 4

  static func render(lines: MenuBarTrafficStatusLabel.Lines, logo: NSImage?) -> NSImage {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: textFont,
      // Template images only use the alpha channel; black keeps full coverage.
      .foregroundColor: NSColor.black,
    ]
    let upload = NSAttributedString(string: lines.upload, attributes: attributes)
    let download = NSAttributedString(string: lines.download, attributes: attributes)
    let uploadSize = upload.size()
    let downloadSize = download.size()
    let textWidth = ceil(max(uploadSize.width, downloadSize.width))
    // Two 9pt rows keep the image inside the 22pt status-item height.
    let height = rowHeight * 2
    let logoWidth = logo == nil ? 0 : logoPointSize
    let gap = logo == nil ? 0 : logoTextGap
    let width = logoWidth + gap + textWidth
    let textMinX = logoWidth + gap
    let size = NSSize(width: width, height: height)

    // Pre-rasterized at 2x rather than handler-backed so the status item always
    // has concrete bitmap content to composite and template-mask.
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(width * scale),
      pixelsHigh: Int(height * scale),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return NSImage(size: size)
    }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    logo?.draw(in: NSRect(
      x: 0,
      y: (height - logoPointSize) / 2,
      width: logoPointSize,
      height: logoPointSize
    ))
    // Right-aligned rows keep the units flush while the digit widths vary.
    download.draw(at: NSPoint(x: textMinX + textWidth - downloadSize.width, y: 0))
    upload.draw(at: NSPoint(x: textMinX + textWidth - uploadSize.width, y: rowHeight))
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = true
    return image
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

struct AppActivationPolicyWindowSnapshot {
  let canBecomeMain: Bool
  let isVisible: Bool
  let isMiniaturized: Bool
  let isPanel: Bool

  init(
    canBecomeMain: Bool,
    isVisible: Bool,
    isMiniaturized: Bool,
    isPanel: Bool = false
  ) {
    self.canBecomeMain = canBecomeMain
    self.isVisible = isVisible
    self.isMiniaturized = isMiniaturized
    self.isPanel = isPanel
  }

  @MainActor
  init(window: NSWindow) {
    self.init(
      canBecomeMain: window.canBecomeMain,
      isVisible: window.isVisible,
      isMiniaturized: window.isMiniaturized,
      isPanel: window is NSPanel
    )
  }

  var keepsDockActive: Bool {
    isRegularAppWindow && (isVisible || isMiniaturized)
  }

  var isRegularAppWindow: Bool {
    canBecomeMain && !isPanel
  }
}

enum AppActivationPolicyResolver {
  static func policy(
    for windows: [AppActivationPolicyWindowSnapshot]
  ) -> NSApplication.ActivationPolicy {
    windows.contains(where: \.keepsDockActive) ? .regular : .accessory
  }

  static func shouldRefreshAfterClosing(_ window: AppActivationPolicyWindowSnapshot) -> Bool {
    window.isRegularAppWindow
  }

  static func shouldOpenMainWindow(
    for windows: [AppActivationPolicyWindowSnapshot]
  ) -> Bool {
    !windows.contains(where: \.isRegularAppWindow)
  }
}

/// Debug builds usually run from DerivedData, and auto-registering those paths
/// as the login item is exactly how stale BTM records get created (the record
/// then points at a build product that the next clean deletes). The silent
/// launch-time repair therefore only ships in Release builds; the settings
/// toggle still registers explicitly in every configuration.
enum LaunchAtLoginRepairLaunchGate {
  static var shouldRun: Bool {
    #if DEBUG
    false
    #else
    true
    #endif
  }
}

enum AppLaunchWarmupPolicy {
  static var shouldRunForCurrentProcess: Bool {
    shouldRun(
      environment: ProcessInfo.processInfo.environment,
      isXCTestCaseAvailable: NSClassFromString("XCTest.XCTestCase") != nil,
      bundlePaths: Bundle.allBundles.map(\.bundlePath)
    )
  }

  static func shouldRun(
    environment: [String: String],
    isXCTestCaseAvailable: Bool,
    bundlePaths: [String]
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] == nil
      && environment["XCTestBundlePath"] == nil
      && !isXCTestCaseAvailable
      && !bundlePaths.contains { $0.hasSuffix(".xctest") }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static weak var sharedDelegate: AppDelegate?

  weak var appModel: AppModel?
  private var terminationCleanupInFlight = false
  private var openMainWindow: (() -> Void)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.sharedDelegate = self
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeMain(_:)),
      name: NSWindow.didBecomeMainNotification,
      object: nil
    )
    if UserDefaults.standard.bool(forKey: AppModel.silentStartDefaultsKey) {
      // Intentionally deferred to the next main runloop: WindowGroup windows are
      // not all instantiated synchronously during launch, so order them out only
      // after AppKit/SwiftUI has finished creating them.
      DispatchQueue.main.async {
        NSApp.windows.forEach { $0.orderOut(nil) }
        Self.refreshActivationPolicyForCurrentWindows()
      }
    } else {
      Self.showMainWindow()
    }
  }

  deinit {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
  }

  func setMainWindowOpener(_ opener: @escaping () -> Void) {
    openMainWindow = opener
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
    // Login-item state can change behind the app's back in System Settings;
    // re-read it whenever the user comes back so the toggle stays honest.
    appModel?.refreshLaunchSettings()
  }

  @objc private func windowWillClose(_ notification: Notification) {
    guard
      let window = notification.object as? NSWindow,
      AppActivationPolicyResolver.shouldRefreshAfterClosing(
        AppActivationPolicyWindowSnapshot(window: window)
      )
    else { return }
    Self.scheduleActivationPolicyRefresh()
  }

  @objc private func windowDidBecomeMain(_ notification: Notification) {
    Self.refreshActivationPolicyForCurrentWindows()
  }

  @MainActor
  static func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    let shouldOpenWindow = AppActivationPolicyResolver.shouldOpenMainWindow(
      for: NSApp.windows.map(AppActivationPolicyWindowSnapshot.init(window:))
    )
    if shouldOpenWindow {
      sharedDelegate?.openMainWindow?()
    }
    sharedDelegate?.appModel?.resumeDeferredInitialTunHelperPromptAfterUserOpen()
    activateRegularWindows()
    // Intentionally deferred to the next main runloop: activation does not
    // reliably take on the first call during the .accessory -> .regular policy
    // transition, so re-activate once AppKit has applied the new policy.
    DispatchQueue.main.async {
      activateRegularWindows()
    }
  }

  private static func activateRegularWindows() {
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    for window in NSApp.windows
    where AppActivationPolicyWindowSnapshot(window: window).isRegularAppWindow {
      if window.isMiniaturized {
        window.deminiaturize(nil)
      }
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate()
  }

  @MainActor
  static func refreshActivationPolicyForCurrentWindows() {
    let snapshots = NSApp.windows.map(AppActivationPolicyWindowSnapshot.init(window:))
    let policy = AppActivationPolicyResolver.policy(for: snapshots)
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
  }

  private static func scheduleActivationPolicyRefresh() {
    // Intentionally deferred to the next main runloop: callers such as
    // windowWillClose fire while the closing window is still in NSApp.windows,
    // so recompute the activation policy after it has actually been removed.
    DispatchQueue.main.async {
      refreshActivationPolicyForCurrentWindows()
    }
  }
}

extension Notification.Name {
  static let clashMaxImportClashXRequested = Notification.Name("io.github.clashmax.import-clashx-requested")
}
