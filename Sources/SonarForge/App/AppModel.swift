import SwiftUI
import Observation
import CoreAudio
import os.log

/// Central observable application state.
/// Keeps the audio engine at arm's length from SwiftUI while exposing
/// the minimal surface the UI needs (see DECISIONS.md D-004).
///
/// Main-actor isolated: all UI-bound state and profile mutations must happen
/// on the main thread. Engine callbacks hop here via `Task { @MainActor in … }`.
@MainActor
@Observable
final class AppModel {
    // MARK: - High-level state

    var isBypassed: Bool = false
    var engineState: AudioEngineState = .idle
    /// Toggled by Help menu commands (commands can't present sheets themselves).
    var showingShortcutsHelp: Bool = false
    var showingWelcome: Bool = false
    var showingTroubleshooting: Bool = false

    private static let welcomeSeenKey = "hasSeenWelcome"

    func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
    }
    var isProcessing: Bool { engineState == .running }

    var currentProfile: EQProfile = .flat
    var showingB: Bool = false              // A/B comparison state
    // A/B slots reference library profiles by id (not snapshots): swapping
    // reloads the live, saved profile, so edits made on either side are never
    // reverted, and the active selection tracks whichever slot is showing.
    private var aProfileID: UUID?
    private var bProfileID: UUID?

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

    // MARK: - Output digital level (post-gain sample peak)

    /// Instantaneous sample-peak of the latest output buffer, in dBFS (0 = full scale).
    var outputPeakDBFS: Float = -120
    /// Decaying peak-hold for the meter bar.
    var outputPeakHoldDBFS: Float = -120
    /// UI clip light: sticky after a buffer hit |sample| ≥ 1.0.
    var outputClipActive: Bool = false

    /// Floor used when the buffer is silent / engine is off.
    static let outputMeterFloorDBFS: Float = -60
    private static let clipHoldSeconds: TimeInterval = 2.0
    /// Peak-hold decay per poll (~20 Hz → roughly 15 dB/s).
    private static let peakHoldDecayDB: Float = 0.75

    @ObservationIgnored private var outputLevelTimer: Timer?
    @ObservationIgnored private var clipHoldUntil: Date?

    // MARK: - Output device selection

    var outputDevices: [AudioOutputDevice] = []
    var selectedOutputUID: String? {
        didSet {
            guard oldValue != selectedOutputUID else { return }
            audioEngine.selectOutputDevice(uid: selectedOutputUID)
        }
    }

    // MARK: - Spectrum (Chunk 3.1)

    // Display bins (dBFS, log-spaced 20 Hz–20 kHz), updated ~20 Hz while enabled.
    // Used by SwiftUI Canvas path (frequency-response overlay). Standalone
    // visualizers (bars / LED / spectrogram / Reactor) poll `spectrumFeed`
    // instead so they keep animating during main-thread UI tracking.
    var preEQLevels: [Float] = []
    var postEQLevels: [Float] = []

    /// Thread-safe latest bins for display-link visualizers (not observable).
    @ObservationIgnored let spectrumFeed = SpectrumFeed()
    /// Thread-safe post-EQ PCM window for the oscilloscope (not observable).
    @ObservationIgnored let waveformFeed = WaveformFeed()

    private static let visualizationsEnabledKey = "visualizationsEnabled"

    /// Master switch for spectrum/PCM analysis and all visualizers (persisted).
    /// When off, FFT + waveform capture stop entirely — EQ audio is unaffected.
    var visualizationsEnabled: Bool = {
        if UserDefaults.standard.object(forKey: visualizationsEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: visualizationsEnabledKey)
    }() {
        didSet {
            guard oldValue != visualizationsEnabled else { return }
            UserDefaults.standard.set(visualizationsEnabled, forKey: Self.visualizationsEnabledKey)
            updateSpectrumEnabled()
        }
    }

    /// Main-window frequency pane is on screen (Chunk 6.2 CPU saver).
    var spectrumViewVisible: Bool = false {
        didSet { updateSpectrumEnabled() }
    }
    /// Pop-out visualizer window is open — keeps analysis alive even if the
    /// main window is closed (menu-bar-only use with a detached visualizer).
    var visualizerPopoutVisible: Bool = false {
        didSet { updateSpectrumEnabled() }
    }
    /// Menu-bar extra panel is open (mini meter needs spectrum bins).
    var menuBarVisualizerVisible: Bool = false {
        didSet { updateSpectrumEnabled() }
    }

    private func updateSpectrumEnabled() {
        // Visibility alone is not enough: the user can fully disable visualizers
        // to save CPU/battery while still running the EQ.
        let displayOpen = spectrumViewVisible || visualizerPopoutVisible || menuBarVisualizerVisible
        let enabled = visualizationsEnabled && displayOpen
        audioEngine.setSpectrumEnabled(enabled)
        if !enabled {
            spectrumFeed.clear()
            waveformFeed.clear()
            preEQLevels = []
            postEQLevels = []
        }
    }

    // MARK: - Dependencies (injected)

    private(set) var audioEngine: AudioEngineProtocol
    private(set) var profileManager: ProfileManager

    /// Retains the Core Audio device-list listener so the output picker auto-updates.
    @ObservationIgnored private var deviceListListener: AudioObjectPropertyListenerBlock?

    // MARK: - Initialization

    init(audioEngine: AudioEngineProtocol = SonarForgeAudioEngine(),
         profileManager: ProfileManager? = nil) {
        self.audioEngine = audioEngine
        self.profileManager = profileManager ?? ProfileManager(store: try? ProfileStore())

        self.audioEngine.onStateChange = { [weak self] newState in
            // Engine callbacks arrive on a background queue; hop to the main actor.
            Task { @MainActor in
                guard let self else { return }
                self.engineState = newState
                self.syncOutputLevelPolling(for: newState)
            }
        }
        // Debug/automation hook: `--debug-log-spectrum` logs the loudest bin's
        // pre/post levels ~1 Hz so external tooling can verify the EQ acoustically
        // (post − pre at a tone's bin == the EQ gain applied there).
        // File write (`--debug-log-spectrum-file`) is Debug-only (audit L6):
        // Release builds never open an arbitrary path from argv.
        let probeLogging = CommandLine.arguments.contains("--debug-log-spectrum")
        #if DEBUG
        let probeFilePath: String? = {
            guard let i = CommandLine.arguments.firstIndex(of: "--debug-log-spectrum-file"),
                  CommandLine.arguments.indices.contains(i + 1) else { return nil }
            return CommandLine.arguments[i + 1]
        }()
        #else
        let probeFilePath: String? = nil
        #endif
        let probeLogger = Logger(subsystem: "com.sonarforge.app", category: "SpectrumProbe")
        var lastProbe = Date.distantPast

        self.audioEngine.onSpectrum = { [weak self] pre, post in
            if probeLogging || probeFilePath != nil,
               Date().timeIntervalSince(lastProbe) > 1.0,
               let peak = pre.indices.max(by: { pre[$0] < pre[$1] }) {
                lastProbe = Date()
                let preDB = String(format: "%.2f", pre[peak])
                let postDB = String(format: "%.2f", post[peak])
                if probeLogging {
                    probeLogger.info("probe bin=\(peak) pre=\(preDB, privacy: .public) post=\(postDB, privacy: .public)")
                }
                #if DEBUG
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
                #endif
            }
            // Publish to the feed immediately (any thread) so display-link
            // visualizers never wait on the main actor / SwiftUI body cycle.
            guard let self else { return }
            self.spectrumFeed.publish(pre: pre, post: post)
            Task { @MainActor in
                self.preEQLevels = pre
                self.postEQLevels = post
            }
        }
        self.audioEngine.onWaveform = { [weak self] snapshot in
            self?.waveformFeed.publish(snapshot)
        }
        updateSpectrumEnabled()
        refreshOutputDevices()

        // Keep the output picker current automatically (devices plugged/unplugged,
        // our aggregate appearing/disappearing) — no manual refresh needed.
        deviceListListener = AudioDeviceUtils.addDeviceListChangeListener { [weak self] in
            Task { @MainActor in self?.refreshOutputDevices() }
        }

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
            _ = try? importProfile(from: URL(fileURLWithPath: path))
        }

        // Debug/automation hook: `open SonarForge.app --args --autostart-engine`
        // starts the engine immediately (used for autonomous CPU/stability testing).
        if CommandLine.arguments.contains("--autostart-engine") {
            startEngine()
        }

        // Marketing/docs: `--export-window-snapshot <path>` selects Sonar Wave,
        // starts the engine (live spectrum), and ContentView schedules a PNG export.
        if WindowSnapshot.isExportRequested {
            // Use `self.` — the init parameter is optional and shadows the property.
            if let wave = self.profileManager.profiles.first(where: { $0.name == "Sonar Wave" }) {
                selectProfile(id: wave.id)
            }
            // Sonar Wave peaks at ±8.7 dB — a little preamp headroom keeps the
            // digital CLIP badge off in the hero shot with typical program material.
            setPreamp(-6, persist: false)
            if !CommandLine.arguments.contains("--autostart-engine") {
                startEngine()
            }
        }

        // First run: show the welcome/permission explainer (Chunk 6.3). Skipped
        // for automation launches so scripts stay headless.
        if !UserDefaults.standard.bool(forKey: Self.welcomeSeenKey),
           !CommandLine.arguments.contains("--autostart-engine"),
           !WindowSnapshot.isExportRequested {
            showingWelcome = true
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
    /// Always stamps the live preamp onto the profile first so band/crossfeed
    /// commits never re-save a stale preamp after the user moved the slider.
    func commitProfileEdit() {
        if currentProfile.preamp != preampDB {
            currentProfile.preamp = preampDB
        }
        profileManager.update(currentProfile)
    }

    /// Last profile disk-write error, if any (surfaced in the main UI).
    var profileSaveError: String? { profileManager.lastSaveError }

    func clearProfileSaveError() {
        profileManager.clearSaveError()
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

    /// Starts the audio engine.
    ///
    /// Do **not** preflight with `CGPreflightScreenCaptureAccess` /
    /// `CGRequestScreenCaptureAccess`. Those APIs cover Screen Recording, not
    /// the System Audio Recording TCC that Core Audio taps use
    /// (`NSAudioCaptureUsageDescription`). On macOS 15+ the services are
    /// distinct ("Screen & System Audio Recording" vs "System Audio Recording
    /// Only"); a false-negative preflight blocked start even when the user had
    /// already granted the correct toggle (regression in v0.2.1).
    ///
    /// There is no public preflight for System Audio Recording. Denied /
    /// stale TCC is handled by the engine start watchdog + UI recovery copy
    /// (see `Documentation/AUDIO_PATH.md` § Permission).
    func startEngine() {
        audioEngine.start()
    }

    func stopEngine() {
        audioEngine.stop()
    }

    /// Clears the clip LED early (also auto-clears after a short hold).
    func clearOutputClipIndicator() {
        outputClipActive = false
        clipHoldUntil = nil
        audioEngine.clearOutputClipLatch()
    }

    // MARK: - Output level polling

    private func syncOutputLevelPolling(for state: AudioEngineState) {
        switch state {
        case .running:
            startOutputLevelPolling()
        case .idle, .failed, .starting:
            stopOutputLevelPolling()
            if state != .starting {
                outputPeakDBFS = Self.outputMeterFloorDBFS
                outputPeakHoldDBFS = Self.outputMeterFloorDBFS
                outputClipActive = false
                clipHoldUntil = nil
            }
        }
    }

    private func startOutputLevelPolling() {
        guard outputLevelTimer == nil else { return }
        // ~20 Hz is enough for a meter; RT already measured every buffer.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollOutputLevels()
        }
        // CommonModes so the meter keeps updating during menu/slider tracking.
        RunLoop.main.add(timer, forMode: .common)
        outputLevelTimer = timer
        pollOutputLevels()
    }

    private func stopOutputLevelPolling() {
        outputLevelTimer?.invalidate()
        outputLevelTimer = nil
    }

    private func pollOutputLevels() {
        let linear = audioEngine.latestOutputPeakLinear()
        let db: Float
        if linear > 1e-9 {
            db = 20 * log10(linear)
        } else {
            db = Self.outputMeterFloorDBFS
        }
        // Clamp display range for the bar; true overs still light the clip LED.
        outputPeakDBFS = max(db, Self.outputMeterFloorDBFS)
        outputPeakHoldDBFS = max(outputPeakHoldDBFS - Self.peakHoldDecayDB, outputPeakDBFS)

        if audioEngine.outputClipLatched() {
            outputClipActive = true
            clipHoldUntil = Date().addingTimeInterval(Self.clipHoldSeconds)
            // Clear the RT latch so a later clip can re-trigger after the hold.
            audioEngine.clearOutputClipLatch()
        }
        if let until = clipHoldUntil, Date() >= until {
            outputClipActive = false
            clipHoldUntil = nil
        }
    }

    func toggleEngine() {
        if isProcessing { stopEngine() } else { startEngine() }
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

    /// Applies preamp to the engine. Pass `persist: false` during continuous
    /// slider drags (live audio + model only — no profile JSON write yet);
    /// pass `true` on gesture end so the value is committed to the active profile.
    /// Always updates `preampDB` so band commits / reloads see the live value.
    /// Spectrum UI stays smooth via SpectrumFeed (not via skipping this write).
    func setPreamp(_ db: Double, persist: Bool = true) {
        preampDB = db   // didSet forwards to the engine
        guard persist else { return }
        commitProfileEdit()
    }

    /// Master output gain (session-only; not stored in the profile).
    func setOutputGain(_ db: Double) {
        outputGainDB = db   // didSet forwards to the engine
    }

    /// Toggles crossfeed for the current profile: updates the model, applies it
    /// live on the engine, and persists (crossfeed is saved per profile).
    func setCrossfeedEnabled(_ enabled: Bool) {
        guard currentProfile.crossfeedEnabled != enabled else { return }
        currentProfile.crossfeedEnabled = enabled
        audioEngine.setCrossfeedEnabled(enabled)
        commitProfileEdit()
    }

    /// Sets crossfeed strength (0…1). Pass `persist: false` during a continuous
    /// slider drag so we only push the engine (no `currentProfile` write) —
    /// mutating the profile every tick re-rendered the whole main window and
    /// starved the spectrum visualizers. Commit once on gesture end.
    func setCrossfeedAmount(_ amount: Double, persist: Bool = true) {
        let clamped = min(max(amount, 0), 1)
        audioEngine.setCrossfeedAmount(clamped)
        guard persist else { return }
        guard currentProfile.crossfeedAmount != clamped else { return }
        currentProfile.crossfeedAmount = clamped
        commitProfileEdit()
    }

    func loadProfile(_ profile: EQProfile) {
        let sanitized = ProfileManager.sanitize(profile).profile
        currentProfile = sanitized
        // Remember which profile is loaded in the showing slot (by id).
        if showingB { bProfileID = sanitized.id } else { aProfileID = sanitized.id }
        // The profile's preamp is part of A/B state (Chunk 1.2).
        preampDB = sanitized.preamp
        audioEngine.loadProfile(sanitized)
    }

    func swapAB() {
        // Commit live preamp into the library before leaving the slot so A/B
        // round-trips keep the gain staging the user just set.
        if currentProfile.preamp != preampDB {
            currentProfile.preamp = preampDB
            profileManager.update(currentProfile)
        }
        showingB.toggle()
        let slotID = showingB ? bProfileID : aProfileID
        // Reload the slot's profile fresh from the library so edits on either
        // side are preserved (never a stale snapshot), and make it the active
        // profile so the Profile menu reflects the slot that's showing.
        if let id = slotID, let profile = profileManager.profiles.first(where: { $0.id == id }) {
            profileManager.setActive(id)
            loadProfile(profile)
        } else if showingB {
            // First switch to B with nothing assigned yet: adopt the current
            // profile as B's starting point (pick a different one to compare).
            bProfileID = currentProfile.id
        } else {
            aProfileID = currentProfile.id
        }
    }
}
