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
          Stepper("Mixed Port: \(appModel.overrides.mixedPort)", value: $appModel.overrides.mixedPort, in: 1024...65535)
          Stepper("Controller Port: \(appModel.overrides.externalControllerPort)", value: $appModel.overrides.externalControllerPort, in: 1024...65535)
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
          Toggle("System Proxy", isOn: Binding(
            get: { appModel.systemProxyEnabled },
            set: { appModel.setSystemProxyEnabled($0) }
          ))
          Toggle("TUN Mode", isOn: $appModel.tunEnabled)
          HStack {
            Text(appModel.helperClient.statusMessage)
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              appModel.refreshHelperStatus()
            } label: {
              Label("Status", systemImage: "waveform.path.ecg")
            }
            Button {
              appModel.refreshHelperLogs()
            } label: {
              Label("Logs", systemImage: "text.alignleft")
            }
          }
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
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
  }
}
