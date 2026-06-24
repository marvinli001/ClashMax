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
    XCTAssertEqual(MenuBarPanelLayout.width, 312)
    XCTAssertEqual(MenuBarPanelLayout.controlWidth, 108)
    XCTAssertEqual(MenuBarPanelLayout.trafficChartHeight, 52)
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
        .frame(width: MenuBarPanelLayout.controlWidth, alignment: .trailing)
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
      MenuBarGroupSelectionLabel(
        selectedNode: "Auto Select - Hong Kong Premium Relay With A Very Long Name",
        delay: ProxyDelayDisplay(state: .measured(8888))
      )
    }
    .padding(MenuBarPanelLayout.padding)
    .frame(width: MenuBarPanelLayout.width)
    .environment(\.locale, Locale(identifier: "zh-Hans"))

    let size = fittingSize(for: view)

    XCTAssertLessThanOrEqual(size.width, MenuBarPanelLayout.width + 1)
    XCTAssertLessThanOrEqual(size.height, 52)
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
      .environmentObject(model)
      .environmentObject(model.runtimeData)
      .environmentObject(AppUpdateController())
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
