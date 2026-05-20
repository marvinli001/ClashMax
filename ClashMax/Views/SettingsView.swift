import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var settings: PersistedSettingsStore
  @EnvironmentObject private var appUpdateController: AppUpdateController
  private let bundledCoreInfo: BundledCoreInfo

  init(bundledCoreInfo: BundledCoreInfo = BundledCoreInfo()) {
    self.bundledCoreInfo = bundledCoreInfo
  }

  var body: some View {
    AdaptivePage(
      title: "Settings",
      subtitle: "Runtime overrides and system integration controls."
    ) {
      EmptyView()
    } content: {
      Form {
        Section("General") {
          SettingsToggleRow(
            "Developer Mode",
            description: "Show helper diagnostics and advanced recovery details.",
            isOn: Binding(
              get: { appModel.developerMode },
              set: { appModel.setDeveloperMode($0) }
            )
          )
          SettingsControlRow("Appearance", description: "Choose the app color scheme.") {
            Picker("Appearance", selection: $settings.appTheme) {
              ForEach(AppTheme.allCases) { theme in
                Text(theme.displayName).tag(theme)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220, alignment: .trailing)
          }
          SettingsControlRow(
            "Language",
            description: String(
              format: String(localized: "Current app language: %@. Change per-app language in macOS Language & Region, then reopen ClashMax if needed."),
              AppLocalization.currentLanguageDisplayName
            )
          ) {
            Button {
              AppLocalization.openLanguageAndRegionSettings()
            } label: {
              Label("Open Language & Region", systemImage: "globe")
            }
            .help("Open System Settings > General > Language & Region.")
          }
        }

        Section("Updates") {
          UpdateVersionRow(
            title: "App Package",
            description: appUpdateController.statusMessage,
            version: appUpdateController.versionSummary
          ) {
            CheckForUpdatesButton(updateController: appUpdateController)
          }

          UpdateVersionRow(
            title: "Bundled Core",
            description: bundledCoreInfo.statusMessage,
            version: bundledCoreInfo.versionSummary
          )
        }

        Section("Launch") {
          SettingsToggleRow(
            "Launch at Login",
            description: "Register ClashMax as a macOS login item.",
            isOn: Binding(
              get: { settings.launchSettings.launchAtLogin },
              set: { appModel.setLaunchAtLogin($0) }
            )
          )

          SettingsToggleRow(
            "Silent Start",
            description: "Hide the main window when launched by the login item.",
            isOn: Binding(
              get: { settings.launchSettings.silentStart },
              set: { appModel.setSilentStart($0) }
            )
          )
          .help("When enabled, ClashMax hides its main window during login-item startup. Open it from the menu bar when needed.")

          SettingsControlRow("Login Item Status", description: settings.launchSettings.statusMessage) {
            Button {
              appModel.openLoginItemsSettings()
            } label: {
              Label("Open Login Items", systemImage: "gearshape")
            }
            .help("Open System Settings > General > Login Items & Extensions.")
          }

        }

        Section("Runtime") {
          PortControl(
            title: "Mixed Port",
            description: "HTTP and SOCKS inbound port used by Mihomo.",
            value: $settings.overrides.mixedPort
          )
          PortControl(
            title: "Controller Port",
            description: "Local controller API port bound to 127.0.0.1.",
            value: $settings.externalControllerSettings.port
          )
          SettingsToggleRow(
            "Allow LAN",
            description: "Allow devices on this LAN to use the proxy port.",
            isOn: $settings.overrides.allowLan
          )
          SettingsToggleRow(
            "Enable DNS Override",
            description: "Write app-managed DNS options into the runtime profile.",
            isOn: Binding(
              get: { settings.overrides.dnsEnabled ?? false },
              set: { settings.overrides.dnsEnabled = $0 }
            )
          )
          SettingsControlRow("Delay Test Mode", description: settings.delayTestSettings.mode.description) {
            Picker("Delay Test Mode", selection: $settings.delayTestSettings.mode) {
              ForEach(DelayTestMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
          }
          SettingsToggleRow(
            "Unified Delay",
            description: "Run manual delay tests twice and use the second result to reduce handshake bias.",
            isOn: $settings.delayTestSettings.unifiedDelay
          )
          ExternalControlSettingsRow()
          SettingsControlRow("Log Level", description: "Runtime logging verbosity.") {
            Picker("Log Level", selection: $settings.overrides.logLevel) {
              Text("Info").tag("info")
              Text("Warning").tag("warning")
              Text("Error").tag("error")
              Text("Debug").tag("debug")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120, alignment: .trailing)
          }
        }

        Section("System") {
          SettingsControlRow("Proxy Routing", description: "Routing mode used when the core starts.") {
            Picker("Proxy Routing", selection: Binding(
              get: { settings.proxyRoutingMode },
              set: { appModel.requestProxyRoutingMode($0) }
            )) {
              ForEach(ProxyRoutingMode.visibleCases(developerMode: settings.developerMode)) { mode in
                Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
            .help("Start uses this routing mode.")
          }

          if settings.proxyRoutingMode == .tun {
            SettingsControlRow("TUN Helper Status", description: appModel.tunHelperPreparationState.message) {
              ViewThatFits(in: .horizontal) {
                helperActionButtons
                helperActionButtonRows
              }
            }
            .onAppear {
              appModel.refreshHelperRegistrationStatus()
            }

            if settings.developerMode {
              Text("LaunchDaemon approval is managed by macOS. Registering may open System Settings instead of showing an app permission sheet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
              if !appModel.helperLogs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(appModel.helperLogs.suffix(6), id: \.self) { line in
                    Text(line)
                      .font(.system(.caption, design: .monospaced))
                      .lineLimit(2)
                  }
                }
              }
            }
          } else if settings.proxyRoutingMode == .networkExtensionExperimental {
            SettingsControlRow(
              "TUN Helper",
              description: "NE Transparent Proxy mode does not touch the privileged TUN helper."
            ) {
              Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            }
          } else {
            SettingsControlRow(
              "TUN Helper",
              description: "System Proxy mode does not need a privileged helper. Switch to TUN if you want VPN-style routing for non-HTTP traffic."
            ) {
              Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            }
          }
        }

        if settings.developerMode {
          Section("NE Transparent Proxy Experimental") {
            SettingsControlRow("System Extension", description: appModel.networkExtensionController.statusMessage) {
              ViewThatFits(in: .horizontal) {
                networkExtensionActionButtons
                networkExtensionActionButtonRows
              }
            }
            .onAppear {
              appModel.refreshNetworkExtensionStatus()
            }

            SettingsControlRow(
              "Transparent Proxy Status",
              description: appModel.networkExtensionController.tunnelStatusMessage
            ) {
              Label(
                appModel.networkExtensionController.vpnStatus.displayName,
                systemImage: networkExtensionStatusSymbol
              )
              .foregroundStyle(appModel.networkExtensionController.vpnStatus.isActive ? .green : .secondary)
            }

            SettingsControlRow(
              "NE Diagnostics",
              description: networkExtensionDiagnosticsSummary
            ) {
              Button {
                appModel.refreshNetworkExtensionStatus()
              } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
              }
            }

            if let error = appModel.networkExtensionController.recentError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }

            if let error = appModel.networkExtensionSystemDNSState.errorMessage {
              Text(String(format: String(localized: "DNS: %@"), error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        appModel.refreshLaunchSettings()
      }
    }
  }

  private var isHelperBusy: Bool {
    appModel.tunHelperPreparationState == .checking
  }

  private var helperBusyIndicator: some View {
    Group {
      if isHelperBusy {
        ProgressView()
          .controlSize(.small)
          .help("Talking to the TUN helper…")
      }
    }
  }

  private var helperActionButtons: some View {
    HStack(spacing: 8) {
      helperBusyIndicator
      helperRegisterButton
      helperOpenSettingsButton
      helperRepairButton
      helperStatusButton
      if settings.developerMode {
        helperLogsButton
      }
    }
  }

  private var helperActionButtonRows: some View {
    VStack(alignment: .trailing, spacing: 8) {
      HStack(spacing: 8) {
        helperRegisterButton
        helperOpenSettingsButton
        helperRepairButton
      }
      HStack(spacing: 8) {
        helperBusyIndicator
        helperStatusButton
        if settings.developerMode {
          helperLogsButton
        }
      }
    }
  }

  private var helperRegisterButton: some View {
    Button {
      appModel.registerHelper()
    } label: {
      Label("Register", systemImage: "checkmark.shield")
    }
    .disabled(isHelperBusy)
  }

  private var helperOpenSettingsButton: some View {
    Button {
      appModel.openHelperApprovalSettings()
    } label: {
      Label("Open Settings", systemImage: "gearshape")
    }
    .help("Open System Settings > General > Login Items & Extensions.")
  }

  private var helperRepairButton: some View {
    Button {
      appModel.repairHelperRegistration()
    } label: {
      Label("Repair", systemImage: "wrench.and.screwdriver")
    }
    .disabled(isHelperBusy)
  }

  private var helperStatusButton: some View {
    Button {
      appModel.refreshHelperStatus()
    } label: {
      Label("Status", systemImage: "waveform.path.ecg")
    }
    .disabled(isHelperBusy)
  }

  private var helperLogsButton: some View {
    Button {
      appModel.refreshHelperLogs()
    } label: {
      Label("Logs", systemImage: "text.alignleft")
    }
  }

  private var networkExtensionActionButtons: some View {
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

      Button {
        appModel.repairNetworkExtensionDNS()
      } label: {
        Label("Repair DNS", systemImage: "wrench.and.screwdriver")
      }
      .disabled(!appModel.canRepairNetworkExtensionDNS)
    }
  }

  private var networkExtensionStatusSymbol: String {
    switch appModel.networkExtensionController.vpnStatus {
    case .notConfigured:
      "checkmark.circle"
    case .connecting, .connected, .reasserting, .disconnecting:
      "network"
    case .invalid, .disconnected:
      "xmark.circle"
    }
  }

  private var networkExtensionDiagnosticsSummary: String {
    let diagnostics = appModel.networkExtensionController.diagnostics
    let dnsRuntime = appModel.networkExtensionRoutingSettings.dnsFakeIPEnabled
      ? String(localized: "fake-ip")
      : String(localized: "profile")
    return String(
      format: String(localized: "TCP %lld, UDP %lld, DNS captures %lld, DNS datagrams %lld, SOCKS failures %lld, DNS %@, system DNS %@."),
      diagnostics.activeTCPBridgeCount,
      diagnostics.activeUDPBridgeCount,
      diagnostics.dnsCaptureCount,
      diagnostics.dnsDatagramCount,
      diagnostics.socksHandshakeFailureCount,
      dnsRuntime,
      appModel.networkExtensionSystemDNSState.displayName
    )
  }

  private var networkExtensionActionButtonRows: some View {
    VStack(alignment: .trailing, spacing: 8) {
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
      }
      Button {
        appModel.refreshNetworkExtensionStatus()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      Button {
        appModel.repairNetworkExtensionDNS()
      } label: {
        Label("Repair DNS", systemImage: "wrench.and.screwdriver")
      }
      .disabled(!appModel.canRepairNetworkExtensionDNS)
    }
  }
}

private struct SettingsToggleRow: View {
  let title: String
  let description: String?
  @Binding var isOn: Bool

  init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
    self.title = title
    self.description = description
    _isOn = isOn
  }

  var body: some View {
    SettingsControlRow(title, description: description) {
      Toggle(localizedSettingsText(title), isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(localizedSettingsText(title))
    }
  }
}

private struct SettingsControlRow<Control: View>: View {
  let title: String
  let description: String?
  let control: Control

  init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.description = description
    self.control = control()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleBlock
        Spacer(minLength: 16)
        control
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        titleBlock
        control
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(localizedSettingsText(title))
        .foregroundStyle(.primary)
      if let description {
        Text(localizedSettingsText(description))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .layoutPriority(1)
  }
}

private struct UpdateVersionRow<Action: View>: View {
  let title: String
  let description: String
  let version: String
  let action: Action

  init(
    title: String,
    description: String,
    version: String,
    @ViewBuilder action: () -> Action
  ) {
    self.title = title
    self.description = description
    self.version = version
    self.action = action()
  }

  init(
    title: String,
    description: String,
    version: String
  ) where Action == EmptyView {
    self.title = title
    self.description = description
    self.version = version
    action = EmptyView()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 16) {
        titleBlock
        Spacer(minLength: 16)
        versionLabel
        action
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        titleBlock
        HStack(spacing: 10) {
          versionLabel
          action
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(localizedSettingsText(title))
        .foregroundStyle(.primary)
      Text(localizedSettingsText(description))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .layoutPriority(1)
  }

  private var versionLabel: some View {
    Text(version)
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }
}

private struct ExternalControlSettingsRow: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var settings: PersistedSettingsStore
  @State private var isControllerPresented = false
  @State private var isCORSPresented = false
  @State private var draft = ExternalControllerSettings.default
  @State private var addressDraft = ExternalControllerSettings.default.address
  @State private var secretDraft = ""
  @State private var error: String?
  @State private var corsDraft = ExternalControllerCORSSettings.default
  @State private var originDraft = ""
  @State private var corsError: String?
  @State private var suppressControllerPresentation = false

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("External Control")
            .foregroundStyle(.primary)
          corsSettingsButton
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.leading)
      }
      .layoutPriority(1)

      Spacer(minLength: 16)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      guard !suppressControllerPresentation else {
        suppressControllerPresentation = false
        return
      }
      presentControllerSettings()
    }
    .sheet(isPresented: $isControllerPresented) {
      ExternalControlSettingsSheet(
        draft: $draft,
        addressDraft: $addressDraft,
        secretDraft: $secretDraft,
        error: $error,
        onCancel: {
          isControllerPresented = false
        },
        onSave: save
      )
      .frame(width: 520)
      .padding(24)
    }
  }

  private var description: String {
    let controllerSettings = settings.externalControllerSettings
    let state = controllerSettings.enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    return String(
      format: String(localized: "%@ for external web dashboards at %@ with Bearer auth."),
      state,
      controllerSettings.address
    )
  }

  private var corsSettingsButton: some View {
    Button {
      suppressControllerPresentation = true
      syncCORSDraft()
      isCORSPresented = true
      DispatchQueue.main.async {
        suppressControllerPresentation = false
      }
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("Configure external control CORS")
    .popover(isPresented: $isCORSPresented, arrowEdge: .bottom) {
      ExternalControlCORSSettingsPopover(
        draft: $corsDraft,
        originDraft: $originDraft,
        error: $corsError,
        onCancel: {
          isCORSPresented = false
        },
        onSave: saveCORS
      )
      .frame(width: 520)
      .padding(18)
    }
  }

  private func presentControllerSettings() {
    syncDraft()
    isControllerPresented = true
  }

  private func syncDraft() {
    draft = settings.externalControllerSettings
    addressDraft = draft.address
    secretDraft = draft.normalizedSecret
    error = nil
  }

  private func syncCORSDraft() {
    corsDraft = settings.externalControllerSettings.cors
    corsDraft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(corsDraft.allowedOrigins)
    originDraft = ""
    corsError = nil
  }

  private func save() {
    guard let parsed = Self.parseAddress(addressDraft) else {
      error = "Listen address must use host:port, for example 127.0.0.1:9097."
      return
    }
    draft.host = parsed.host
    draft.port = parsed.port
    draft.secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft.cors.enabled = draft.enabled
    draft.cors.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(draft.cors.allowedOrigins)
    if let validationError = draft.validationError {
      error = validationError
      return
    }
    settings.externalControllerSettings = draft
    isControllerPresented = false
  }

  private func saveCORS() {
    corsDraft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(corsDraft.allowedOrigins)
    if let validationError = corsDraft.validationError {
      corsError = validationError
      return
    }
    var controllerSettings = settings.externalControllerSettings
    corsDraft.enabled = controllerSettings.enabled
    controllerSettings.cors = corsDraft
    settings.externalControllerSettings = controllerSettings
    isCORSPresented = false
  }

  private static func parseAddress(_ value: String) -> (host: String, port: Int)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("["),
       let closeBracket = trimmed.firstIndex(of: "]") {
      let hostStart = trimmed.index(after: trimmed.startIndex)
      let host = String(trimmed[hostStart..<closeBracket])
      let portStart = trimmed.index(after: closeBracket)
      guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
      let numberStart = trimmed.index(after: portStart)
      guard numberStart < trimmed.endIndex, let port = Int(trimmed[numberStart...]) else { return nil }
      return (host, port)
    }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 2, let port = Int(parts[1]) {
      return (parts[0], port)
    }
    if parts.count > 2, let portText = parts.last, let port = Int(portText) {
      let host = parts.dropLast().joined(separator: ":")
      return (host, port)
    }
    return nil
  }
}

private struct ExternalControlCORSSettingsPopover: View {
  @Binding var draft: ExternalControllerCORSSettings
  @Binding var originDraft: String
  @Binding var error: String?

  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("External Control CORS Settings", systemImage: "network")
        .font(.title3.weight(.semibold))

      Toggle("Allow Private Network Access", isOn: $draft.allowPrivateNetwork)
        .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 8) {
        Text("Allowed Origins")
          .font(.headline)

        VStack(spacing: 8) {
          ForEach(Array(draft.allowedOrigins.enumerated()), id: \.offset) { index, _ in
            HStack(spacing: 8) {
              TextField("https://dashboard.example", text: originBinding(at: index))
                .textFieldStyle(.roundedBorder)
              Button {
                draft.allowedOrigins.remove(at: index)
              } label: {
                Image(systemName: "trash")
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.borderedProminent)
              .tint(.red)
              .controlSize(.small)
              .help("Remove origin")
            }
          }
        }

        HStack(spacing: 8) {
          TextField("https://dashboard.example", text: $originDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addOrigin)
          Button("Add", action: addOrigin)
            .disabled(originDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Text("Always includes: \(ExternalControllerCORSSettings.fixedLocalOrigins.joined(separator: ", "))")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func originBinding(at index: Int) -> Binding<String> {
    Binding(
      get: {
        guard draft.allowedOrigins.indices.contains(index) else { return "" }
        return draft.allowedOrigins[index]
      },
      set: { value in
        guard draft.allowedOrigins.indices.contains(index) else { return }
        draft.allowedOrigins[index] = value
      }
    )
  }

  private func addOrigin() {
    let trimmed = originDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard ExternalControllerCORSSettings.isValidOrigin(trimmed) else {
      error = "Invalid origin: \(trimmed)"
      return
    }
    draft.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(draft.allowedOrigins + [trimmed])
    originDraft = ""
    error = nil
  }
}

private struct ExternalControlSettingsSheet: View {
  @Binding var draft: ExternalControllerSettings
  @Binding var addressDraft: String
  @Binding var secretDraft: String
  @Binding var error: String?

  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("External Controller Listen Address", systemImage: "network")
        .font(.title3.weight(.semibold))

      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .center, spacing: 14) {
          Text("Enable External Controller")
            .frame(width: 170, alignment: .leading)
          Toggle("Enable External Controller", isOn: $draft.enabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        labeledField("Controller Listen Address") {
          HStack(spacing: 8) {
            TextField("127.0.0.1:9097", text: $addressDraft)
              .textFieldStyle(.roundedBorder)
              .monospacedDigit()
              .disabled(!draft.enabled)
            copyButton(value: addressDraft, isEnabled: draft.enabled, help: "Copy listen address")
          }
        }

        labeledField("API Access Secret") {
          HStack(spacing: 8) {
            TextField("set-your-secret", text: $secretDraft)
              .textFieldStyle(.roundedBorder)
              .disabled(!draft.enabled)
            copyButton(value: secretDraft, isEnabled: draft.enabled, help: "Copy API secret")
          }
        }
      }

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  @ViewBuilder
  private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Text(localizedSettingsText(title))
        .frame(width: 170, alignment: .leading)
      content()
    }
  }

  private func copyButton(value: String, isEnabled: Bool, help: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(!isEnabled || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .help(help)
  }
}

private func localizedSettingsText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private struct PortControl: View {
  private static let portRange = 1024...65535

  let title: String
  var description: String?
  @Binding var value: Int
  @State private var draft = ""

  var body: some View {
    SettingsControlRow(title, description: description) {
      HStack(spacing: 8) {
        TextField("", text: $draft)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 82)
          .onSubmit(commitDraft)
          .onChange(of: draft) { _, newValue in
            updateValueIfValid(newValue)
          }
          .onAppear(perform: syncDraft)
          .onChange(of: value) { _, _ in
            syncDraft()
          }

        Stepper("", value: clampedValue, in: Self.portRange)
          .labelsHidden()
      }
    }
  }

  private var clampedValue: Binding<Int> {
    Binding(
      get: { value },
      set: { newValue in value = Self.clamped(newValue) }
    )
  }

  private func updateValueIfValid(_ text: String) {
    guard let parsed = Int(text), Self.portRange.contains(parsed) else { return }
    value = parsed
  }

  private func commitDraft() {
    guard let parsed = Int(draft) else {
      syncDraft()
      return
    }
    value = Self.clamped(parsed)
    syncDraft()
  }

  private func syncDraft() {
    let current = "\(value)"
    if draft != current {
      draft = current
    }
  }

  private static func clamped(_ value: Int) -> Int {
    min(max(value, portRange.lowerBound), portRange.upperBound)
  }
}
