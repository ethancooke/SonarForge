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
        XCTAssertEqual(manager.profiles.count, EQProfile.debugPresets.count)
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
        XCTAssertEqual(second.profiles.count, 1)
        XCTAssertEqual(second.profiles[0].name, "Flat")
        XCTAssertEqual(second.activeProfileID, second.profiles[0].id)
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
    }

    func testDeleteActiveFallsBackAndPersists() throws {
        let manager = try makeManager()
        let active = try XCTUnwrap(manager.activeProfile)
        manager.delete(active.id)

        XCTAssertFalse(manager.profiles.contains(where: { $0.id == active.id }))
        XCTAssertNotNil(manager.activeProfile, "deleting the active profile must fall back")

        let relaunched = try makeManager()
        XCTAssertEqual(relaunched.activeProfileID, manager.activeProfileID)
    }

    func testDeletingEverythingLeavesFlat() throws {
        let manager = try makeManager()
        for profile in manager.profiles {
            manager.delete(profile.id)
        }
        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(manager.profiles[0].name, "Flat")
        XCTAssertEqual(manager.activeProfileID, manager.profiles[0].id)
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

        manager.delete(bass.id)
        XCTAssertTrue(manager.orderedFavorites.isEmpty)
        XCTAssertTrue(try makeStore().favoriteIDs.isEmpty, "persisted order cleaned up")
    }

    func testQuickSwitchListsFavoritesFirstThenRestByName() throws {
        let manager = try makeManager()
        let midCut = try XCTUnwrap(manager.profiles.first(where: { $0.name == "Mid Cut" }))
        manager.toggleFavorite(midCut.id)

        let quick = manager.quickSwitchProfiles
        XCTAssertEqual(quick.first?.name, "Mid Cut")
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
}
