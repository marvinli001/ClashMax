import SwiftUI

struct ProfilesView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var subscriptionName = ""
  @State private var subscriptionURL = ""
  @State private var profileBeingEdited: Profile?
  @State private var editProfileName = ""
  @State private var profilePendingDeletion: Profile?

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

        if appModel.profileStore.profiles.isEmpty {
          CenteredUnavailableState(
            title: "No profiles",
            systemImage: "doc.badge.plus",
            message: "Profiles stay unchanged on disk; ClashMax generates a runtime copy when starting."
          )
        } else {
          Table(appModel.profileStore.profiles, selection: profileSelection) {
            TableColumn("Name") { profile in
              Text(profile.name)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Source") { profile in
              Text(profile.source.displayName)
                .foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 120, max: 140)

            TableColumn("Updated") { profile in
              Text(profile.updatedAt, style: .date)
                .foregroundStyle(.secondary)
            }
            .width(min: 96, ideal: 120, max: 140)

            TableColumn("Actions") { profile in
              profileActions(profile)
            }
            .width(min: 220, ideal: 248, max: 280)
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        if let message = appModel.profileOperationMessage {
          Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
            .lineLimit(2)
        }

        if let error = appModel.lastError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(3)
        }
      }
    }
    .sheet(item: $profileBeingEdited) { profile in
      ProfileEditSheet(
        profile: profile,
        name: $editProfileName,
        onCancel: closeEditSheet,
        onSave: {
          saveProfileEdits(profile)
        }
      )
    }
    .alert("Delete Profile?", isPresented: deleteConfirmationPresented) {
      Button("Delete", role: .destructive) {
        confirmDeleteProfile()
      }
      Button("Cancel", role: .cancel) {
        profilePendingDeletion = nil
      }
    } message: {
      Text("Remove \(profilePendingDeletion?.name ?? "this profile") from ClashMax. Stored subscription metadata and the app-managed profile copy will be deleted.")
    }
  }

  private var subscriptionControls: some View {
    GroupBox("Subscription") {
      VStack(alignment: .leading, spacing: 8) {
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

        if appModel.isAddingSubscription {
          subscriptionLoadingIndicator
        }
      }
      .animation(.easeInOut(duration: 0.16), value: appModel.isAddingSubscription)
    }
  }

  private var subscriptionFields: some View {
    HStack(spacing: 10) {
      TextField("Name", text: $subscriptionName)
        .frame(width: 180)
      TextField("Subscription URL", text: $subscriptionURL)
        .frame(minWidth: 260)
    }
    .disabled(appModel.isAddingSubscription)
  }

  private var addSubscriptionButton: some View {
    Button {
      let name = subscriptionName
      let urlString = subscriptionURL
      Task { @MainActor in
        let didAdd = await appModel.addSubscription(name: name, urlString: urlString)
        if didAdd {
          subscriptionName = ""
          subscriptionURL = ""
        }
      }
    } label: {
      HStack(spacing: 6) {
        if appModel.isAddingSubscription {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "plus")
        }
        Text(appModel.isAddingSubscription ? "Adding" : "Add")
      }
      .frame(minWidth: 64)
    }
    .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appModel.isAddingSubscription)
  }

  private var subscriptionLoadingIndicator: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Fetching and validating subscription...")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .transition(.opacity)
  }

  private var profileSelection: Binding<Profile.ID?> {
    Binding(
      get: { appModel.profileStore.activeProfileID },
      set: { id in
        if let id, let profile = appModel.profileStore.profiles.first(where: { $0.id == id }) {
          appModel.selectProfile(profile)
        }
      }
    )
  }

  private func profileActions(_ profile: Profile) -> some View {
    let isUpdating = appModel.updatingProfileIDs.contains(profile.id)

    return HStack(spacing: 6) {
      Button {
        beginEditing(profile)
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .help("Edit profile")

      Button {
        Task { @MainActor in
          await appModel.updateSubscription(profile)
        }
      } label: {
        HStack(spacing: 5) {
          if isUpdating {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
          Text(isUpdating ? "Updating" : "Update")
        }
      }
      .disabled(!profile.isSubscription || isUpdating)
      .help(profile.isSubscription ? "Refresh nodes from the subscription URL" : "Only subscription profiles can be updated")

      Button(role: .destructive) {
        profilePendingDeletion = profile
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .help("Delete profile")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { profilePendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          profilePendingDeletion = nil
        }
      }
    )
  }

  private func confirmDeleteProfile() {
    guard let profile = profilePendingDeletion else { return }
    profilePendingDeletion = nil
    appModel.deleteProfile(profile)
  }

  private func beginEditing(_ profile: Profile) {
    editProfileName = profile.name
    profileBeingEdited = profile
  }

  private func closeEditSheet() {
    profileBeingEdited = nil
    editProfileName = ""
  }

  private func saveProfileEdits(_ profile: Profile) {
    appModel.renameProfile(profile, to: editProfileName)
    closeEditSheet()
  }
}

private struct ProfileEditSheet: View {
  let profile: Profile
  @Binding var name: String
  let onCancel: () -> Void
  let onSave: () -> Void
  @FocusState private var isNameFocused: Bool

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Edit Profile")
          .font(.title3.weight(.semibold))
        Text(profile.name)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Form {
        TextField("Name", text: $name)
          .focused($isNameFocused)
          .onSubmit {
            if !trimmedName.isEmpty {
              onSave()
            }
          }

        LabeledContent("Source") {
          Text(profile.source.displayName)
            .foregroundStyle(.secondary)
        }
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear {
      isNameFocused = true
    }
  }
}
