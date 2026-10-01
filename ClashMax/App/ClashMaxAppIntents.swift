import AppIntents
import Foundation

// Every action runs inside the app process against the live `AppModel` (registered with
// `AppDependencyManager` in `ClashMaxApp.init`) and awaits the operation it starts, so Shortcuts
// shows what actually happened — or the specific failure — instead of a success that only meant
// "a clashmax:// URL was opened" (roadmap B3). The URL scheme stays for shortcuts built on it.

/// Shows an already-localized message verbatim. The `%@` key is in the string catalog as an
/// identity format, so the message is an argument and is never looked up as a key itself.
private func verbatimResource(_ message: String) -> LocalizedStringResource {
  "\(message)"
}

extension ClashMaxIntentError: CustomLocalizedStringResourceConvertible {
  var localizedStringResource: LocalizedStringResource {
    verbatimResource(message)
  }
}

@MainActor
private enum ClashMaxIntentRunner {
  static func dialog(
    _ appModel: AppModel,
    _ operation: (ClashMaxIntentExecutor) async throws -> String
  ) async throws -> IntentDialog {
    do {
      let message = try await operation(ClashMaxIntentExecutor(controller: appModel))
      return IntentDialog(verbatimResource(message))
    } catch let error as ClashMaxIntentError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ClashMaxIntentError(UserFacingError.message(for: error))
    }
  }
}

// MARK: - Parameter types

enum ClashMaxToggleActionAppEnum: String, AppEnum {
  case turnOn
  case turnOff
  case toggle

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .turnOn: "Turn On",
    .turnOff: "Turn Off",
    .toggle: "Toggle",
  ]

  var action: ClashMaxToggleAction {
    switch self {
    case .turnOn: .turnOn
    case .turnOff: .turnOff
    case .toggle: .toggle
    }
  }
}

enum ClashMaxRoutingModeAppEnum: String, AppEnum {
  case systemProxy
  case tun
  case neProxy

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routing Mode"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .systemProxy: "System Proxy",
    .tun: "TUN",
    .neProxy: "NE Proxy",
  ]

  var mode: ProxyRoutingMode {
    switch self {
    case .systemProxy: .systemProxy
    case .tun: .tun
    case .neProxy: .neProxy
    }
  }
}

struct ClashMaxProfileEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "ClashMax Profile"
  static let defaultQuery = ClashMaxProfileQuery()

  var id: UUID
  var name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: verbatimResource(name))
  }
}

struct ClashMaxProfileQuery: EntityQuery {
  @Dependency private var appModel: AppModel

  @MainActor
  func entities(for identifiers: [UUID]) async throws -> [ClashMaxProfileEntity] {
    let wanted = Set(identifiers)
    return profiles().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ClashMaxProfileEntity] {
    profiles()
  }

  @MainActor
  private func profiles() -> [ClashMaxProfileEntity] {
    ClashMaxIntentExecutor(controller: appModel).profileOptions().map {
      ClashMaxProfileEntity(id: $0.id, name: $0.name)
    }
  }
}

/// A proxy group, identified by name. Resolving an identifier never needs the core, so a saved
/// shortcut still reaches `perform` — and its specific error — while ClashMax is stopped.
struct ClashMaxProxyGroupEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Proxy Group"
  static let defaultQuery = ClashMaxProxyGroupQuery()

  var id: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: verbatimResource(id))
  }
}

struct ClashMaxProxyGroupQuery: EntityQuery {
  @Dependency private var appModel: AppModel

  func entities(for identifiers: [String]) async throws -> [ClashMaxProxyGroupEntity] {
    identifiers.map(ClashMaxProxyGroupEntity.init(id:))
  }

  @MainActor
  func suggestedEntities() async throws -> [ClashMaxProxyGroupEntity] {
    ClashMaxIntentExecutor(controller: appModel).selectableGroups().map { ClashMaxProxyGroupEntity(id: $0.name) }
  }
}

/// A node inside one group. The identifier carries both names, length-prefixed so no character in
/// either name can make it ambiguous.
struct ClashMaxProxyNodeEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Proxy Node"
  static let defaultQuery = ClashMaxProxyNodeQuery()

  var id: String
  var groupName: String
  var nodeName: String

  init(groupName: String, nodeName: String) {
    id = ClashMaxProxyNodeIdentifier.encode(groupName: groupName, nodeName: nodeName)
    self.groupName = groupName
    self.nodeName = nodeName
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: verbatimResource(nodeName))
  }
}

