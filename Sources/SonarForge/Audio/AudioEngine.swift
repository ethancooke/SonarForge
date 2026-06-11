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
///    the output device buffers each IO cycle, then applies smoothed gain (Chunk 1.2:
///    preamp × output gain, or unity when bypassed; one-pole smoother, no zipper noise).
///    The EQ slots between the two gain stages in Chunk 2.2.
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

    // MARK: - Start watchdog

    /// Deliberately not `controlQueue`: the watchdog exists precisely because a start
    /// attempt can wedge `controlQueue` inside a blocking Core Audio call (see
    /// `startOnQueue`), so its timer must live somewhere that is still scheduled.
    private let watchdogQueue = DispatchQueue(label: "com.sonarforge.audio.watchdog", qos: .utility)

    /// Monotonic start-attempt counter. Incremented on `controlQueue` when an attempt is
    /// armed and again when it completes (either outcome); the fired watchdog compares
    /// against the value it was armed with to decide whether the attempt is still in flight.
    private let startGeneration = ManagedAtomic<UInt64>(0)

    /// Pending watchdog work item (touched only on `controlQueue`).
    private var startWatchdogItem: DispatchWorkItem?

    private static let startWatchdogTimeout: TimeInterval = 10

    private static let startTimeoutMessage =
        "Engine start timed out. macOS is likely blocking the System Audio Recording " +
        "permission (a stale entry stops matching the app after a rebuild). Run " +
        "`tccutil reset All com.sonarforge.SonarForge`, then relaunch and re-grant."

    // Property listeners (kept so they can be removed on stop)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    // MARK: - Render-thread shared state

    /// State shared with the realtime IO block. Atomics are written from any thread and
    /// read with relaxed ordering in the block. Gains are published as Float bit patterns
    /// in UInt32 atomics. `smoothedGain`/`smoothingCoeff` are written on `controlQueue`
    /// strictly before `AudioDeviceStart` and afterwards touched only by the render thread.
    private final class RenderContext {
        let bypassed = ManagedAtomic<Bool>(false)
        let preampGainBits = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
        let outputGainBits = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
        /// Set by the control queue just before teardown; the gain smoother ramps
        /// to silence so stop/restart transitions don't click (Chunk 6.1).
        let fadeOut = ManagedAtomic<Bool>(false)
        var smoothedGain: Float = 0
        var smoothingCoeff: Float = 0.001
        /// RT-local: tracks bypass transitions so EQ state resets when re-engaging.
        var wasBypassed: Bool = true
    }
    private let renderContext = RenderContext()

    /// The live EQ (Chunk 2.2). Producer side driven from `controlQueue` only
    /// (single-producer contract of its command ring); consumer side runs in the
    /// IO block.
    private let eq = RealtimeParametricEQ()
    /// Last loaded profile bands; re-applied after every engine (re)start so
    /// device/sample-rate changes recompute coefficients at the new rate.
    private var currentBands: [EQBand] = []
    private var currentSampleRate: Double = 48000

    /// Spectrum analysis (Chunk 3.1): realtime taps feed lock-free rings; FFT
    /// runs on the analyzer's own queue at 30 Hz while enabled.
    private let analyzer = SpectrumAnalyzer()
    var onSpectrum: (([Float], [Float]) -> Void)? {
        get { analyzer.onSnapshot }
        set { analyzer.onSnapshot = newValue }
    }

    func setSpectrumEnabled(_ enabled: Bool) {
        analyzer.enabled.store(enabled, ordering: .relaxed)
        logger.info("Spectrum analysis \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    /// Gain controls are clamped to a sane range; the UI exposes ±12 dB (see D-009).
    private static let gainRangeDB = -24.0...24.0
    /// One-pole smoother time constant. Doubles as the start fade-in (gain begins at 0).
    private static let gainSmoothingSeconds = 0.015

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
        controlQueue.async { self.stopOnQueue() }
    }

    func setBypass(_ bypassed: Bool) {
        renderContext.bypassed.store(bypassed, ordering: .relaxed)
        logger.info("Bypass set to \(bypassed)")
    }

    func setPreamp(_ db: Double) {
        let clamped = min(max(db, Self.gainRangeDB.lowerBound), Self.gainRangeDB.upperBound)
        renderContext.preampGainBits.store(GainMath.linearGain(fromDB: clamped).bitPattern, ordering: .relaxed)
        logger.debug("Preamp set to \(clamped) dB")
    }

    func setOutputGain(_ db: Double) {
        let clamped = min(max(db, Self.gainRangeDB.lowerBound), Self.gainRangeDB.upperBound)
        renderContext.outputGainBits.store(GainMath.linearGain(fromDB: clamped).bitPattern, ordering: .relaxed)
        logger.debug("Output gain set to \(clamped) dB")
    }

    func loadProfile(_ profile: EQProfile) {
        controlQueue.async {
            self.currentBands = profile.bands
            let applied = self.eq.apply(bands: profile.bands, sampleRate: self.currentSampleRate)
            self.logger.info("Profile loaded: \(profile.name, privacy: .public) (\(applied) bands @ \(self.currentSampleRate) Hz)")
        }
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
        armStartWatchdog()

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

            // 5. Arm the gain smoother before IO starts. Starting from 0 makes the
            //    one-pole smoother double as the start fade-in (~45 ms to 95%).
            renderContext.smoothingCoeff = GainMath.smoothingCoefficient(
                timeConstant: Self.gainSmoothingSeconds, sampleRate: outputRate)
            renderContext.smoothedGain = 0

            // 5b. (Re)apply EQ coefficients at the actual output rate and clear
            //     filter state — device or rate may have changed since last start.
            currentSampleRate = outputRate
            eq.apply(bands: currentBands, sampleRate: outputRate)
            eq.requestStateReset()

            // 5c. Spectrum analysis runs while the engine runs (its CPU cost is
            //     gated separately by the `enabled` atomic the IO block reads).
            analyzer.start(sampleRate: outputRate)

            // 6. Install the realtime IO block (nil queue → HAL realtime thread) and start.
            var newProcID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, nil, Self.makeIOBlock(context: renderContext, eq: eq, analyzer: analyzer)),
                      "AudioDeviceCreateIOProcIDWithBlock")
            ioProcID = newProcID
            try check(AudioDeviceStart(newAggregateID, newProcID), "AudioDeviceStart")

            currentOutputDeviceID = outputID
            installDeviceListeners(outputDeviceID: outputID)
            disarmStartWatchdog() // before .running so the watchdog can't fire on a completed start
            state = .running
            logger.info("Engine running: system audio → tap → SonarForge → \(outputName, privacy: .public)")
        } catch {
            disarmStartWatchdog()
            logger.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            stopOnQueue()
            state = .failed(error.localizedDescription)
        }
    }

    /// Arms a timer that surfaces a hung start attempt to the UI.
    ///
    /// Why this exists: `AudioDeviceCreateIOProcIDWithBlock` can block forever inside
    /// coreaudiod when a stale TCC entry no longer matches our ad-hoc signature (see
    /// Documentation/AUDIO_PATH.md, "Permission"). The blocked call cannot be cancelled
    /// and `controlQueue` stays wedged behind it — including any queued stop()/start(),
    /// so "Retry" in the UI only takes effect if coreaudiod eventually returns. The
    /// watchdog therefore only *reports* the failure; it does not unblock anything.
    ///
    /// The fired watchdog must not write `state`: that property is owned by
    /// `controlQueue`, and the wedged attempt may resume at any moment and assign it
    /// concurrently. Instead it emits `.failed` straight through `onStateChange`. If the
    /// blocked call later returns and the start completes, the resulting `.running`
    /// notification supersedes the synthetic failure in the UI — which is accurate.
    private func armStartWatchdog() {
        let generation = startGeneration.wrappingIncrementThenLoad(ordering: .relaxed)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.startGeneration.load(ordering: .relaxed) == generation else { return }
            self.logger.error("Start watchdog fired: engine still starting after \(Self.startWatchdogTimeout, privacy: .public)s — likely a stale System Audio Recording TCC entry (see AUDIO_PATH.md)")
            self.onStateChange?(.failed(Self.startTimeoutMessage))
        }
        startWatchdogItem = item
        watchdogQueue.asyncAfter(deadline: .now() + Self.startWatchdogTimeout, execute: item)
    }

    private func disarmStartWatchdog() {
        startGeneration.wrappingIncrement(ordering: .relaxed)
        startWatchdogItem?.cancel()
        startWatchdogItem = nil
    }

    private func stopOnQueue() {
        removeDeviceListeners()

        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            // Fade to silence before teardown so stops and device-switch
            // rebuilds don't click (~40 ms ≈ 93% of the way down at τ = 15 ms;
            // the remainder is masked by the stop itself). The control queue
            // may sleep; the render thread does the actual ramping.
            renderContext.fadeOut.store(true, ordering: .relaxed)
            usleep(40_000)

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
        analyzer.stop()
        renderContext.fadeOut.store(false, ordering: .relaxed)
        logger.info("Engine stopped and Core Audio objects released")

        // Reset state here (not in the public stop()) so internal stop→start sequences
        // (device switch, scheduled restart) don't leave a stale .running that makes
        // startOnQueue's reentrancy guard refuse the rebuild.
        state = .idle
    }

    // MARK: - Realtime IO block

    /// Builds the realtime IO block. Static factory so the block provably captures only the
    /// render context, the EQ, and the analyzer (no `self`, no Core Audio object IDs,
    /// nothing that could allocate).
    ///
    /// Realtime rules: no allocations, no locks, no ObjC messaging. The EQ drains its
    /// lock-free command ring here; spectrum taps write into lock-free rings.
    private static func makeIOBlock(context: RenderContext, eq: RealtimeParametricEQ, analyzer: SpectrumAnalyzer) -> AudioDeviceIOBlock {
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

            // Locate the first stereo buffer once — the EQ and the spectrum taps
            // all operate on it. Non-stereo layouts pass through with gain only
            // (documented MVP limit).
            var stereoData: UnsafeMutablePointer<Float32>?
            var stereoFrames = 0
            for i in 0..<outABL.count {
                if outABL[i].mNumberChannels == 2, let data = outABL[i].mData {
                    stereoData = data.assumingMemoryBound(to: Float32.self)
                    stereoFrames = Int(outABL[i].mDataByteSize) / (bytesPerSample * 2)
                    break
                }
            }

            // Spectrum pre-EQ tap (Chunk 3.1): the raw system mix, post-copy,
            // pre-processing. One atomic read gates all analysis cost.
            let analyzeThisCycle = analyzer.enabled.load(ordering: .relaxed)
            if analyzeThisCycle, let stereo = stereoData {
                analyzer.capturePre(stereo, frames: stereoFrames)
            }

            // EQ pass (Chunk 2.2). Always drain pending parameter commands, even
            // when bypassed, so coefficients are current the moment bypass lifts.
            eq.drainCommands()

            let isBypassed = context.bypassed.load(ordering: .relaxed)
            if !isBypassed, let stereo = stereoData {
                if context.wasBypassed {
                    // Re-engaging: clear stale filter history. The gain smoother's
                    // crossfade masks the transition.
                    eq.resetState()
                }
                eq.processStereoInterleaved(stereo, frameCount: stereoFrames)
            }
            context.wasBypassed = isBypassed

            // Gain pass (Chunk 1.2): per-sample one-pole smoothing toward the target —
            // unity when bypassed, preamp × output gain when active. The smoother
            // prevents zipper noise on fader moves, gives a click-free bypass
            // crossfade (~15 ms), and doubles as the start fade-in (gain starts at 0).
            // The EQ is linear, so applying the combined gain after it is exactly
            // equivalent to preamp-before/output-after until a nonlinear stage exists.
            let preampGain = Float(bitPattern: context.preampGainBits.load(ordering: .relaxed))
            let outputGain = Float(bitPattern: context.outputGainBits.load(ordering: .relaxed))
            let fadingOut = context.fadeOut.load(ordering: .relaxed)
            let target: Float = fadingOut ? 0.0 : (isBypassed ? 1.0 : preampGain * outputGain)

            let startGain = context.smoothedGain
            if target == 1.0 && abs(startGain - 1.0) < 1e-6 {
                // Settled at unity: true zero-cost path (bypass honesty — we are
                // provably not touching the samples).
                context.smoothedGain = 1.0
            } else {
                let k = context.smoothingCoeff
                var finalGain = startGain
                for i in 0..<outABL.count {
                    guard let data = outABL[i].mData else { continue }
                    let channels = max(Int(outABL[i].mNumberChannels), 1)
                    let frames = Int(outABL[i].mDataByteSize) / (bytesPerSample * channels)
                    let floats = data.assumingMemoryBound(to: Float32.self)
                    var gain = startGain
                    for frame in 0..<frames {
                        gain += k * (target - gain)
                        for channel in 0..<channels {
                            floats[frame * channels + channel] *= gain
                        }
                    }
                    finalGain = gain
                }
                context.smoothedGain = finalGain
            }

            // Spectrum post tap (Chunk 3.1): what actually reaches the hardware
            // (post-EQ, post-gain). When bypassed this equals the pre tap.
            if analyzeThisCycle, let stereo = stereoData {
                analyzer.capturePost(stereo, frames: stereoFrames)
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
