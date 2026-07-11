import Foundation
import Atomics
import os.log

/// Bridges the realtime render path to FFT analysis (Chunk 3.1) and post-EQ
/// PCM (mono + stereo) for time-domain visuals.
///
/// Realtime side (`capturePre`/`capturePost`): lock-free ring writes only —
/// no allocations, no locks. Gated by `enabled`. Post writes a mono FFT ring
/// and a **single interleaved stereo ring** so L/R samples never desync
/// (independent mono rings can drop at different times and destroy correlation).
///
/// Analysis side: timer on a utility queue → spectrum bins via `onSnapshot`
/// and a `WaveformSnapshot` via `onWaveform`.
final class SpectrumAnalyzer {

    static let updateRate = 20.0
    /// Samples published each tick (~21 ms @ 48 kHz).
    static let waveformDisplayCount = 1024
    /// Mono float capacity for the FFT post path.
    static let waveformRingCapacity = 8192
    /// Stereo ring holds L,R pairs as floats (2 × frames).
    static let stereoRingFloatCapacity = waveformRingCapacity * 2

    static let targetHzPerBin = 2.93
    static let minFFTSize = 4096
    static let maxFFTSize = 65536

    static func fftSize(forSampleRate sampleRate: Double) -> Int {
        let target = Int((max(sampleRate, 1) / targetHzPerBin).rounded())
        var pow2 = 1
        while pow2 < target { pow2 <<= 1 }
        let lower = pow2 >> 1
        let nearest = (lower >= 1 && (target - lower) < (pow2 - target)) ? lower : pow2
        return max(minFFTSize, min(maxFFTSize, nearest))
    }

    let enabled = ManagedAtomic<Bool>(false)

    var onSnapshot: (([Float], [Float]) -> Void)?
    /// Post-EQ mono + stereo PCM + levels + correlation + balance. Analysis queue.
    var onWaveform: ((WaveformSnapshot) -> Void)?

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Spectrum")
    private let preRing = SampleRing(capacity: maxFFTSize)
    private let postRing = SampleRing(capacity: maxFFTSize)
    /// Interleaved L,R float pairs — single producer timeline for stereo meters.
    private let stereoRing = SampleRing(capacity: stereoRingFloatCapacity)
    private let queue = DispatchQueue(label: "com.sonarforge.audio.spectrum", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var processor: SpectrumProcessor?
    private var preWindow = [Float]()
    private var postWindow = [Float]()
    /// Rolling stereo history (newest at end), always equal length.
    private var leftWindow = [Float]()
    private var rightWindow = [Float]()
    private var scratch = [Float](repeating: 0, count: maxFFTSize)
    private var leftScratch = [Float](repeating: 0, count: waveformRingCapacity)
    private var rightScratch = [Float](repeating: 0, count: waveformRingCapacity)
    /// Contiguous FFT input windows (copied from ring tails; no `Array(suffix:)`).
    private var preFFTInput = [Float](repeating: 0, count: maxFFTSize)
    private var postFFTInput = [Float](repeating: 0, count: maxFFTSize)
    private var preBins = [Float]()
    private var postBins = [Float]()
    private var floorBins = [Float]()
    /// Reused PCM arrays for waveform publish (avoids 3×1024 allocs per tick).
    private var waveMono = [Float](repeating: 0, count: waveformDisplayCount)
    private var waveLeft = [Float](repeating: 0, count: waveformDisplayCount)
    private var waveRight = [Float](repeating: 0, count: waveformDisplayCount)
    private var currentFFTSize = minFFTSize

    // MARK: - Realtime side

    @inline(__always)
    func capturePre(_ samples: UnsafePointer<Float32>, frames: Int) {
        preRing.writeMonoFromInterleavedStereo(samples, frames: frames)
    }

    @inline(__always)
    func capturePost(_ samples: UnsafePointer<Float32>, frames: Int) {
        postRing.writeMonoFromInterleavedStereo(samples, frames: frames)
        stereoRing.writeInterleavedStereoFrames(samples, frames: frames)
    }

    // MARK: - Lifecycle

    func start(sampleRate: Double) {
        queue.async {
            let size = Self.fftSize(forSampleRate: sampleRate)
            self.currentFFTSize = size
            let processor = SpectrumProcessor(fftSize: size, sampleRate: sampleRate)
            self.processor = processor
            self.preWindow.removeAll(keepingCapacity: true)
            self.postWindow.removeAll(keepingCapacity: true)
            self.leftWindow.removeAll(keepingCapacity: true)
            self.rightWindow.removeAll(keepingCapacity: true)
            if let processor {
                self.preBins = [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
                self.postBins = self.preBins
                self.floorBins = self.preBins
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Self.updateRate)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer?.cancel()
            self.timer = timer
            self.logger.info(
                "Spectrum analysis started (\(size)-pt FFT @ \(sampleRate) Hz, wave=\(Self.waveformDisplayCount))"
            )
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.processor = nil
        }
    }

    // MARK: - Analysis

    private func tick() {
        guard enabled.load(ordering: .relaxed), let processor else { return }

        drainFFT(ring: preRing, into: &preWindow)
        drainFFT(ring: postRing, into: &postWindow)
        drainStereo()

        let size = currentFFTSize
        if preWindow.count >= size || postWindow.count >= size {
            let pre: [Float]
            if preWindow.count >= size {
                copyLast(size, from: preWindow, into: &preFFTInput)
                preFFTInput.withUnsafeBufferPointer { ptr in
                    _ = processor.process(
                        UnsafeBufferPointer(start: ptr.baseAddress!, count: size),
                        into: &preBins
                    )
                }
                pre = preBins
            } else {
                pre = floorBins
            }
            let post: [Float]
            if postWindow.count >= size {
                copyLast(size, from: postWindow, into: &postFFTInput)
                postFFTInput.withUnsafeBufferPointer { ptr in
                    _ = processor.process(
                        UnsafeBufferPointer(start: ptr.baseAddress!, count: size),
                        into: &postBins
                    )
                }
                post = postBins
            } else {
                post = floorBins
            }
            // Copy on publish so listeners can retain snapshots without racing
            // the next tick’s in-place bin buffers.
            onSnapshot?(Array(pre), Array(post))
        }

        publishWaveform()
    }

    /// Copies the last `count` samples of `source` into `dest[0..<count]`.
    private func copyLast(_ count: Int, from source: [Float], into dest: inout [Float]) {
        precondition(source.count >= count)
        if dest.count < count {
            dest = [Float](repeating: 0, count: count)
        }
        let start = source.count - count
        for i in 0..<count {
            dest[i] = source[start + i]
        }
    }

    private func drainFFT(ring: SampleRing, into window: inout [Float]) {
        let maxKeep = currentFFTSize
        let read = scratch.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, maxCount: min(maxKeep, ptr.count))
        }
        guard read > 0 else { return }
        window.append(contentsOf: scratch[0..<read])
        if window.count > maxKeep {
            window.removeFirst(window.count - maxKeep)
        }
    }

