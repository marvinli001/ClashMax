import Pow
import SwiftUI

enum DashboardLayoutMetrics {
  static let runModePickerWidth: CGFloat = 214
  static let proxyRoutingModePickerWidth: CGFloat = 272
  static let launchProfileControlWidth: CGFloat = 178
  static let launchMixedPortControlWidth: CGFloat = 104
  static let launchStartButtonWidth: CGFloat = 156
  static let dashboardGridSpacing: CGFloat = 12
  static let metricTileMinimumColumnWidth: CGFloat = 118
  static let metricTileSingleRowBreakpoint: CGFloat = 680
  static let metricTileTwoColumnBreakpoint: CGFloat = 420
  static let runningPairColumnsBreakpoint: CGFloat = 700

  static func pagePadding(for width: CGFloat) -> CGFloat {
    width < 760 ? 14 : 18
  }

  static func launchVisualSideLength(
    availableWidth: CGFloat,
    availableHeight: CGFloat,
    isVisualActive: Bool = false
  ) -> CGFloat {
    let width = max(0, availableWidth)
    let height = max(0, availableHeight)
    let candidate = min(width * 0.22, height * 0.26)
    let active = min(max(candidate, 112), 220)
    if isVisualActive { return active }
    let resting = min(active * 0.55, 96)
    return max(resting, 68)
  }

  static func launchControlsMaxWidth(availableWidth: CGFloat) -> CGFloat {
    min(max(availableWidth - 32, 360), 640)
  }

  static func dashboardMaxWidth(for width: CGFloat) -> CGFloat {
    width < 900 ? .infinity : 1180
  }
}

struct RunModePicker: View {
  let selection: Binding<RunMode>

