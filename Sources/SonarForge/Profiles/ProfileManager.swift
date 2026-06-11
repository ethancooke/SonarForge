import Foundation
import Observation
import os.log

/// Observable profile library (Chunk 4.1.2): the in-memory source of truth for
/// the UI, persisting every mutation immediately through `ProfileStore`.
///
/// Responsibilities:
/// - Syncs the built-in factory preset catalog on every launch.
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

    /// Favorites in the user's order (the order they were favorited, persisted
    /// in UserDefaults via the store). Profiles flagged favorite but missing
    /// from the order list (edited externally) are appended defensively.
    var orderedFavorites: [EQProfile] {
        let ordered = favoriteOrder.compactMap { id in profiles.first(where: { $0.id == id && $0.isFavorite }) }
        let stragglers = profiles.filter { $0.isFavorite && !favoriteOrder.contains($0.id) }
        return ordered + stragglers
    }

    /// The quick-switch list used by the menu bar and the ⌘1–9 Profiles menu:
    /// ordered favorites first, then the rest by name. Index = shortcut number.
    var quickSwitchProfiles: [EQProfile] {
        orderedFavorites + profiles.filter { !$0.isFavorite }
    }

    /// In-memory mirror of the persisted favorites order.
    private var favoriteOrder: [UUID] = []

    /// - Parameter store: nil degrades to a non-persistent in-memory library
    ///   (storage directory creation failed — rare, but the app must still run).
    init(store: ProfileStore?) {
        self.store = store
        guard let store else {
            logger.error("Profile storage unavailable — running in-memory only (changes will not persist)")
            profiles = EQProfile.factoryPresets.sorted(by: Self.nameOrder)
            activeProfileID = profiles.first(where: { $0.id == FactoryPresetID.flat })?.id ?? profiles.first?.id
            return
        }

        store.syncFactoryPresets(EQProfile.factoryPresets, obsoleteNames: EQProfile.obsoleteFactoryNames)
        profiles = store.loadAll().sorted(by: Self.nameOrder)

        // The library is never empty: restore the factory Flat if everything was removed.
        if profiles.isEmpty, let flat = EQProfile.canonicalFactory(id: FactoryPresetID.flat) {
            persist(flat)
            profiles = [flat]
        }

        if let saved = store.activeProfileID, profiles.contains(where: { $0.id == saved }) {
            activeProfileID = saved
        } else {
            activeProfileID = profiles.first(where: { $0.id == FactoryPresetID.flat })?.id ?? profiles.first?.id
            store.activeProfileID = activeProfileID
        }

        // Reconcile the persisted favorites order with reality: drop stale IDs,
        // append any favorite-flagged profiles missing from the list.
        var order = store.favoriteIDs.filter { id in profiles.contains(where: { $0.id == id && $0.isFavorite }) }
        for profile in profiles where profile.isFavorite && !order.contains(profile.id) {
            order.append(profile.id)
        }
        favoriteOrder = order
        store.favoriteIDs = order
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
        guard !isFactory(id) else { return }
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
        copy.isFactory = false
        profiles.append(copy)
        profiles.sort(by: Self.nameOrder)
        persist(copy)
        return copy
    }

    func delete(_ id: UUID) {
        guard !isFactory(id), let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        favoriteOrder.removeAll { $0 == id }
        store?.favoriteIDs = favoriteOrder
        do {
            try store?.delete(id: id)
        } catch {
            logger.error("Failed to delete profile file: \(error.localizedDescription, privacy: .public)")
        }

        if profiles.isEmpty, let flat = EQProfile.canonicalFactory(id: FactoryPresetID.flat) {
            persist(flat)
            profiles = [flat]
        }
        if activeProfileID == id, let fallback = profiles.first {
            setActive(fallback.id)
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFavorite.toggle()
        if profiles[index].isFavorite {
            favoriteOrder.append(id)
        } else {
            favoriteOrder.removeAll { $0 == id }
        }
        store?.favoriteIDs = favoriteOrder
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

    // MARK: - Import / Export (4.1.3)

    /// Adds an externally sourced profile under a fresh identity: new UUID (so
    /// importing the same file twice duplicates rather than colliding with an
    /// existing profile) and a deduplicated name. Attribution and content are
    /// preserved verbatim.
    @discardableResult
    func importProfile(_ incoming: EQProfile) -> EQProfile {
        var profile = incoming
        profile.id = UUID()
        profile.name = uniqueName(basedOn: incoming.name)
        profile.isFactory = false
        profiles.append(profile)
        profiles.sort(by: Self.nameOrder)
        persist(profile)
        return profile
    }

    /// Pretty-printed JSON for a profile — the same format the store writes,
    /// so an exported file can be dropped straight into another library.
    func exportData(for id: UUID) throws -> Data {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    static func decodeProfile(from data: Data) throws -> EQProfile {
        try JSONDecoder().decode(EQProfile.self, from: data)
    }

    // MARK: - Factory presets

    func isFactory(_ id: UUID) -> Bool {
        profiles.first(where: { $0.id == id })?.isFactory ?? false
    }

    func isFactoryModified(_ id: UUID) -> Bool {
        profiles.first(where: { $0.id == id })?.differsFromFactoryDefault() ?? false
    }

    @discardableResult
    func resetFactoryPreset(_ id: UUID) -> EQProfile? {
        guard let canonical = EQProfile.canonicalFactory(id: id),
              let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var restored = canonical
        restored.isFavorite = profiles[index].isFavorite
        profiles[index] = restored
        persist(restored)
        return restored
    }

    func resetAllFactoryPresets() {
        for factory in EQProfile.factoryPresets {
            resetFactoryPreset(factory.id)
        }
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