    private func drainStereo() {
        let maxKeep = Self.waveformDisplayCount * 2
        let frames = leftScratch.withUnsafeMutableBufferPointer { lp in
            rightScratch.withUnsafeMutableBufferPointer { rp in
                stereoRing.readStereoFrames(
                    left: lp.baseAddress!,
                    right: rp.baseAddress!,
                    maxFrames: min(maxKeep, lp.count)
                )
            }
        }
        guard frames > 0 else { return }
        leftWindow.append(contentsOf: leftScratch[0..<frames])
        rightWindow.append(contentsOf: rightScratch[0..<frames])
        if leftWindow.count > maxKeep {
            leftWindow.removeFirst(leftWindow.count - maxKeep)
            rightWindow.removeFirst(rightWindow.count - maxKeep)
        }
    }

    private func publishWaveform() {
        let n = Self.waveformDisplayCount
        guard leftWindow.count >= n, rightWindow.count == leftWindow.count else { return }

        // Newest N frames — lockstep L/R (no cross-ring realignment).
        let start = leftWindow.count - n
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var leftSq: Float = 0
        var rightSq: Float = 0
        var cross: Float = 0

        for i in 0..<n {
            let l = leftWindow[start + i]
            let r = rightWindow[start + i]
            waveLeft[i] = l
            waveRight[i] = r
            waveMono[i] = (l + r) * 0.5
            leftPeak = max(leftPeak, abs(l))
            rightPeak = max(rightPeak, abs(r))
            leftSq += l * l
            rightSq += r * r
            cross += l * r
        }

        let invN = 1 / Float(n)
        let leftRMS = sqrt(leftSq * invN)
        let rightRMS = sqrt(rightSq * invN)
        let denom = sqrt(leftSq * rightSq)
        // Pearson correlation; silent-channel pans → 0 (use balance for position).
        let correlation: Float = denom > 1e-12 ? max(-1, min(1, cross / denom)) : 0
        // Balance: −1 left … 0 center … +1 right (RMS energy).
        let sum = leftRMS + rightRMS
        let balance: Float = sum > 1e-9 ? max(-1, min(1, (rightRMS - leftRMS) / sum)) : 0

        // Copy into the snapshot so consumers own stable arrays while we reuse
        // waveMono/Left/Right on the next tick.
        onWaveform?(WaveformSnapshot(
            mono: Array(waveMono), left: Array(waveLeft), right: Array(waveRight),
            leftPeak: leftPeak, rightPeak: rightPeak,
            leftRMS: leftRMS, rightRMS: rightRMS,
            correlation: correlation,
            balance: balance
        ))
    }
}
