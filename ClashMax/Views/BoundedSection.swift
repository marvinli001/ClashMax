import SwiftUI

/// Issue #27: how much vertical space a *secondary* section may claim inside a page.
///
/// A page is a fixed-height container — the window hands the detail column exactly the room it has,
/// and nothing inside scrolls unless it says so. A section whose height grows with its data (the
/// provider summaries above the Proxies and Rules lists) therefore outgrows the window as soon as a
/// profile carries enough providers. SwiftUI does not clip an oversized child: a flexible frame
/// grows to fit it, so the overflow propagated all the way out to the split view, painted over the
/// title bar and dragged the sidebar's rows off screen. The window ended up unusable.
///
/// Capping such a section at a share of the page keeps the primary list — the reason the page
/// exists — on screen no matter how many rows the data has.
enum SecondarySectionHeight {
  /// A secondary section never claims more than this share of the page it sits in.
  static let pageHeightShare: CGFloat = 0.34
  /// A section shorter than this cannot show anything useful, so a cramped page gives it this much
  /// and lets the page's own containment deal with the remainder.
  static let floor: CGFloat = 88
  /// Past this the section stops growing even on a very tall window: it summarizes the page, it is
  /// not the page.
  static let ceiling: CGFloat = 260

  /// The tallest a secondary section may be on a page of `pageHeight` points.
  ///
  /// An unknown page height (zero before the first geometry pass, or a non-finite proposal) falls
  /// back to the ceiling rather than to zero, so the section is never invisible.
  static func maxHeight(pageHeight: CGFloat) -> CGFloat {
    guard pageHeight.isFinite, pageHeight > 0 else { return ceiling }
    return min(max(pageHeight * pageHeightShare, floor), ceiling)
  }
}

/// Content that keeps its natural height while it fits and scrolls within `maxHeight` once it does
/// not, so it can never push its siblings — or the window's chrome — out of the way.
///
/// The height has to be measured: a bare `ScrollView` is flexible along its scroll axis and would
/// claim the whole cap even for a single row, leaving a mostly empty box on the common path.
/// See `SecondarySectionHeight` for why the cap exists at all.
struct BoundedHeightSection<Content: View>: View {
  var maxHeight: CGFloat
  @ViewBuilder var content: Content

  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView(.vertical) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        // The scroll view proposes an unbounded height along its axis, so this reports the
        // content's natural height even while the section itself is clamped below it.
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          contentHeight = height
        }
    }
    .frame(height: resolvedHeight)
    .scrollDisabled(!overflows)
    .scrollIndicators(overflows ? .automatic : .hidden)
  }

  private var cap: CGFloat { max(maxHeight, 0) }

  private var resolvedHeight: CGFloat { min(max(contentHeight, 0), cap) }

  private var overflows: Bool { contentHeight > cap }
}
