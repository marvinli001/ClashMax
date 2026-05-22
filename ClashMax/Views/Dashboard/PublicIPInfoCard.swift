import SwiftUI

struct PublicIPInfoCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var publicIP: PublicIPCoordinator
  let availableWidth: CGFloat
  @State private var showsFullIP = false

  var body: some View {
    TimelineView(.periodic(from: Date(), by: 5)) { context in
      content(now: context.date)
        .task(id: refreshTickID(for: context.date)) {
          appModel.refreshPublicIPInfo(now: context.date)
        }
    }
    .task {
      appModel.refreshPublicIPInfo()
    }
  }

  private func content(now: Date) -> some View {
    let state = publicIP.state

    return VStack(alignment: .leading, spacing: cardVerticalSpacing) {
      HStack(spacing: 10) {
        DashboardSectionHeader(
          title: "Public IP",
          symbolName: "globe",
          trailing: isCompact ? nil : state.info.map { "Updated \($0.fetchedAt.formatted(date: .omitted, time: .standard))" }
        )

        if state.isLoading {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          appModel.refreshPublicIPInfo(force: true, now: now)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(state.isLoading)
        .help("Refresh public IP")
      }

      if let info = state.info {
        infoBody(info)
      } else if state.isLoading {
        publicIPSkeletonBody
      } else {
        placeholderBody(
          title: "Public IP unavailable",
          symbolName: "network.slash",
          message: state.errorMessage ?? "Refresh after the runtime is ready."
        )
      }

      if let message = state.errorMessage {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(isCompact ? 3 : 2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: isCompact ? 190 : 210, alignment: .topLeading)
    .dashboardCard(interactive: true)
  }

  private func infoBody(_ info: PublicIPInfo) -> some View {
    VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
      if shouldStackIdentity {
        VStack(alignment: .leading, spacing: 10) {
          regionIdentity(for: info)
          ipAddressPill(for: info)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(spacing: 12) {
          regionIdentity(for: info)
          Spacer(minLength: 8)
          ipAddressPill(for: info)
        }
      }

      LazyVGrid(columns: detailColumns, alignment: .leading, spacing: isCompact ? 6 : 8) {
        PublicIPInfoDetail(title: "ASN / ISP", value: asnISPSummary(for: info))
        PublicIPInfoDetail(title: "Organization", value: info.organization ?? "--")
        PublicIPInfoDetail(title: "Location", value: locationSummary(for: info))
        PublicIPInfoDetail(title: "Timezone", value: info.timezone ?? "--")
        PublicIPInfoDetail(title: "Coordinates", value: coordinateSummary(for: info))
        PublicIPInfoDetail(title: "Source", value: info.sourceName)
      }
    }
  }

  private var publicIPSkeletonBody: some View {
    VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
      if shouldStackIdentity {
        VStack(alignment: .leading, spacing: 10) {
          ClashMaxCurrentNodeSkeleton(isCompact: isCompact)
        }
      } else {
        HStack(spacing: 12) {
          ClashMaxCurrentNodeSkeleton(isCompact: isCompact)
          Spacer(minLength: 8)
          ClashMaxSkeletonBar(width: 128, height: 32, cornerRadius: 8)
        }
      }

      LazyVGrid(columns: detailColumns, alignment: .leading, spacing: isCompact ? 6 : 8) {
        ForEach(0..<6, id: \.self) { index in
          VStack(alignment: .leading, spacing: 5) {
            ClashMaxSkeletonBar(width: 62, height: 8)
            ClashMaxSkeletonBar(width: index.isMultiple(of: 2) ? 128 : 96, height: 11)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: isCompact ? 98 : 128, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  private func regionIdentity(for info: PublicIPInfo) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "location.circle.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.cyan)
        .frame(width: 42, height: 42)
        .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(countryTitle(for: info))
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.68)
        Text(info.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func ipAddressPill(for info: PublicIPInfo) -> some View {
    HStack(spacing: 6) {
      Text(showsFullIP ? info.ipAddress : maskedIP(info.ipAddress))
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.64)

      Button {
        showsFullIP.toggle()
      } label: {
        Image(systemName: showsFullIP ? "eye.slash" : "eye")
      }
      .buttonStyle(.borderless)
      .help(showsFullIP ? "Hide IP address" : "Show IP address")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func placeholderBody(title: String, symbolName: String, message: String? = nil) -> some View {
    VStack(spacing: isCompact ? 8 : 10) {
      Image(systemName: symbolName)
        .font(.system(size: isCompact ? 22 : 24, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(Color.secondary.opacity(0.86))
          .multilineTextAlignment(.center)
          .lineLimit(isCompact ? 3 : 2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: isCompact ? 98 : 128)
    .frame(maxHeight: .infinity, alignment: .center)
  }

  private var detailColumns: [GridItem] {
    if availableWidth < 340 {
      return [GridItem(.flexible(minimum: 120), spacing: 8)]
    }

    let minimum: CGFloat = isCompact ? 118 : 150
    return [
      GridItem(.flexible(minimum: minimum), spacing: 10),
      GridItem(.flexible(minimum: minimum), spacing: 10)
    ]
  }

  private var isCompact: Bool {
    availableWidth < 460
  }

  private var shouldStackIdentity: Bool {
    availableWidth < 360
  }

  private var cardVerticalSpacing: CGFloat {
    isCompact ? 10 : 12
  }

  private func refreshTickID(for date: Date) -> Int {
    Int(date.timeIntervalSince1970 / 5)
  }

  private func countryTitle(for info: PublicIPInfo) -> String {
    let country = info.countryName ?? info.countryCode
    return country ?? "Unknown Region"
  }

  private func asnISPSummary(for info: PublicIPInfo) -> String {
    [info.asn, info.isp]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
      .nonEmpty ?? "--"
  }

  private func locationSummary(for info: PublicIPInfo) -> String {
    [info.city, info.region]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
      .nonEmpty ?? "--"
  }

  private func coordinateSummary(for info: PublicIPInfo) -> String {
    guard let latitude = info.latitude, let longitude = info.longitude else {
      return "--"
    }
    return String(format: "%.2f, %.2f", latitude, longitude)
  }

  private func maskedIP(_ ip: String) -> String {
    let parts = ip.split(separator: ".")
    if parts.count == 4, let first = parts.first, let last = parts.last {
      return "\(first).xxx.xxx.\(last)"
    }

    guard ip.count > 10 else { return "xxxx" }
    return "\(ip.prefix(6))...\(ip.suffix(4))"
  }
}

private struct PublicIPInfoDetail: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.68)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
