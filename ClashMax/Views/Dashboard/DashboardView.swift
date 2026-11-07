import SwiftUI

struct DashboardView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var dashboardNamespace

  var body: some View {
    let state = appModel.dashboardRuntimeState

    GeometryReader { proxy in
      ScrollView {
        RunningDashboardView(
          currentNodeCoordinator: appModel.dashboardCurrentNodeCoordinator,
          state: state,
          namespace: dashboardNamespace,
          reduceMotion: reduceMotion,
          availableWidth: max(0, proxy.size.width - 2 * DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
        )
        .padding(DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
        .frame(maxWidth: DashboardLayoutMetrics.dashboardMaxWidth(for: proxy.size.width))
        .frame(maxWidth: .infinity)
      }
    }
    .background {
      DashboardSceneBackground()
    }
    .animation(
      reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.04),
      value: state.usesOperationalLayout
    )
  }
}

private struct DashboardSceneBackground: View {
  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .ignoresSafeArea()
  }
}
