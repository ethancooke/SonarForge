import Foundation
import AVFoundation
import CoreAudio
import os.log

/// Concrete implementation of the system-wide audio engine.
/// This is the home of the Core Audio Tap + processing + output routing.
///
/// Platform requirements (locked):
/// - macOS 14.2 and later only (minimum for stable Core Audio Taps per Apple sample code)
/// - Apple Silicon (arm64) only — no Intel support
///
/// IMPORTANT (Chunk 1.1): The initial implementation focuses exclusively on
/// reliable capture → passthrough → bypass. EQ, spectrum, and advanced device
/// handling come in subsequent chunks.
///
/// Threading model (target):
/// - Render work happens on the high-priority Core Audio / AVAudioEngine thread.
/// - All parameter updates from UI arrive via lock-free or double-buffered mechanisms.
/// - Heavy reconfiguration (device changes, tap recreation) happens off the audio thread.
final class SonarForgeAudioEngine: AudioEngineProtocol {

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Engine")

    // MARK: - Public State (read-only from outside)

    private(set) var isRunning: Bool = false
    private(set) var currentSampleRate: Double = 48000
    private(set) var currentChannelCount: Int = 2

    // MARK: - Internal Engine Objects

    private var avEngine: AVAudioEngine?
    private var inputTap: AVAudioNode?          // Will hold reference to the tap node or input
    private var processTapID: AudioObjectID = kAudioObjectUnknown

    private var outputDeviceID: AudioDeviceID?

    // Bypass state (must be safe to read/write from audio & main threads)
    private var _bypassed: Bool = false
    var isBypassed: Bool {
        get { _bypassed }
        set {
            _bypassed = newValue
            // In a real implementation we would atomically communicate this to the render block
        }
    }

    // MARK: - Initialization

    init() {
        logger.info("SonarForgeAudioEngine initialized (macOS 14.2+ / Apple Silicon only, stub for Chunk 1.1)")
    }

    // MARK: - Lifecycle

    /// Starts the audio engine with a global Core Audio Tap.
    /// This is the heart of Chunk 1.1.
    func start() throws {
        logger.info("Starting audio engine with Core Audio Tap...")

        // 1. Permission check / request should have been done by the caller (AppModel).
        //    Here we assume we have (or will fail gracefully).

        // 2. Create the tap description (global stereo mixdown, exclude ourselves to prevent feedback).
        //    See Apple's "Capturing system audio with Core Audio taps" sample.
        //    The exclusion list takes Core Audio *process object* IDs, not raw PIDs,
        //    so we translate our own PID first. Failing to exclude ourselves would
        //    cause an immediate feedback loop once we re-render the tapped audio.
        let ourProcessObject = try Self.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObject])
        tapDescription.muteBehavior = .muted          // Critical: prevent double audio
        tapDescription.name = "SonarForge System Tap"
        tapDescription.isPrivate = true               // Not visible to other tapping apps

        // 3. Create the process tap
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            logger.error("Failed to create process tap: \(status)")
            throw AudioEngineError.failedToCreateTap(status)
        }
        processTapID = tapID
        logger.info("Process tap created: \(tapID)")

        // 4. Build an AVAudioEngine that uses the tap as an input source.
        //    A common pattern is to create an aggregate device containing the tap
        //    or to use the tap directly via lower-level APIs.
        //
        //    For the MVP we will use AVAudioEngine + a custom input node approach
        //    or the technique shown in Apple's sample / community gists.
        //
        //    TODO (Chunk 1.1): Implement the actual wiring.
        //    One proven path:
        //      - Create an AVAudioDevice aggregate that includes the tap as an input.
        //      - Or attach a node whose input comes from the tap buffer list via render callback.
        //
        //    For now this is a skeleton that will be filled during Chunk 1.1.

        let engine = AVAudioEngine()
        self.avEngine = engine

        // Placeholder: In the real implementation we would:
        // - Obtain the tap's audio format
        // - Connect a player or input node
        // - Attach our processing (initially just a passthrough or gain node)
        // - Connect to the outputNode (user-selected device)
        // - Install a render callback or tap for spectrum analysis later

        // 5. Start the engine
        try engine.start()
        isRunning = true
        logger.info("AVAudioEngine started successfully (passthrough mode)")

        // TODO (Chunk 1.1): Install actual tap input + output device selection + bypass logic
    }

    func stop() {
        logger.info("Stopping audio engine")
        avEngine?.stop()
        avEngine = nil

        if processTapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(processTapID)
            if status != noErr {
                logger.error("Failed to destroy process tap \(self.processTapID): \(status)")
            }
            processTapID = kAudioObjectUnknown
        }

        isRunning = false
    }

    // MARK: - AudioEngineProtocol

    func setBypass(_ bypassed: Bool) {
        isBypassed = bypassed
        logger.debug("Bypass set to \(bypassed)")
        // The render block must read this (or a mirrored atomic) on every buffer
    }

    func setPreamp(_ db: Double) {
        // Will be applied inside the render chain (Chunk 2+)
        logger.debug("Preamp set to \(db) dB")
    }

    func setOutputGain(_ db: Double) {
        logger.debug("Output gain set to \(db) dB")
    }

    func loadProfile(_ profile: EQProfile) {
        logger.debug("Loading profile: \(profile.name) with \(profile.bands.count) bands")
        // In Chunk 2 we will translate this into live biquad coefficients
    }

    // MARK: - Device Management (future chunks)

    func selectOutputDevice(_ deviceID: AudioDeviceID) throws {
        // Reconfigure engine output
        self.outputDeviceID = deviceID
    }

    // MARK: - Core Audio Helpers

    /// Translates a Unix PID into the Core Audio process object ID that the
    /// CATapDescription exclusion list expects (kAudioHardwarePropertyTranslatePIDToProcessObject).
    private static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &dataSize,
            &processObjectID
        )
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            throw AudioEngineError.failedToTranslatePID(status)
        }
        return processObjectID
    }

    // MARK: - Error Types

    enum AudioEngineError: LocalizedError {
        case failedToCreateTap(OSStatus)
        case failedToTranslatePID(OSStatus)
        case permissionDenied
        case noOutputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .failedToCreateTap(let status):
                "Failed to create Core Audio process tap (OSStatus: \(status))"
            case .failedToTranslatePID(let status):
                "Failed to translate PID to Core Audio process object (OSStatus: \(status))"
            case .permissionDenied:
                "Screen & System Audio Recording permission is required."
            case .noOutputDevice:
                "No suitable output device selected."
            case .unsupportedFormat:
                "The audio format from the tap is not supported."
            }
        }
    }
}
