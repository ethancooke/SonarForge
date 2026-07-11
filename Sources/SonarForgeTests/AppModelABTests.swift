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

    /// Bug: preamp slider only pushed the engine; profile JSON kept the old
    /// value, so band commits / profile reload / A/B restored the stale preamp.
    func testPreampPersistSurvivesReloadAndBandCommit() throws {
        let (model, pm) = try makeModel()
        let x = pm.create(name: "X")
        model.selectProfile(id: x.id)

        model.setPreamp(-7.5, persist: true)
        XCTAssertEqual(model.currentProfile.preamp, -7.5, accuracy: 0.001)
        let saved = try XCTUnwrap(pm.profiles.first(where: { $0.id == x.id })?.preamp)
        XCTAssertEqual(saved, -7.5, accuracy: 0.001)

        // Band commit must not clobber the live preamp with a stale field.
        model.setPreamp(-9.0, persist: false)
        _ = model.addBand(EQBand(type: .peaking, frequency: 500, gain: 2, q: 1))
        XCTAssertEqual(model.currentProfile.preamp, -9.0, accuracy: 0.001)
        let afterBand = try XCTUnwrap(pm.profiles.first(where: { $0.id == x.id })?.preamp)
        XCTAssertEqual(afterBand, -9.0, accuracy: 0.001)

        model.selectProfile(id: x.id)
        XCTAssertEqual(model.preampDB, -9.0, accuracy: 0.001)
        XCTAssertEqual(model.currentProfile.preamp, -9.0, accuracy: 0.001)
    }

    func testPreampSurvivesABRoundTrip() throws {
        let (model, _) = try makeModel()
        let x = model.profileManager.create(name: "X")
        let y = model.profileManager.create(name: "Y")
        model.selectProfile(id: x.id)
        model.setPreamp(-4.0, persist: true)

        model.swapAB()
        model.selectProfile(id: y.id)
        model.setPreamp(-1.0, persist: true)

        model.swapAB() // back to X
        XCTAssertEqual(model.currentProfile.id, x.id)
        XCTAssertEqual(model.preampDB, -4.0, accuracy: 0.001)
        XCTAssertEqual(model.currentProfile.preamp, -4.0, accuracy: 0.001)
    }
}

/// Minimal no-op engine so AppModel can be exercised without Core Audio.
private final class MockAudioEngine: AudioEngineProtocol {
    var state: AudioEngineState = .idle
    var onStateChange: ((AudioEngineState) -> Void)?
    var onSpectrum: (([Float], [Float]) -> Void)?
    var onWaveform: ((WaveformSnapshot) -> Void)?
    private(set) var loadedProfile: EQProfile?
    func setSpectrumEnabled(_ enabled: Bool) {}
    func start() {}
    func stop() {}
    func setBypass(_ bypassed: Bool) {}
    func setPreamp(_ db: Double) {}
    func setOutputGain(_ db: Double) {}
    private(set) var crossfeedEnabled = false
    private(set) var crossfeedAmount = Crossfeed.defaultAmount
    func setCrossfeedEnabled(_ enabled: Bool) { crossfeedEnabled = enabled }
    func setCrossfeedAmount(_ amount: Double) { crossfeedAmount = amount }
    func loadProfile(_ profile: EQProfile) { loadedProfile = profile }
    func selectOutputDevice(uid: String?) {}
    private(set) var mockPeak: Float = 0
    private(set) var mockClip = false
    func latestOutputPeakLinear() -> Float { mockPeak }
    func outputClipLatched() -> Bool { mockClip }
    func clearOutputClipLatch() { mockClip = false }
}
