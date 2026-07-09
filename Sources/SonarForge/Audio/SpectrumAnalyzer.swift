import Foundation
import Atomics
import os.log

/// Bridges the realtime render path to FFT analysis (Chunk 3.1).
///
/// Realtime side (`capturePre`/`capturePost`): mixes the stereo buffer to mono
/// into lock-free rings — no allocations, no locks. Gated by the `enabled`
/// atomic, which the IO block reads once per cycle.
///
/// Analysis side: a 30 Hz timer on a utility queue drains the rings into
/// rolling windows and, when a full FFT window is available, computes display
/// bins via `SpectrumProcessor` and reports them through `onSnapshot`
/// (delivered on the analysis queue; the observer hops to the main actor).
final class SpectrumAnalyzer {

    static let updateRate = 20.0   // Hz — plenty for a line spectrum; halves UI redraw cost

    /// Target FFT bin spacing. The FFT window is sized per sample rate to hold
    /// this resolution (~0.34 s window), so the low end has enough bins to fill
    /// the log-spaced display at any rate — a fixed 4096-point FFT starved
    /// everything below ~80 Hz into a flat line, badly so at 96 kHz (D-013).
    static let targetHzPerBin = 2.93
    static let minFFTSize = 4096
    /// Upper bound (supports up to ~192 kHz at target resolution); also the
    /// preallocated ring/scratch size, so nothing reallocates while audio runs.
    static let maxFFTSize = 65536

    /// Nearest power-of-two FFT size for a sample rate, clamped to the supported
    /// range. Rounds to *nearest* (not up) so 48 kHz lands on 16384 rather than
    /// overshooting to 32768 and doubling the window latency.
    static func fftSize(forSampleRate sampleRate: Double) -> Int {
        let target = Int((max(sampleRate, 1) / targetHzPerBin).rounded())
        var pow2 = 1
        while pow2 < target { pow2 <<= 1 }
        let lower = pow2 >> 1
        let nearest = (lower >= 1 && (target - lower) < (pow2 - target)) ? lower : pow2
        return max(minFFTSize, min(maxFFTSize, nearest))
    }

    /// Written from any thread (UI toggle), read by the realtime block.
    let enabled = ManagedAtomic<Bool>(false)

    /// (preDB, postDB) display bins. Called on the analysis queue.
    var onSnapshot: (([Float], [Float]) -> Void)?

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Spectrum")
    private let preRing = SampleRing(capacity: maxFFTSize)
    private let postRing = SampleRing(capacity: maxFFTSize)
    private let queue = DispatchQueue(label: "com.sonarforge.audio.spectrum", qos: .utility)

    // Analysis-queue state.
    private var timer: DispatchSourceTimer?
    private var processor: SpectrumProcessor?
    private var preWindow = [Float]()
    private var postWindow = [Float]()
    private var scratch = [Float](repeating: 0, count: maxFFTSize)
    /// FFT window length for the current sample rate (set in `start`).
    private var currentFFTSize = minFFTSize

    // MARK: - Realtime side

    @inline(__always)
    func capturePre(_ samples: UnsafePointer<Float32>, frames: Int) {
        preRing.writeMonoFromInterleavedStereo(samples, frames: frames)
    }

    @inline(__always)
    func capturePost(_ samples: UnsafePointer<Float32>, frames: Int) {
        postRing.writeMonoFromInterleavedStereo(samples, frames: frames)
    }

    // MARK: - Lifecycle (engine control queue)

    func start(sampleRate: Double) {
        queue.async {
            let size = Self.fftSize(forSampleRate: sampleRate)
            self.currentFFTSize = size
            self.processor = SpectrumProcessor(fftSize: size, sampleRate: sampleRate)
            self.preWindow.removeAll(keepingCapacity: true)
            self.postWindow.removeAll(keepingCapacity: true)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Self.updateRate)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer?.cancel()
            self.timer = timer
            self.logger.info("Spectrum analysis started (\(size)-point FFT @ \(sampleRate) Hz, \(Self.updateRate) Hz updates)")
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.processor = nil
        }
    }

    // MARK: - Analysis (analysis queue only)

    private func tick() {
        guard enabled.load(ordering: .relaxed), let processor else { return }

        drain(ring: preRing, into: &preWindow)
        drain(ring: postRing, into: &postWindow)

        let size = currentFFTSize
        guard preWindow.count >= size || postWindow.count >= size else { return }
        let pre = preWindow.count >= size
            ? processor.process(Array(preWindow.suffix(size)))
            : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
        let post = postWindow.count >= size
            ? processor.process(Array(postWindow.suffix(size)))
            : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
        onSnapshot?(pre, post)
    }

    private func drain(ring: SampleRing, into window: inout [Float]) {
        let size = currentFFTSize
        let read = scratch.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, maxCount: size)
        }
        guard read > 0 else { return }
        window.append(contentsOf: scratch[0..<read])
        if window.count > size {
            window.removeFirst(window.count - size)
        }
    }
}
