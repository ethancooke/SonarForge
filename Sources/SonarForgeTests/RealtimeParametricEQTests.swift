import XCTest
@testable import SonarForge

final class RealtimeParametricEQTests: XCTestCase {

    let fs = 48000.0

    /// RMS of one channel of an interleaved stereo buffer, skipping `settle` frames.
    private func rms(_ buffer: [Float32], channel: Int, settle: Int) -> Double {
        var sum = 0.0
        var count = 0
        var frame = settle
        while frame * 2 + channel < buffer.count {
            let v = Double(buffer[frame * 2 + channel])
            sum += v * v
            count += 1
            frame += 1
        }
        return sqrt(sum / Double(max(count, 1)))
    }

    private func makeStereoSine(frequency: Double, frames: Int, amplitude: Double = 0.25) -> [Float32] {
        var buffer = [Float32](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let v = Float32(amplitude * sin(2.0 * .pi * frequency * Double(f) / fs))
            buffer[f * 2] = v
            buffer[f * 2 + 1] = v
        }
        return buffer
    }

    func testZeroBandsLeavesBufferUntouched() {
        let eq = RealtimeParametricEQ()
        eq.drainCommands()
        var buffer = makeStereoSine(frequency: 1000, frames: 4096)
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: 4096)
        }
        XCTAssertEqual(buffer, original, "no active bands must be bit-identical")
    }

    /// End-to-end gain staging: a +3 dBFS 1 kHz tone through a freshly created
    /// profile with +2 dB peaking @ 1 kHz must read +5 dBFS at the output.
    func testProfilePlusTwoDBOnThreeDBToneYieldsFiveDB() {
        let profile = EQProfile(
            id: UUID(),
            name: "Test +2 @ 1 kHz",
            preamp: 0,
            bands: [EQBand(type: .peaking, frequency: 1000, gain: 2, q: 1.0)],
            isFavorite: false,
            sourceAttribution: nil,
            notes: "Automated EQ application test"
        )

        let eq = RealtimeParametricEQ()
        eq.apply(bands: profile.bands, sampleRate: fs)
        eq.drainCommands()

        let inputDBFS = 3.0
        let inputPeak = Double(GainMath.linearGain(fromDB: inputDBFS))
        let frames = 48000
        var buffer = makeStereoSine(frequency: 1000, frames: frames, amplitude: inputPeak)
        let inputRMS = rms(buffer, channel: 0, settle: 4800)

        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: frames)
        }

        let outputRMS = rms(buffer, channel: 0, settle: 4800)
        // Sine peak ≈ RMS × √2; dBFS is referenced to full-scale peak (1.0).
        let outputPeakDBFS = 20 * log10(outputRMS * sqrt(2.0))
        let eqContributionDB = 20 * log10(outputRMS / inputRMS)

        XCTAssertEqual(eqContributionDB, 2.0, accuracy: 0.2, "EQ adds +2 dB at 1 kHz")
        XCTAssertEqual(outputPeakDBFS, 5.0, accuracy: 0.3,
                       "+3 dBFS input + +2 dB EQ @ 1 kHz → +5 dBFS output (profile: \(profile.name))")
    }

    /// Same scenario verified through the spectrum analyzer path (pre/post tap
    /// equivalent): FFT of the EQ'd tone must peak at ~+5 dBFS near 1 kHz.
    func testSpectrumConfirmsFiveDBAfterProfileApplied() throws {
        let profile = EQProfile(
            id: UUID(),
            name: "Spectrum Verify +2 @ 1 kHz",
            preamp: 0,
            bands: [EQBand(type: .peaking, frequency: 1000, gain: 2, q: 1.0)],
            isFavorite: false
        )

        let eq = RealtimeParametricEQ()
        eq.apply(bands: profile.bands, sampleRate: fs)
        eq.drainCommands()

        let fftSize = 4096
        let inputPeak = Double(GainMath.linearGain(fromDB: 3.0))
        var buffer = makeStereoSine(frequency: 1000, frames: fftSize, amplitude: inputPeak)
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: fftSize)
        }

        let mono = (0..<fftSize).map { buffer[$0 * 2] }
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: fftSize, sampleRate: fs, binCount: 64))
        let bins = processor.process(mono)
        let peakIndex = try XCTUnwrap(bins.indices.max(by: { bins[$0] < bins[$1] }))
        let peakFrequency = processor.binCenterFrequencies[peakIndex]

        XCTAssertEqual(Double(peakFrequency), 1000, accuracy: 150, "peak lands near 1 kHz")
        XCTAssertEqual(bins[peakIndex], 5.0, accuracy: 1.5,
                       "spectrum reads +5 dBFS after +3 dB tone + +2 dB EQ profile")
    }

    func testSineThroughPeakingMatchesAnalyticGain() {
        let eq = RealtimeParametricEQ()
        let band = EQBand(type: .peaking, frequency: 1000, gain: 6, q: 1.0)
        eq.apply(bands: [band], sampleRate: fs)
        eq.drainCommands()

        let frames = 48000
        var buffer = makeStereoSine(frequency: 1000, frames: frames)
        let inputRMS = rms(buffer, channel: 0, settle: 4800)
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: frames)
        }
        let outputRMS = rms(buffer, channel: 0, settle: 4800)

        let gainDB = 20 * log10(outputRMS / inputRMS)
        XCTAssertEqual(gainDB, 6.0, accuracy: 0.2, "1 kHz sine through +6 dB @ 1 kHz peaking")
    }

    func testSineOutsidePeakingBandIsUnaffected() {
        let eq = RealtimeParametricEQ()
        let band = EQBand(type: .peaking, frequency: 4000, gain: 12, q: 4.0)
        eq.apply(bands: [band], sampleRate: fs)
        eq.drainCommands()

        let frames = 48000
        var buffer = makeStereoSine(frequency: 100, frames: frames)
        let inputRMS = rms(buffer, channel: 0, settle: 4800)
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: frames)
        }
        let outputRMS = rms(buffer, channel: 0, settle: 4800)

        let gainDB = 20 * log10(outputRMS / inputRMS)
        XCTAssertEqual(gainDB, 0.0, accuracy: 0.1, "100 Hz sine far below a narrow 4 kHz boost")
    }

    func testCascadedBandsSumTheirResponses() {
        let eq = RealtimeParametricEQ()
        let bands = [
            EQBand(type: .peaking, frequency: 1000, gain: 3, q: 1.0),
            EQBand(type: .peaking, frequency: 1000, gain: 3, q: 1.0),
        ]
        eq.apply(bands: bands, sampleRate: fs)
        eq.drainCommands()

        let frames = 48000
        var buffer = makeStereoSine(frequency: 1000, frames: frames)
        let inputRMS = rms(buffer, channel: 0, settle: 4800)
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: frames)
        }
        let gainDB = 20 * log10(rms(buffer, channel: 0, settle: 4800) / inputRMS)
        XCTAssertEqual(gainDB, 6.0, accuracy: 0.3, "two +3 dB bands in series ≈ +6 dB")
    }

    func testChannelsAreIndependent() {
        let eq = RealtimeParametricEQ()
        eq.apply(bands: [EQBand(type: .peaking, frequency: 1000, gain: 6, q: 1.0)], sampleRate: fs)
        eq.drainCommands()

        // Left = 1 kHz sine, right = silence. Right must stay silent.
        let frames = 8192
        var buffer = [Float32](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            buffer[f * 2] = Float32(0.25 * sin(2.0 * .pi * 1000 * Double(f) / fs))
        }
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: frames)
        }
        let rightRMS = rms(buffer, channel: 1, settle: 0)
        XCTAssertLessThan(rightRMS, 1e-9, "no crosstalk between channels")
    }

    func testReducingBandCountDisablesUpperBands() {
        let eq = RealtimeParametricEQ()
        eq.apply(bands: [
            EQBand(type: .peaking, frequency: 1000, gain: 12, q: 1.0),
            EQBand(type: .peaking, frequency: 1000, gain: 12, q: 1.0),
        ], sampleRate: fs)
        eq.drainCommands()
        // Now shrink to zero bands — buffer must pass through untouched.
        eq.apply(bands: [], sampleRate: fs)
        eq.drainCommands()

        var buffer = makeStereoSine(frequency: 1000, frames: 4096)
        let original = buffer
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: 4096)
        }
        XCTAssertEqual(buffer, original)
    }

    func testManyApplyCallsDoNotStallOrCorrupt() {
        let eq = RealtimeParametricEQ()
        // Push far more profile swaps than the ring holds, draining between some
        // of them, to exercise wraparound. The producer must never deadlock
        // (push sleeps when full and the drain below frees space).
        let drainExpectation = expectation(description: "producer finished")
        let producer = Thread {
            for i in 0..<200 {
                let gain = Double(i % 24) - 12.0
                eq.apply(bands: [EQBand(type: .peaking, frequency: 1000, gain: gain, q: 1.0)], sampleRate: self.fs)
            }
            drainExpectation.fulfill()
        }
        producer.start()
        // Simulate the RT thread draining periodically.
        for _ in 0..<400 {
            eq.drainCommands()
            usleep(200)
        }
        wait(for: [drainExpectation], timeout: 10)
        eq.drainCommands()

        // After the dust settles the EQ must still process sanely.
        var buffer = makeStereoSine(frequency: 1000, frames: 4096)
        buffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: 4096)
        }
        for v in buffer {
            XCTAssertFalse(v.isNaN)
            XCTAssertFalse(v.isInfinite)
        }
    }

    // MARK: - Performance

    /// Chunk 2.1 CPU target: < 1–2 % of one core for 8–12 bands at 48 kHz.
    /// Processing 10 s of audio must therefore take well under 0.2 s wall time.
    func testTwelveBandPerformanceTarget() {
        let eq = RealtimeParametricEQ()
        let bands = (0..<12).map { i in
            EQBand(type: .peaking, frequency: 60.0 * pow(2.0, Double(i) * 0.8), gain: i % 2 == 0 ? 4 : -4, q: 1.4)
        }
        eq.apply(bands: bands, sampleRate: fs)
        eq.drainCommands()

        let seconds = 10
        let blockFrames = 512
        let blocks = (48000 * seconds) / blockFrames
        // Refill from a template each block: re-processing the same buffer would
        // compound the bands' net gain exponentially until Float32 overflows.
        let template = makeStereoSine(frequency: 440, frames: blockFrames)
        var buffer = template

        let start = Date()
        buffer.withUnsafeMutableBufferPointer { ptr in
            template.withUnsafeBufferPointer { t in
                for _ in 0..<blocks {
                    ptr.baseAddress!.update(from: t.baseAddress!, count: blockFrames * 2)
                    eq.processStereoInterleaved(ptr.baseAddress!, frameCount: blockFrames)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let percentOfRealtime = elapsed / Double(seconds) * 100.0
        print("12-band EQ: \(String(format: "%.3f", elapsed))s for \(seconds)s of 48 kHz stereo → \(String(format: "%.2f", percentOfRealtime))% of realtime")

        // The < 1–2 % chunk target applies to optimized (Release) builds — measured
        // 0.2 % there (see AUDIO_PATH.md). Debug builds carry ~20× overhead from
        // bounds checks and disabled inlining, so this assertion is a loose
        // regression guard, not the performance target.
        XCTAssertLessThan(percentOfRealtime, 15.0, "12-band cost regressed an order of magnitude")

        for v in buffer {
            XCTAssertFalse(v.isNaN)
        }
    }
}
