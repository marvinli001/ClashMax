import SwiftUI

/// What a profile tried to change, what ClashMax overrode, and what it let through (roadmap C1) —
/// and the one question ClashMax will not answer on the user's behalf: whether to start listeners
/// the subscription opens to the network (roadmap C3).
struct SubscriptionAuditSheet: View {
  let profileID: Profile.ID

  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss
  @State private var listenerChangeInFlight = false
  @State private var confirmsAllowingOpenProxy = false

  private var profile: Profile? {
    profileStore.profiles.first { $0.id == profileID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let profile, let report = profile.subscriptionDiagnostics.latestAudit {
        header(profile: profile, report: report)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            content(profile: profile, report: report)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ContentUnavailableView(
          "No Audit Report",
          systemImage: "shield",
          description: Text("This profile has not been audited yet.")
        )
      }
      Divider()
      HStack {
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 560, height: 600)
    .onDisappear {
      appModel.acknowledgeAuditReport(for: profileID)
    }
  }

  private func header(profile: Profile, report: SubscriptionAuditReport) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(String(format: String(localized: "Audit: %@"), profile.name))
        .font(.headline)
      Text(verbatim: "\(triggerText(report.trigger)) · \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func content(profile: Profile, report: SubscriptionAuditReport) -> some View {
    if let failure = report.generationFailure {
      Label(
        String(format: String(localized: "ClashMax could not generate a config from this profile, so what it would override is unknown: %@"), failure),
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    }

    if report.isNodeListOnly {
      Label(
        "This subscription supplies a node list only. ClashMax writes every other setting itself, so nothing in it can change how the core runs.",
        systemImage: "checkmark.shield"
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else if report.isClean {
      Label(
        "Nothing security-sensitive: the profile does not touch the control API, inbound ports, LAN access, TUN, DNS, the sniffer, listeners or authentication.",
        systemImage: "checkmark.shield"
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      if !report.exposedListeners.isEmpty, profile.isSubscription {
        listenerDecision(profile: profile, report: report)
      }
      attemptedSection(report)
      itemSection(
        title: "What ClashMax overrode",
        emptyText: "Nothing: every setting above runs as the profile wrote it.",
        items: report.overridden
      )
      itemSection(
        title: "What it let through",
        emptyText: "Nothing: ClashMax replaced every setting above.",
        items: report.passedThrough
      )
    }
  }

  /// Roadmap C3. Listeners another device can reach are kept off until this is answered.
  private func listenerDecision(profile: Profile, report: SubscriptionAuditReport) -> some View {
    let policy = profile.subscriptionProviderOptions.exposedListenerPolicy
    return VStack(alignment: .leading, spacing: 8) {
      Label {
        Group {
          if policy == .allowExposed {
            Text("This subscription's listeners are running, and other devices on your network can reach them:")
          } else {
            Text("This subscription wants to open listeners that other devices on your network can reach. They stay off unless you allow them:")
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "network.badge.shield.half.filled")
          .foregroundStyle(.orange)
      }
      .font(.callout.weight(.semibold))

      ForEach(report.exposedListeners) { listener in
        Text(verbatim: "• \(listener.name): \(listener.endpoint)")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }

      if let consequence = report.items.first(where: { $0.key.lowercased() == "listeners" })?.consequence {
        Text(consequence)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        if listenerChangeInFlight {
          ProgressView().controlSize(.small)
        }
        if policy == .allowExposed {
          Button("Turn Off") {
            setListenerPolicy(.blockExposed)
          }
        } else {
          if policy == nil {
            Button("Keep Off") {
              setListenerPolicy(.blockExposed)
            }
          }
          Button("Allow…") {
            confirmsAllowingOpenProxy = true
          }
        }
      }
      .disabled(listenerChangeInFlight)
    }
    .padding(12)
    .background(Color.orange.opacity(0.10), in: SurfaceRadius.shape(SurfaceRadius.tile))
    .confirmationDialog(
      "Allow listeners other devices can reach?",
      isPresented: $confirmsAllowingOpenProxy
    ) {
      Button("Allow") {
        setListenerPolicy(.allowExposed)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(report.items.first(where: { $0.key.lowercased() == "listeners" })?.consequence ?? "")
    }
  }

  private func attemptedSection(_ report: SubscriptionAuditReport) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("What it tried to change")
        .font(.subheadline.weight(.semibold))
      Text(String(
        format: String(localized: "%lld settings: %lld overridden by ClashMax, %lld let through."),
        Int64(report.items.count),
        Int64(report.overridden.count),
        Int64(report.passedThrough.count)
      ))
      .font(.caption)
      .foregroundStyle(.secondary)
      ForEach(report.items) { item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          SeverityBadge(severity: item.severity)
          Text(item.key)
            .font(.system(.callout, design: .monospaced))
          Text(item.attempted)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func itemSection(title: LocalizedStringKey, emptyText: LocalizedStringKey, items: [SubscriptionAuditReport.Item]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      if items.isEmpty {
        Text(emptyText)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              SeverityBadge(severity: item.severity)
              Text(item.key)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            }
            Text(item.outcome)
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
            if let consequence = item.consequence {
              Text(consequence)
                .font(.caption)
                .foregroundStyle(item.severity == .danger ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
  }

  private func triggerText(_ trigger: SubscriptionAuditReport.Trigger) -> String {
    switch trigger {
    case .imported: String(localized: "Imported")
    case .updated: String(localized: "Updated")
    case .automaticUpdate: String(localized: "Updated automatically")
    case .onDemand: String(localized: "Checked")
    }
  }

  private func setListenerPolicy(_ policy: InheritedListenerPolicy) {
    listenerChangeInFlight = true
    Task { @MainActor in
      await appModel.setInheritedListenerPolicy(policy, for: profileID)
      listenerChangeInFlight = false
    }
  }
}

private struct SeverityBadge: View {
  let severity: ProviderOptionsRisk.Severity

  var body: some View {
    Text(severity.displayName)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .foregroundStyle(tint)
      .background(tint.opacity(0.15), in: Capsule())
  }

  private var tint: Color {
    switch severity {
    case .danger: .red
    case .warning: .orange
    case .info: .secondary
    }
  }
}
