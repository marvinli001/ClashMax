import SwiftUI

/// Where a page publishes its title.
enum PageChromePlacement {
  /// Window title bar, via `navigationTitle`. This is what earns the system Liquid
  /// Glass title treatment on macOS 26, and it hands the page's title row back to
  /// the content.
  case toolbar
  /// Inline title drawn inside the content area, for hosts that have no window title
  /// bar to publish into — currently the `Settings` scene.
  case inline
}

extension EnvironmentValues {
  @Entry var pageChromePlacement: PageChromePlacement = .toolbar
}

struct AdaptivePage<Actions: View, Content: View>: View {
  let title: String
  var maxContentWidth: CGFloat = .infinity
  @ViewBuilder var actions: Actions
  @ViewBuilder var content: Content

  @Environment(\.pageChromePlacement) private var placement
  @State private var pageWidth: CGFloat = 0

  var body: some View {
    switch placement {
    case .toolbar:
      page { pageActionBar }
        .navigationTitle(localizedPageText(title))
    case .inline:
      page { inlineHeader }
    }
  }

  /// Page-owned controls sit at the top-trailing corner of the content, not in the
  /// window toolbar. The toolbar already carries the global run controls, and a second
  /// segmented picker sitting next to the run-mode picker reads as one continuous
  /// control instead of two unrelated ones.
  ///
  /// Skipped entirely when the page declares no actions, so pages like Rules and
  /// Settings don't pay a row of vertical space (and the stack's spacing) for nothing.
  @ViewBuilder
  private var pageActionBar: some View {
    if Actions.self != EmptyView.self {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        actions
      }
    }
  }

  private func page<Header: View>(@ViewBuilder header: () -> Header) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      header()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(DashboardLayoutMetrics.pagePadding(for: pageWidth))
    .frame(maxWidth: maxContentWidth)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Replaces a GeometryReader wrapper: this reports the container width without
    // the reader's habit of claiming all proposed space and flattening ideal sizes.
    // Measured on the outermost frame, so the value never depends on the padding
    // it feeds.
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      pageWidth = width
    }
  }

  private var inlineHeader: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        titleBlock
          .frame(maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
        actions
          .fixedSize(horizontal: true, vertical: false)
      }

      VStack(alignment: .leading, spacing: 10) {
        titleBlock
        actions
      }
    }
  }

  private var titleBlock: some View {
    Text(localizedPageText(title))
      .font(.title2.weight(.semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.78)
  }
}

/// Finder-style status line under a page's primary list, carrying the live counts
/// that used to live in the window subtitle. Pages show it only alongside their
/// populated list — skeleton and empty states already say what the counts would.
struct PageStatusFooter: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

struct CenteredUnavailableState: View {
  let title: String
  let systemImage: String
  var message: String?

  var body: some View {
    // ContentUnavailableView is the platform's own empty state, so it tracks system
    // metrics and Liquid Glass styling instead of re-deriving them here.
    ContentUnavailableView {
      Label(localizedPageText(title), systemImage: systemImage)
    } description: {
      if let message {
        Text(localizedPageText(message))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private func localizedPageText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}