struct ClashMaxProxyNodeQuery: EntityQuery {
  @Dependency private var appModel: AppModel
  @IntentParameterDependency<SelectClashMaxProxyNodeIntent>(\.$group) private var selectNodeIntent

  func entities(for identifiers: [String]) async throws -> [ClashMaxProxyNodeEntity] {
    identifiers.compactMap { identifier in
      ClashMaxProxyNodeIdentifier.decode(identifier).map {
        ClashMaxProxyNodeEntity(groupName: $0.groupName, nodeName: $0.nodeName)
      }
    }
  }

  /// The nodes of the group already chosen in the same action — the list depends on it.
  @MainActor
  func suggestedEntities() async throws -> [ClashMaxProxyNodeEntity] {
    guard let groupName = selectNodeIntent?.group.id else { return [] }
    return ClashMaxIntentExecutor(controller: appModel).selectableNodes(inGroup: groupName).map {
      ClashMaxProxyNodeEntity(groupName: groupName, nodeName: $0.name)
    }
  }
}

// MARK: - Lifecycle

struct StartClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Start ClashMax"
  static let description = IntentDescription("Start the active ClashMax runtime.")
  static let openAppWhenRun = false

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.start() })
  }
}

struct StopClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop ClashMax"
  static let description = IntentDescription("Stop the active ClashMax runtime.")
  static let openAppWhenRun = false

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.stop() })
  }
}

struct RestartClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Restart ClashMax"
  static let description = IntentDescription("Restart the active ClashMax runtime.")
  static let openAppWhenRun = false

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.restart() })
  }
}

// MARK: - Routing

struct ToggleSystemProxyIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle System Proxy"
  static let description = IntentDescription("Turn the macOS System Proxy managed by ClashMax on or off. Only available in System Proxy routing mode.")
  static let openAppWhenRun = false

  @Parameter(title: "Action", default: .toggle)
  var action: ClashMaxToggleActionAppEnum

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.setSystemProxy(action.action) })
  }
}

struct SetClashMaxRoutingModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Set ClashMax Routing Mode"
  static let description = IntentDescription("Switch ClashMax between System Proxy, TUN and NE Proxy routing. A running ClashMax restarts in the new mode.")
  static let openAppWhenRun = false

  @Parameter(title: "Routing Mode")
  var mode: ClashMaxRoutingModeAppEnum

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.setRoutingMode(mode.mode) })
  }
}

struct SetClashMaxTunIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle ClashMax TUN"
  static let description = IntentDescription("Turn TUN routing on or off. Turning it off switches ClashMax back to System Proxy routing. TUN needs the ClashMax privileged helper.")
  static let openAppWhenRun = false

  @Parameter(title: "Action", default: .toggle)
  var action: ClashMaxToggleActionAppEnum

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.setTun(action.action) })
  }
}

// MARK: - Profiles and nodes

struct SelectClashMaxProfileIntent: AppIntent {
  static let title: LocalizedStringResource = "Select ClashMax Profile"
  static let description = IntentDescription("Make a profile the active one. A running ClashMax restarts with it.")
  static let openAppWhenRun = false

  @Parameter(title: "Profile")
  var profile: ClashMaxProfileEntity

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.selectProfile(id: profile.id) })
  }
}

struct SelectClashMaxProxyNodeIntent: AppIntent {
  static let title: LocalizedStringResource = "Select ClashMax Node"
  static let description = IntentDescription("Choose the node a proxy group uses. ClashMax has to be running.")
  static let openAppWhenRun = false

  @Parameter(title: "Proxy Group")
  var group: ClashMaxProxyGroupEntity

  @Parameter(title: "Node")
  var node: ClashMaxProxyNodeEntity

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) {
      // The node picker lists the chosen group's nodes, but a saved shortcut can pair a node with a
      // group edited since; the group parameter is the one the user sees, so it wins.
      try await $0.selectNode(node.nodeName, inGroup: group.id)
    })
  }
}

// MARK: - Subscriptions and network policy

struct UpdateClashMaxSubscriptionsIntent: AppIntent {
  static let title: LocalizedStringResource = "Update ClashMax Subscriptions"
  static let description = IntentDescription("Refresh all subscription profiles in ClashMax.")
  static let openAppWhenRun = false

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.updateAllSubscriptions() })
  }
}

