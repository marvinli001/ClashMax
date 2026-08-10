import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import ClashMax

@MainActor
final class MenuBarPanelLayoutTests: XCTestCase {
  private static let maximumPanelHeight: CGFloat = 560

  func testPanelWidthStaysInsidePlannedRichPanelRange() {
    XCTAssertTrue(MenuBarPanelLayout.plannedWidthRange.contains(MenuBarPanelLayout.width))
    // Control Center's 320pt panel width is the native reference for a rich
    // menu bar panel.
    XCTAssertEqual(MenuBarPanelLayout.width, 320)
    XCTAssertEqual(MenuBarPanelLayout.trailingControlWidth, 162)
    XCTAssertEqual(MenuBarPanelLayout.trafficChartHeight, 52)
    // The trailing column and its row label both have to fit the panel's content
    // box, so the column can never be widened past the point where a row title
    // would have no room left.
    XCTAssertLessThanOrEqual(
      MenuBarPanelLayout.trailingControlWidth + 100,
      MenuBarPanelLayout.width - 2 * MenuBarPanelLayout.padding
    )
  }

  func testPanelAddsNoChromeMarginInsideTheSystemPanel() async throws {
    // `MenuBarExtra(.window)` draws the rounded, blurred panel itself. The app
    // must not wrap its content in a second card: any background/border/outer
    // margin of its own stacks a panel inside the system panel. An outer margin
    // shows up here as content that no longer fills the declared panel width.
    let fixture = try Self.makeFixture()
    defer { fixture.cleanup() }

    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await store.waitForManifestLoad()
    let model = makeAppModel(paths: fixture.paths, store: store, defaults: fixture.defaults)

    let size = fittingSize(
      for: fullPanelView(model: model, localeIdentifier: "en"),
      height: Self.maximumPanelHeight
    )

    XCTAssertEqual(size.width, MenuBarPanelLayout.width, accuracy: 1)
    // Content sits directly against the system panel's edge, inset only enough
    // to clear its rounded corners.
    XCTAssertTrue((8 ... 16).contains(MenuBarPanelLayout.padding))
  }

