import Foundation
import CoreAudio
import Atomics
import os.log

/// System-wide audio engine: Core Audio process tap → private aggregate device → HAL IOProc passthrough.
///
/// Platform requirements (locked, see DECISIONS.md D-001/D-002):
/// - macOS 14.2+ only (minimum for stable Core Audio Taps)
/// - Apple Silicon (arm64) only
///
/// Technique (Chunk 1.1, see Documentation/AUDIO_PATH.md and DECISIONS.md D-007):
/// 1. A global stereo-mixdown `CATapDescription` captures every process except our own
///    (excluding ourselves prevents a feedback loop). `muteBehavior = .muted` silences the
///    original signal so only our re-rendered audio reaches the hardware.
/// 2. A private aggregate device contains the user's output device (clock master) and the
///    tap (drift-compensated). The HAL keeps capture and render in sync for us.
/// 3. A single `AudioDeviceIOProcIDWithBlock` on the aggregate copies tap input buffers to
///    the output device buffers each IO cycle. In Chunk 1.1 both the "processing" and
///    "bypass" paths are this same bit-identical copy; the EQ slots into the non-bypassed
///    branch in Chunk 2.2.
///
/// Threading model:
/// - All engine control (start/stop/reconfigure, Core Audio object lifecycle) happens on
///   `controlQueue` (serial). Public methods only enqueue work.
/// - The IO block runs on the HAL's realtime thread: no allocations, no locks, no ObjC.
///   It reads the bypass flag with a relaxed atomic load and mutates only render-local state.
/// - Device-change notifications arrive on `controlQueue` and trigger a debounced restart.
final class SonarForgeAudioEngine: AudioEngineProtocol {

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Engine")
    private let tapLogger = Logger(subsystem: "com.sonarforge.audio", category: "TapLifecycle")
    private let deviceLogger = Logger(subsystem: "com.sonarforge.audio", category: "DeviceManagement")

    private let controlQueue = DispatchQueue(label: "com.sonarforge.audio.control", qos: .userInitiated)

    // MARK: - Public State

