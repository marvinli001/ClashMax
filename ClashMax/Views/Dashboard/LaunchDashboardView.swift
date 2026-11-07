import SwiftUI

struct DashboardIdleSurface: View {
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 28) {
        idleFact("Traffic", symbolName: "chart.xyaxis.line")
        idleFact("Public IP", symbolName: "globe")
        Spacer(minLength: 0)
      }
      VStack(alignment: .leading, spacing: 12) {
        idleFact("Traffic", symbolName: "chart.xyaxis.line")
        idleFact("Public IP", symbolName: "globe")
      }
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func idleFact(_ title: LocalizedStringResource, symbolName: String) -> some View {
    HStack(spacing: 8) {
      Label { Text(title) } icon: { Image(systemName: symbolName) }
      Text("Not running").foregroundStyle(.secondary)
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }
}

extension View {
  @ViewBuilder
  func dashboardMatchedGeometry(id: String, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
    if reduceMotion { self } else { matchedGeometryEffect(id: id, in: namespace) }
  }
}
