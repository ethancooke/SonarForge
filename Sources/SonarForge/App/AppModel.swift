import SwiftUI
import Observation
import CoreAudio

/// Central observable application state.
/// Keeps the audio engine at arm's length from SwiftUI while exposing
/// the minimal surface the UI needs (see DECISIONS.md D-004).
@Observable
final class AppModel {
    // MARK: - High-level state

    var isBypassed: Bool = false
    var engineState: AudioEngineState = .idle
    var isProcessing: Bool { engineState == .running }

    var currentProfile: EQProfile = .flat
    var aProfile: EQProfile = .flat
    var bProfile: EQProfile = .flat
    var showingB: Bool = false              // A/B comparison state

    var preampDB: Double = 0.0
    var outputGainDB: Double = 0.0

    // MARK: - Output device selection

    var outputDevices: [AudioOutputDevice] = []
    var selectedOutputUID: String? = nil {
        didSet {
            guard oldValue != selectedOutputUID else { return }
            audioEngine.selectOutputDevice(uid: selectedOutputUID)
        }
    }

    // Spectrum data delivered from the audio engine (updated at UI-friendly rate)
    var preEQLevels: [Float] = []
    var postEQLevels: [Float] = []

    // MARK: - Dependencies (injected)

    private(set) var audioEngine: AudioEngineProtocol

    // MARK: - Initialization

    init(audioEngine: AudioEngineProtocol = SonarForgeAudioEngine()) {
        self.audioEngine = audioEngine
        self.audioEngine.onStateChange = { [weak self] newState in
            // Engine callbacks arrive on a background queue; hop to the main actor.
            Task { @MainActor in
                self?.engineState = newState
            }
        }
        refreshOutputDevices()
    }

    // MARK: - Engine control (UI → Model → Engine)

    func startEngine() {
        audioEngine.start()
    }

    func stopEngine() {
        audioEngine.stop()
    }

    func toggleEngine() {
        isProcessing ? stopEngine() : startEngine()
    }

    func refreshOutputDevices() {
        outputDevices = AudioDeviceUtils.allOutputDevices()
    }

    func openPrivacySettings() {
        PermissionHelper.openScreenRecordingPrivacySettings()
    }

    // MARK: - Intentions (UI → Model → Engine)

    func toggleBypass() {
        isBypassed.toggle()
        audioEngine.setBypass(isBypassed)
    }

    func setPreamp(_ db: Double) {
        preampDB = db
        audioEngine.setPreamp(db)
    }

    func setOutputGain(_ db: Double) {
        outputGainDB = db
        audioEngine.setOutputGain(db)
    }

    func loadProfile(_ profile: EQProfile) {
        currentProfile = profile
        // Update A/B as appropriate
        if !showingB {
            aProfile = profile
        } else {
            bProfile = profile
        }
        audioEngine.loadProfile(profile)
    }

    func swapAB() {
        showingB.toggle()
        let active = showingB ? bProfile : aProfile
        currentProfile = active
        audioEngine.loadProfile(active)
    }

    // Called by the audio engine (on a background queue) when spectrum updates arrive
    func didReceiveSpectrum(pre: [Float], post: [Float]) {
        // Dispatch to main for @Observable
        Task { @MainActor in
            self.preEQLevels = pre
            self.postEQLevels = post
        }
    }
}