    /// Last known state. Written on `controlQueue`; reads from other threads see the
    /// most recent completed transition (UI should observe `onStateChange` instead).
    private(set) var state: AudioEngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            logger.info("Engine state: \(self.state.description, privacy: .public)")
            onStateChange?(state)
        }
    }
    var onStateChange: ((AudioEngineState) -> Void)?

    // MARK: - Core Audio objects (touched only on controlQueue)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var currentOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var selectedOutputUID: String?
    private var pendingRestart = false

    // Property listeners (kept so they can be removed on stop)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    // MARK: - Render-thread shared state

    /// State shared with the realtime IO block. The atomic is written from any thread and
    /// read with relaxed ordering in the block. The ramp counters are written on
    /// `controlQueue` strictly before `AudioDeviceStart` and afterwards mutated only by
    /// the realtime thread.
    private final class RenderContext {
        let bypassed = ManagedAtomic<Bool>(false)
        var rampFramesRemaining: Int = 0
        var rampTotalFrames: Int = 0
    }
    private let renderContext = RenderContext()

    init() {
        logger.info("SonarForgeAudioEngine initialized (macOS 14.2+ / Apple Silicon only)")
    }

    deinit {
        // Best effort: tear down synchronously if the owner forgot to stop.
        controlQueue.sync { self.stopOnQueue() }
    }

    // MARK: - AudioEngineProtocol

    func start() {
        controlQueue.async { self.startOnQueue() }
    }

    func stop() {
        controlQueue.async {
            self.stopOnQueue()
            self.state = .idle
        }
    }

    func setBypass(_ bypassed: Bool) {
        renderContext.bypassed.store(bypassed, ordering: .relaxed)
        logger.info("Bypass set to \(bypassed)")
    }

    func setPreamp(_ db: Double) {
        // Chunk 1.2: applied in the render chain with smoothing.
        logger.debug("Preamp set to \(db) dB (not yet applied — Chunk 1.2)")
    }

    func setOutputGain(_ db: Double) {
        logger.debug("Output gain set to \(db) dB (not yet applied — Chunk 1.2)")
    }

    func loadProfile(_ profile: EQProfile) {
        logger.debug("Profile loaded: \(profile.name) (\(profile.bands.count) bands — EQ arrives in Chunk 2)")
    }

    func selectOutputDevice(uid: String?) {
        controlQueue.async {
            guard self.selectedOutputUID != uid else { return }
            self.selectedOutputUID = uid
            self.deviceLogger.info("Output device selection changed to \(uid ?? "system default", privacy: .public)")
            if case .running = self.state {
                self.stopOnQueue()
                self.startOnQueue()
            }
        }
    }

    // MARK: - Start / Stop (controlQueue only)

    private func startOnQueue() {
        if case .running = state { return }
        if case .starting = state { return }
        state = .starting

        do {
            // 1. Resolve the output device (selected UID, falling back to system default).
            let outputID = try resolveOutputDevice()
            guard let outputUID = AudioDeviceUtils.deviceUID(outputID) else {
                throw AudioEngineError.noOutputDevice
            }
            let outputName = AudioDeviceUtils.deviceName(outputID) ?? "unknown"
            let outputRate = AudioDeviceUtils.nominalSampleRate(outputID) ?? 48000
            deviceLogger.info("Output device: \(outputName, privacy: .public) (uid: \(outputUID, privacy: .public), \(outputRate) Hz)")

            // 2. Create the process tap: global stereo mixdown, our own process excluded,
            //    original audio muted (we are now responsible for rendering it).
            let ourProcessObject = try Self.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObject])
            tapDescription.muteBehavior = .muted
            tapDescription.name = "SonarForge System Tap"
            tapDescription.isPrivate = true

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "AudioHardwareCreateProcessTap")
            tapID = newTapID
            tapLogger.info("Process tap created: \(newTapID)")
            logTapFormat()

            // 3. Create a private aggregate: output device is the clock master, the tap is
            //    drift-compensated against it. tapautostart lets IO begin as soon as we start.
            let aggregateUID = "com.sonarforge.aggregate"
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SonarForge",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: outputUID,
                        kAudioSubDeviceDriftCompensationKey: false,
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
                      "AudioHardwareCreateAggregateDevice")
            aggregateID = newAggregateID
            deviceLogger.info("Aggregate device created: \(newAggregateID)")

            // 4. Moderate IO buffer size (512 frames ≈ 10.7 ms @ 48 kHz). Non-fatal if refused.
            setBufferFrameSize(512, on: newAggregateID)

            // 5. Arm the fade-in ramp (~30 ms) before IO starts to mask the start transition.
            renderContext.rampTotalFrames = max(Int(outputRate * 0.030), 1)
            renderContext.rampFramesRemaining = renderContext.rampTotalFrames

            // 6. Install the realtime IO block (nil queue → HAL realtime thread) and start.
            var newProcID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, nil, Self.makeIOBlock(context: renderContext)),
                      "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = newProcID
            try check(AudioDeviceStart(newAggregateID, newProcID), "AudioDeviceStart")

            currentOutputDeviceID = outputID
            installDeviceListeners(outputDeviceID: outputID)
            state = .running
            logger.info("Engine running: system audio → tap → SonarForge → \(outputName, privacy: .public)")
        } catch {
            logger.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            stopOnQueue()
            state = .failed(error.localizedDescription)
        }
    }

    private func stopOnQueue() {
        removeDeviceListeners()

        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            var status = AudioDeviceStop(aggregateID, procID)
            if status != noErr { logger.error("AudioDeviceStop failed (OSStatus: \(status))") }
            status = AudioDeviceDestroyIOProcID(aggregateID, procID)
            if status != noErr { logger.error("AudioDeviceDestroyIOProcID failed (OSStatus: \(status))") }
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { deviceLogger.error("Failed to destroy aggregate \(self.aggregateID) (OSStatus: \(status))") }
            aggregateID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { tapLogger.error("Failed to destroy tap \(self.tapID) (OSStatus: \(status))") }
            tapID = kAudioObjectUnknown
        }

        currentOutputDeviceID = kAudioObjectUnknown
        logger.info("Engine stopped and Core Audio objects released")
    }

    // MARK: - Realtime IO block

    /// Builds the realtime IO block. Static factory so the block provably captures only the
    /// render context (no `self`, no Core Audio object IDs, nothing that could allocate).
    ///
    /// Realtime rules: no allocations, no locks, no ObjC messaging. `memset`/`memcpy` and a
    /// relaxed atomic load are the heaviest operations here.
    private static func makeIOBlock(context: RenderContext) -> AudioDeviceIOBlock {
        return { _, inInputData, _, outOutputData, _ in
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)

            // Zero all output buffers first: covers missing input, channel-count
            // mismatches, and guarantees we never send stale memory to the hardware.
            for i in 0..<outABL.count {
                if let data = outABL[i].mData {
                    memset(data, 0, Int(outABL[i].mDataByteSize))
                }
            }

            // Chunk 1.1: bypassed and active paths are the same bit-identical copy.
            // The branch exists so the toggle mechanism is exercised now; the EQ will
            // replace the body of the non-bypassed branch in Chunk 2.2.
            _ = context.bypassed.load(ordering: .relaxed)

            let pairCount = min(inABL.count, outABL.count)
            let bytesPerSample = MemoryLayout<Float32>.size
            for i in 0..<pairCount {
                let inBuf = inABL[i]
                let outBuf = outABL[i]
                guard let inData = inBuf.mData, let outData = outBuf.mData else { continue }

                let inChannels = max(Int(inBuf.mNumberChannels), 1)
                let outChannels = max(Int(outBuf.mNumberChannels), 1)

                if inChannels == outChannels {
                    memcpy(outData, inData, min(Int(inBuf.mDataByteSize), Int(outBuf.mDataByteSize)))
                } else {
                    // Channel-count mismatch (e.g. stereo tap → multichannel interface):
                    // map the first min(in, out) channels frame by frame.
                    let inFloats = inData.assumingMemoryBound(to: Float32.self)
                    let outFloats = outData.assumingMemoryBound(to: Float32.self)
                    let frames = min(Int(inBuf.mDataByteSize) / (bytesPerSample * inChannels),
                                     Int(outBuf.mDataByteSize) / (bytesPerSample * outChannels))
                    let channels = min(inChannels, outChannels)
                    for frame in 0..<frames {
                        for channel in 0..<channels {
                            outFloats[frame * outChannels + channel] = inFloats[frame * inChannels + channel]
                        }
                    }
                }
            }

            // Short linear fade-in after start to mask the transition.
            if context.rampFramesRemaining > 0 {
                let total = Float32(max(context.rampTotalFrames, 1))
                let alreadyDone = context.rampTotalFrames - context.rampFramesRemaining
                var maxFramesThisCycle = 0
                for i in 0..<outABL.count {
                    guard let data = outABL[i].mData else { continue }
                    let channels = max(Int(outABL[i].mNumberChannels), 1)
                    let frames = Int(outABL[i].mDataByteSize) / (bytesPerSample * channels)
                    maxFramesThisCycle = max(maxFramesThisCycle, frames)
                    let floats = data.assumingMemoryBound(to: Float32.self)
                    let rampFrames = min(frames, context.rampFramesRemaining)
                    for frame in 0..<rampFrames {
                        let gain = Float32(alreadyDone + frame + 1) / total
                        for channel in 0..<channels {
                            floats[frame * channels + channel] *= gain
                        }
                    }
                }
                context.rampFramesRemaining = max(0, context.rampFramesRemaining - maxFramesThisCycle)
            }
        }
    }

    // MARK: - Device change handling (controlQueue)

    private func installDeviceListeners(outputDeviceID: AudioDeviceID) {
        // Default output changed — only relevant when following the system default.
        var defaultAddr = AudioDeviceUtils.address(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.selectedOutputUID == nil else { return }
            self.scheduleRestart(reason: "system default output device changed")
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, controlQueue, defaultBlock)
        defaultOutputListener = defaultBlock

        // Our output device disappeared.
        var aliveAddr = AudioDeviceUtils.address(kAudioDevicePropertyDeviceIsAlive)
        let aliveBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if !AudioDeviceUtils.isAlive(self.currentOutputDeviceID) {
                self.scheduleRestart(reason: "output device disconnected")
            }
        }
        AudioObjectAddPropertyListenerBlock(outputDeviceID, &aliveAddr, controlQueue, aliveBlock)
        deviceAliveListener = aliveBlock

        // Sample rate changed under us.
        var rateAddr = AudioDeviceUtils.address(kAudioDevicePropertyNominalSampleRate)
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(reason: "output device sample rate changed")
        }
        AudioObjectAddPropertyListenerBlock(outputDeviceID, &rateAddr, controlQueue, rateBlock)
        sampleRateListener = rateBlock
    }

    private func removeDeviceListeners() {
        if let block = defaultOutputListener {
            var addr = AudioDeviceUtils.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, controlQueue, block)
            defaultOutputListener = nil
        }
        if currentOutputDeviceID != kAudioObjectUnknown {
            if let block = deviceAliveListener {
                var addr = AudioDeviceUtils.address(kAudioDevicePropertyDeviceIsAlive)
                AudioObjectRemovePropertyListenerBlock(currentOutputDeviceID, &addr, controlQueue, block)
            }
            if let block = sampleRateListener {
                var addr = AudioDeviceUtils.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(currentOutputDeviceID, &addr, controlQueue, block)
            }
        }
        deviceAliveListener = nil
        sampleRateListener = nil
    }

    /// Debounced full restart. Device transitions often fire several notifications in a
    /// burst; we coalesce them and rebuild once things settle.
    private func scheduleRestart(reason: String) {
        guard !pendingRestart else { return }
        pendingRestart = true
        deviceLogger.info("Engine restart scheduled (\(reason, privacy: .public))")
        controlQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.pendingRestart = false
            self.stopOnQueue()
            self.startOnQueue()
        }
    }

    // MARK: - Helpers (controlQueue)

    private func resolveOutputDevice() throws -> AudioDeviceID {
        if let uid = selectedOutputUID {
            if let id = AudioDeviceUtils.deviceID(forUID: uid) {
                return id
            }
            deviceLogger.warning("Selected output device \(uid, privacy: .public) not found; falling back to system default")
        }
        guard let defaultID = AudioDeviceUtils.defaultOutputDeviceID() else {
            throw AudioEngineError.noOutputDevice
        }
        return defaultID
    }

    private func setBufferFrameSize(_ frames: UInt32, on deviceID: AudioObjectID) {
        var addr = AudioDeviceUtils.address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            deviceLogger.warning("Could not set buffer frame size to \(frames) (OSStatus: \(status)) — using device default")
        }
    }

    private func logTapFormat() {
        var addr = AudioDeviceUtils.address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format)
        if status == noErr {
            tapLogger.info("Tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, formatID \(format.mFormatID)")
        } else {
            tapLogger.warning("Could not read tap format (OSStatus: \(status))")
        }
    }

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

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioEngineError.coreAudio(operation, status)
        }
    }

    // MARK: - Error Types

    enum AudioEngineError: LocalizedError {
        case coreAudio(String, OSStatus)
        case failedToTranslatePID(OSStatus)
        case permissionDenied
        case noOutputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let operation, let status):
                "\(operation) failed (OSStatus: \(status))"
            case .failedToTranslatePID(let status):
                "Failed to translate PID to Core Audio process object (OSStatus: \(status))"
            case .permissionDenied:
                "System Audio Recording permission is required."
            case .noOutputDevice:
                "No suitable output device available."
            case .unsupportedFormat:
                "The audio format from the tap is not supported."
            }
        }
    }
}
