import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // Issue #27: a flexible frame does not clamp an oversized child — SwiftUI grows the frame
        // to fit it and then centers the overflow. So a page whose content outgrew the window used
        // to stretch this column from the inside, painting over the title bar and pushing the
        // sidebar's rows off screen; the window could only be recovered by quitting. GeometryReader
        // always reports the size it was proposed no matter what it contains, which pins the column
        // to the window, and the clip keeps a page that still overflows contained inside it.
        GeometryReader { _ in
          detail
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipped()
        // Transient notices (a copied report, a delay test that failed, a helper that answered
        // late) float over the page and go away by themselves. Errors are the alert below.
        .overlay(alignment: .top) {
          // A readiness issue already stands in the strip (and on the Home page); a toast repeating
          // the same words on top of it would be a third copy of one fact. A notice whose time ran
          // out while no window was open is never drawn; the task below clears it.
          if let notice = appModel.appNotice,
             notice.message != appModel.readinessIssue,
             notice.remainingDisplayDuration() > 0
          {
            AppNoticeToast(notice: notice)
              .padding(.top, 12)
              .padding(.horizontal, 16)
              .transition(reduceMotion ? .opacity : .offset(y: -10).combined(with: .opacity))
          }
        }
        .animation(.spring(duration: 0.28, bounce: 0), value: appModel.appNotice?.id)
        // Each notice leaves when its own time is up, counted from when it was posted — not from
        // when this window happened to show it. Dismissed by id, so a notice that times out never
        // takes a newer one down with it.
        .task(id: appModel.appNotice?.id) {
          guard let notice = appModel.appNotice else { return }
          let remaining = notice.remainingDisplayDuration()
          if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
          }
          appModel.dismissAppNotice(id: notice.id)
        }
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
    .alert(
      Text("Error"),
      isPresented: errorAlertPresented,
      presenting: appModel.pendingErrorAlert
    ) { alert in
      Button("Copy") {
        copyErrorAlert(alert)
      }
      Button("Show Logs") {
        appModel.selectedSection = .logs
      }
      Button("OK", role: .cancel) {}
    } message: { alert in
      Text(alert.message)
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

  /// Every published error raises this native alert once; dismissing it acknowledges the error
  /// without forgetting it (the Status page and the Logs page still carry it).
  private var errorAlertPresented: Binding<Bool> {
    Binding(
      get: { appModel.pendingErrorAlert != nil },
      set: { isPresented in
        if !isPresented {
          appModel.acknowledgeErrorAlert()
        }
      }
    )
  }

  private func copyErrorAlert(_ alert: AppErrorAlert) {
    let text = [alert.message, alert.details]
      .compactMap(\.self)
      .joined(separator: "\n\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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

/// The one-line runtime summary above every page: state, profile, routing. Errors and notices no
/// longer land here — an error raises the alert in `ContentView` and a notice floats as a toast —
/// so the only supplement left is a readiness issue, which is a standing condition rather than an
/// event and stays until it is fixed.
struct StatusStrip: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    StatusStripContent(
      statusSummary: NSLocalizedString(appModel.statusSummary, comment: ""),
      statusSymbol: statusSymbol,
      statusStyle: statusStyle,
      profileName: appModel.profileStore.activeProfile?.name ?? String(localized: "No Profile"),
      proxyRoutingStatus: proxyRoutingStatus,
      readinessIssue: appModel.readinessIssue
    )
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
    let format = isActive ? String(localized: "%@ On") : String(localized: "%@ Ready")
    return String(format: format, appModel.proxyRoutingMode.displayName)
  }
}

struct StatusStripContent: View {
  let statusSummary: String
  let statusSymbol: String
  let statusStyle: Color
  let profileName: String
  let proxyRoutingStatus: String
  let readinessIssue: String?

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

      if let readinessIssue {
        readinessLabel(readinessIssue, lineLimit: 1)
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

      if let readinessIssue {
        readinessLabel(readinessIssue, lineLimit: 2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func readinessLabel(_ issue: String, lineLimit: Int) -> some View {
    Label(issue, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(.secondary)
      .lineLimit(lineLimit)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A notice that floats over the page and leaves on its own (`ContentView` times it). Warnings
/// stay a little longer than confirmations; any of them can be clicked away.
private struct AppNoticeToast: View {
  @Environment(AppModel.self) private var appModel
  let notice: AppNotice

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: notice.symbolName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tint)
      Text(notice.message)
        .font(.callout)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        appModel.dismissAppNotice(id: notice.id)
      } label: {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 560)
    .toastSurface()
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    switch notice.tone {
    case .info:
      return .blue
    case .success:
      return .green
    case .warning:
      return .orange
    }
  }
}

private extension View {
  /// Liquid Glass on macOS 26; the same rounded material surface the system uses below it.
  @ViewBuilder
  func toastSurface() -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    if #available(macOS 26, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
  }
}
