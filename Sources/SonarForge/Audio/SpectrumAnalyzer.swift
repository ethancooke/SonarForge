import Foundation
import Atomics
import os.log

/// Bridges the realtime render path to FFT analysis (Chunk 3.1) and post-EQ
/// PCM (mono + stereo) for time-domain visuals.
///
/// Realtime side (`capturePre`/`capturePost`): lock-free ring writes only —
/// no allocations, no locks. Gated by `enabled`. Post writes separate FFT and
/// waveform rings so drains never starve each other.
///
/// Analysis side: timer on a utility queue → spectrum bins via `onSnapshot`
/// and a `WaveformSnapshot` via `onWaveform`.
final class SpectrumAnalyzer {

    static let updateRate = 20.0
    /// Samples published each tick (~21 ms @ 48 kHz).
    static let waveformDisplayCount = 1024
    static let waveformRingCapacity = 8192

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
    /// Post-EQ mono + stereo PCM + levels + correlation. Analysis queue.
    var onWaveform: ((WaveformSnapshot) -> Void)?

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Spectrum")
    private let preRing = SampleRing(capacity: maxFFTSize)
    private let postRing = SampleRing(capacity: maxFFTSize)
    private let waveMonoRing = SampleRing(capacity: waveformRingCapacity)
    private let waveLeftRing = SampleRing(capacity: waveformRingCapacity)
    private let waveRightRing = SampleRing(capacity: waveformRingCapacity)
    private let queue = DispatchQueue(label: "com.sonarforge.audio.spectrum", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var processor: SpectrumProcessor?
    private var preWindow = [Float]()
    private var postWindow = [Float]()
    private var monoWindow = [Float]()
    private var leftWindow = [Float]()
    private var rightWindow = [Float]()
    private var scratch = [Float](repeating: 0, count: maxFFTSize)
    private var waveScratch = [Float](repeating: 0, count: waveformRingCapacity)
    private var currentFFTSize = minFFTSize

    // MARK: - Realtime side

    @inline(__always)
    func capturePre(_ samples: UnsafePointer<Float32>, frames: Int) {
        preRing.writeMonoFromInterleavedStereo(samples, frames: frames)
    }

    @inline(__always)
    func capturePost(_ samples: UnsafePointer<Float32>, frames: Int) {
        postRing.writeMonoFromInterleavedStereo(samples, frames: frames)
        waveMonoRing.writeMonoFromInterleavedStereo(samples, frames: frames)
        waveLeftRing.writeChannelFromInterleavedStereo(samples, frames: frames, channel: 0)
        waveRightRing.writeChannelFromInterleavedStereo(samples, frames: frames, channel: 1)
    }

    // MARK: - Lifecycle

    func start(sampleRate: Double) {
        queue.async {
            let size = Self.fftSize(forSampleRate: sampleRate)
            self.currentFFTSize = size
            self.processor = SpectrumProcessor(fftSize: size, sampleRate: sampleRate)
            self.preWindow.removeAll(keepingCapacity: true)
            self.postWindow.removeAll(keepingCapacity: true)
            self.monoWindow.removeAll(keepingCapacity: true)
            self.leftWindow.removeAll(keepingCapacity: true)
            self.rightWindow.removeAll(keepingCapacity: true)

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
        drainWave(ring: waveMonoRing, into: &monoWindow)
        drainWave(ring: waveLeftRing, into: &leftWindow)
        drainWave(ring: waveRightRing, into: &rightWindow)

        let size = currentFFTSize
        if preWindow.count >= size || postWindow.count >= size {
            let pre = preWindow.count >= size
                ? processor.process(Array(preWindow.suffix(size)))
                : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
            let post = postWindow.count >= size
                ? processor.process(Array(postWindow.suffix(size)))
                : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
            onSnapshot?(pre, post)
        }

        publishWaveform()
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

    private func drainWave(ring: SampleRing, into window: inout [Float]) {
        let maxKeep = Self.waveformDisplayCount * 2
        let read = waveScratch.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, maxCount: min(maxKeep, ptr.count))
        }
        guard read > 0 else { return }
        window.append(contentsOf: waveScratch[0..<read])
        if window.count > maxKeep {
            window.removeFirst(window.count - maxKeep)
        }
    }

    private func publishWaveform() {
        let n = Self.waveformDisplayCount
        guard monoWindow.count >= n, leftWindow.count >= n, rightWindow.count >= n else { return }

        // Align mono (and L/R with same offset) to a rising zero-crossing.
        let start = Self.triggerIndex(in: monoWindow, length: n)
        // Keep L/R in time with mono: use the same relative offset from the end.
        let monoEndOffset = monoWindow.count - start - n
        let leftStart = max(0, leftWindow.count - n - monoEndOffset)
        let rightStart = max(0, rightWindow.count - n - monoEndOffset)
        guard leftStart + n <= leftWindow.count, rightStart + n <= rightWindow.count else { return }

        var mono = [Float](repeating: 0, count: n)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var leftSq: Float = 0
        var rightSq: Float = 0
        var cross: Float = 0

        for i in 0..<n {
            let m = monoWindow[start + i]
            let l = leftWindow[leftStart + i]
            let r = rightWindow[rightStart + i]
            mono[i] = m
            left[i] = l
            right[i] = r
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
        let correlation: Float = denom > 1e-12 ? max(-1, min(1, cross / denom)) : 0

        onWaveform?(WaveformSnapshot(
            mono: mono, left: left, right: right,
            leftPeak: leftPeak, rightPeak: rightPeak,
            leftRMS: leftRMS, rightRMS: rightRMS,
            correlation: correlation
        ))
    }

    private static func triggerIndex(in samples: [Float], length: Int) -> Int {
        let end = samples.count
        let searchStart = max(0, end - length * 2)
        let searchEnd = end - length
        guard searchEnd > searchStart + 1 else {
            return max(0, end - length)
        }
        var i = searchEnd - 1
        while i > searchStart {
            if samples[i - 1] <= 0 && samples[i] > 0 {
                return i
            }
            i -= 1
        }
        return max(0, end - length)
    }
}
