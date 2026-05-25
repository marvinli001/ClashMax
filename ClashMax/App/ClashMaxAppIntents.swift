import AppIntents
import AppKit

@available(macOS 13.0, *)
private enum ClashMaxIntentCommand {
  static func open(_ action: String) {
    guard let url = URL(string: "clashmax://\(action)") else { return }
    NSWorkspace.shared.open(url)
  }
}

@available(macOS 13.0, *)
struct StartClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Start ClashMax"
  static let description = IntentDescription("Start the active ClashMax runtime.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("start")
    return .result()
  }
}

@available(macOS 13.0, *)
struct StopClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop ClashMax"
  static let description = IntentDescription("Stop the active ClashMax runtime.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("stop")
    return .result()
  }
}

@available(macOS 13.0, *)
struct RestartClashMaxIntent: AppIntent {
  static let title: LocalizedStringResource = "Restart ClashMax"
  static let description = IntentDescription("Restart the active ClashMax runtime.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("restart")
    return .result()
  }
}

@available(macOS 13.0, *)
struct ToggleSystemProxyIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle System Proxy"
  static let description = IntentDescription("Toggle the macOS System Proxy managed by ClashMax.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("toggle-system-proxy")
    return .result()
  }
}

@available(macOS 13.0, *)
struct UpdateClashMaxSubscriptionsIntent: AppIntent {
  static let title: LocalizedStringResource = "Update ClashMax Subscriptions"
  static let description = IntentDescription("Refresh all subscription profiles in ClashMax.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("update-all-subscriptions")
    return .result()
  }
}

@available(macOS 13.0, *)
struct ApplyClashMaxNetworkPolicyIntent: AppIntent {
  static let title: LocalizedStringResource = "Apply ClashMax Network Policy"
  static let description = IntentDescription("Apply the saved ClashMax policy matching the current Wi-Fi network.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    ClashMaxIntentCommand.open("apply-current-network-policy")
    return .result()
  }
}

@available(macOS 13.0, *)
struct ClashMaxAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartClashMaxIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Start proxy in \(.applicationName)"
      ],
      shortTitle: "Start",
      systemImageName: "play.fill"
    )
    AppShortcut(
      intent: StopClashMaxIntent(),
      phrases: [
        "Stop \(.applicationName)",
        "Stop proxy in \(.applicationName)"
      ],
      shortTitle: "Stop",
      systemImageName: "stop.fill"
    )
    AppShortcut(
      intent: RestartClashMaxIntent(),
      phrases: [
        "Restart \(.applicationName)",
        "Restart proxy in \(.applicationName)"
      ],
      shortTitle: "Restart",
      systemImageName: "arrow.clockwise"
    )
    AppShortcut(
      intent: ToggleSystemProxyIntent(),
      phrases: [
        "Toggle system proxy in \(.applicationName)",
        "Switch system proxy in \(.applicationName)"
      ],
      shortTitle: "System Proxy",
      systemImageName: "network.badge.shield.half.filled"
    )
    AppShortcut(
      intent: UpdateClashMaxSubscriptionsIntent(),
      phrases: [
        "Update subscriptions in \(.applicationName)",
        "Refresh subscriptions in \(.applicationName)"
      ],
      shortTitle: "Update Subs",
      systemImageName: "arrow.triangle.2.circlepath"
    )
    AppShortcut(
      intent: ApplyClashMaxNetworkPolicyIntent(),
      phrases: [
        "Apply network policy in \(.applicationName)",
        "Use current network policy in \(.applicationName)"
      ],
      shortTitle: "Network Policy",
      systemImageName: "wifi.router"
    )
  }
}
