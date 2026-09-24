import Shimmer
import SwiftUI

extension View {
  /// Marks a whole skeleton — a list, a table, a card body — as loading, with one shimmer across
  /// it. Apply it to the outermost skeleton container only: the bars and rows inside do not shimmer
  /// on their own, so every bar in the container shares the same band instead of each running its
  /// own looping mask. A skeleton nested in another one (the node skeleton inside the public-IP
  /// skeleton) leaves the shimmer to the outer container.
  func clashMaxSkeleton(active: Bool = true) -> some View {
    modifier(ClashMaxSkeletonModifier(active: active))
  }
}

private extension EnvironmentValues {
  @Entry var isInsideClashMaxSkeleton = false
}

private struct ClashMaxSkeletonModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isInsideClashMaxSkeleton) private var isInsideSkeleton
  let active: Bool

  func body(content: Content) -> some View {
    if isInsideSkeleton {
      content
    } else {
      content
        .environment(\.isInsideClashMaxSkeleton, active)
        .redacted(reason: active ? .placeholder : [])
        .shimmering(active: active && !reduceMotion)
    }
  }
}

/// One placeholder bar. It has no shimmer of its own: the container it sits in applies
/// `clashMaxSkeleton()` once for all of its bars.
struct ClashMaxSkeletonBar: View {
  var width: CGFloat?
  var height: CGFloat = 10
  var cornerRadius: CGFloat = 4

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(Color.secondary.opacity(0.24))
      .frame(width: width, height: height)
      .accessibilityHidden(true)
  }
}

struct ClashMaxSkeletonRow: View {
  var showsLeadingIcon = true
  var trailingWidth: CGFloat?

  var body: some View {
    HStack(spacing: 10) {
      if showsLeadingIcon {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.secondary.opacity(0.20))
          .frame(width: 18, height: 18)
      }

      VStack(alignment: .leading, spacing: 6) {
        ClashMaxSkeletonBar(width: 150, height: 11)
        ClashMaxSkeletonBar(width: 96, height: 8)
      }

      Spacer(minLength: 12)

      if let trailingWidth {
        ClashMaxSkeletonBar(width: trailingWidth, height: 9)
      }
    }
    .padding(.vertical, 5)
    .accessibilityHidden(true)
  }
}

struct ClashMaxSkeletonList: View {
  var rows: Int = 5
  var showsLeadingIcon = true
  var trailingWidth: CGFloat? = 56

  var body: some View {
    VStack(spacing: 8) {
      ForEach(0..<rows, id: \.self) { index in
        ClashMaxSkeletonRow(
          showsLeadingIcon: showsLeadingIcon,
          trailingWidth: index.isMultiple(of: 2) ? trailingWidth : nil
        )
      }
    }
    .clashMaxSkeleton()
    .accessibilityHidden(true)
  }
}

struct ClashMaxSkeletonTable: View {
  var rows: Int = 7

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(0..<rows, id: \.self) { index in
        HStack(spacing: 16) {
          ClashMaxSkeletonBar(width: index.isMultiple(of: 3) ? 190 : 150, height: 10)
          ClashMaxSkeletonBar(width: 70, height: 10)
          ClashMaxSkeletonBar(width: 120, height: 10)
          Spacer(minLength: 12)
          ClashMaxSkeletonBar(width: 56, height: 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)

        if index < rows - 1 {
          Divider()
            .opacity(0.35)
        }
      }
    }
    // Inside the table's background, so the band sweeps the rows and the frame stays solid.
    .clashMaxSkeleton()
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
    }
    .accessibilityHidden(true)
  }
}

struct ClashMaxProxyGroupSkeletonList: View {
  var groupCount: Int = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(0..<groupCount, id: \.self) { index in
        VStack(alignment: .leading, spacing: 10) {
          ClashMaxSkeletonRow(showsLeadingIcon: true, trailingWidth: index.isMultiple(of: 2) ? 64 : nil)

          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 10, alignment: .topLeading)],
            alignment: .leading,
            spacing: 10
          ) {
            ForEach(0..<4, id: \.self) { itemIndex in
              VStack(alignment: .leading, spacing: 9) {
                ClashMaxSkeletonBar(width: itemIndex.isMultiple(of: 2) ? 128 : 160, height: 11)
                HStack {
                  ClashMaxSkeletonBar(width: 54, height: 9)
                  Spacer()
                  ClashMaxSkeletonBar(width: 42, height: 9)
                }
              }
              .padding(10)
              .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
              .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
      }
    }
    .clashMaxSkeleton()
    .accessibilityHidden(true)
  }
}

struct ClashMaxCurrentNodeSkeleton: View {
  var isCompact = false

  var body: some View {
    VStack(alignment: .leading, spacing: isCompact ? 10 : 14) {
      HStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.secondary.opacity(0.18))
          .frame(width: 42, height: 42)
        VStack(alignment: .leading, spacing: 7) {
          ClashMaxSkeletonBar(width: 160, height: 13)
          ClashMaxSkeletonBar(width: 110, height: 9)
        }
      }

      HStack(spacing: 10) {
        ClashMaxSkeletonBar(width: 150, height: 28, cornerRadius: 6)
        ClashMaxSkeletonBar(width: nil, height: 28, cornerRadius: 6)
      }
    }
    .clashMaxSkeleton()
    .accessibilityHidden(true)
  }
}

struct ClashMaxChartSkeleton: View {
  var body: some View {
    Canvas { context, size in
      let inset: CGFloat = 8
      let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
      let values: [CGFloat] = [0.24, 0.42, 0.35, 0.68, 0.50, 0.74, 0.46, 0.58]
      var path = Path()

      for (index, value) in values.enumerated() {
        let progress = CGFloat(index) / CGFloat(values.count - 1)
        let point = CGPoint(
          x: plot.minX + plot.width * progress,
          y: plot.maxY - plot.height * value
        )
        if index == 0 {
          path.move(to: point)
        } else {
          path.addLine(to: point)
        }
      }

      context.stroke(path, with: .color(.secondary.opacity(0.28)), lineWidth: 2.2)
    }
    .clashMaxSkeleton()
    .accessibilityHidden(true)
  }
}
