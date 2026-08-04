import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    // @Environment does not vend bindings; @Bindable wraps the tracked reference so
    // `$appModel.selectedSection` still resolves.
    @Bindable var appModel = appModel
    return NavigationSplitView {
      SidebarView(selection: $appModel.selectedSection)
    } detail: {
      VStack(spacing: 0) {
        StatusStrip()
        Divider()
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
        .toolbar {
          // Deliberately the default placement, not `.navigation`: `.navigation` sits
          // *before* the window title and pushes the app name off the leading edge.
          // The title owns the leading edge, these global runtime controls own the
          // trailing side, and they are the only things in here — per-page controls
          // stay inside the page (see `AdaptivePage.pageActionBar`) so they never read
          // as an extension of the run-mode picker.
          ToolbarItemGroup {
            RunModePicker(selection: Binding(
              get: { appModel.overrides.mode },
              set: { appModel.requestMode($0) }
            ))

            Button {
              if appModel.canStopRuntime {
                appModel.stop()
              } else {
                appModel.start()
              }
            } label: {
              Label(toolbarRunTitle, systemImage: toolbarRunSymbol)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!appModel.canStopRuntime && appModel.readinessIssue != nil)
          }
        }
    }
    .sheet(isPresented: initialTunHelperPromptPresented) {
      if let prompt = appModel.initialTunHelperPrompt {
        InitialTunHelperPromptSheet(
          prompt: prompt,
          actionInFlight: appModel.initialTunHelperPromptActionInFlight,
          onPrimaryAction: {
            appModel.installInitialTunHelper()
          },
          onLater: {
            appModel.dismissInitialTunHelperPrompt()
          }
        )
      }
    }
    .onAppear {
      appModel.evaluateInitialTunHelperPromptOnLaunch()
    }
  }

  private var initialTunHelperPromptPresented: Binding<Bool> {
    Binding(
      get: { appModel.initialTunHelperPrompt != nil },
      set: { isPresented in
        if !isPresented {
          appModel.dismissInitialTunHelperPrompt()
        }
      }
    )
  }

  private var toolbarRunTitle: String {
    appModel.canStopRuntime ? String(localized: "Stop") : String(localized: "Start")
  }

  private var toolbarRunSymbol: String {
    appModel.canStopRuntime ? "stop.fill" : "play.fill"
  }

  @ViewBuilder
  private var detail: some View {
    switch appModel.selectedSection {
    case .home:
      DashboardView()
    case .status:
      StatusView()
    case .profiles:
      ProfilesView()
    case .proxies:
      ProxiesView(searchCoordinator: appModel.proxiesSearchCoordinator)
    case .connections:
      ConnectionsView()
    case .routing:
      RoutingView()
    case .rules:
      RulesView()
    case .logs:
      LogsView()
    case .settings:
      SettingsView()
    }
  }
}

/// Guided setup for the privileged TUN helper.
///
/// Written as an explicit checklist because the middle step happens outside the
/// app: macOS sends the user to System Settings and reports nothing back, so
/// without visible "done / doing / next" state people cannot tell whether the
/// toggle they just flipped registered. ClashMax watches for the approval
/// itself, so no step ever asks the user to come back and press refresh.
private struct InitialTunHelperPromptSheet: View {
  let prompt: InitialTunHelperPrompt
  let actionInFlight: Bool
  let onPrimaryAction: () -> Void
  let onLater: () -> Void

  private enum StepState {
    case done
    case current
    case upcoming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header

      VStack(alignment: .leading, spacing: 12) {
        if case let .relocate(issue) = prompt.stage {
          step(
            number: 1,
            title: String(localized: "Move ClashMax to the Applications folder"),
            detail: issue.explanation,
            state: .current
          )
        }
        step(
          number: relocateStepShown ? 2 : 1,
          title: String(localized: "Install the helper"),
          detail: String(localized: "ClashMax registers a background service that opens the TUN interface."),
          state: installStepState
        )
        step(
          number: relocateStepShown ? 3 : 2,
          title: String(localized: "Approve it in System Settings"),
          detail: String(localized: "General ▸ Login Items & Extensions ▸ Allow in the Background — turn on ClashMax."),
          state: approveStepState
        )
      }

      statusLine

      HStack {
        Spacer()
        Button("Later", action: onLater)
          .keyboardShortcut(.cancelAction)

        Button {
          onPrimaryAction()
        } label: {
          if actionInFlight {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(prompt.primaryButtonTitle)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(actionInFlight)
      }
    }
    .padding(24)
    .frame(width: 520, alignment: .topLeading)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "checkmark.shield")
        .font(.system(size: 36, weight: .semibold))
        .foregroundStyle(.blue)
        .frame(width: 44, height: 44)

