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

    Picker("Profile", selection: Binding<Profile.ID?>(
      get: { appModel.profileStore.activeProfileID },
      set: { id in
        if let id, let profile = appModel.profileStore.profiles.first(where: { $0.id == id }) {
          appModel.selectProfile(profile)
        }
      }
    )) {
      Text("No Profile").tag(Profile.ID?.none)
      ForEach(appModel.profileStore.profiles) { profile in
        Text(profile.name).tag(Profile.ID?.some(profile.id))
      }
    }

    Picker("Proxy", selection: Binding(
      get: { appModel.proxyRoutingMode },
      set: { appModel.requestProxyRoutingMode($0) }
    )) {
      ForEach(ProxyRoutingMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }

    Divider()

    Text(appModel.statusSummary)
    Text("Owner: \(appModel.runtimeOwner.rawValue)")
    Text(appModel.profileStore.activeProfile?.name ?? "No Profile")
    Text(appModel.trafficSample.shortLabel)

    Button(appModel.systemProxyEnabled ? "Disable System Proxy" : "Enable System Proxy") {
      appModel.setSystemProxyEnabled(!appModel.systemProxyEnabled)
    }
    .disabled(appModel.proxyRoutingMode == .tun)

    Button("Update Subscription") {
      appModel.updateActiveSubscription()
    }
    .disabled(!(appModel.profileStore.activeProfile?.isSubscription ?? false))

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