  func testFullPanelFitsPlannedWidthWithoutProfile() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanup() }

    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    await store.waitForManifestLoad()
    let model = makeAppModel(paths: fixture.paths, store: store, defaults: fixture.defaults)

    let size = fittingSize(
      for: fullPanelView(model: model, localeIdentifier: "zh-Hans"),
      height: Self.maximumPanelHeight
    )

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, Self.maximumPanelHeight)
  }

  func testFullPanelFitsPlannedWidthWithLongProfileName() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanup() }

    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try await importLocalProfile(into: store, paths: fixture.paths)
    try await store.rename(
      profile,
      to: "Long Subscription Profile Name - 香港 日本 美国 自动选择 - Very Long Provider Alias"
    )
    let model = makeAppModel(paths: fixture.paths, store: store, defaults: fixture.defaults)
    model.tunnelCoreRunning = true
    model.trafficSample = TrafficSample(upload: 4096, download: 32768)
    model.trafficHistory = Self.sampleTrafficHistory

    let size = fittingSize(
      for: fullPanelView(model: model, localeIdentifier: "en"),
      height: Self.maximumPanelHeight
    )

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, Self.maximumPanelHeight)
  }

  func testRunningPanelFitsPlannedWidthWithTrafficChart() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanup() }

    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    _ = try await importLocalProfile(into: store, paths: fixture.paths)
    let model = makeAppModel(paths: fixture.paths, store: store, defaults: fixture.defaults)
    model.tunnelCoreRunning = true
    model.trafficSample = TrafficSample(upload: 8192, download: 65536)
    model.trafficHistory = Self.sampleTrafficHistory

    let size = fittingSize(
      for: fullPanelView(model: model, localeIdentifier: "zh-Hans"),
      height: Self.maximumPanelHeight
    )

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, Self.maximumPanelHeight)
  }

  func testTrafficSectionWithEmptySamplesFitsCompactLayout() {
    let view = MenuBarTrafficSection(sample: .zero, history: [])
      .padding(MenuBarPanelLayout.padding)
      .frame(width: MenuBarPanelLayout.width)
      .environment(\.locale, Locale(identifier: "en"))

    let size = fittingSize(for: view, height: 120)

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 96)
  }

  func testHeaderFitsPlannedWidthWithLongProfileAndOwnerLabels() {
    let view = MenuBarHeader(
      runtime: MenuBarRuntimePresentation(
        dashboardRuntimeState: .running,
        runtimeOwner: .networkExtension
      ),
      profileName: "Long Subscription Profile Name - 香港 日本 美国 自动选择 - Very Long Provider Alias",
      ownerName: String(localized: "Network Extension owns transparent proxy routing.")
    )
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
    .environment(\.locale, Locale(identifier: "zh-Hans"))

    let size = fittingSize(for: view)
    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 72)
  }

  func testStatusMessageKeepsLongRecoveryCopyWithinPanelWidth() {
    let view = MenuBarStatusMessage(
      runtime: MenuBarRuntimePresentation(
        dashboardRuntimeState: .blocked(reason: "TUN helper requires approval."),
        runtimeOwner: .stopped,
        readinessIssue: "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status."
      )
    )
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
    .environment(\.locale, Locale(identifier: "en"))

    let size = fittingSize(for: view)
    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 104)
  }

  func testControlRowKeepsFixedControlColumnInsidePanelWidth() {
    let view = MenuBarControlRow(title: String(localized: "Proxy Routing"), systemImage: "network") {
      Text(String(localized: "System Proxy"))
        .lineLimit(1)
        .frame(width: MenuBarPanelLayout.trailingControlWidth, alignment: .trailing)
    }
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
    .environment(\.locale, Locale(identifier: "zh-Hans"))

    let size = fittingSize(for: view)
    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 52)
  }

  func testGroupSelectionRowKeepsLongGroupNodeAndDelayInsidePanelWidth() {
    let view = MenuBarControlRow(
      title: "Proxy Group - 香港 日本 美国 自动选择 - Very Long Provider Alias",
      systemImage: "point.3.connected.trianglepath.dotted"
    ) {
      groupSelector(
        node: "Auto Select - Hong Kong Premium Relay With A Very Long Name",
        delay: .measured(8888)
      )
    }
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
    .environment(\.locale, Locale(identifier: "zh-Hans"))

    let size = fittingSize(for: view)

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 52)
  }

  func testRunModeProfileAndGroupSelectorShareOneDrawnControlWidth() throws {
    // The three control rows must present one aligned column. Measuring the view
    // tree is not enough: a stock popup button reports whatever width its frame
    // claims while AppKit draws the bezel at its own intrinsic width, which is
    // exactly how the rows drifted apart (79 / 90 / 118pt for Run Mode / Profile
    // / a group). So this measures the *drawn* bezel out of a render.
    let panel = VStack(alignment: .leading, spacing: 7) {
      MenuBarSelectionMenu {
        Button("Rule") {}
      } value: {
        Label(RunMode.rule.displayName, systemImage: "list.bullet.rectangle")
      }

      MenuBarSelectionMenu {
        Button("Elite") {}
      } value: {
        Label("Elite", systemImage: "arrow.triangle.2.circlepath.circle")
      }

      groupSelector(node: "[vless]JP Nano", delay: .measured(66))

      // The cap: an absurd node name must not widen the column past the others.
      groupSelector(
        node: "[vless] 日本 东京 IEPL 专线 中继 - Premium Relay Node 01 - 倍率 0.2",
        delay: .measured(8888)
      )

      groupSelector(node: "JP", delay: .unknown)
        .disabled(true)
    }
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width, alignment: .leading)
    .environment(\.locale, Locale(identifier: "zh-Hans"))

    let bezels = try Self.drawnRowWidths(for: panel)

    XCTAssertEqual(bezels.count, 5, "expected one drawn bezel per selection row, got \(bezels)")
    for width in bezels {
      XCTAssertEqual(
        width,
        MenuBarPanelLayout.trailingControlWidth,
        accuracy: 1.5,
        "a selection control drew at \(width)pt instead of the shared column width"
      )
    }
  }

  private func groupSelector(node: String, delay: ProxyDelayState) -> some View {
    MenuBarSelectionMenu {
      Button(node) {}
    } value: {
      MenuBarGroupSelectionLabel(selectedNode: node, delay: ProxyDelayDisplay(state: delay))
    }
  }

  /// Widths of the painted horizontal bands in a rendered view — one band per
  /// control row here, because the panel itself paints no background.
  private static func drawnRowWidths<Content: View>(for view: Content) throws -> [CGFloat] {
    let hostingView = NSHostingView(rootView: view)
    hostingView.appearance = NSAppearance(named: .aqua)
    hostingView.setFrameSize(NSSize(width: MenuBarPanelLayout.width, height: 400))
    hostingView.layoutSubtreeIfNeeded()
    hostingView.setFrameSize(hostingView.fittingSize)
    hostingView.layoutSubtreeIfNeeded()

    let rep = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

    let scale = CGFloat(rep.pixelsWide) / hostingView.bounds.width
    var widths: [CGFloat] = []
    var band: (first: Int, last: Int)?

    for y in 0..<rep.pixelsHigh {
      let painted = (0..<rep.pixelsWide).filter { x in
        (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02
      }
      if let first = painted.first, let last = painted.last {
        band = (min(band?.first ?? first, first), max(band?.last ?? last, last))
      } else if let finished = band {
        widths.append(CGFloat(finished.last - finished.first + 1) / scale)
        band = nil
      }
    }
    if let finished = band {
      widths.append(CGFloat(finished.last - finished.first + 1) / scale)
    }
    return widths
  }

  func testProxyModeSelectorRowFitsPanelWidthInEnglishAndChinese() {
    // Mirrors `MenuBarProxyModeSelector`'s layout (title + three icon/short-label
    // options) without needing an `AppModel`. Both locales must stay inside the
    // 312pt panel and on one compact line.
    let localizedTitles: [(locale: String, title: String)] = [
      ("en", "Proxy Mode"),
      ("zh-Hans", "代理模式")
    ]

    for testCase in localizedTitles {
      let view = MenuBarControlRow(
        title: testCase.title,
        systemImage: "network.badge.shield.half.filled"
      ) {
        HStack(spacing: 8) {
          ForEach(ProxyRoutingMode.allCases) { mode in
            Button {} label: {
              MenuBarProxyModeOptionLabel(mode: mode)
            }
            .buttonStyle(.borderless)
          }
        }
      }
      .padding(MenuBarPanelLayout.padding)
      .frame(width: MenuBarPanelLayout.width)
      .environment(\.locale, Locale(identifier: testCase.locale))

      let size = fittingSize(for: view, height: 80)

      XCTAssertLessThanOrEqual(
        size.width,
        MenuBarPanelLayout.width + 1,
        "Proxy Mode row overflowed the panel in \(testCase.locale)"
      )
      XCTAssertLessThanOrEqual(
        size.height,
        52,
        "Proxy Mode row was not compact in \(testCase.locale)"
      )
    }
  }

  func testFooterButtonLabelsKeepLongEnglishAndChineseTitlesInsidePanelWidth() {
    let view = HStack(spacing: 5) {
      MenuBarFooterButtonLabel(
        title: "Update Subscription Providers",
        systemImage: "arrow.triangle.2.circlepath"
      )
      MenuBarFooterButtonLabel(
        title: "更新全部订阅和远程提供者",
        systemImage: "shippingbox"
      )
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .font(.caption)
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)

    let size = fittingSize(for: view, height: 80)

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 52)
  }

  func testRuleMatchSimulationDebouncerRunsOnlyLatestScheduledWork() async throws {
    let debouncer = RuleMatchSimulationDebouncer(delayNanoseconds: 20_000_000)
    var events: [String] = []

    debouncer.schedule { events.append("first") }
    debouncer.schedule { events.append("second") }
    try await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(events, ["second"])
  }

  func testRuleMatchSimulationDebouncerImmediateRunCancelsPendingWork() async throws {
    let debouncer = RuleMatchSimulationDebouncer(delayNanoseconds: 20_000_000)
    var events: [String] = []

    debouncer.schedule { events.append("scheduled") }
    debouncer.runImmediately { events.append("immediate") }
    try await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(events, ["immediate"])
  }

  func testConnectionAppIconCacheReusesLoadedIconsAndEvictsOldestPath() throws {
    let loadedImage = NSImage(size: NSSize(width: 16, height: 16))
    var loadedPaths: [String] = []
    let cache = ConnectionAppIconCache(maximumCount: 2) { path in
      loadedPaths.append(path)
      return loadedImage
    }

    let first = try XCTUnwrap(cache.icon(for: "  /Applications/One.app  "))
    let second = try XCTUnwrap(cache.icon(for: "/Applications/One.app"))
    _ = cache.icon(for: "/Applications/Two.app")
    _ = cache.icon(for: "/Applications/Three.app")
    _ = cache.icon(for: "/Applications/One.app")

    XCTAssertTrue(first === loadedImage)
    XCTAssertTrue(second === loadedImage)
    XCTAssertEqual(
      loadedPaths,
      [
        "/Applications/One.app",
        "/Applications/Two.app",
        "/Applications/Three.app",
        "/Applications/One.app"
      ]
    )
  }

  private func fullPanelView(model: AppModel, localeIdentifier: String) -> some View {
    MenuBarView()
      .environment(model)
      .environment(model.runtimeData)
      .environment(AppUpdateController())
      .environment(\.locale, Locale(identifier: localeIdentifier))
  }

  private func makeAppModel(paths: RuntimePaths, store: ProfileStore, defaults: UserDefaults) -> AppModel {
    AppModel(
      paths: paths,
      profileStore: store,
      systemProxyController: SystemProxyController(
        commandRunner: RecordingCommandRunner(outputs: Self.defaultNetworkSetupOutputs()),
        snapshotDefaults: defaults
      ),
      helperClient: TunnelHelperClient(
        transport: MenuBarPanelHelperTransport(),
        service: MenuBarPanelHelperService(),
        fingerprintProvider: MenuBarPanelHelperFingerprintProvider(),
        registrationRecordStore: UserDefaultsHelperRegistrationRecordStore(defaults: defaults),
        bootstrapStatusTimeoutSeconds: 0.01
      ),
      loginItemService: MenuBarPanelLoginItemService(),
      defaults: defaults
    )
  }

  @discardableResult
  private func importLocalProfile(into store: ProfileStore, paths: RuntimePaths) async throws -> Profile {
    let configURL = paths.appSupport.appendingPathComponent("layout-profile.yaml")
    try """
    mixed-port: 7890
    proxies:
      - name: DIRECT
        type: direct
    """.write(to: configURL, atomically: true, encoding: .utf8)
    return try await store.importLocalConfig(from: configURL)
  }

  private func fittingSize<Content: View>(for view: Content, height: CGFloat = 400) -> CGSize {
    let hostingView = NSHostingView(rootView: view)
    hostingView.setFrameSize(NSSize(width: MenuBarPanelLayout.width, height: height))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView.fittingSize
  }

  private static func makeFixture() throws -> MenuBarPanelLayoutFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxMenuBarPanelLayoutTests-\(UUID().uuidString)", isDirectory: true)
    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    try paths.prepareDirectories()

    let suiteName = "ClashMaxMenuBarPanelLayoutTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return MenuBarPanelLayoutFixture(root: root, paths: paths, defaults: defaults, defaultsSuiteName: suiteName)
  }

  private static func defaultNetworkSetupOutputs() -> [String: String] {
    [
      "/usr/sbin/networksetup -listallnetworkservices": "Wi-Fi\n",
      "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer:\nPort: 0\n",
      "/usr/sbin/networksetup -getproxybypassdomains Wi-Fi": "There aren't any bypass domains set.\n",
      "/usr/sbin/networksetup -getdnsservers Wi-Fi": "There aren't any DNS Servers set on Wi-Fi.\n"
    ]
  }

  private static let sampleTrafficHistory = [
    TrafficSample(upload: 512, download: 4096),
    TrafficSample(upload: 2048, download: 16384),
    TrafficSample(upload: 4096, download: 32768),
    TrafficSample(upload: 1024, download: 8192),
    TrafficSample(upload: 8192, download: 65536),
    TrafficSample(upload: 4096, download: 32768)
  ]
}

