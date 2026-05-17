import SwiftUI

struct AdaptivePage<Actions: View, Content: View>: View {
  let title: String
  var subtitle: String?
  var maxContentWidth: CGFloat = .infinity
  @ViewBuilder var actions: Actions
  @ViewBuilder var content: Content

  var body: some View {
    GeometryReader { proxy in
      VStack(alignment: .leading, spacing: 16) {
        header
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding(DashboardLayoutMetrics.pagePadding(for: proxy.size.width))
      .frame(maxWidth: maxContentWidth)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        titleBlock
        Spacer(minLength: 12)
        actions
      }

      VStack(alignment: .leading, spacing: 10) {
        titleBlock
        actions
      }
    }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(localizedPageText(title))
        .font(.title2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
      if let subtitle {
        Text(localizedPageText(subtitle))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct CenteredUnavailableState: View {
  let title: String
  let systemImage: String
  var message: String?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.tertiary)

      Text(localizedPageText(title))
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)

      if let message {
        Text(localizedPageText(message))
          .font(.callout)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .frame(maxWidth: 360)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .accessibilityElement(children: .combine)
  }
}

private func localizedPageText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}
