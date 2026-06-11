import Foundation
import Observation
import os.log

/// Observable profile library (Chunk 4.1.2): the in-memory source of truth for
/// the UI, persisting every mutation immediately through `ProfileStore`.
///
/// Responsibilities:
/// - Seeds starter profiles (the debug presets, including Flat) on first launch.
/// - Restores the last-active profile across launches.
/// - CRUD: create, rename, duplicate, delete, favorite, set-active.
/// - Guarantees the library is never empty and there is always an active profile.
///
/// Favorites: `EQProfile.isFavorite` (stored in the profile JSON) is the source
/// of truth; `ProfileStore.favoriteIDs` is reserved for favorites *ordering*
/// when the menu-bar quick switch arrives (Chunk 4.3).
///
/// Threading: main thread only (it backs SwiftUI). Applying the active profile
/// to the audio engine is the caller's job (AppModel), keeping this type free
/// of engine dependencies.
@Observable
final class ProfileManager {

    @ObservationIgnored
    private let store: ProfileStore?
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.sonarforge.app", category: "ProfileManager")

    /// Sorted by name (case-insensitive) for stable presentation.
    private(set) var profiles: [EQProfile] = []
    private(set) var activeProfileID: UUID?

    var activeProfile: EQProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var favorites: [EQProfile] {
        profiles.filter(\.isFavorite)
    }

    /// - Parameter store: nil degrades to a non-persistent in-memory library
    ///   (storage directory creation failed — rare, but the app must still run).
    init(store: ProfileStore?) {
        self.store = store
        guard let store else {
            logger.error("Profile storage unavailable — running in-memory only (changes will not persist)")
            profiles = EQProfile.debugPresets.sorted(by: Self.nameOrder)
            activeProfileID = profiles.first(where: { $0.name == "Flat" })?.id ?? profiles.first?.id
            return
        }

        store.seedIfNeeded(with: EQProfile.debugPresets)
        profiles = store.loadAll().sorted(by: Self.nameOrder)

        // The library is never empty: recreate Flat if the user removed everything
        // (e.g. deleted files by hand between launches).
        if profiles.isEmpty {
            let flat = EQProfile.newUserProfile(name: "Flat")
            persist(flat)
            profiles = [flat]
        }

        if let saved = store.activeProfileID, profiles.contains(where: { $0.id == saved }) {
            activeProfileID = saved
        } else {
            activeProfileID = profiles.first(where: { $0.name == "Flat" })?.id ?? profiles.first?.id
            store.activeProfileID = activeProfileID
        }
    }

    // MARK: - CRUD

    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        store?.activeProfileID = id
    }

    @discardableResult
    func create(name: String = "New Profile") -> EQProfile {
        let profile = EQProfile.newUserProfile(name: uniqueName(basedOn: name))
        profiles.append(profile)
        profiles.sort(by: Self.nameOrder)
        persist(profile)
        return profile
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        let updated = profiles[index]
        profiles.sort(by: Self.nameOrder)
        persist(updated)
    }

    @discardableResult
    func duplicate(_ id: UUID) -> EQProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = uniqueName(basedOn: "\(original.name) Copy")
        copy.isFavorite = false
        profiles.append(copy)
        profiles.sort(by: Self.nameOrder)
        persist(copy)
        return copy
    }

    func delete(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        do {
            try store?.delete(id: id)
        } catch {
            logger.error("Failed to delete profile file: \(error.localizedDescription, privacy: .public)")
        }

        if profiles.isEmpty {
            create(name: "Flat")
        }
        if activeProfileID == id, let fallback = profiles.first {
            setActive(fallback.id)
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFavorite.toggle()
        persist(profiles[index])
    }

    /// Replaces an existing profile's content (same id) and persists. Used by
    /// import/edit flows (4.1.3+).
    func update(_ profile: EQProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        profiles.sort(by: Self.nameOrder)
        persist(profile)
    }

    // MARK: - Helpers

    private static func nameOrder(_ a: EQProfile, _ b: EQProfile) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private func persist(_ profile: EQProfile) {
        do {
            try store?.save(profile)
        } catch {
            logger.error("Failed to save profile \(profile.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Name", "Name 2", "Name 3", … until unused.
    private func uniqueName(basedOn base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "New Profile" : trimmed
        var name = candidate
        var counter = 2
        while profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(candidate) \(counter)"
            counter += 1
        }
        return name
    }
}