struct ApplyClashMaxNetworkPolicyIntent: AppIntent {
  static let title: LocalizedStringResource = "Apply ClashMax Network Policy"
  static let description = IntentDescription("Apply the saved ClashMax policy matching the current Wi-Fi network.")
  static let openAppWhenRun = false

  @Dependency private var appModel: AppModel

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await .result(dialog: ClashMaxIntentRunner.dialog(appModel) { try await $0.applyCurrentNetworkPolicy() })
  }
}

/// `AppShortcutsProvider` takes at most ten shortcuts; these ten are all of them. "Activate
/// scenario" (roadmap B3) waits on B2 and would need one of these slots.
struct ClashMaxAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartClashMaxIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Start proxy in \(.applicationName)",
      ],
      shortTitle: "Start",
      systemImageName: "play.fill"
    )
    AppShortcut(
      intent: StopClashMaxIntent(),
      phrases: [
        "Stop \(.applicationName)",
        "Stop proxy in \(.applicationName)",
      ],
      shortTitle: "Stop",
      systemImageName: "stop.fill"
    )
    AppShortcut(
      intent: RestartClashMaxIntent(),
      phrases: [
        "Restart \(.applicationName)",
        "Restart proxy in \(.applicationName)",
      ],
      shortTitle: "Restart",
      systemImageName: "arrow.clockwise"
    )
    AppShortcut(
      intent: ToggleSystemProxyIntent(),
      phrases: [
        "Toggle system proxy in \(.applicationName)",
        "Switch system proxy in \(.applicationName)",
      ],
      shortTitle: "System Proxy",
      systemImageName: "network.badge.shield.half.filled"
    )
    AppShortcut(
      intent: SetClashMaxRoutingModeIntent(),
      phrases: [
        "Set routing mode in \(.applicationName)",
        "Change routing mode in \(.applicationName)",
      ],
      shortTitle: "Routing Mode",
      systemImageName: "arrow.triangle.branch"
    )
    AppShortcut(
      intent: SetClashMaxTunIntent(),
      phrases: [
        "Toggle TUN in \(.applicationName)",
        "Switch TUN in \(.applicationName)",
      ],
      shortTitle: "TUN",
      systemImageName: "point.topleft.down.curvedto.point.bottomright.up"
    )
    AppShortcut(
      intent: SelectClashMaxProfileIntent(),
      phrases: [
        "Select a profile in \(.applicationName)",
        "Switch profile in \(.applicationName)",
      ],
      shortTitle: "Select Profile",
      systemImageName: "doc.text"
    )
    AppShortcut(
      intent: SelectClashMaxProxyNodeIntent(),
      phrases: [
        "Select a node in \(.applicationName)",
        "Switch node in \(.applicationName)",
      ],
      shortTitle: "Select Node",
      systemImageName: "point.3.connected.trianglepath.dotted"
    )
    AppShortcut(
      intent: UpdateClashMaxSubscriptionsIntent(),
      phrases: [
        "Update subscriptions in \(.applicationName)",
        "Refresh subscriptions in \(.applicationName)",
      ],
      shortTitle: "Update Subs",
      systemImageName: "arrow.triangle.2.circlepath"
    )
    AppShortcut(
      intent: ApplyClashMaxNetworkPolicyIntent(),
      phrases: [
        "Apply network policy in \(.applicationName)",
        "Use current network policy in \(.applicationName)",
      ],
      shortTitle: "Network Policy",
      systemImageName: "wifi.router"
    )
  }
}

/// Builds and parses `ClashMaxProxyNodeEntity` identifiers: `<group length>:<group><node>`.
enum ClashMaxProxyNodeIdentifier {
  static func encode(groupName: String, nodeName: String) -> String {
    "\(groupName.count):\(groupName)\(nodeName)"
  }

  static func decode(_ identifier: String) -> (groupName: String, nodeName: String)? {
    guard let colon = identifier.firstIndex(of: ":"),
          let length = Int(identifier[..<colon]),
          length >= 0
    else { return nil }
    let rest = identifier[identifier.index(after: colon)...]
    guard rest.count >= length else { return nil }
    let split = rest.index(rest.startIndex, offsetBy: length)
    let nodeName = String(rest[split...])
    guard !nodeName.isEmpty else { return nil }
    return (String(rest[..<split]), nodeName)
  }
}