      VStack(alignment: .leading, spacing: 6) {
        Text("Set Up TUN Routing")
          .font(.title3.weight(.semibold))
        Text("TUN mode needs a privileged helper. This is a one-time setup.")
        Text("System Proxy and Network Extension routing keep working without it.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if prompt.isWaitingOnSystemSettings {
        ProgressView()
          .controlSize(.small)
      }
      Text(prompt.statusMessage)
        .font(.callout)
        .foregroundStyle(isFailed ? Color.orange : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func step(number: Int, title: String, detail: String, state: StepState) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Group {
        switch state {
        case .done:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        case .current:
          Image(systemName: "\(number).circle.fill")
            .foregroundStyle(.blue)
        case .upcoming:
          Image(systemName: "\(number).circle")
            .foregroundStyle(.secondary)
        }
      }
      .font(.title3)
      .frame(width: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(state == .current ? .semibold : .regular))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .opacity(state == .upcoming ? 0.55 : 1)
  }

  private var relocateStepShown: Bool {
    if case .relocate = prompt.stage { return true }
    return false
  }

  private var isFailed: Bool {
    if case .failed = prompt.stage { return true }
    return false
  }

  private var installStepState: StepState {
    switch prompt.stage {
    case .relocate:
      return .upcoming
    case .install, .failed:
      return .current
    case .approve, .ready:
      return .done
    }
  }

  private var approveStepState: StepState {
    switch prompt.stage {
    case .approve:
      return .current
    case .ready:
      return .done
    case .relocate, .install, .failed:
      return .upcoming
    }
  }
}

struct StatusStrip: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    StatusStripContent(
      statusSummary: appModel.statusSummary,
      statusSymbol: statusSymbol,
      statusStyle: statusStyle,
      profileName: appModel.profileStore.activeProfile?.name ?? String(localized: "No Profile"),
      proxyRoutingStatus: proxyRoutingStatus,
      supplemental: supplemental
    )
  }

  private var supplemental: StatusStripSupplemental? {
    if let issue = appModel.readinessIssue {
      return .issue(issue)
    }
    if let error = appModel.lastError {
      return .error(error)
    }
    if let notice = appModel.appNotice {
      return .notice(message: notice.message, symbolName: notice.symbolName, tone: notice.tone)
    }
    return nil
  }

  private var statusSymbol: String {
    if appModel.isRunning {
      return "checkmark.circle.fill"
    }
    switch appModel.coreController.status {
    case .running:
      return "checkmark.circle.fill"
    case .starting, .restarting:
      return "clock.arrow.circlepath"
    case .crashed:
      return "exclamationmark.triangle.fill"
    case .stopped:
      return "stop.circle"
    }
  }

  private var statusStyle: Color {
    if appModel.isRunning {
      return .green
    }
    switch appModel.coreController.status {
    case .running:
      return .green
    case .crashed:
      return .red
    case .starting, .restarting:
      return .orange
    case .stopped:
      return .secondary
    }
  }

  private var proxyRoutingStatus: String {
    let isActive = appModel.systemProxyEnabled || appModel.tunEnabled || appModel.networkExtensionEnabled
    return "\(appModel.proxyRoutingMode.displayName) \(isActive ? "On" : "Ready")"
  }
}

enum StatusStripSupplemental {
  case issue(String)
  case error(String)
  case notice(message: String, symbolName: String, tone: AppNotice.Tone)

  var message: String {
    switch self {
    case let .issue(message), let .error(message):
      return message
    case let .notice(message, _, _):
      return message
    }
  }

  var symbolName: String {
    switch self {
    case .issue:
      return "exclamationmark.triangle.fill"
    case .error:
      return "xmark.octagon.fill"
    case let .notice(_, symbolName, _):
      return symbolName
    }
  }

  var color: Color {
    switch self {
    case .issue:
      return .secondary
    case .error:
      return .red
    case let .notice(_, _, tone):
      switch tone {
      case .info:
        return .blue
        case .success:
          return .green
        case .warning:
          return .orange
        }
      }
    }
}

struct StatusStripContent: View {
  let statusSummary: String
  let statusSymbol: String
  let statusStyle: Color
  let profileName: String
  let proxyRoutingStatus: String
  let supplemental: StatusStripSupplemental?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      wideStrip
      compactStrip
    }
    .font(.callout)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var wideStrip: some View {
    HStack(spacing: 14) {
      Label(statusSummary, systemImage: statusSymbol)
        .foregroundStyle(statusStyle)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(minWidth: 0, alignment: .leading)

      Divider()
        .frame(height: 16)

      Text(profileName)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(minWidth: 0, alignment: .leading)

      Text(proxyRoutingStatus)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)

      Spacer()

      if let supplemental {
        supplementalLabel(supplemental, lineLimit: 1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
  }

  private var compactStrip: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 10) {
        Label(statusSummary, systemImage: statusSymbol)
          .foregroundStyle(statusStyle)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

        Text(profileName)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

        Text(proxyRoutingStatus)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }

      if let supplemental {
        supplementalLabel(supplemental, lineLimit: 2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func supplementalLabel(_ supplemental: StatusStripSupplemental, lineLimit: Int) -> some View {
    Label(supplemental.message, systemImage: supplemental.symbolName)
      .foregroundStyle(supplemental.color)
      .lineLimit(lineLimit)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
