import XCTest
@testable import SonarForge

/// Regression tests for the A/B comparison slots, which previously held stale
/// snapshots: editing then swapping reverted (and could overwrite) edits, and
/// the active selection didn't track the showing slot.
@MainActor
final class AppModelABTests: XCTestCase {

    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelABTests-\(UUID().uuidString)", isDirectory: true)
        suiteName = "AppModelABTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() throws -> (AppModel, ProfileManager) {
        let store = try ProfileStore(directory: tempDirectory, defaults: defaults)
        let pm = ProfileManager(store: store)
        return (AppModel(audioEngine: MockAudioEngine(), profileManager: pm), pm)
    }

    /// Bug: editing bands then toggling A/B reverted the edit (stale snapshot),
    /// and a later commit wrote the stale version back over the saved edit.
    func testBandEditSurvivesABRoundTrip() throws {
        let (model, pm) = try makeModel()
        let x = pm.create(name: "X")
        model.selectProfile(id: x.id)

        _ = model.addBand(EQBand(type: .peaking, frequency: 100, gain: 5, q: 1))
        XCTAssertEqual(model.currentProfile.bands.count, 1)

        model.swapAB()   // -> B (adopts current as B's start)
        model.swapAB()   // -> A
        XCTAssertEqual(model.currentProfile.id, x.id, "should be back on A's profile")
        XCTAssertEqual(model.currentProfile.bands.count, 1, "edit on A must survive an A/B round-trip")
    }

    /// Bug: the Profile selection (active id + currentProfile) didn't follow the
    /// showing slot, so the dropdown showed the wrong profile after a swap.
    func testActiveSelectionTracksShowingSlot() throws {
        let (model, pm) = try makeModel()
        let x = pm.create(name: "X")
        let y = pm.create(name: "Y")

        model.selectProfile(id: x.id)              // A = X
        XCTAssertEqual(pm.activeProfileID, x.id)

        model.swapAB()                             // -> B
        model.selectProfile(id: y.id)              // B = Y
        XCTAssertEqual(pm.activeProfileID, y.id)
        XCTAssertEqual(model.currentProfile.id, y.id)

        model.swapAB()                             // -> A
        XCTAssertEqual(pm.activeProfileID, x.id, "active id must follow the A slot")
        XCTAssertEqual(model.currentProfile.id, x.id)

        model.swapAB()                             // -> B
        XCTAssertEqual(pm.activeProfileID, y.id, "active id must follow the B slot")
        XCTAssertEqual(model.currentProfile.id, y.id)
    }
}

/// Minimal no-op engine so AppModel can be exercised without Core Audio.
private final class MockAudioEngine: AudioEngineProtocol {
    var state: AudioEngineState = .idle
    var onStateChange: ((AudioEngineState) -> Void)?
    var onSpectrum: (([Float], [Float]) -> Void)?
    private(set) var loadedProfile: EQProfile?
    func setSpectrumEnabled(_ enabled: Bool) {}
    func start() {}
    func stop() {}
    func setBypass(_ bypassed: Bool) {}
    func setPreamp(_ db: Double) {}
    func setOutputGain(_ db: Double) {}
    func loadProfile(_ profile: EQProfile) { loadedProfile = profile }
    func selectOutputDevice(uid: String?) {}
}
