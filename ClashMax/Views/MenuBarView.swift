import SwiftUI

struct MenuBarView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @EnvironmentObject private var appUpdateController: AppUpdateController

  var body: some View {
    Button(canStopRuntime ? "Stop Core" : "Start Core") {
      if canStopRuntime {
        appModel.stop()
      } else {
        appModel.start()
      }
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
    Text(runtimeData.trafficSample.shortLabel)

    Button(appModel.systemProxyEnabled ? "Disable System Proxy" : "Enable System Proxy") {
      appModel.setSystemProxyEnabled(!appModel.systemProxyEnabled)
    }
    .disabled(appModel.proxyRoutingMode != .systemProxy)

    Button("Update Subscription") {
      appModel.updateActiveSubscription()
    }
    .disabled(!(appModel.profileStore.activeProfile?.isSubscription ?? false))

    CheckForUpdatesButton(updateController: appUpdateController)

    Button("Open Window") {
      AppDelegate.showMainWindow()
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
  }

  private var canStopRuntime: Bool {
    appModel.canStopRuntime
  }
}
