import SwiftUI

struct ProfilesView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var subscriptionURL = ""
  @State private var profileBeingEdited: Profile?
  @State private var editProfileName = ""
  @State private var editSubscriptionURL = ""
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
          ScrollView {
            LazyVGrid(columns: profileGridColumns, alignment: .leading, spacing: 12) {
              ForEach(appModel.profileStore.profiles) { profile in
                ProfileCard(
                  profile: profile,
                  isActive: appModel.profileStore.activeProfileID == profile.id,
                  isUpdating: appModel.updatingProfileIDs.contains(profile.id),
                  sourceURLString: appModel.profileStore.subscriptionURLString(for: profile),
                  selectAction: { appModel.selectProfile(profile) },
                  editAction: { beginEditing(profile) },
                  updateAction: {
                    Task { @MainActor in
                      await appModel.updateSubscription(profile)
                    }
                  },
                  deleteAction: { profilePendingDeletion = profile }
                )
              }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
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
        profile: currentProfile(matching: profile) ?? profile,
        name: $editProfileName,
        subscriptionURL: $editSubscriptionURL,
        onCancel: closeEditSheet,
        onResetRemoteName: {
          resetRemoteName(profile)
        },
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
            subscriptionField
            addSubscriptionButton
          }

          VStack(alignment: .leading, spacing: 10) {
            subscriptionField
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

  private var subscriptionField: some View {
    TextField("Subscription URL", text: $subscriptionURL)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 320)
      .disabled(appModel.isAddingSubscription)
  }

  private var addSubscriptionButton: some View {
    Button {
      let urlString = subscriptionURL
      Task { @MainActor in
        let didAdd = await appModel.addSubscription(urlString: urlString)
        if didAdd {
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

  private var profileGridColumns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: 280, maximum: 360),
        spacing: 12,
        alignment: .topLeading
      )
    ]
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
    editSubscriptionURL = appModel.profileStore.subscriptionURLString(for: profile) ?? ""
    profileBeingEdited = profile
  }

  private func closeEditSheet() {
    profileBeingEdited = nil
    editProfileName = ""
    editSubscriptionURL = ""
  }

  private func currentProfile(matching profile: Profile) -> Profile? {
    appModel.profileStore.profiles.first { $0.id == profile.id }
  }

  private func saveProfileEdits(_ profile: Profile) {
    let trimmedName = editProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return }
    let trimmedURL = editSubscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let originalURL = appModel.profileStore.subscriptionURLString(for: profile)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if profile.isSubscription, trimmedURL != originalURL {
      Task { @MainActor in
        let didUpdate = await appModel.updateSubscriptionSource(profile, urlString: trimmedURL)
        if didUpdate {
          if let updated = currentProfile(matching: profile), updated.name != trimmedName {
            appModel.renameProfile(updated, to: trimmedName)
          }
          closeEditSheet()
        }
      }
      return
    }

    if let updated = currentProfile(matching: profile), updated.name != trimmedName {
      appModel.renameProfile(updated, to: trimmedName)
    }
    closeEditSheet()
  }

  private func resetRemoteName(_ profile: Profile) {
    appModel.resetSubscriptionName(profile)
    if let updated = currentProfile(matching: profile) {
      editProfileName = updated.name
    }
  }
}

private struct ProfileCard: View {
  let profile: Profile
  let isActive: Bool
  let isUpdating: Bool
  let sourceURLString: String?
  let selectAction: () -> Void
  let editAction: () -> Void
  let updateAction: () -> Void
  let deleteAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      titleBlock

      ProfileMetricsRow(profile: profile)

      Spacer(minLength: 4)

      actionButtons
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
    .dashboardCard(interactive: true)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(isActive ? Color.accentColor : Color.clear)
        .frame(width: 3)
        .padding(.vertical, 8)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: selectAction)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(profile.name)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
        if isActive {
          Text("Active")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
        }
      }

      Text(sourceLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      Button {
        editAction()
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .help("Edit profile")

      Button {
        updateAction()
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
        deleteAction()
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .help("Delete profile")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private var sourceLine: String {
    if let sourceURLString, let url = URL(string: sourceURLString), let host = url.host(percentEncoded: false) {
      return "\(host) - \(sourceURLString)"
    }
    switch profile.source {
    case let .localFile(originalPath):
      return originalPath ?? "Local YAML"
    case .subscription:
      return "Subscription URL unavailable"
    }
  }
}

private struct ProfileMetricsRow: View {
  let profile: Profile

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      metric("Source", profile.source.displayName, "externaldrive")
      metric("Usage", profile.subscriptionMetadata?.trafficSummary ?? "-", "chart.bar")
      metric("Expires", expiresLabel, "calendar")
      metric("Interval", updateIntervalLabel(profile.subscriptionMetadata?.updateIntervalMinutes), "clock.arrow.circlepath")
      metric("Updated", profile.updatedAt.formatted(date: .abbreviated, time: .omitted), "arrow.triangle.2.circlepath")
    }
  }

  private var columns: [GridItem] {
    [
      GridItem(.flexible(minimum: 92), spacing: 8, alignment: .topLeading),
      GridItem(.flexible(minimum: 92), spacing: 8, alignment: .topLeading)
    ]
  }

  private func metric(_ title: String, _ value: String, _ symbolName: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(value)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var expiresLabel: String {
    guard let expireAt = profile.subscriptionMetadata?.traffic?.expireAt else { return "-" }
    return expireAt.formatted(date: .abbreviated, time: .omitted)
  }

  private func updateIntervalLabel(_ minutes: Int?) -> String {
    guard let minutes, minutes > 0 else { return "-" }
    if minutes % 1_440 == 0 {
      return "\(minutes / 1_440)d"
    }
    if minutes % 60 == 0 {
      return "\(minutes / 60)h"
    }
    return "\(minutes)m"
  }
}

private struct ProfileEditSheet: View {
  let profile: Profile
  @Binding var name: String
  @Binding var subscriptionURL: String
  let onCancel: () -> Void
  let onResetRemoteName: () -> Void
  let onSave: () -> Void
  @FocusState private var isNameFocused: Bool

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedSubscriptionURL: String {
    subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Edit Profile")
          .font(.title3.weight(.semibold))
        Text(profile.source.displayName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Form {
        TextField("Name", text: $name)
          .focused($isNameFocused)
          .onSubmit {
            if canSave {
              onSave()
            }
          }

        if profile.isSubscription {
          TextField("Subscription URL", text: $subscriptionURL)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              if canSave {
                onSave()
              }
            }

          Button {
            onResetRemoteName()
          } label: {
            Label("Restore Remote Name", systemImage: "arrow.counterclockwise")
          }
          .disabled(!profile.nameIsUserCustomized)
        } else {
          LabeledContent("Source") {
            Text(profile.source.displayName)
              .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      isNameFocused = true
    }
  }

  private var canSave: Bool {
    !trimmedName.isEmpty && (!profile.isSubscription || !trimmedSubscriptionURL.isEmpty)
  }
}
