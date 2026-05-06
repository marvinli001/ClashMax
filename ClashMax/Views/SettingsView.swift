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
        Section("Runtime") {
          HStack {
            Text("Mixed Port")
            Spacer()
            Stepper("\(appModel.overrides.mixedPort)", value: $appModel.overrides.mixedPort, in: 1024...65535)
              .labelsHidden()
          }
          HStack {
            Text("Controller Port")
            Spacer()
            Stepper("\(appModel.overrides.externalControllerPort)", value: $appModel.overrides.externalControllerPort, in: 1024...65535)
              .labelsHidden()
          }
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
    }
  }

  private var helperActionButtons: some View {
    HStack(spacing: 8) {
      helperRegisterButton
      helperOpenSettingsButton
      helperRepairButton
      helperStatusButton
      helperLogsButton
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
        helperLogsButton
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
