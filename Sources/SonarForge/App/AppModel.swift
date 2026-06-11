import SwiftUI
import Observation
import CoreAudio
import os.log

/// Central observable application state.
/// Keeps the audio engine at arm's length from SwiftUI while exposing
/// the minimal surface the UI needs (see DECISIONS.md D-004).
@Observable
final class AppModel {
    // MARK: - High-level state

    var isBypassed: Bool = false
    var engineState: AudioEngineState = .idle
    /// Toggled by the Help menu command (the command can't present sheets itself).
    var showingShortcutsHelp: Bool = false
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

    // MARK: - Spectrum (Chunk 3.1)

    // Display bins (dBFS, log-spaced 20 Hz–20 kHz), updated ~30 Hz while enabled.
    var preEQLevels: [Float] = []
    var postEQLevels: [Float] = []

    var showPreSpectrum: Bool = false {
        didSet { updateSpectrumEnabled() }
    }
    var showPostSpectrum: Bool = true {
        didSet { updateSpectrumEnabled() }
    }
    var showSpectrumLegend: Bool = false

    private func updateSpectrumEnabled() {
        let enabled = showPreSpectrum || showPostSpectrum
        audioEngine.setSpectrumEnabled(enabled)
        if !enabled {
            preEQLevels = []
            postEQLevels = []
        }
    }

    // MARK: - Dependencies (injected)

    private(set) var audioEngine: AudioEngineProtocol
    private(set) var profileManager: ProfileManager

    // MARK: - Initialization

    init(audioEngine: AudioEngineProtocol = SonarForgeAudioEngine(),
         profileManager: ProfileManager? = nil) {
        self.audioEngine = audioEngine
        self.profileManager = profileManager ?? ProfileManager(store: try? ProfileStore())

        self.audioEngine.onStateChange = { [weak self] newState in
            // Engine callbacks arrive on a background queue; hop to the main actor.
            Task { @MainActor in
                self?.engineState = newState
            }
        }
        // Debug/automation hook: `--debug-log-spectrum` logs the loudest bin's
        // pre/post levels ~1 Hz so external tooling can verify the EQ acoustically
        // (post − pre at a tone's bin == the EQ gain applied there).
        let probeLogging = CommandLine.arguments.contains("--debug-log-spectrum")
        let probeFilePath: String? = {
            guard let i = CommandLine.arguments.firstIndex(of: "--debug-log-spectrum-file"),
                  CommandLine.arguments.indices.contains(i + 1) else { return nil }
            return CommandLine.arguments[i + 1]
        }()
        let probeLogger = Logger(subsystem: "com.sonarforge.app", category: "SpectrumProbe")
        var lastProbe = Date.distantPast

        self.audioEngine.onSpectrum = { [weak self] pre, post in
            if (probeLogging || probeFilePath != nil),
               Date().timeIntervalSince(lastProbe) > 1.0,
               let peak = pre.indices.max(by: { pre[$0] < pre[$1] }) {
                lastProbe = Date()
                let preDB = String(format: "%.2f", pre[peak])
                let postDB = String(format: "%.2f", post[peak])
                if probeLogging {
                    probeLogger.info("probe bin=\(peak) pre=\(preDB, privacy: .public) post=\(postDB, privacy: .public)")
                }
                if let path = probeFilePath {
                    let line = "probe bin=\(peak) pre=\(preDB) post=\(postDB)\n"
                    if let data = line.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: path) {
                            if let handle = FileHandle(forWritingAtPath: path) {
                                handle.seekToEndOfFile()
                                handle.write(data)
                                try? handle.close()
                            }
                        } else {
                            FileManager.default.createFile(atPath: path, contents: data)
                        }
                    }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if self.showPreSpectrum { self.preEQLevels = pre }
                if self.showPostSpectrum { self.postEQLevels = post }
            }
        }
        updateSpectrumEnabled()
        refreshOutputDevices()

        // Restore the last-used profile and apply it to the engine. The engine
        // stores the bands and re-applies them at the real device rate on start,
        // so this is safe before the engine is running.
        if let active = self.profileManager.activeProfile {
            loadProfile(active)
        }

        // Debug/automation hook: `--import-profile <path>` loads a native profile
        // JSON before launch (used for acoustic verification scripts).
        if let importIndex = CommandLine.arguments.firstIndex(of: "--import-profile"),
           CommandLine.arguments.indices.contains(importIndex + 1) {
            let path = CommandLine.arguments[importIndex + 1]
            try? importProfile(from: URL(fileURLWithPath: path))
        }

