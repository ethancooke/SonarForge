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

    // Gain staging (Chunk 1.2). didSet wiring means SwiftUI slider bindings reach
    // the engine directly; the engine smooths the change on the render thread.
    var preampDB: Double = 0.0 {
        didSet {
            guard oldValue != preampDB else { return }
            audioEngine.setPreamp(preampDB)
        }
    }
    var outputGainDB: Double = 0.0 {
        didSet {
            guard oldValue != outputGainDB else { return }
            audioEngine.setOutputGain(outputGainDB)
        }
    }

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

        // Debug/automation hook: `open SonarForge.app --args --autostart-engine`
        // starts the engine immediately (used for autonomous CPU/stability testing).
        if CommandLine.arguments.contains("--autostart-engine") {
            startEngine()
        }
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
        preampDB = db   // didSet forwards to the engine
    }

    func setOutputGain(_ db: Double) {
        outputGainDB = db   // didSet forwards to the engine
    }

    func loadProfile(_ profile: EQProfile) {
        currentProfile = profile
        // Update A/B as appropriate
        if !showingB {
            aProfile = profile
        } else {
            bProfile = profile
        }
        // The profile's preamp is part of A/B state (Chunk 1.2).
        preampDB = profile.preamp
        audioEngine.loadProfile(profile)
    }

    func swapAB() {
        showingB.toggle()
        let active = showingB ? bProfile : aProfile
        currentProfile = active
        preampDB = active.preamp
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
