import Foundation
import os.log

/// On-disk persistence for EQ profiles (Chunk 4.1.1).
///
/// Format: one pretty-printed JSON file per profile in
/// `Application Support/SonarForge/Profiles/<uuid>.json`. The file *is* the
/// export format — sharing a profile is copying its file. Writes are atomic
/// (temp file + rename via `.atomic`), so a crash mid-save can never corrupt
/// an existing profile.
///
/// The active profile ID and the favorites order live in UserDefaults: they
/// are app state, not profile content, and keeping them out of the JSON keeps
/// exported files clean.
///
/// Threading: all methods are synchronous file I/O — call from the main thread
/// (profiles are a few KB; loads are one-time) or a background queue, but not
/// concurrently from multiple threads. The observable manager layer (4.1.2)
/// owns serialization of access.
final class ProfileStore {

    private let logger = Logger(subsystem: "com.sonarforge.app", category: "ProfileStore")

    let directory: URL
    private let defaults: UserDefaults

    private static let activeProfileKey = "activeProfileID"
    private static let favoritesKey = "favoriteProfileIDs"
    private static let seededKey = "profileStoreSeeded"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - directory: storage directory; defaults to Application Support/SonarForge/Profiles.
    ///     Created (with intermediates) if missing.
    ///   - defaults: UserDefaults backing for active/favorites state (injectable for tests).
    init(directory: URL? = nil, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        if let directory {
            self.directory = directory
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            self.directory = appSupport
                .appendingPathComponent("SonarForge", isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Profiles on disk

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Loads every readable profile. Corrupt or non-profile files are skipped
    /// (logged), never fatal — one bad file must not take down the library.
    func loadAll() -> [EQProfile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        var profiles: [EQProfile] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                profiles.append(try decoder.decode(EQProfile.self, from: data))
            } catch {
                logger.warning("Skipping unreadable profile file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return profiles
    }

    /// Atomically writes (creates or overwrites) a profile.
    func save(_ profile: EQProfile) throws {
        let data = try encoder.encode(profile)
        try data.write(to: fileURL(for: profile.id), options: .atomic)
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Seeds starter profiles exactly once (first launch). Returns true if seeding ran.
    @discardableResult
    func seedIfNeeded(with starters: [EQProfile]) -> Bool {
        guard !defaults.bool(forKey: Self.seededKey) else { return false }
        for profile in starters {
            do {
                try save(profile)
            } catch {
                logger.error("Failed to seed profile \(profile.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        defaults.set(true, forKey: Self.seededKey)
        logger.info("Seeded \(starters.count) starter profiles")
        return true
    }

    // MARK: - App state (UserDefaults)

    var activeProfileID: UUID? {
        get { defaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.activeProfileKey) }
    }

    /// Ordered favorites. Unknown IDs are tolerated (profile may have been
    /// deleted on another machine / by hand) and cleaned up by the manager.
    var favoriteIDs: [UUID] {
        get {
            (defaults.stringArray(forKey: Self.favoritesKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        }
        set { defaults.set(newValue.map(\.uuidString), forKey: Self.favoritesKey) }
    }
}
