import Foundation
import SwiftData

/// Opens the library store through the migration plan (SPEC D-10, DECISIONS ADR-014).
///
/// Before a schema upgrade it copies the store files to `Backups/<timestamp>/`. If the
/// store cannot be opened at all, it moves the files to a backup, starts an empty library
/// and reports the backup so the app can tell the user once.
enum StoreLoader {
    struct Result {
        let container: ModelContainer
        /// Set when the library could not be opened and a fresh one was created.
        let recoveredFromFailure: URL?
    }

    static let currentVersion = "\(SchemaV2.versionIdentifier)"
    static let versionKey = "store.schemaVersion"

    /// Where SwiftData keeps the default store; the same file as before Phase 2.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    static func makeContainer(storeURL: URL?, defaults: UserDefaults, keepBackups: Int = 3) throws -> Result {
        let schema = Schema(versionedSchema: SchemaV2.self)
        guard let storeURL else {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, migrationPlan: AIQuizMigrationPlan.self, configurations: config)
            return Result(container: container, recoveredFromFailure: nil)
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: storeURL.path), defaults.string(forKey: versionKey) != currentVersion {
            if let backup = try? backUp(storeURL, reason: "before-v\(currentVersion)") {
                Log.data.info("Backed up the library before the schema upgrade: \(backup.lastPathComponent)")
            }
            pruneBackups(near: storeURL, keep: keepBackups)
        }

        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            let container = try ModelContainer(for: schema, migrationPlan: AIQuizMigrationPlan.self, configurations: config)
            defaults.set(currentVersion, forKey: versionKey)
            return Result(container: container, recoveredFromFailure: nil)
        } catch {
            Log.data.error("Library could not be opened: \(String(describing: error))")
            let backup = try backUp(storeURL, reason: "unreadable", move: true)
            let container = try ModelContainer(for: schema, migrationPlan: AIQuizMigrationPlan.self, configurations: config)
            defaults.set(currentVersion, forKey: versionKey)
            return Result(container: container, recoveredFromFailure: backup)
        }
    }

    /// The store and its `-wal` / `-shm` companions plus SwiftData's external-storage folder.
    static func storeFiles(_ storeURL: URL) -> [URL] {
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let support = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
        return [name, name + "-wal", name + "-shm", support].map { dir.appending(path: $0) }
    }

    /// Copies (or moves) the store files into `Backups/<timestamp>-<reason>/`.
    @discardableResult
    static func backUp(_ storeURL: URL, reason: String, move: Bool = false) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate, .withTime]).replacingOccurrences(of: ":", with: "")
        let folder = backupsFolder(near: storeURL).appending(path: "\(stamp)-\(reason)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in storeFiles(storeURL) where fm.fileExists(atPath: file.path) {
            let target = folder.appending(path: file.lastPathComponent)
            if move {
                try fm.moveItem(at: file, to: target)
            } else {
                try fm.copyItem(at: file, to: target)
            }
        }
        return folder
    }

    static func backupsFolder(near storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "Backups")
    }

    /// Keeps the newest `keep` upgrade backups. Backups of unreadable stores are never pruned.
    static func pruneBackups(near storeURL: URL, keep: Int) {
        let fm = FileManager.default
        let folder = backupsFolder(near: storeURL)
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let upgrades = items.filter { $0.contains("-before-") }.sorted()
        for old in upgrades.dropLast(keep) {
            try? fm.removeItem(at: folder.appending(path: old))
        }
    }
}
