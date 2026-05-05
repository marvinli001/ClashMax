import SwiftUI

struct MenuBarView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    Button(canStopRuntime ? "Stop Core" : "Start Core") {
      canStopRuntime ? appModel.stop() : appModel.start()
    }

    Picker("Mode", selection: Binding(
      get: { appModel.overrides.mode },
      set: { appModel.requestMode($0) }
    )) {
      ForEach(RunMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }

    Picker("Proxy", selection: Binding(
      get: { appModel.proxyRoutingMode },
      set: { appModel.setProxyRoutingMode($0) }
    )) {
      ForEach(ProxyRoutingMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }

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

  private var canStopRuntime: Bool {
    appModel.isRunning || appModel.dashboardRuntimeState.isStarting
  }
}
