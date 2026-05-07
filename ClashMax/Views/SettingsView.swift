import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel

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
            isOn: $appModel.developerMode
          )
          SettingsControlRow("Appearance", description: "Choose the app color scheme.") {
            Picker("Appearance", selection: $appModel.appTheme) {
              ForEach(AppTheme.allCases) { theme in
                Text(theme.displayName).tag(theme)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220, alignment: .trailing)
          }
        }

        Section("Launch") {
          SettingsToggleRow(
            "Launch at Login",
            description: "Register ClashMax as a macOS login item.",
            isOn: Binding(
              get: { appModel.launchSettings.launchAtLogin },
              set: { appModel.setLaunchAtLogin($0) }
            )
          )

          SettingsToggleRow(
            "Silent Start",
            description: "Hide the main window when launched by the login item.",
            isOn: Binding(
              get: { appModel.launchSettings.silentStart },
              set: { appModel.setSilentStart($0) }
            )
          )
          .help("When enabled, ClashMax hides its main window during login-item startup. Open it from the menu bar when needed.")

          SettingsControlRow("Login Item Status", description: appModel.launchSettings.statusMessage) {
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
            value: $appModel.overrides.mixedPort
          )
          PortControl(
            title: "Controller Port",
            description: "Local controller API port bound to 127.0.0.1.",
            value: $appModel.externalControllerSettings.port
          )
          SettingsToggleRow(
            "Allow LAN",
            description: "Allow devices on this LAN to use the proxy port.",
            isOn: $appModel.overrides.allowLan
          )
          SettingsToggleRow(
            "Enable DNS Override",
            description: "Write app-managed DNS options into the runtime profile.",
            isOn: Binding(
              get: { appModel.overrides.dnsEnabled ?? false },
              set: { appModel.overrides.dnsEnabled = $0 }
            )
          )
          SettingsControlRow("Delay Test Mode", description: appModel.delayTestSettings.mode.description) {
            Picker("Delay Test Mode", selection: $appModel.delayTestSettings.mode) {
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
            isOn: $appModel.delayTestSettings.unifiedDelay
          )
          ExternalControlSettingsRow()
          SettingsControlRow("Log Level", description: "Runtime logging verbosity.") {
            Picker("Log Level", selection: $appModel.overrides.logLevel) {
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
              get: { appModel.proxyRoutingMode },
              set: { appModel.requestProxyRoutingMode($0) }
            )) {
              ForEach(ProxyRoutingMode.allCases) { mode in
                Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .trailing)
            .help("Start uses this routing mode.")
          }

          if appModel.proxyRoutingMode == .tun {
            SettingsControlRow("TUN Helper Status", description: appModel.helperClient.statusMessage) {
              ViewThatFits(in: .horizontal) {
                helperActionButtons
                helperActionButtonRows
              }
            }
            .onAppear {
              appModel.refreshHelperRegistrationStatus()
            }

            if appModel.developerMode {
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
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        appModel.refreshLaunchSettings()
      }
    }
  }

  private var helperActionButtons: some View {
    HStack(spacing: 8) {
      helperRegisterButton
      helperOpenSettingsButton
      helperRepairButton
      helperStatusButton
      if appModel.developerMode {
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
        helperStatusButton
        if appModel.developerMode {
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
  }

  private var helperStatusButton: some View {
    Button {
      appModel.refreshHelperStatus()
    } label: {
      Label("Status", systemImage: "waveform.path.ecg")
    }
  }

  private var helperLogsButton: some View {
    Button {
      appModel.refreshHelperLogs()
    } label: {
      Label("Logs", systemImage: "text.alignleft")
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
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(title)
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
      Text(title)
        .foregroundStyle(.primary)
      if let description {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .layoutPriority(1)
  }
}

private struct ExternalControlSettingsRow: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("External Control")
            .foregroundStyle(.primary)
          ExternalControlSettingsButton()
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .layoutPriority(1)

      Spacer(minLength: 16)

      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var description: String {
    let settings = appModel.externalControllerSettings
    let state = settings.enabled ? "Enabled" : "Disabled"
    return "\(state) for external web dashboards at \(settings.address) with Bearer auth."
  }
}

private struct ExternalControlSettingsButton: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var isPresented = false
  @State private var draft = ExternalControllerSettings.default
  @State private var addressDraft = ExternalControllerSettings.default.address
  @State private var secretDraft = ""
  @State private var originDraft = ""
  @State private var error: String?
  @State private var showsOrigins = true

  var body: some View {
    Button {
      syncDraft()
      isPresented = true
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .help("Configure external controller access")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      popoverContent
        .frame(width: 540)
        .padding(18)
    }
  }

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("External Controller", systemImage: "network")
        .font(.title3.weight(.semibold))

      Toggle("Enable External Controller", isOn: $draft.enabled)
        .toggleStyle(.switch)

      VStack(alignment: .leading, spacing: 10) {
        labeledField("Controller Listen Address") {
          HStack(spacing: 8) {
            TextField("127.0.0.1:9097", text: $addressDraft)
              .textFieldStyle(.roundedBorder)
              .monospacedDigit()
              .disabled(!draft.enabled)
            copyButton(value: addressDraft, help: "Copy listen address")
          }
        }

        labeledField("API Access Secret") {
          HStack(spacing: 8) {
            TextField("set-your-secret", text: $secretDraft)
              .textFieldStyle(.roundedBorder)
              .disabled(!draft.enabled)
            copyButton(value: secretDraft, help: "Copy API secret")
          }
        }
      }

      Divider()

      Toggle("Allow Private Network Access", isOn: $draft.cors.allowPrivateNetwork)
        .toggleStyle(.switch)
        .disabled(!draft.enabled)

      DisclosureGroup("Allowed Web Panel Origins", isExpanded: $showsOrigins) {
        VStack(alignment: .leading, spacing: 8) {
          VStack(spacing: 8) {
            ForEach(Array(draft.cors.allowedOrigins.enumerated()), id: \.offset) { index, _ in
              HStack(spacing: 8) {
                TextField("https://dashboard.example", text: originBinding(at: index))
                  .textFieldStyle(.roundedBorder)
                  .disabled(!draft.enabled)
                Button {
                  draft.cors.allowedOrigins.remove(at: index)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!draft.enabled)
                .help("Remove origin")
              }
            }
          }

          HStack(spacing: 8) {
            TextField("https://dashboard.example", text: $originDraft)
              .textFieldStyle(.roundedBorder)
              .disabled(!draft.enabled)
              .onSubmit(addOrigin)
            Button("Add", action: addOrigin)
              .disabled(!draft.enabled || originDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }

          Text("Always includes: \(ExternalControllerCORSSettings.fixedLocalOrigins.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
      }
      .disabled(!draft.enabled)

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
        Button("Save") {
          save()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func syncDraft() {
    draft = appModel.externalControllerSettings
    addressDraft = draft.address
    secretDraft = draft.normalizedSecret
    originDraft = ""
    error = nil
  }

  @ViewBuilder
  private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Text(title)
        .frame(width: 170, alignment: .leading)
      content()
    }
  }

  private func copyButton(value: String, help: String) -> some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .help(help)
  }

  private func originBinding(at index: Int) -> Binding<String> {
    Binding(
      get: {
        guard draft.cors.allowedOrigins.indices.contains(index) else { return "" }
        return draft.cors.allowedOrigins[index]
      },
      set: { value in
        guard draft.cors.allowedOrigins.indices.contains(index) else { return }
        draft.cors.allowedOrigins[index] = value
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
    draft.cors.allowedOrigins = ExternalControllerCORSSettings.normalizedOrigins(draft.cors.allowedOrigins + [trimmed])
    originDraft = ""
    error = nil
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
    appModel.externalControllerSettings = draft
    isPresented = false
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
