import SwiftUI
import Observation
import CoreAudio

/// Central observable application state.
/// Keeps the audio engine at arm's length from SwiftUI while exposing
/// the minimal surface the UI needs.
@Observable
final class AppModel {
    // MARK: - High-level state

    var isBypassed: Bool = false
    var isProcessing: Bool = false          // true when audio engine is running
    var currentProfile: EQProfile = .flat
    var aProfile: EQProfile = .flat
    var bProfile: EQProfile = .flat
    var showingB: Bool = false              // A/B comparison state

    var preampDB: Double = 0.0
    var outputGainDB: Double = 0.0

    var selectedOutputDeviceID: AudioDeviceID?

    // Spectrum data delivered from the audio engine (updated at UI-friendly rate)
    var preEQLevels: [Float] = []
    var postEQLevels: [Float] = []

    // Permission / error state
    var hasSystemAudioPermission: Bool = false
    var audioErrorMessage: String?

    // MARK: - Dependencies (injected)

    // The real audio engine will be created and owned here or in a coordinator.
    // For early chunks we keep a placeholder.
    private(set) var audioEngine: AudioEngineProtocol?

    // MARK: - Initialization

    init() {
        // TODO (Chunk 1+): Create and configure the concrete AudioEngine
        // audioEngine = SonarForgeAudioEngine(...)
        // audioEngine?.delegate = self
    }

    // MARK: - Intentions (UI → Model → Engine)

    func toggleBypass() {
        isBypassed.toggle()
        audioEngine?.setBypass(isBypassed)
    }

    func setPreamp(_ db: Double) {
        preampDB = db
        audioEngine?.setPreamp(db)
    }

    func setOutputGain(_ db: Double) {
        outputGainDB = db
        audioEngine?.setOutputGain(db)
    }

    func loadProfile(_ profile: EQProfile) {
        currentProfile = profile
        // Update A/B as appropriate
        if !showingB {
            aProfile = profile
        } else {
            bProfile = profile
        }
        audioEngine?.loadProfile(profile)
    }

    func swapAB() {
        showingB.toggle()
        let active = showingB ? bProfile : aProfile
        currentProfile = active
        audioEngine?.loadProfile(active)
    }

    // Called by the audio engine (on a background queue) when spectrum updates arrive
    func didReceiveSpectrum(pre: [Float], post: [Float]) {
        // Dispatch to main for @Observable
        Task { @MainActor in
            self.preEQLevels = pre
            self.postEQLevels = post
        }
    }

    func requestPermissionsIfNeeded() async {
        // Implementation lives with the audio engine / permission helper
        // Update hasSystemAudioPermission and audioErrorMessage accordingly
    }
}

// Placeholder protocol so the UI layer can compile before the real engine exists.
protocol AudioEngineProtocol: AnyObject {
    func setBypass(_ bypassed: Bool)
    func setPreamp(_ db: Double)
    func setOutputGain(_ db: Double)
    func loadProfile(_ profile: EQProfile)
    // Later: start/stop, selectOutputDevice, etc.
}
