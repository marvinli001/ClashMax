import Foundation

/// The geo databases in the core's working directory and the "update now" flow that refreshes them
/// (roadmap B5). Split out of `AppModel` (roadmap D1); `AppModel` keeps the same members as facades
/// over this store, so views and tests read them unchanged. The settings stay on `AppModel`, which
/// hands each call the directory, the applied settings, and the logging/error sinks it owns.
@MainActor
@Observable
final class GeoDatabaseStore {
  /// What the geo databases in the core's working directory look like right now. `nil` means the
  /// directory has not been stat'ed yet (roadmap B5).
  private(set) var geoDatabaseInventory: GeoDatabaseInventory?
  @ObservationIgnored private var geoDatabaseInventoryTask: Task<Void, Never>?
  private(set) var geoDatabaseUpdateInFlight = false
  private(set) var lastGeoDatabaseUpdateAt: Date?
  private(set) var lastGeoDatabaseUpdateFailure: String?
  /// What the last refresh actually did, described from the working directory rather than from the
  /// endpoint's status code.
  private(set) var geoDatabaseUpdateStatusMessage: String?
  @ObservationIgnored private var geoDatabaseUpdateTask: Task<Void, Never>?

  /// Stats the geo databases in the core's working directory (roadmap B5). Safe to call with the
  /// core down — the files outlive it, and their age is exactly what the diagnosis is about.
  func refreshGeoDatabaseInventory(at directory: URL, settings geoSettings: GeoDatabaseSettings) {
    geoDatabaseInventoryTask?.cancel()
    geoDatabaseInventoryTask = Task { @MainActor [weak self] in
      let inventory = await GeoDatabaseInventoryReader.inventory(at: directory, settings: geoSettings)
      guard !Task.isCancelled, let self else { return }
      geoDatabaseInventory = inventory
    }
  }

  /// Asks the core to re-download the geo databases (roadmap B5).
  ///
  /// `POST /configs/geo` answers 204 for "downloaded four files" and for "did nothing at all", so
  /// the status code alone cannot be reported as success. The working directory is stat'ed either
  /// side of the call and the outcome is described from what actually changed on disk: files
  /// rewritten, nothing to do because the remote is unchanged (the core sends `If-None-Match` and
  /// skips the write on a 304), or a refresh that touched nothing while a referenced database is
  /// still missing — which is the silent no-op, and is reported as one.
  ///
  /// `apiClient` is read again once the task runs, as it was on `AppModel`, so a runtime stopped in
  /// between ends the update instead of calling a controller that is gone.
  func updateGeoDatabases(
    at directory: URL,
    settings geoSettings: GeoDatabaseSettings,
    requirements: GeoRuleRequirements,
    apiClient: @escaping @MainActor () -> (any MihomoAPIControlling)?,
    appendAppLog: @escaping @MainActor (_ level: String, _ message: String) -> Void,
    reportError: @escaping @MainActor (String) -> Void
  ) {
    guard geoDatabaseUpdateTask == nil, apiClient() != nil else { return }
    geoDatabaseUpdateInFlight = true
    geoDatabaseUpdateStatusMessage = nil
    geoDatabaseUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        geoDatabaseUpdateInFlight = false
        geoDatabaseUpdateTask = nil
      }
      guard let apiClient = apiClient() else { return }
      let before = await GeoDatabaseInventoryReader.inventory(at: directory, settings: geoSettings)
      do {
        try await apiClient.updateGeoDatabases()
      } catch is CancellationError {
        return
      } catch {
        let message = UserFacingError.message(for: error)
        guard !Task.isCancelled else { return }
        lastGeoDatabaseUpdateFailure = message
        geoDatabaseUpdateStatusMessage = nil
        appendAppLog("warn", "Geo database update failed: \(message)")
        reportError("Could not update the geo databases: \(message)")
        return
      }
      let after = await GeoDatabaseInventoryReader.inventory(at: directory, settings: geoSettings)
      guard !Task.isCancelled else { return }
      geoDatabaseInventory = after
      lastGeoDatabaseUpdateAt = Date()
      lastGeoDatabaseUpdateFailure = nil
      let kinds = requirements.isKnown && requirements.referencesAny
        ? requirements.referencedKinds
        : GeoDatabaseKind.allCases
      let changed = kinds.compactMap { after.state(for: $0) }
        .filter { $0 != before.state(for: $0.kind) }
      let stillMissing = kinds.compactMap { after.state(for: $0) }.filter { !$0.exists }
      if !changed.isEmpty {
        let names = changed.map(\.fileName).joined(separator: ", ")
        geoDatabaseUpdateStatusMessage = String(
          format: String(localized: "Updated %@."),
          names
        )
        appendAppLog("info", "Geo database update rewrote \(names).")
      } else if !stillMissing.isEmpty {
        let names = stillMissing.map(\.fileName).joined(separator: ", ")
        geoDatabaseUpdateStatusMessage = String(
          format: String(localized: "The core reported no error but did not download %@. No rule in the running config asks for that database."),
          names
        )
        appendAppLog("warn", "Geo database update downloaded nothing; \(names) still absent.")
      } else {
        geoDatabaseUpdateStatusMessage = String(localized: "The geo databases were already current.")
        appendAppLog("info", "Geo database update found nothing newer to download.")
      }
    }
  }
}