  var body: some View {
    Picker("Mode", selection: selection) {
      ForEach(RunMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct ProxyRoutingModePicker: View {
  let selection: Binding<ProxyRoutingMode>
  let developerMode: Bool

  init(selection: Binding<ProxyRoutingMode>, developerMode: Bool = false) {
    self.selection = selection
    self.developerMode = developerMode
  }

  var body: some View {
    Picker("Proxy Routing", selection: selection) {
      ForEach(ProxyRoutingMode.visibleCases(developerMode: developerMode)) { mode in
        Text(segmentTitle(for: mode))
          .lineLimit(1)
          .tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .help(selection.wrappedValue.displayName)
  }

  private func segmentTitle(for mode: ProxyRoutingMode) -> String {
    switch mode {
    case .networkExtensionExperimental:
      String(localized: "NE Proxy")
    default:
      mode.displayName
    }
  }
}

struct ProxyRoutingSettingsButton: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var isPresented = false
  @State private var systemDraft = SystemProxySettings.default
  @State private var tunDraft = TunSettings.default
  @State private var settingsError: String?

  var body: some View {
    Button {
      syncDrafts()
      isPresented = true
    } label: {
      Image(systemName: "gearshape")
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.regular)
    .help("Configure \(appModel.proxyRoutingMode.displayName)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popoverContent
        .frame(width: 480)
        .padding(18)
    }
  }

  @ViewBuilder
  private var popoverContent: some View {
    switch appModel.proxyRoutingMode {
    case .systemProxy:
      SystemProxySettingsPopover(
        settings: $systemDraft,
        isActive: appModel.systemProxyEnabled,
        serviceAddress: "\(systemDraft.normalizedProxyHost):\(appModel.overrides.mixedPort)",
        error: settingsError,
        onCancel: { isPresented = false },
        onSave: saveSystemProxySettings
      )
    case .tun:
      TunSettingsPopover(
        settings: $tunDraft,
        error: settingsError,
        onCancel: { isPresented = false },
        onReset: { tunDraft = .default },
        onSave: saveTunSettings
      )
    case .networkExtensionExperimental:
      NetworkExtensionSettingsPopover()
    }
  }

  private func syncDrafts() {
    systemDraft = appModel.systemProxySettings
    tunDraft = appModel.tunSettings
    settingsError = nil
  }

  private func saveSystemProxySettings() {
    if let validationError = systemDraft.validationError {
      settingsError = validationError
      return
    }
    guard appModel.updateSystemProxySettings(systemDraft) else {
      settingsError = appModel.lastError
      return
    }
    isPresented = false
  }

  private func saveTunSettings() {
    appModel.updateTunSettings(tunDraft)
    isPresented = false
  }
}

private struct NetworkExtensionSettingsPopover: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        SettingsRuntimeLine(title: "System Extension", value: appModel.networkExtensionController.statusMessage)
        SettingsRuntimeLine(title: "Transparent Proxy", value: appModel.networkExtensionController.vpnStatus.displayName)
        SettingsRuntimeLine(title: "System Proxy", value: "Off")
        SettingsRuntimeLine(title: "TUN Helper", value: "Untouched")
        Text(appModel.networkExtensionController.tunnelStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let error = appModel.networkExtensionController.recentError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack(spacing: 8) {
        Button {
          appModel.installNetworkExtension()
        } label: {
          Label("Install", systemImage: "puzzlepiece")
        }
        Button {
          appModel.openNetworkExtensionSettings()
        } label: {
          Label("Approve", systemImage: "gearshape")
        }
        .help("Open System Settings > General > Login Items & Extensions > Network Extensions.")
        Button {
          appModel.refreshNetworkExtensionStatus()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    }
    .onAppear {
      appModel.refreshNetworkExtensionStatus()
    }
  }
}

private struct SettingsRuntimeLine: View {
  let title: String
  let value: String

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .multilineTextAlignment(.trailing)
    }
    .font(.callout)
  }
}

private struct SystemProxySettingsPopover: View {
  @Binding var settings: SystemProxySettings
  let isActive: Bool
  let serviceAddress: String
  let error: String?
  let onCancel: () -> Void
  let onSave: () -> Void
  @State private var bypassDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      popoverHeader("System Proxy Settings", systemImage: "network.badge.shield.half.filled")

      GroupBox("Current System Proxy") {
        VStack(alignment: .leading, spacing: 6) {
          LabeledContent("Status") {
            Text(isActive ? "Enabled" : "Not Enabled")
              .foregroundStyle(isActive ? Color.green : Color.secondary)
          }
          LabeledContent("Service Address") {
            Text(serviceAddress)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
      }

      Form {
        TextField("Proxy Host", text: $settings.proxyHost)
        Toggle("Use Default Bypass", isOn: $settings.useDefaultBypass)
        Toggle("Validate Bypass Entries", isOn: $settings.validateBypass)
        Toggle("Proxy Guard", isOn: $settings.guardEnabled)
        Stepper("Guard Interval \(settings.normalizedGuardIntervalSeconds)s", value: $settings.guardIntervalSeconds, in: SystemProxySettings.minimumGuardIntervalSeconds...SystemProxySettings.maximumGuardIntervalSeconds, step: 5)
          .disabled(!settings.guardEnabled)
      }

      EditableStringList(
        title: "Custom Bypass",
        placeholder: "192.168.0.0/16",
        values: $settings.customBypassDomains,
        draft: $bypassDraft,
        validator: SystemProxySettings.isValidBypassDomain
      )

      if settings.useDefaultBypass {
        WrappingTokenList(title: "Default Bypass", values: SystemProxySettings.defaultBypassDomains)
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      popoverActions(onCancel: onCancel, onSave: onSave, saveDisabled: settings.validationError != nil)
    }
  }
}

private struct TunSettingsPopover: View {
  @Binding var settings: TunSettings
  let error: String?
  let onCancel: () -> Void
  let onReset: () -> Void
  let onSave: () -> Void
  @State private var dnsDraft = ""
  @State private var routeDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        popoverHeader("TUN Settings", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        Spacer()
        Button("Reset Defaults", action: onReset)
      }

      Form {
        Picker("TUN Stack", selection: $settings.stack) {
          ForEach(TunStack.allCases) { stack in
            Text(stack.displayName).tag(stack)
          }
        }
        .pickerStyle(.segmented)

        TextField("Device", text: $settings.device)
        Toggle("Auto Route", isOn: $settings.autoRoute)
        Toggle("Strict Route", isOn: $settings.strictRoute)
        Toggle("Auto Detect Interface", isOn: $settings.autoDetectInterface)
        Stepper("MTU \(settings.normalizedMTU)", value: $settings.mtu, in: 576...9_000, step: 10)
      }

      EditableStringList(
        title: "DNS Hijack",
        placeholder: "any:53",
        values: $settings.dnsHijack,
        draft: $dnsDraft,
        validator: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(" ") }
      )

      EditableStringList(
        title: "Route Exclude Address",
        placeholder: "192.168.0.0/16",
        values: $settings.routeExcludeAddresses,
        draft: $routeDraft,
        validator: SystemProxySettings.isValidBypassDomain
      )

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      popoverActions(onCancel: onCancel, onSave: onSave, saveDisabled: false)
    }
  }
}

private struct EditableStringList: View {
  let title: String
  let placeholder: String
  @Binding var values: [String]
  @Binding var draft: String
  let validator: (String) -> Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      WrappingTokenList(title: nil, values: values, removeAction: remove)

      HStack(spacing: 8) {
        TextField(placeholder, text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .disabled(!validator(draft))
      }
    }
  }

  private func add() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard validator(trimmed) else { return }
    values = SystemProxySettings.normalizedBypassDomains(values + [trimmed])
    draft = ""
  }

  private func remove(_ value: String) {
    values.removeAll { $0 == value }
  }
}

