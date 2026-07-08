import XCTest
@testable import SonarForge

final class CrossfeedTests: XCTestCase {

    let fs = 48000.0

    /// Builds an interleaved stereo buffer from per-channel sample generators.
    private func makeStereo(frames: Int, left: (Int) -> Double, right: (Int) -> Double) -> [Float32] {
        var buffer = [Float32](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            buffer[f * 2] = Float32(left(f))
            buffer[f * 2 + 1] = Float32(right(f))
        }
        return buffer
    }

    private func process(_ crossfeed: Crossfeed, _ buffer: inout [Float32]) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            crossfeed.processStereoInterleaved(ptr.baseAddress!, frameCount: ptr.count / 2)
        }
    }

    /// Disabled crossfeed must be an exact pass-through (bypass honesty).
    func testDisabledIsPassThrough() {
        let crossfeed = Crossfeed()
        crossfeed.prepare(sampleRate: fs)
        crossfeed.setAmount(0.6)
        crossfeed.setEnabled(false)

        let original = makeStereo(frames: 512,
                                  left: { sin(2.0 * .pi * 440 * Double($0) / self.fs) },
                                  right: { sin(2.0 * .pi * 880 * Double($0) / self.fs) })
        var buffer = original
        process(crossfeed, &buffer)

        XCTAssertEqual(buffer, original, "Disabled crossfeed altered the samples")
    }

    /// A mono (centered) signal must pass through untouched for any amount:
    /// L == R in ⇒ L == R out, and each sample unchanged. This is the core
    /// tonal-neutrality guarantee of the complementary-filter design.
    func testMonoIsToneNeutral() {
        for amount in [0.0, 0.3, 0.6, 1.0] {
            let crossfeed = Crossfeed()
            crossfeed.prepare(sampleRate: fs)
            crossfeed.setAmount(amount)
            crossfeed.setEnabled(true)

            let mono: (Int) -> Double = { 0.3 * sin(2.0 * .pi * 200 * Double($0) / self.fs) }
            let original = makeStereo(frames: 2048, left: mono, right: mono)
            var buffer = original
            process(crossfeed, &buffer)

            // Allow only float round-trip error from the double-precision internals.
            for i in 0..<buffer.count {
                XCTAssertEqual(Double(buffer[i]), Double(original[i]), accuracy: 1e-5,
                               "Mono sample \(i) changed at amount \(amount)")
            }
        }
    }

    /// With a hard-panned low tone (energy only in L), enabling crossfeed must
    /// bleed audible low-frequency energy into the previously-silent R channel.
    func testCrossfeedBleedsLowsToOppositeChannel() {
        let crossfeed = Crossfeed()
        crossfeed.prepare(sampleRate: fs)
        crossfeed.setAmount(1.0)   // maximum blend
        crossfeed.setEnabled(true)

        // 150 Hz is well below the 700 Hz crossover, so it should cross over.
        var buffer = makeStereo(frames: 4096,
                                left: { 0.4 * sin(2.0 * .pi * 150 * Double($0) / self.fs) },
                                right: { _ in 0 })
        process(crossfeed, &buffer)

        // Measure the back half so the bleed ramp has settled.
        let settle = 2048
        var rightEnergy = 0.0
        var leftEnergy = 0.0
        var frame = settle
        while frame * 2 + 1 < buffer.count {
            rightEnergy += Double(buffer[frame * 2 + 1]) * Double(buffer[frame * 2 + 1])
            leftEnergy += Double(buffer[frame * 2]) * Double(buffer[frame * 2])
            frame += 1
        }
        XCTAssertGreaterThan(rightEnergy, 0.01, "No low-frequency energy crossed to the right channel")
        XCTAssertGreaterThan(leftEnergy, 0.0, "Left channel unexpectedly emptied")
    }

    /// A hard-panned *high* tone must keep near-full separation (the far ear
    /// stays quiet), matching real head-shadowing.
    func testHighsKeepSeparation() {
        let crossfeed = Crossfeed()
        crossfeed.prepare(sampleRate: fs)
        crossfeed.setAmount(1.0)
        crossfeed.setEnabled(true)

        // 8 kHz is far above the crossover — the low-pass crossfeed path is ~0.
        var buffer = makeStereo(frames: 4096,
                                left: { 0.4 * sin(2.0 * .pi * 8000 * Double($0) / self.fs) },
                                right: { _ in 0 })
        process(crossfeed, &buffer)

        let settle = 2048
        var rightEnergy = 0.0
        var leftEnergy = 0.0
        var frame = settle
        while frame * 2 + 1 < buffer.count {
            rightEnergy += Double(buffer[frame * 2 + 1]) * Double(buffer[frame * 2 + 1])
            leftEnergy += Double(buffer[frame * 2]) * Double(buffer[frame * 2])
            frame += 1
        }
        // The far-ear high-frequency leakage should be a tiny fraction of the near ear.
        XCTAssertLessThan(rightEnergy, leftEnergy * 0.05,
                          "High-frequency content leaked across channels")
    }

    /// The output must never contain NaN/Inf regardless of settings.
    func testProducesFiniteOutput() {
        let crossfeed = Crossfeed()
        crossfeed.prepare(sampleRate: fs)
        crossfeed.setAmount(1.0)
        crossfeed.setEnabled(true)

        var buffer = makeStereo(frames: 1024,
                                left: { _ in Double.random(in: -1...1) },
                                right: { _ in Double.random(in: -1...1) })
        process(crossfeed, &buffer)

        XCTAssertTrue(buffer.allSatisfy { $0.isFinite }, "Crossfeed produced a non-finite sample")
    }
}
