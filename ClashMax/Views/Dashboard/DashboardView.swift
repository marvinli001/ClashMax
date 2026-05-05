import Pow
import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var appModel: AppModel
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
                state: state,
                namespace: dashboardNamespace,
                reduceMotion: reduceMotion,
                availableWidth: proxy.size.width
              )
              .transition(.movingParts.blur.combined(with: .opacity))
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
          .transition(.movingParts.blur.combined(with: .opacity))
          .padding(DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
          .frame(maxWidth: DashboardLayoutMetrics.dashboardMaxWidth(for: proxy.size.width))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background {
      DashboardSceneBackground()
    }
    .animation(
      reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.62, dampingFraction: 0.86),
      value: state
    )
    .animation(.easeInOut(duration: 0.24), value: appModel.profileStore.activeProfileID)
  }
}

enum DashboardHomeBackgroundStyle {
  static func fillID(for _: DashboardRuntimeState) -> String {
    "system-window"
  }
}

private struct DashboardSceneBackground: View {

  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .ignoresSafeArea()
  }
}
