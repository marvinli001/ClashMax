import SwiftUI

struct MenuBarView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    Button(appModel.isRunning ? "Stop Core" : "Start Core") {
      appModel.isRunning ? appModel.stop() : appModel.start()
    }

    Picker("Mode", selection: Binding(
      get: { appModel.overrides.mode },
      set: { appModel.requestMode($0) }
    )) {
      ForEach(RunMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }

    Toggle("System Proxy", isOn: Binding(
      get: { appModel.systemProxyEnabled },
      set: { appModel.setSystemProxyEnabled($0) }
    ))

    Toggle("TUN", isOn: $appModel.tunEnabled)

    Divider()

    Text(appModel.statusSummary)
    Text(appModel.profileStore.activeProfile?.name ?? "No Profile")
    Text(appModel.trafficSample.shortLabel)

    Button("Update Subscription") {
      appModel.updateActiveSubscription()
    }

    Button("Open Window") {
      NSApp.activate(ignoringOtherApps: true)
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
  }
}