@MainActor
final class MainWindowLayoutTests: XCTestCase {
  func testRoutingWorkspaceLayoutUsesThreeDeterministicBreakpoints() {
    XCTAssertEqual(RoutingWorkspaceLayout.mode(forWidth: 819), .singleColumn)
    XCTAssertEqual(RoutingWorkspaceLayout.mode(forWidth: 820), .twoColumn)
    XCTAssertEqual(RoutingWorkspaceLayout.mode(forWidth: 1_219), .twoColumn)
    XCTAssertEqual(RoutingWorkspaceLayout.mode(forWidth: 1_220), .threeColumn)
  }

  func testConnectionsLayoutMovesDetailBelowAtNarrowWidths() {
    XCTAssertEqual(ConnectionsLayout.mode(forWidth: 1_079), .stackedDetail)
    XCTAssertEqual(ConnectionsLayout.mode(forWidth: 1_080), .splitDetail)
  }

  func testStatusStripCompactMessageFitsNarrowWidthWithoutSingleLineLoss() {
    let view = StatusStripContent(
      statusSummary: "Crashed: mihomo exited with code 2",
      statusSymbol: "exclamationmark.triangle.fill",
      statusStyle: .red,
      profileName: "Long Subscription Profile Name - 香港 日本 美国 自动选择",
      proxyRoutingStatus: "Network Extension Ready",
      supplemental: .error(
        "Could not repair TUN routing because the helper still reports a stale default route after reload and restart."
      )
    )
    .frame(width: 520)

    let size = fittingSize(for: view, width: 520, height: 160)

    XCTAssertLessThanOrEqual(size.width, 521)
    XCTAssertGreaterThan(size.height, 36)
    XCTAssertLessThanOrEqual(size.height, 96)
  }

