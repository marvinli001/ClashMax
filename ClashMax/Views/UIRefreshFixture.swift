#if DEBUG
  import AppKit
  import ServiceManagement
  import SwiftUI

  /// Separate process entry: P0 has no model; production captures use temporary stores with services disabled.
  @MainActor
  enum UIRefreshFixture {
    private static var temporaryDirectory: URL?
    private static var defaultsDomain: String?

    static func cleanup() {
      if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
      if let defaultsDomain { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
    }

    static func run() {
      if ProcessInfo.processInfo.arguments.contains("--production")
        || Bundle.main.bundleIdentifier?.hasPrefix("io.github.clashmax.UIFixture.") == true
      {
        ClashMaxFixtureApp.main()
        return
      }
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      let arguments = ProcessInfo.processInfo.arguments
      let dark = arguments.contains("--dark")
      let menu = arguments.contains("--menu")
      let size = menu ? NSSize(width: 320, height: 520)
        : arguments.contains("--settings-window") ? NSSize(width: 880, height: 680)
        : NSSize(width: arguments.contains("--wide") ? 1480 : arguments.contains("--minimum") ? 980 : 1180,
                 height: arguments.contains("--wide") ? 900 : arguments.contains("--minimum") ? 660 : 760)
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
      window.title = "ClashMax · Synthetic UI Fixture"
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let sectionIndex = arguments.firstIndex(of: "--page")
      let section = sectionIndex.flatMap { arguments.indices.contains($0 + 1) ? AppSection(rawValue: arguments[$0 + 1]) : nil } ?? .home
      let view = UIRefreshPrototype(menuOnly: menu, initialSection: section)
        .preferredColorScheme(dark ? .dark : .light)
      window.contentView = NSHostingView(rootView: AnyView(view))
      window.center()
      window.makeKeyAndOrderFront(nil)
      app.activate(ignoringOtherApps: true)
      if let index = arguments.firstIndex(of: "--capture"), arguments.indices.contains(index + 1) {
        let path = arguments[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          if arguments.contains("--layout"), let root = window.contentView {
            @MainActor
            func inspect(_ view: NSView) {
              if view is NSScrollView || view is NSTableView || view is NSSearchField {
                print(String(describing: type(of: view)), view.convert(view.bounds, to: root))
              }
              for child in view.subviews { inspect(child) }
            }
            inspect(root)
          }
          let capture = Process()
          capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
          let target = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) } ?? window
          if arguments.contains("--layout") {
            for owned in NSApp.windows {
              print("FixtureWindow", owned.windowNumber, owned.title, owned.isVisible, owned.isKeyWindow, owned.frame)
            }
          }
          target.makeKeyAndOrderFront(nil)
          capture.arguments = ["-x", "-o", "-l", String(target.windowNumber), path]
          do {
            try capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus != 0 {
              cleanup()
              exit(capture.terminationStatus)
            }
          } catch {
            fputs("Fixture capture failed: \(error)\n", stderr)
          }
          cleanup()
          app.terminate(nil)
        }
      }
      if arguments.contains("--timed") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { cleanup(); app.terminate(nil) }
      }
      app.run()
    }
  }

  private struct ClashMaxFixtureApp: App {
    @NSApplicationDelegateAdaptor(FixtureAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var model: AppModel
    @State private var updateController = AppUpdateController(startsUpdater: false)
    private let arguments = ProcessInfo.processInfo.arguments

    init() {
      do {
        let model = try UIRefreshFixture.makeProductionModel(arguments: ProcessInfo.processInfo.arguments)
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--page"), ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
          model.selectedSection = AppSection(rawValue: ProcessInfo.processInfo.arguments[index + 1]) ?? .home
        }
        _model = State(initialValue: model)
      } catch {
        fputs("Fixture failed: \(error)\n", stderr)
        UIRefreshFixture.cleanup()
        exit(1)
      }
    }

    var body: some Scene {
      let _ = delegate.configure(model: model) { openWindow(id: "ui-fixture") }
      WindowGroup("ClashMax", id: "ui-fixture") {
        FixtureProductionRoot(menu: arguments.contains("--menu"), settingsWindow: arguments.contains("--settings-window"))
          .environment(model).environment(model.settings).environment(model.profileStore)
          .environment(model.providerAnalytics).environment(model.runtimeSnippetLibrary)
          .environment(model.profileCoordinator).environment(model.systemProxy)
          .environment(model.runtimeData).environment(model.publicIP).environment(updateController)
          .preferredColorScheme(arguments.contains("--dark") ? .dark : .light)
          .frame(minWidth: arguments.contains("--menu") ? 320 : arguments.contains("--settings-window") ? 740 : 980,
                 minHeight: arguments.contains("--menu") ? 420 : arguments.contains("--settings-window") ? 560 : 660)
      }
      .defaultSize(width: arguments.contains("--menu") ? 320 : arguments.contains("--settings-window") ? 880 : arguments.contains("--wide") ? 1480 : arguments.contains("--minimum") ? 980 : 1180,
                   height: arguments.contains("--menu") ? 520 : arguments.contains("--settings-window") ? 680 : arguments.contains("--wide") ? 900 : arguments.contains("--minimum") ? 660 : 760)
      .defaultLaunchBehavior(.presented)
      .restorationBehavior(.disabled)
      .commands { WorkspaceFindCommands(); InspectorCommands() }
    }
  }

  private final class FixtureAppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: (() -> Void)?
    private var model: AppModel?
    func configure(model: AppModel, opener: @escaping () -> Void) {
      self.model = model
      openWindow = opener
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      NSApp.setActivationPolicy(.regular)
      DispatchQueue.main.async {
        if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { self.openWindow?() }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          guard let model = self.model,
                let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
          UIRefreshFixture.prepareProductionWindow(window, model: model)
        }
      }
    }
  }

  private struct FixtureProductionRoot: View {
    let menu: Bool
    let settingsWindow: Bool
    var body: some View {
      if menu { MenuBarView() }
      else if settingsWindow { SettingsView().environment(\.pageChromePlacement, .inline) }
      else { ContentView() }
    }
  }

  private extension UIRefreshFixture {
    static func prepareProductionWindow(_ window: NSWindow, model: AppModel) {
      DispatchQueue.main.async { configureProductionWindow(window, model: model) }
    }

    static func configureProductionWindow(_ window: NSWindow, model: AppModel) {
      let arguments = ProcessInfo.processInfo.arguments
      let size = arguments.contains("--menu") ? NSSize(width: 320, height: 520)
        : arguments.contains("--settings-window") ? NSSize(width: 880, height: 680)
        : NSSize(width: arguments.contains("--wide") ? 1480 : arguments.contains("--minimum") ? 980 : 1180,
                 height: arguments.contains("--wide") ? 900 : arguments.contains("--minimum") ? 660 : 760)
      window.setContentSize(size)
      window.center()
      window.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      if arguments.contains("--exercise") { exercise(model: model, window: window) }
      if arguments.contains("--animate-start") {
        Task { @MainActor in
          let groups = model.runtimeData.proxyGroups
          let connections = model.runtimeData.connections
          let samples = model.runtimeData.trafficHistory
          try? await Task.sleep(for: .milliseconds(1_500))
          model.runtimeData.clearRuntimeCollections()
          model.coreController.transitionVisualFixture(to: .starting)
          try? await Task.sleep(for: .milliseconds(1_600))
          model.coreController.transitionVisualFixture(to: .running(version: "Synthetic fixture"))
          model.configureVisualFixtureOwnership(startedAt: Date())
          model.runtimeData.proxyGroups = groups
          model.runtimeData.connections = connections
          for sample in samples { model.runtimeData.appendTrafficSample(sample) }
        }
      }
      if arguments.contains("--show-details") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
          guard let root = window.contentView else { return }
          @MainActor
          func select(_ view: NSView) {
            if let table = view as? NSTableView, table.bounds.width > 400, table.numberOfRows > 0 {
              window.makeFirstResponder(table)
              table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            for child in view.subviews { select(child) }
          }
          select(root)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let location = NSPoint(x: window.frame.width - (model.selectedSection == .profiles ? 158 : 134),
                                   y: window.frame.height - 111)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
              if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1)
              {
                window.sendEvent(event)
              }
            }
            print("Fixture details button clicked in the synthetic window")
          }
        }
      }
      if let index = arguments.firstIndex(of: "--capture"), arguments.indices.contains(index + 1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
          if arguments.contains("--layout") {
            print("Fixture window", window.frame, "layout", window.contentLayoutRect, "safe", window.contentView?.safeAreaInsets as Any)
            @MainActor
            func inspect(_ view: NSView) {
              if view is NSScrollView || view is NSTableView || view is NSSearchField {
                print(String(describing: type(of: view)), view.convert(view.bounds, to: window.contentView))
              }
              for child in view.subviews { inspect(child) }
            }
            if let root = window.contentView { inspect(root) }
          }
          let capture = Process()
          capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
          capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), arguments[index + 1]]
          do { try capture.run(); capture.waitUntilExit() }
          catch { fputs("Capture failed: \(error)\n", stderr); cleanup(); exit(1) }
          cleanup()
          exit(capture.terminationStatus)
        }
      }
      if arguments.contains("--timed") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { cleanup(); exit(0) }
      }
    }

    static func makeProductionModel(arguments: [String]) throws -> AppModel {
      let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClashMax-UIFixture-" + UUID().uuidString)
      temporaryDirectory = directory
      let paths = RuntimePaths(appSupport: directory, profiles: directory.appendingPathComponent("Profiles"),
                               runtime: directory.appendingPathComponent("Runtime"), subscriptions: directory.appendingPathComponent("Subscriptions"),
                               logs: directory.appendingPathComponent("Logs"))
      try paths.prepareDirectories()
      let secrets = FixtureSecrets()
      let store = ProfileStore(paths: paths, keychain: secrets)
      var sourceURL: URL?
      if !arguments.contains("--empty") {
        let name = arguments.contains("--long-text") ? "Example Workspace · 长配置名称与键盘可访问性验证 · A very long synthetic profile name for layout inspection.yaml" : "Example Workspace.yaml"
        let source = directory.appendingPathComponent(name)
        try "proxies:\n  - name: Example Node\n    type: socks5\n    server: 192.0.2.10\n    port: 1080\nproxy-groups:\n  - name: Default\n    type: select\n    proxies: [Example Node, DIRECT]\nrules:\n  - MATCH,Default\n".write(to: source, atomically: true, encoding: .utf8)
        sourceURL = source
      }
      let domain = "ClashMax.UIFixture." + UUID().uuidString
      defaultsDomain = domain
      let defaults = UserDefaults(suiteName: domain)!
      let state: CoreStatus = arguments.contains("--crashed") ? .crashed(message: String(repeating: "Synthetic validation error: example configuration needs attention. ", count: arguments.contains("--long-text") ? 6 : 1))
        : arguments.contains("--starting") ? .starting : arguments.contains("--stopped") || arguments.contains("--empty") || arguments.contains("--animate-start") ? .stopped : .running(version: "Synthetic fixture")
      let endpoints = OutboundProxyEndpointStore(manifestURL: paths.outboundProxyEndpointManifestURL, secretStore: secrets)
      let model = AppModel(paths: paths, isVisualFixture: true, profileStore: store, outboundProxyEndpointStore: endpoints,
                           coreController: .visualFixture(status: state), loginItemService: FixtureLoginItems(),
                           publicIPInfoClient: FixturePublicIP(), defaults: defaults, externalDashboardSecretStore: secrets)
      model.configureVisualFixtureOwnership()
      let count = arguments.contains("--stress") ? 2_000 : 18
      let nodes = (0..<count).map { index in
        ProxyNode(name: ["Tokyo", "Singapore", "Auckland", "Seoul", "Frankfurt", "Los Angeles"][index % 6] + " · Example \(index + 1)" + (arguments.contains("--long-text") ? " · A very long synthetic node name · 长名称验证" : ""),
                  type: index % 2 == 0 ? "vless" : "trojan", delay: 28 + index * 7 % 280, isSelectable: true)
      }
      let groups = ["Default", "Streaming", "Development"].enumerated().map { index, name in
        ProxyGroup(name: name, type: "select", selected: nodes[index].name, nodes: nodes)
      }
      model.runtimeData.proxyGroups = groups
      model.profilePreviewGroups = groups
      if arguments.contains("--preview") {
        model.previewRuntimeActive = true
        model.systemProxyEnabled = false
      }
      for index in 0..<72 {
        model.runtimeData.appendTrafficSample(TrafficSample(upload: 200_000 + Int(abs(sin(Double(index) / 6)) * 1_800_000),
                                                            download: 500_000 + Int(abs(sin(Double(index) / 9)) * 12_000_000)))
      }
      model.runtimeData.connections = (0..<32).map { index in
        ConnectionSnapshot(id: "fixture-\(index)", network: index % 3 == 0 ? "udp" : "tcp", host: "service-\(index).example.com",
                           sourceIP: "192.0.2.2", destinationIP: "203.0.113.\(index + 1)", destinationPort: 443,
                           processName: ["Safari", "Mail", "TextEdit"][index % 3],
                           processPath: ["/Applications/Safari.app/Contents/MacOS/Safari",
                                         "/System/Applications/Mail.app/Contents/MacOS/Mail",
                                         "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"][index % 3],
                           upload: index * 3200, download: index * 140_000, chain: [nodes[index % nodes.count].name, "Default"],
                           rule: "DomainSuffix", rulePayload: "example.com", startedAt: Date().addingTimeInterval(-Double(index * 8)))
      }
      model.runtimeData.rules = (0..<120).map { index in
        RuntimeRule(index: index, type: "DomainSuffix", payload: "service-\(index).example.com", policy: index % 4 == 0 ? "DIRECT" : "Default")
      }
      for index in 0..<(arguments.contains("--stress") ? 2_000 : 40) {
        model.runtimeData.appendLog(level: index % 9 == 0 ? "warning" : "info", message: "[Synthetic] service-\(index).example.com:443 matched DomainSuffix using Default · Example network event")
      }
      model.runtimeData.flushPendingLogs()
      Task { @MainActor in
        do {
          if let sourceURL { _ = try await store.importLocalConfig(from: sourceURL) }
          await model.runtimeSnippetLibrary.waitForLoad()
          try await model.runtimeSnippetLibrary.saveSnippet(RuntimeSnippet(name: "Example YAML Patch", payload: .rawYAML(RawYAMLPatchSettings(yaml: "# 合成配置\nprofile:\n  store-selected: true\n"))))
        } catch {
          fputs("Fixture data failed: \(error)\n", stderr)
          cleanup()
          exit(1)
        }
      }
      if arguments.contains("--no-groups") {
        model.runtimeData.proxyGroups = []
        model.profilePreviewGroups = []
      }
      if arguments.contains("--empty") {
        model.runtimeData.clearRuntimeCollections()
        model.profilePreviewGroups = []
      }
      return model
    }

    static func exercise(model: AppModel, window: NSWindow) {
      Task { @MainActor in
        for tick in 0..<44 {
          if tick == 0 { model.selectedSection = .home }
          if tick == 8 { model.selectedSection = .proxies }
          if tick == 28 { model.selectedSection = .logs }
          var groups = model.runtimeData.proxyGroups
          for groupIndex in groups.indices {
            for nodeIndex in stride(from: tick % 20, to: groups[groupIndex].nodes.count, by: 20) {
              groups[groupIndex].nodes[nodeIndex].delay = 20 + (tick * 7 + nodeIndex) % 280
            }
          }
          model.runtimeData.proxyGroups = groups
          model.runtimeData.appendLog(level: "info", message: "[Synthetic stress] batch \(tick) example.com updated")
          model.runtimeData.flushPendingLogs()
          model.runtimeData.appendTrafficSample(TrafficSample(upload: tick * 4_000, download: tick * 300_000))
          if let root = window.contentView {
            @MainActor
            func scroll(_ view: NSView) {
              if let viewport = view as? NSScrollView, viewport.bounds.width > 400, viewport.bounds.height > 200 {
                let maximum = max(0, (viewport.documentView?.bounds.height ?? 0) - viewport.bounds.height)
                viewport.contentView.scroll(to: NSPoint(x: 0, y: maximum * CGFloat(tick % 8) / 7))
                viewport.reflectScrolledClipView(viewport.contentView)
              }
              for child in view.subviews { scroll(child) }
            }
            scroll(root)
            if tick == 16, let field = root.firstDescendant(of: NSSearchField.self) {
              field.stringValue = "Tokyo"
              field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    }
  }

  private struct FixtureSecrets: SecretStoring {
    func save(_ value: String, account: String) throws {}
    func load(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
  }

  private final class FixtureLoginItems: LoginItemManaging {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {}
    func unregister() async throws {}
    func openSystemSettingsLoginItems() {}
  }

  private struct FixturePublicIP: PublicIPInfoFetching {
    func fetchPublicIPInfo() async throws -> PublicIPInfo {
      PublicIPInfo(ipAddress: "203.0.113.42", countryCode: "JP", countryName: "Japan", city: "Tokyo", asn: "AS64496", isp: "Example Network",
                   sourceName: "Synthetic fixture", sourceHost: "example.com", fetchedAt: Date())
    }
  }

  private struct UIRefreshPrototype: View {
    let menuOnly: Bool
    @State private var section: AppSection = .home
    @State private var query = ""
    @State private var draft = "# 合成配置 · Synthetic configuration\nproxies: []\nrules:\n  - DOMAIN,example.com,DIRECT\n"
    @State private var running = true
    @State private var selectedNode = "Tokyo · Example 01"
    @State private var browsingNode: String?
    private let nodes = ["Tokyo · Example 01", "Singapore · Example 02", "Auckland · Example 03", "Direct"]

    init(menuOnly: Bool, initialSection: AppSection) {
      self.menuOnly = menuOnly
      _section = State(initialValue: initialSection)
    }

    var body: some View {
      if menuOnly {
        menuPanel
      } else {
        NavigationSplitView {
          SidebarView(selection: $section)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
        } detail: {
          VStack(spacing: 0) {
            StatusStripContent(statusSummary: running ? "Running" : "Stopped", statusSymbol: running ? "checkmark.circle.fill" : "stop.circle",
                               statusStyle: running ? .green : .secondary, profileName: "Example Workspace", proxyRoutingStatus: "System Proxy · Synthetic", readinessIssue: nil)
            Divider()
            if section == .proxies {
              proxyWorkspace
            } else if section == .routing {
              VStack {
                WorkspaceSearchField(prompt: "Search", text: $query)
                SnippetTextEditor(text: $draft)
              }.padding(18)
            } else {
              home
            }
          }
          .navigationTitle(section.title)
          .toolbar {
            ToolbarItemGroup {
              Text("Rule").foregroundStyle(.secondary)
              Button(running ? "Stop" : "Start", systemImage: "power") { running.toggle() }
            }
          }
        }
      }
    }

    private var home: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 12) {
            CoreVisualView(state: running ? .running : .stopped, reduceMotion: true)
              .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
              Text("Example Workspace").font(.headline)
              Text("System Proxy · Synthetic data").foregroundStyle(.secondary)
            }
            Spacer()
          }
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
              Label("Current Node", systemImage: "location.circle").font(.headline)
              Menu {
                ForEach(nodes, id: \.self) { node in
                  Button(node) { selectedNode = node }
                }
              } label: {
                Label(selectedNode, systemImage: "point.3.connected.trianglepath.dotted")
                  .padding(.horizontal, 12).padding(.vertical, 8)
              }
              .menuStyle(.borderlessButton)
              .modifier(FunctionalGlass())
              Text("42 ms · VLESS").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading).dashboardCard()
            VStack(alignment: .leading, spacing: 16) {
              Label("Public IP", systemImage: "globe").font(.headline)
              Text("203.0.113.42").font(.title3.monospaced())
              Text("Documentation address · Synthetic").foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading).dashboardCard()
          }
          VStack(alignment: .leading, spacing: 16) {
            Label("Traffic", systemImage: "chart.xyaxis.line").font(.headline)
            HStack(spacing: 28) {
              Label("12.4 MB/s", systemImage: "arrow.down").foregroundStyle(.blue)
              Label("1.8 MB/s", systemImage: "arrow.up").foregroundStyle(.cyan)
            }.font(.title2.monospacedDigit())
            TrafficSparkline(samples: Self.samples, sampleCount: 72).frame(height: 180)
          }.padding(16).dashboardCard()
        }.padding(18)
      }
    }

    private var proxyWorkspace: some View {
      VStack(spacing: 12) {
        WorkspaceSearchField(prompt: "Search", text: $query)
        HStack(spacing: 0) {
          List { Label("Default", systemImage: "point.3.connected.trianglepath.dotted"); Text("Streaming"); Text("Development") }
            .frame(width: 210)
          Divider()
          List(selection: $browsingNode) {
            ForEach(nodes.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { node in
              HStack { Text(node); Spacer(); Text("42 ms").monospacedDigit().foregroundStyle(.secondary)
                if node == selectedNode { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
              }.tag(node)
            }
          }
        }
        HStack {
          Text(browsingNode ?? selectedNode).lineLimit(1)
          Spacer()
          Button(String(localized: "Use")) { if let browsingNode { selectedNode = browsingNode } }.disabled(browsingNode == nil)
        }
        PageStatusFooter(text: "3 groups · 4 synthetic nodes")
      }.padding(18)
    }

    private var menuPanel: some View {
      VStack(alignment: .leading, spacing: 12) {
        Label(running ? "Running" : "Stopped", systemImage: "power.circle.fill").font(.headline)
        Text("Example Workspace").foregroundStyle(.secondary)
        Button(running ? "Stop" : "Start") { running.toggle() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
        Divider()
        HStack { Label("12.4 MB/s", systemImage: "arrow.down"); Spacer(); Label("1.8 MB/s", systemImage: "arrow.up") }.monospacedDigit()
        TrafficSparkline(samples: Self.samples, sampleCount: 72).frame(height: 52)
        Divider()
        LabeledContent("Routing", value: "System Proxy")
        LabeledContent("Run Mode", value: "Rule")
        Menu(selectedNode) { ForEach(nodes, id: \.self) { node in Button(node) { selectedNode = node } } }
        Spacer()
        Divider()
        Button(String(localized: "Open Main Window")) { section = .home }
      }.padding(12).frame(width: 320)
    }

    private static let samples = (0..<72).map { index in
      TrafficSample(upload: 200_000 + Int(abs(sin(Double(index) / 6)) * 1_800_000),
                    download: 500_000 + Int(abs(sin(Double(index) / 9)) * 12_000_000))
    }
  }
#endif
