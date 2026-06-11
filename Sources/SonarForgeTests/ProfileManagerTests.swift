import XCTest
@testable import SonarForge

@MainActor
final class ProfileManagerTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileManagerTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "ProfileManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() throws -> ProfileStore {
        try ProfileStore(directory: tempDirectory, defaults: defaults)
    }

    private func makeManager() throws -> ProfileManager {
        ProfileManager(store: try makeStore())
    }

    // MARK: - Seeding & restore

    func testFirstLaunchSeedsPresetsAndActivatesFlat() throws {
        let manager = try makeManager()
        XCTAssertEqual(manager.profiles.count, EQProfile.factoryPresets.count)
        XCTAssertEqual(manager.activeProfile?.name, "Flat")
        XCTAssertTrue(manager.profiles.contains(where: { $0.name == "Telephone" }))
    }

    func testActiveProfileSurvivesRelaunch() throws {
        let first = try makeManager()
        let bass = try XCTUnwrap(first.profiles.first(where: { $0.name == "Bass Boost" }))
        first.setActive(bass.id)

        // New manager over the same store — simulates app relaunch.
        let second = try makeManager()
        XCTAssertEqual(second.activeProfile?.id, bass.id)
        XCTAssertEqual(second.activeProfile?.name, "Bass Boost")
    }

    func testEmptiedLibraryRecreatesFlatOnLaunch() throws {
        let first = try makeManager()
        let store = try makeStore()
        for profile in first.profiles {
            try store.delete(id: profile.id)
        }

        let second = try makeManager()
        XCTAssertEqual(second.profiles.count, EQProfile.factoryPresets.count)
        XCTAssertTrue(second.profiles.contains(where: { $0.id == FactoryPresetID.flat }))
        XCTAssertEqual(second.activeProfileID, FactoryPresetID.flat)
    }

    func testInMemoryFallbackStillWorks() {
        let manager = ProfileManager(store: nil)
        XCTAssertFalse(manager.profiles.isEmpty)
        XCTAssertNotNil(manager.activeProfile)
        manager.create(name: "Ephemeral")
        XCTAssertTrue(manager.profiles.contains(where: { $0.name == "Ephemeral" }))
    }

    // MARK: - CRUD

    func testCreatePersistsAndDeduplicatesNames() throws {
        let manager = try makeManager()
        let a = manager.create(name: "My Cans")
        let b = manager.create(name: "My Cans")
        XCTAssertEqual(a.name, "My Cans")
        XCTAssertEqual(b.name, "My Cans 2")

        let relaunched = try makeManager()
        XCTAssertTrue(relaunched.profiles.contains(where: { $0.id == a.id }))
        XCTAssertTrue(relaunched.profiles.contains(where: { $0.id == b.id }))
    }

    func testRenamePersistsAndIgnoresEmpty() throws {
        let manager = try makeManager()
        let profile = manager.create(name: "Before")
        manager.rename(profile.id, to: "  After  ")
        XCTAssertEqual(manager.profiles.first(where: { $0.id == profile.id })?.name, "After")

        manager.rename(profile.id, to: "   ")
        XCTAssertEqual(manager.profiles.first(where: { $0.id == profile.id })?.name, "After", "empty rename ignored")

        let relaunched = try makeManager()
        XCTAssertEqual(relaunched.profiles.first(where: { $0.id == profile.id })?.name, "After")
    }

    func testDuplicateCopiesContentWithNewIdentity() throws {
        let manager = try makeManager()
        let bass = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Bass Boost" }))
        let copy = try XCTUnwrap(manager.duplicate(bass.id))

        XCTAssertNotEqual(copy.id, bass.id)
        XCTAssertEqual(copy.name, "Bass Boost Copy")
        XCTAssertEqual(copy.bands, bass.bands)
        XCTAssertEqual(copy.preamp, bass.preamp)
        XCTAssertFalse(copy.isFavorite)
        XCTAssertFalse(copy.isFactory)
    }

    func testDeleteActiveFallsBackAndPersists() throws {
        let manager = try makeManager()
        let user = manager.create(name: "Disposable")
        manager.setActive(user.id)
        manager.delete(user.id)

        XCTAssertFalse(manager.profiles.contains(where: { $0.id == user.id }))
        XCTAssertNotNil(manager.activeProfile, "deleting the active profile must fall back")

        let relaunched = try makeManager()
        XCTAssertEqual(relaunched.activeProfileID, manager.activeProfileID)
    }

    func testFactoryPresetsSurviveDeleteAllAttempts() throws {
        let manager = try makeManager()
        for profile in manager.profiles {
            manager.delete(profile.id)
        }
        XCTAssertEqual(manager.profiles.count, EQProfile.factoryPresets.count)
        XCTAssertTrue(manager.profiles.contains(where: { $0.id == FactoryPresetID.flat }))
        XCTAssertEqual(manager.activeProfileID, FactoryPresetID.flat)
    }

    func testToggleFavoritePersists() throws {
        let manager = try makeManager()
        let profile = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Telephone" }))
        manager.toggleFavorite(profile.id)
        XCTAssertTrue(manager.favorites.contains(where: { $0.id == profile.id }))

        let relaunched = try makeManager()
        XCTAssertTrue(relaunched.favorites.contains(where: { $0.id == profile.id }))
    }

    func testUpdateReplacesContent() throws {
        let manager = try makeManager()
        var profile = manager.create(name: "Editable")
        profile.preamp = -3.5
        profile.bands = [EQBand(type: .peaking, frequency: 2000, gain: 4, q: 2)]
        manager.update(profile)

        let relaunched = try makeManager()
        let loaded = try XCTUnwrap(relaunched.profiles.first(where: { $0.id == profile.id }))
        XCTAssertEqual(loaded.preamp, -3.5)
        XCTAssertEqual(loaded.bands.count, 1)
    }

    // MARK: - Favorites ordering & quick switch (4.3)

    func testFavoritesKeepTheOrderTheyWereFavorited() throws {
        let manager = try makeManager()
        let telephone = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Telephone" }))
        let bass = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Bass Boost" }))

        manager.toggleFavorite(telephone.id)
        manager.toggleFavorite(bass.id)
        XCTAssertEqual(manager.orderedFavorites.map(\.name), ["Telephone", "Bass Boost"],
                       "favoriting order, not name order")

        let relaunched = try makeManager()
        XCTAssertEqual(relaunched.orderedFavorites.map(\.name), ["Telephone", "Bass Boost"],
                       "order persists across relaunch")
    }

    func testUnfavoriteAndDeleteRemoveFromOrder() throws {
        let manager = try makeManager()
        let telephone = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Telephone" }))
        let bass = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Bass Boost" }))
        manager.toggleFavorite(telephone.id)
        manager.toggleFavorite(bass.id)

        manager.toggleFavorite(telephone.id)   // unfavorite
        XCTAssertEqual(manager.orderedFavorites.map(\.name), ["Bass Boost"])

        let disposable = manager.create(name: "Disposable Favorite")
        manager.toggleFavorite(disposable.id)
        manager.delete(disposable.id)
        XCTAssertEqual(manager.orderedFavorites.map(\.name), ["Bass Boost"])
    }

    func testQuickSwitchListsFavoritesFirstThenRestByName() throws {
        let manager = try makeManager()
        let midScoop = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Mid Scoop" }))
        manager.toggleFavorite(midScoop.id)

        let quick = manager.quickSwitchProfiles
        XCTAssertEqual(quick.first?.name, "Mid Scoop")
        let rest = quick.dropFirst().map(\.name)
        XCTAssertEqual(Array(rest), rest.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertEqual(quick.count, manager.profiles.count, "every profile appears exactly once")
    }

    // MARK: - Import / Export

    func testExportImportRoundTripPreservesContentWithNewIdentity() throws {
        let manager = try makeManager()
        let bass = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Bass Boost" }))

        let data = try manager.exportData(for: bass.id)
        let decoded = try ProfileManager.decodeProfile(from: data)
        let imported = manager.importProfile(decoded)

        XCTAssertNotEqual(imported.id, bass.id, "import must mint a new identity")
        XCTAssertEqual(imported.name, "Bass Boost 2", "name deduplicated against the original")
        XCTAssertEqual(imported.bands, bass.bands)
        XCTAssertEqual(imported.preamp, bass.preamp)
        XCTAssertEqual(imported.sourceAttribution, bass.sourceAttribution, "attribution preserved verbatim")

        let relaunched = try makeManager()
        XCTAssertTrue(relaunched.profiles.contains(where: { $0.id == imported.id }), "import persists")
    }

    func testImportSameDataTwiceCreatesTwoCopies() throws {
        let manager = try makeManager()
        let flat = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Flat" }))
        let data = try manager.exportData(for: flat.id)

        let first = manager.importProfile(try ProfileManager.decodeProfile(from: data))
        let second = manager.importProfile(try ProfileManager.decodeProfile(from: data))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.name, second.name)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try ProfileManager.decodeProfile(from: Data("not json".utf8)))
    }

    func testExportUnknownProfileThrows() throws {
        let manager = try makeManager()
        XCTAssertThrowsError(try manager.exportData(for: UUID()))
    }

    func testProfilesSortedByName() throws {
        let manager = try makeManager()
        manager.create(name: "zzz Last")
        manager.create(name: "AAA First")
        let names = manager.profiles.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    // MARK: - Factory presets

    func testFactoryCatalogHasTenIndustryPresets() throws {
        XCTAssertEqual(EQProfile.factoryPresets.count, 10)
        XCTAssertTrue(EQProfile.factoryPresets.allSatisfy(\.isFactory))
        XCTAssertTrue(EQProfile.factoryPresets.allSatisfy { $0.preamp == 0 })
    }

    func testFilterShowcaseDemonstratesAllFilterTypes() throws {
        let showcase = try XCTUnwrap(EQProfile.canonicalFactory(id: FactoryPresetID.filterShowcase))
        XCTAssertEqual(showcase.bands.count, 10)
        let types = Set(showcase.bands.map(\.type))
        XCTAssertEqual(types, Set(FilterType.allCases))
    }

    func testFactoryPresetCannotBeDeletedOrRenamed() throws {
        let manager = try makeManager()
        let bass = try XCTUnwrap(manager.profiles.first(where: { $0.id == FactoryPresetID.bassBoost }))
        let countBefore = manager.profiles.count

        manager.delete(bass.id)
        XCTAssertEqual(manager.profiles.count, countBefore)

        manager.rename(bass.id, to: "Renamed Bass")
        XCTAssertEqual(manager.profiles.first(where: { $0.id == bass.id })?.name, "Bass Boost")
    }

    func testResetFactoryPresetRestoresCanonicalBands() throws {
        let manager = try makeManager()
        var bass = try XCTUnwrap(manager.profiles.first(where: { $0.id == FactoryPresetID.bassBoost }))
        bass.bands[0].gain = 12
        bass.preamp = -3
        manager.update(bass)
        XCTAssertTrue(manager.isFactoryModified(FactoryPresetID.bassBoost))

        let restored = try XCTUnwrap(manager.resetFactoryPreset(FactoryPresetID.bassBoost))
        XCTAssertEqual(restored.bands[0].gain, 5)
        XCTAssertEqual(restored.preamp, 0)
        XCTAssertFalse(manager.isFactoryModified(FactoryPresetID.bassBoost))
    }

    func testDuplicateFactoryCreatesEditableUserCopy() throws {
        let manager = try makeManager()
        let copy = try XCTUnwrap(manager.duplicate(FactoryPresetID.rock))
        XCTAssertFalse(copy.isFactory)
        XCTAssertTrue(copy.name.contains("Rock"))
        manager.delete(copy.id)
    }

    /// Regression: the canonical factory presets mint fresh band UUIDs each
    /// process launch. A loaded (on-disk) factory preset therefore has different
    /// band ids than the in-memory canon — it must still read as unmodified.
    func testFactoryPresetNotModifiedWhenOnlyBandIdsDiffer() throws {
        let manager = try makeManager()
        var bass = try XCTUnwrap(manager.profiles.first(where: { $0.id == FactoryPresetID.bassBoost }))
        bass.bands = bass.bands.map {
            EQBand(id: UUID(), type: $0.type, frequency: $0.frequency, gain: $0.gain, q: $0.q)
        }
        manager.update(bass)
        XCTAssertFalse(manager.isFactoryModified(FactoryPresetID.bassBoost),
                       "band identity must not count as user modification")
    }

    /// Regression: the name-based legacy cleanup is a one-time migration. After
    /// it has run, a *user* profile that happens to share a factory preset's
    /// name must survive subsequent launches.
    func testUserProfileNamedLikeFactorySurvivesResync() throws {
        let store = try makeStore()
        store.syncFactoryPresets(EQProfile.factoryPresets, obsoleteNames: EQProfile.obsoleteFactoryNames)

        var custom = EQProfile.newUserProfile(name: "Rock")
        custom.bands = [EQBand(type: .peaking, frequency: 500, gain: 3, q: 1)]
        try store.save(custom)

        // Next launch.
        store.syncFactoryPresets(EQProfile.factoryPresets, obsoleteNames: EQProfile.obsoleteFactoryNames)
        XCTAssertTrue(store.loadAll().contains(where: { $0.id == custom.id }),
                      "post-migration sync must not delete user profiles by name")
    }

    func testSyncRemovesObsoleteMidCutAndLegacyDuplicates() throws {
        let store = try makeStore()
        let legacy = EQProfile.newUserProfile(name: "Mid Cut")
        try store.save(legacy)
        var oldBass = EQProfile.newUserProfile(name: "Bass Boost")
        oldBass.bands = [EQBand(type: .lowShelf, frequency: 100, gain: 6, q: 0.707)]
        try store.save(oldBass)

        store.syncFactoryPresets(EQProfile.factoryPresets, obsoleteNames: EQProfile.obsoleteFactoryNames)
        let names = Set(store.loadAll().map(\.name))

        XCTAssertFalse(names.contains("Mid Cut"))
        XCTAssertEqual(store.loadAll().filter { $0.name == "Bass Boost" }.count, 1)
        XCTAssertTrue(store.loadAll().contains(where: { $0.id == FactoryPresetID.bassBoost }))
    }
}
