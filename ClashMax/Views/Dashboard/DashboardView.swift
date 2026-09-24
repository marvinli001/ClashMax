import SwiftUI

struct DashboardView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var dashboardNamespace

  var body: some View {
    let state = appModel.dashboardRuntimeState

    GeometryReader { proxy in
      Group {
        if state.usesOperationalLayout {
          ScrollView {
            VStack(spacing: 16) {
              RunningDashboardView(
                currentNodeCoordinator: appModel.dashboardCurrentNodeCoordinator,
                state: state,
                namespace: dashboardNamespace,
                reduceMotion: reduceMotion,
                availableWidth: proxy.size.width
              )
              .transition(.opacity)
            }
            .padding(DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
            .frame(maxWidth: DashboardLayoutMetrics.dashboardMaxWidth(for: proxy.size.width))
            .frame(maxWidth: .infinity)
          }
        } else {
          LaunchDashboardView(
            state: state,
            namespace: dashboardNamespace,
            reduceMotion: reduceMotion,
            availableSize: proxy.size
          )
          .transition(.opacity)
          .padding(DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
          .frame(maxWidth: DashboardLayoutMetrics.dashboardMaxWidth(for: proxy.size.width))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background {
      DashboardSceneBackground()
    }
    // Only the swap between the launch page and the running page animates. Keyed on the layout
    // rather than on `state`, so starting → running (same layout) does not replay it, and nothing
    // else that happens to change in the same update — a crash message, a readiness issue, a
    // profile switch — is swept into a page-wide spring.
    .animation(
      reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.35, bounce: 0),
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
