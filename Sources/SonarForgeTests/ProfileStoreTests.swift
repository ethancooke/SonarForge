import XCTest
@testable import SonarForge

final class ProfileStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "ProfileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = try ProfileStore(directory: tempDirectory, defaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeProfile(name: String = "Test") -> EQProfile {
        EQProfile(
            id: UUID(),
            name: name,
            preamp: -4.5,
            bands: [
                EQBand(type: .lowShelf, frequency: 105, gain: -2.1, q: 0.70),
                EQBand(type: .peaking, frequency: 1240, gain: 3.4, q: 1.41),
                EQBand(type: .highShelf, frequency: 9800, gain: -5.0, q: 0.5),
            ],
            isFavorite: true,
            sourceAttribution: "AutoEQ / oratory1990 — Test Cans",
            notes: "round-trip me"
        )
    }

    // MARK: - Round trips

    func testSaveAndLoadRoundTripPreservesAllFields() throws {
        let profile = makeProfile()
        try store.save(profile)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], profile, "every field must survive the disk round trip")
    }

    func testOverwriteUpdatesExistingFile() throws {
        var profile = makeProfile()
        try store.save(profile)
        profile.name = "Renamed"
        profile.preamp = -6.0
        try store.save(profile)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.count, 1, "same id must overwrite, not duplicate")
        XCTAssertEqual(loaded[0].name, "Renamed")
        XCTAssertEqual(loaded[0].preamp, -6.0)
    }

    func testDeleteRemovesProfile() throws {
        let keep = makeProfile(name: "Keep")
        let remove = makeProfile(name: "Remove")
        try store.save(keep)
        try store.save(remove)

        try store.delete(id: remove.id)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [keep.id])
    }

    func testDeleteMissingProfileDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete(id: UUID()))
    }

    // MARK: - Robustness

    func testCorruptFileIsSkippedAndOthersLoad() throws {
        let good = makeProfile(name: "Good")
        try store.save(good)
        // A truncated/garbage JSON file alongside it.
        let corruptURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{\"name\": \"not a profi".utf8).write(to: corruptURL)
        // And a non-JSON file that should be ignored entirely.
        try Data("hello".utf8).write(to: tempDirectory.appendingPathComponent("README.txt"))

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [good.id], "corruption must not take down the library")
    }

    func testExportedFileIsPlainReadableJSON() throws {
        let profile = makeProfile()
        try store.save(profile)

        let url = tempDirectory.appendingPathComponent("\(profile.id.uuidString).json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"name\""), "file should be human-readable (pretty-printed)")
        XCTAssertTrue(text.contains("sourceAttribution"), "attribution must be in the export format")
    }

    // MARK: - Seeding

    func testSeedRunsExactlyOnce() throws {
        let starters = [makeProfile(name: "Starter A"), makeProfile(name: "Starter B")]
        XCTAssertTrue(store.seedIfNeeded(with: starters))
        XCTAssertEqual(store.loadAll().count, 2)

        // Second call must be a no-op even if the user deleted everything.
        for p in starters { try store.delete(id: p.id) }
        XCTAssertFalse(store.seedIfNeeded(with: starters))
        XCTAssertEqual(store.loadAll().count, 0, "seeding must not resurrect deleted profiles")
    }

    // MARK: - App state

    func testActiveProfileIDPersists() {
        XCTAssertNil(store.activeProfileID)
        let id = UUID()
        store.activeProfileID = id
        XCTAssertEqual(store.activeProfileID, id)
        store.activeProfileID = nil
        XCTAssertNil(store.activeProfileID)
    }

    func testFavoriteIDsPreserveOrder() {
        let ids = [UUID(), UUID(), UUID()]
        store.favoriteIDs = ids
        XCTAssertEqual(store.favoriteIDs, ids)

        let reordered = [ids[2], ids[0], ids[1]]
        store.favoriteIDs = reordered
        XCTAssertEqual(store.favoriteIDs, reordered, "favorites are user-ordered")
    }

    func testStateSurvivesStoreRecreation() throws {
        let profile = makeProfile()
        try store.save(profile)
        store.activeProfileID = profile.id
        store.favoriteIDs = [profile.id]

        // New store instance over the same directory/defaults — simulates relaunch.
        let reopened = try ProfileStore(directory: tempDirectory, defaults: defaults)
        XCTAssertEqual(reopened.loadAll().map(\.id), [profile.id])
        XCTAssertEqual(reopened.activeProfileID, profile.id)
        XCTAssertEqual(reopened.favoriteIDs, [profile.id])
    }
}
