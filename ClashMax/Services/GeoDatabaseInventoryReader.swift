import Foundation

/// Stats the geo databases in the core's working directory (roadmap B5).
///
/// The core keeps them next to its cache in the `-d` directory and never reports their age over the
/// control API — `GET /configs` carries `geo-auto-update` and `geox-url` but nothing about what is
/// on disk. The file's modification time is the only signal, and it is the same one the core itself
/// uses: its startup line `[GEO] Get GEO database update time error: stat …/GeoSite.dat` is a `stat`
/// of exactly these files.
enum GeoDatabaseInventoryReader {
  /// Always returns an inventory, one entry per database, with `modifiedAt == nil` for the ones that
  /// are not there. An absent file is a real answer here — the core downloads on demand — so it is
  /// reported rather than turned into a failure.
  static func inventory(at directory: URL, settings: GeoDatabaseSettings) async -> GeoDatabaseInventory {
    let names = GeoDatabaseKind.allCases.map { (kind: $0, fileName: $0.fileName(settings: settings)) }
    return await Task.detached(priority: .utility) {
      // A private `FileManager` rather than `.default`: this runs off the main actor, and the
      // shared instance is not safe to hand across isolation domains.
      let fileManager = FileManager()
      let files = names.map { entry in
        let fileURL = directory.appendingPathComponent(entry.fileName)
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return GeoDatabaseFileState(
          kind: entry.kind,
          fileName: entry.fileName,
          modifiedAt: attributes?[.modificationDate] as? Date,
          byteCount: (attributes?[.size] as? NSNumber)?.int64Value
        )
      }
      return GeoDatabaseInventory(directoryPath: directory.path, files: files, readAt: Date())
    }.value
  }
}
