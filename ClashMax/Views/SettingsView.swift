import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Settings",
      subtitle: "Runtime overrides and system integration controls.",
      maxContentWidth: 760
    ) {
      EmptyView()
    } content: {
      Form {
        Section("General") {
          Toggle("Developer Mode", isOn: $appModel.developerMode)
        }

        Section("Launch") {
          Toggle("Launch at Login", isOn: Binding(
            get: { appModel.launchSettings.launchAtLogin },
            set: { appModel.setLaunchAtLogin($0) }
          ))

          Toggle("Silent Start", isOn: Binding(
            get: { appModel.launchSettings.silentStart },
            set: { appModel.setSilentStart($0) }
          ))
          .help("When enabled, ClashMax hides its main window during login-item startup. Open it from the menu bar when needed.")

          Label {
            Text(appModel.launchSettings.statusMessage)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "power")
          }

          Button {
            appModel.openLoginItemsSettings()
          } label: {
            Label("Open Login Items", systemImage: "gearshape")
          }
          .help("Open System Settings > General > Login Items & Extensions.")
        }

        Section("Runtime") {
          PortControl(title: "Mixed Port", value: $appModel.overrides.mixedPort)
          PortControl(title: "Controller Port", value: $appModel.overrides.externalControllerPort)
          Toggle("Allow LAN", isOn: $appModel.overrides.allowLan)
          Toggle("Enable DNS Override", isOn: Binding(
            get: { appModel.overrides.dnsEnabled ?? false },
            set: { appModel.overrides.dnsEnabled = $0 }
          ))
          Picker("Log Level", selection: $appModel.overrides.logLevel) {
            Text("Info").tag("info")
            Text("Warning").tag("warning")
            Text("Error").tag("error")
            Text("Debug").tag("debug")
          }
        }

        Section("System") {
          Picker("Proxy Routing", selection: Binding(
            get: { appModel.proxyRoutingMode },
            set: { appModel.requestProxyRoutingMode($0) }
          )) {
            ForEach(ProxyRoutingMode.allCases) { mode in
              Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
            }
          }
          .help("Start uses this routing mode.")

          if appModel.proxyRoutingMode == .tun {
            VStack(alignment: .leading, spacing: 8) {
              Label {
                Text(appModel.helperClient.statusMessage)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
                  .fixedSize(horizontal: false, vertical: true)
              } icon: {
                Image(systemName: "checkmark.shield")
              }

              ViewThatFits(in: .horizontal) {
                helperActionButtons
                helperActionButtonRows
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
            }
            .onAppear {
              appModel.refreshHelperRegistrationStatus()
            }
          } else {
            Label(
              "System Proxy mode does not need a privileged helper. Switch to TUN if you want VPN-style routing for non-HTTP traffic.",
              systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
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
    VStack(alignment: .leading, spacing: 8) {
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

private struct PortControl: View {
  private static let portRange = 1024...65535

  let title: String
  @Binding var value: Int
  @State private var draft = ""

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      HStack(spacing: 8) {
        TextField("Port", text: $draft)
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
