import SwiftUI

struct ProfilesView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var subscriptionName = ""
  @State private var subscriptionURL = ""
  @State private var renameText = ""

  var body: some View {
    AdaptivePage(
      title: "Profiles",
      subtitle: appModel.profileStore.profiles.isEmpty ? "Import a local YAML file or add a subscription." : "\(appModel.profileStore.profiles.count) profiles"
    ) {
      Button {
        appModel.importLocalProfile()
      } label: {
        Label("Import YAML", systemImage: "square.and.arrow.down")
      }
    } content: {
      VStack(alignment: .leading, spacing: 14) {
        subscriptionControls

        if let activeProfile = appModel.profileStore.activeProfile {
          activeProfileControls(activeProfile)
        }

        if appModel.profileStore.profiles.isEmpty {
          CenteredUnavailableState(
            title: "No profiles",
            systemImage: "doc.badge.plus",
            message: "Profiles stay unchanged on disk; ClashMax generates a runtime copy when starting."
          )
        } else {
          Table(appModel.profileStore.profiles, selection: Binding(
            get: { appModel.profileStore.activeProfileID },
            set: { id in
              if let id, let profile = appModel.profileStore.profiles.first(where: { $0.id == id }) {
                try? appModel.profileStore.select(profile)
              }
            }
          )) {
            TableColumn("Name") { profile in
              Text(profile.name)
            }
            TableColumn("Source") { profile in
              Text(sourceLabel(profile.source))
                .foregroundStyle(.secondary)
            }
            TableColumn("Updated") { profile in
              Text(profile.updatedAt, style: .date)
                .foregroundStyle(.secondary)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        if let error = appModel.lastError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(3)
        }
      }
    }
    .onAppear {
      renameText = appModel.profileStore.activeProfile?.name ?? ""
    }
    .onChange(of: appModel.profileStore.activeProfileID) { _, _ in
      renameText = appModel.profileStore.activeProfile?.name ?? ""
    }
  }

  private var subscriptionControls: some View {
    GroupBox("Subscription") {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          subscriptionFields
          addSubscriptionButton
        }

        VStack(alignment: .leading, spacing: 10) {
          subscriptionFields
          addSubscriptionButton
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var subscriptionFields: some View {
    HStack(spacing: 10) {
      TextField("Name", text: $subscriptionName)
        .frame(width: 180)
      TextField("Subscription URL", text: $subscriptionURL)
        .frame(minWidth: 260)
    }
  }

  private var addSubscriptionButton: some View {
    Button {
      appModel.addSubscription(name: subscriptionName, urlString: subscriptionURL)
      subscriptionName = ""
      subscriptionURL = ""
    } label: {
      Label("Add", systemImage: "plus")
    }
    .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func activeProfileControls(_ activeProfile: Profile) -> some View {
    GroupBox("Active Profile") {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          activeProfileFields(activeProfile)
        }

        VStack(alignment: .leading, spacing: 10) {
          activeProfileFields(activeProfile)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func activeProfileFields(_ activeProfile: Profile) -> some View {
    Group {
      TextField("Profile Name", text: $renameText)
        .frame(width: 220)
      Button {
        appModel.renameActiveProfile(to: renameText)
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      Button {
        appModel.updateActiveSubscription()
      } label: {
        Label("Update", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!activeProfile.isSubscription)

      Button(role: .destructive) {
        appModel.deleteActiveProfile()
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  private func sourceLabel(_ source: ProfileSource) -> String {
    switch source {
    case .localFile: "Local YAML"
    case .subscription: "Subscription"
    }
  }
}

private extension Profile {
  var isSubscription: Bool {
    if case .subscription = source { return true }
    return false
  }
}