private struct WrappingTokenList: View {
  let title: String?
  let values: [String]
  var removeAction: ((String) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if values.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
          ForEach(values, id: \.self) { value in
            HStack(spacing: 4) {
              Text(value)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
              if let removeAction {
                Button {
                  removeAction(value)
                } label: {
                  Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
          }
        }
      }
    }
  }
}

private func popoverHeader(_ title: String, systemImage: String) -> some View {
  Label(title, systemImage: systemImage)
    .font(.title3.weight(.semibold))
}

private func popoverActions(onCancel: @escaping () -> Void, onSave: @escaping () -> Void, saveDisabled: Bool) -> some View {
  HStack {
    Spacer()
    Button("Cancel", action: onCancel)
      .keyboardShortcut(.cancelAction)
    Button("Save", action: onSave)
      .keyboardShortcut(.defaultAction)
      .disabled(saveDisabled)
  }
}

struct DashboardStatusPill: View {
  let title: String
  let value: String
  let symbolName: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(.caption, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(tint.opacity(0.20), lineWidth: 1)
    }
  }
}

struct DashboardMetricTile: View {
  let title: String
  let value: String
  let footnote: String?
  let symbolName: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbolName)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        Spacer()
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.62)
          .contentTransition(.numericText())
          .changeEffect(.pulse(shape: RoundedRectangle(cornerRadius: 8), style: tint.opacity(0.18), count: 1), value: value)

        if let footnote {
          Text(footnote)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
    .dashboardCard()
  }
}

struct DashboardSectionHeader: View {
  let title: String
  let symbolName: String
  var trailing: String?

  var body: some View {
    HStack(spacing: 8) {
      Label(title, systemImage: symbolName)
        .font(.headline)
      Spacer()
      if let trailing {
        Text(trailing)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

struct DashboardEmptyRuntimeView: View {
  let title: String
  let symbolName: String
  var message: String?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 128)
    .frame(maxHeight: .infinity, alignment: .center)
  }
}

enum DashboardCardSurfaceStyle {
  static func surfaceID(for colorScheme: ColorScheme) -> String {
    colorScheme == .dark ? "dark-material-dashboard-card" : "light-flat-dashboard-card"
  }

  static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.16 : 0.04
  }

  static func strokeOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.30 : 0.55
  }
}

struct DashboardCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  var interactive = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    let card = content
      .background {
        if colorScheme == .dark {
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Color.primary.opacity(0.040))
          }
        } else {
          shape.fill(Color(nsColor: .windowBackgroundColor))
        }
      }
      .overlay {
        shape.stroke(
          Color(nsColor: .separatorColor).opacity(DashboardCardSurfaceStyle.strokeOpacity(for: colorScheme)),
          lineWidth: 1
        )
      }
      .shadow(color: .black.opacity(DashboardCardSurfaceStyle.shadowOpacity(for: colorScheme)), radius: colorScheme == .dark ? 16 : 10, x: 0, y: colorScheme == .dark ? 8 : 2)

    if colorScheme == .dark {
      card.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      card
    }
  }
}

extension View {
  func dashboardCard(interactive: Bool = false) -> some View {
    modifier(DashboardCardModifier(interactive: interactive))
  }
}

func dashboardDurationString(from start: Date?, now: Date = Date()) -> String {
  guard let start else { return "--" }
  let interval = max(0, Int(now.timeIntervalSince(start)))
  let hours = interval / 3600
  let minutes = (interval % 3600) / 60
  let seconds = interval % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, seconds)
  }
  return String(format: "%d:%02d", minutes, seconds)
}

struct DashboardTrafficSparkline: View {
  let samples: [TrafficSample]

  var body: some View {
    Canvas { context, size in
      let inset: CGFloat = 8
      let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
      let maxValue = max(samples.map { max($0.upload, $0.download) }.max() ?? 1, 1)

      var baseline = Path()
      baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
      context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

      context.stroke(path(for: samples.map(\.download), maxValue: maxValue, in: plot), with: .color(.cyan), lineWidth: 2.4)
      context.stroke(path(for: samples.map(\.upload), maxValue: maxValue, in: plot), with: .color(.indigo), lineWidth: 2)
    }
  }

  private func path(for values: [Int], maxValue: Int, in rect: CGRect) -> Path {
    var path = Path()
    guard !values.isEmpty else { return path }

    for (index, value) in values.enumerated() {
      let progress = values.count == 1 ? 0 : CGFloat(index) / CGFloat(values.count - 1)
      let x = rect.minX + rect.width * progress
      let y = rect.maxY - rect.height * (CGFloat(value) / CGFloat(maxValue))
      if index == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }

    return path
  }
}
