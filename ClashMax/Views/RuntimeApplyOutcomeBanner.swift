import SwiftUI

/// One shared report of what the last rule/DNS commit actually did to the runtime.
///
/// Issue #15: success used to be indistinguishable from silence, and a rollback — ClashMax restoring
/// the previous config after the core rejected an edit — was completely invisible, which reads as
/// "my change disappeared on its own". Routing, Settings and Profiles all show this same banner so
/// the answer is in the same place wherever the edit was made.
struct RuntimeApplyOutcomeBanner: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    if let outcome = appModel.lastRuntimeApplyOutcome {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: outcome.systemImage)
          .foregroundStyle(Self.tint(for: outcome))
          .font(.callout)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(outcome.title)
            .font(.callout.weight(.semibold))
          Text(outcome.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        if case .restartNeeded = outcome {
          Button("Restart Now") {
            appModel.restart()
            appModel.clearRuntimeApplyOutcome()
          }
          .controlSize(.small)
        }

        Button {
          appModel.clearRuntimeApplyOutcome()
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Dismiss")
        .help("Dismiss")
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Self.tint(for: outcome).opacity(0.10), in: SurfaceRadius.shape(SurfaceRadius.tile))
      .overlay(
        SurfaceRadius.shape(SurfaceRadius.tile)
          .strokeBorder(Self.tint(for: outcome).opacity(0.28), lineWidth: 1)
      )
      .accessibilityElement(children: .contain)
    }
  }

  private static func tint(for outcome: RuntimeApplyOutcome) -> Color {
    switch outcome {
    case .applied:
      return .green
    case .restartNeeded:
      return .orange
    case .savedForNextStart:
      return .secondary
    case .rolledBack:
      return .red
    }
  }
}