  private func fittingSize<Content: View>(for view: Content, width: CGFloat, height: CGFloat) -> CGSize {
    let hostingView = NSHostingView(rootView: view)
    hostingView.setFrameSize(NSSize(width: width, height: height))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView.fittingSize
  }
}

private struct MenuBarPanelLayoutFixture {
  let root: URL
  let paths: RuntimePaths
  let defaults: UserDefaults
  let defaultsSuiteName: String

  func cleanup() {
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    try? FileManager.default.removeItem(at: root)
  }
}

private actor MenuBarPanelHelperTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    HelperClientResponse.failure("Helper is not running.")
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    HelperClientResponse.failure("Helper is not running.")
  }

  func stopTunnel() async throws -> HelperClientResponse {
    HelperClientResponse.failure("Helper is not running.")
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    HelperClientResponse.failure("Helper is not running.")
  }

  func recentLogs() async throws -> [String] {
    []
  }
}

private struct MenuBarPanelHelperFingerprintProvider: HelperFingerprintProviding {
  func currentFingerprint() throws -> String {
    "menu-bar-panel-layout-tests"
  }
}

@MainActor
private final class MenuBarPanelHelperService: HelperServiceManaging {
  var status: SMAppService.Status = .notRegistered

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettingsLoginItems() {}
}

@MainActor
private final class MenuBarPanelLoginItemService: LoginItemManaging {
  var status: SMAppService.Status = .notRegistered

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettingsLoginItems() {}
}
