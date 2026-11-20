import SwiftUI

struct DashboardView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let state = appModel.dashboardRuntimeState

    GeometryReader { proxy in
      let padding = DashboardLayoutMetrics.pagePadding(for: proxy.size.width)
      let pageWidth = min(proxy.size.width, DashboardLayoutMetrics.dashboardMaxWidth(for: proxy.size.width))
      ScrollView {
        RunningDashboardView(
          currentNodeCoordinator: appModel.dashboardCurrentNodeCoordinator,
          state: state,
          availableWidth: max(0, pageWidth - 2 * padding)
        )
        .padding(padding)
        .frame(width: pageWidth)
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
