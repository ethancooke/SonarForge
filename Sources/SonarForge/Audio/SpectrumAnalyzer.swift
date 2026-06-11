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
    static let fftSize = 4096

    /// Written from any thread (UI toggle), read by the realtime block.
    let enabled = ManagedAtomic<Bool>(false)

    /// (preDB, postDB) display bins. Called on the analysis queue.
    var onSnapshot: (([Float], [Float]) -> Void)?

    private let logger = Logger(subsystem: "com.sonarforge.audio", category: "Spectrum")
    private let preRing = SampleRing(capacity: 16384)
    private let postRing = SampleRing(capacity: 16384)
    private let queue = DispatchQueue(label: "com.sonarforge.audio.spectrum", qos: .utility)

    // Analysis-queue state.
    private var timer: DispatchSourceTimer?
    private var processor: SpectrumProcessor?
    private var preWindow = [Float]()
    private var postWindow = [Float]()
    private var scratch = [Float](repeating: 0, count: fftSize)

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
            self.processor = SpectrumProcessor(fftSize: Self.fftSize, sampleRate: sampleRate)
            self.preWindow.removeAll(keepingCapacity: true)
            self.postWindow.removeAll(keepingCapacity: true)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Self.updateRate)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer?.cancel()
            self.timer = timer
            self.logger.info("Spectrum analysis started (\(Self.fftSize)-point FFT @ \(sampleRate) Hz, \(Self.updateRate) Hz updates)")
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

        guard preWindow.count >= Self.fftSize || postWindow.count >= Self.fftSize else { return }
        let pre = preWindow.count >= Self.fftSize
            ? processor.process(Array(preWindow.suffix(Self.fftSize)))
            : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
        let post = postWindow.count >= Self.fftSize
            ? processor.process(Array(postWindow.suffix(Self.fftSize)))
            : [Float](repeating: SpectrumProcessor.floorDB, count: processor.binCount)
        onSnapshot?(pre, post)
    }

    private func drain(ring: SampleRing, into window: inout [Float]) {
        let read = scratch.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, maxCount: Self.fftSize)
        }
        guard read > 0 else { return }
        window.append(contentsOf: scratch[0..<read])
        if window.count > Self.fftSize {
            window.removeFirst(window.count - Self.fftSize)
        }
    }
}