        // Debug/automation hook: `open SonarForge.app --args --autostart-engine`
        // starts the engine immediately (used for autonomous CPU/stability testing).
        if CommandLine.arguments.contains("--autostart-engine") {
            startEngine()
        }
    }

    // MARK: - Profile library (UI → manager → engine)

    func selectProfile(id: UUID) {
        profileManager.setActive(id)
        if let profile = profileManager.activeProfile {
            loadProfile(profile)
        }
    }

    func deleteProfile(id: UUID) {
        let wasActive = profileManager.activeProfileID == id
        profileManager.delete(id)
        // Deleting the active profile falls back to another one; apply it.
        if wasActive, let profile = profileManager.activeProfile {
            loadProfile(profile)
        }
    }

    /// Imports a native profile JSON file, activates it, and applies it.
    @discardableResult
    func importProfile(from url: URL) throws -> EQProfile {
        let data = try Data(contentsOf: url)
        let decoded = try ProfileManager.decodeProfile(from: data)
        let imported = profileManager.importProfile(decoded)
        selectProfile(id: imported.id)
        return imported
    }

    func exportProfile(id: UUID, to url: URL) throws {
        let data = try profileManager.exportData(for: id)
        try data.write(to: url, options: .atomic)
    }

    /// Restores a built-in factory preset to its shipped default.
    func resetFactoryPreset(id: UUID) {
        guard let restored = profileManager.resetFactoryPreset(id) else { return }
        if currentProfile.id == id {
            loadProfile(restored)
        }
    }

    /// Restores every built-in factory preset to its shipped default.
    func resetAllFactoryPresets() {
        let activeID = profileManager.activeProfileID
        profileManager.resetAllFactoryPresets()
        if let activeID, let restored = profileManager.profiles.first(where: { $0.id == activeID }) {
            loadProfile(restored)
        }
    }

    // MARK: - Band editing (Chunk 5.2)

    /// Updates one band of the current profile and applies it to the engine
    /// immediately. Pass `persist: false` during continuous gestures (drags)
    /// to avoid writing the profile file at gesture rate; call
    /// `commitProfileEdit()` once on gesture end.
    func updateBand(at index: Int, _ band: EQBand, persist: Bool = true) {
        guard currentProfile.bands.indices.contains(index) else { return }
        currentProfile.bands[index] = band
        audioEngine.loadProfile(currentProfile)
        if persist { commitProfileEdit() }
    }

    @discardableResult
    func addBand(_ band: EQBand = EQBand()) -> EQBand? {
        guard currentProfile.bands.count < RealtimeParametricEQ.maxBands else { return nil }
        currentProfile.bands.append(band)
        audioEngine.loadProfile(currentProfile)
        commitProfileEdit()
        return band
    }

    func removeBand(at index: Int) {
        guard currentProfile.bands.indices.contains(index) else { return }
        currentProfile.bands.remove(at: index)
        audioEngine.loadProfile(currentProfile)
        commitProfileEdit()
    }

    /// Persists the current profile's content into the library (no-op for
    /// transient profiles that are not in the library).
    func commitProfileEdit() {
        profileManager.update(currentProfile)
    }

    /// Creates a profile from parsed AutoEQ data with mandatory attribution
    /// (D-006), adds it to the library, activates it, and applies it.
    @discardableResult
    func importAutoEQ(_ result: AutoEQImporter.ParseResult, name: String, measuredBy: String) -> EQProfile {
        let measurer = measuredBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = measurer.isEmpty ? "AutoEQ" : "AutoEQ / \(measurer)"
        let profile = EQProfile(
            id: UUID(),
            name: name,
            preamp: result.preamp,
            bands: result.bands,
            isFavorite: false,
            sourceAttribution: "\(source) — \(name)",
            notes: result.format == .graphic
                ? "Imported from AutoEQ GraphicEQ format (approximated with parametric bands) — autoeq.app"
                : "Imported from AutoEQ — autoeq.app"
        )
        let imported = profileManager.importProfile(profile)
        selectProfile(id: imported.id)
        return imported
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

    /// Troubleshooting escape hatch (Chunk 6.1): full teardown + rebuild of the
    /// tap, aggregate, and IOProc. Both calls serialize on the engine's control
    /// queue, so this is safe in any state.
    func resetAudioEngine() {
        audioEngine.stop()
        audioEngine.start()
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
