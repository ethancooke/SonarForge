import XCTest
@testable import SonarForge

final class SampleRingTests: XCTestCase {

    func testMonoMixdownRoundTrip() {
        let ring = SampleRing(capacity: 1024)
        // Interleaved stereo: L = 0.4, R = 0.2 → mono 0.3
        var stereo = [Float32](repeating: 0, count: 200)
        for f in 0..<100 {
            stereo[f * 2] = 0.4
            stereo[f * 2 + 1] = 0.2
        }
        stereo.withUnsafeBufferPointer { ring.writeMonoFromInterleavedStereo($0.baseAddress!, frames: 100) }

        var out = [Float](repeating: 0, count: 256)
        let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 256) }
        XCTAssertEqual(read, 100)
        for i in 0..<read {
            XCTAssertEqual(out[i], 0.3, accuracy: 1e-6)
        }
    }

    func testOverflowDropsWithoutCorruption() {
        let ring = SampleRing(capacity: 64)   // rounds to 64
        var stereo = [Float32](repeating: 0, count: 400)
        for f in 0..<200 {
            stereo[f * 2] = Float32(f)
            stereo[f * 2 + 1] = Float32(f)
        }
        stereo.withUnsafeBufferPointer { ring.writeMonoFromInterleavedStereo($0.baseAddress!, frames: 200) }

        var out = [Float](repeating: 0, count: 256)
        let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 256) }
        XCTAssertEqual(read, 64, "only capacity samples kept; the rest dropped")
        for i in 0..<read {
            XCTAssertEqual(out[i], Float(i), accuracy: 1e-6, "kept samples are the oldest, in order")
        }
    }

    func testWraparoundPreservesOrder() {
        let ring = SampleRing(capacity: 64)
        var out = [Float](repeating: 0, count: 64)
        var expected: Float = 0

        for chunk in 0..<10 {
            var stereo = [Float32](repeating: 0, count: 48 * 2)
            for f in 0..<48 {
                let v = Float32(chunk * 48 + f)
                stereo[f * 2] = v
                stereo[f * 2 + 1] = v
            }
            stereo.withUnsafeBufferPointer { ring.writeMonoFromInterleavedStereo($0.baseAddress!, frames: 48) }

            let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: 64) }
            for i in 0..<read {
                XCTAssertEqual(out[i], expected, accuracy: 1e-6)
                expected += 1
            }
        }
    }
}

final class SpectrumProcessorTests: XCTestCase {

    private func sine(frequency: Double, amplitude: Float, count: Int, sampleRate: Double) -> [Float] {
        (0..<count).map { Float(Double(amplitude) * sin(2.0 * .pi * frequency * Double($0) / sampleRate)) }
    }

    func testFullScaleSineReadsZeroDBAtItsFrequency() throws {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: 4096, sampleRate: 48000, binCount: 64))
        let bins = processor.process(sine(frequency: 1000, amplitude: 1.0, count: 4096, sampleRate: 48000))

        let peakIndex = try XCTUnwrap(bins.indices.max(by: { bins[$0] < bins[$1] }))
        let peakFrequency = processor.binCenterFrequencies[peakIndex]
        // Bins are log-spaced (~11% wide at 64 bins) — peak must land in the right bin.
        XCTAssertEqual(Double(peakFrequency), 1000, accuracy: 1000 * 0.15)
        XCTAssertEqual(bins[peakIndex], 0.0, accuracy: 1.5, "full-scale sine ≈ 0 dBFS")
    }

    func testAmplitudeMapsToDB() throws {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: 4096, sampleRate: 48000, binCount: 64))
        let bins = processor.process(sine(frequency: 2000, amplitude: 0.1, count: 4096, sampleRate: 48000))
        let peak = try XCTUnwrap(bins.max())
        XCTAssertEqual(peak, -20.0, accuracy: 1.5, "amplitude 0.1 ≈ −20 dBFS")
    }

    func testSilenceReadsFloor() throws {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: 4096, sampleRate: 48000, binCount: 64))
        let bins = processor.process([Float](repeating: 0, count: 4096))
        XCTAssertTrue(bins.allSatisfy { $0 == SpectrumProcessor.floorDB })
    }

    func testFrequenciesAwayFromToneStayLow() throws {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: 4096, sampleRate: 48000, binCount: 64))
        let bins = processor.process(sine(frequency: 1000, amplitude: 1.0, count: 4096, sampleRate: 48000))
        // Two octaves away the Hann leakage should be far below the peak.
        for (i, center) in processor.binCenterFrequencies.enumerated()
        where center < 250 || center > 4000 {
            XCTAssertLessThan(bins[i], -40, "leakage at \(center) Hz")
        }
    }

    func testBinCentersSpanAudioBand() throws {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: 4096, sampleRate: 48000, binCount: 64))
        let centers = processor.binCenterFrequencies
        XCTAssertEqual(centers.count, 64)
        XCTAssertGreaterThan(centers.first!, 19)
        XCTAssertLessThan(centers.last!, 20001)
        XCTAssertTrue(zip(centers, centers.dropFirst()).allSatisfy { $0 < $1 }, "monotonic")
    }

    func testRejectsInvalidConfiguration() {
        XCTAssertNil(SpectrumProcessor(fftSize: 1000, sampleRate: 48000, binCount: 64), "non power of two")
        XCTAssertNil(SpectrumProcessor(fftSize: 4096, sampleRate: 0, binCount: 64))
    }

    /// Verifies the pre/post spectrum overlay for the Bass Boost preset: with
    /// 0 dB preamp, post should sit above pre in the bass and match elsewhere.
    func testBassBoostPostTraceRisesInBass() throws {
        let profile = try XCTUnwrap(EQProfile.canonicalFactory(id: FactoryPresetID.bassBoost))
        let fs = 48000.0
        let fftSize = 4096

        let eq = RealtimeParametricEQ()
        eq.apply(bands: profile.bands, sampleRate: fs)
        eq.drainCommands()
        let preampLinear = GainMath.linearGain(fromDB: profile.preamp)

        let toneFrequencies = [50.0, 500.0, 2000.0, 8000.0]
        let perToneAmplitude = 0.1
        var buffer = [Float32](repeating: 0, count: fftSize * 2)
        for frame in 0..<fftSize {
            var sample = 0.0
            for frequency in toneFrequencies {
                sample += perToneAmplitude * sin(2.0 * .pi * frequency * Double(frame) / fs)
            }
            let value = Float32(sample / Double(toneFrequencies.count))
            buffer[frame * 2] = value
            buffer[frame * 2 + 1] = value
        }

        let preMono = (0..<fftSize).map { buffer[$0 * 2] }
        var postBuffer = buffer
        postBuffer.withUnsafeMutableBufferPointer { ptr in
            eq.processStereoInterleaved(ptr.baseAddress!, frameCount: fftSize)
        }
        for i in 0..<postBuffer.count { postBuffer[i] *= preampLinear }

        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: fftSize, sampleRate: fs, binCount: 64))
        let preBins = processor.process(preMono)
        let postBins = processor.process((0..<fftSize).map { postBuffer[$0 * 2] })

        func nearestBin(to frequency: Float) -> Int {
            processor.binCenterFrequencies.enumerated()
                .min(by: { abs($0.1 - frequency) < abs($1.1 - frequency) })!.0
        }

        let bassDelta = postBins[nearestBin(to: 50)] - preBins[nearestBin(to: 50)]
        let midDelta = postBins[nearestBin(to: 2000)] - preBins[nearestBin(to: 2000)]

        XCTAssertEqual(bassDelta, 6, accuracy: 2.5, "bass bins: post ~6 dB above pre")
        XCTAssertEqual(midDelta, 0, accuracy: 2.5, "mid bins: post ≈ pre")
        XCTAssertGreaterThan(bassDelta, midDelta, "post trace rises in the bass vs pre")
    }
}

/// Adaptive FFT sizing (D-013): the window scales with sample rate so the low
/// end keeps real resolution instead of collapsing to a flat line.
final class AdaptiveFFTSizeTests: XCTestCase {

    func testFFTSizeMapping() {
        // 48/44.1 kHz → 16384, 88.2/96 kHz → 32768, 192 kHz → 65536.
        XCTAssertEqual(SpectrumAnalyzer.fftSize(forSampleRate: 44100), 16384)
        XCTAssertEqual(SpectrumAnalyzer.fftSize(forSampleRate: 48000), 16384)
        XCTAssertEqual(SpectrumAnalyzer.fftSize(forSampleRate: 88200), 32768)
        XCTAssertEqual(SpectrumAnalyzer.fftSize(forSampleRate: 96000), 32768)
        XCTAssertEqual(SpectrumAnalyzer.fftSize(forSampleRate: 192000), 65536)
    }

    func testFFTSizeAlwaysPowerOfTwoAndClamped() {
        for sr in stride(from: 8000.0, through: 384000.0, by: 1000.0) {
            let size = SpectrumAnalyzer.fftSize(forSampleRate: sr)
            XCTAssertTrue(size & (size - 1) == 0, "\(size) not a power of two at \(sr) Hz")
            XCTAssertGreaterThanOrEqual(size, SpectrumAnalyzer.minFFTSize)
            XCTAssertLessThanOrEqual(size, SpectrumAnalyzer.maxFFTSize)
        }
    }

    /// The regression this fixes: at 96 kHz a fixed 4096-point FFT starved the
    /// sub-100 Hz display bins, so a 40 Hz and a 60 Hz tone landed on the *same*
    /// display bin (a flat line). With the adaptive size they resolve to
    /// distinct bins near their true frequencies.
    func testLowFrequencyTonesResolveAt96k() throws {
        let fs = 96000.0
        let size = SpectrumAnalyzer.fftSize(forSampleRate: fs)
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: size, sampleRate: fs, binCount: 64))

        func peakBin(forTone frequency: Double) -> Int {
            let samples = (0..<size).map { Float(0.5 * sin(2.0 * .pi * frequency * Double($0) / fs)) }
            let bins = processor.process(samples)
            return bins.indices.max(by: { bins[$0] < bins[$1] })!
        }

        let bin40 = peakBin(forTone: 40)
        let bin60 = peakBin(forTone: 60)

        XCTAssertNotEqual(bin40, bin60, "40 Hz and 60 Hz collapsed onto the same display bin")
        XCTAssertEqual(Double(processor.binCenterFrequencies[bin40]), 40, accuracy: 12,
                       "40 Hz tone peaked far from 40 Hz")
        XCTAssertEqual(Double(processor.binCenterFrequencies[bin60]), 60, accuracy: 12,
                       "60 Hz tone peaked far from 60 Hz")
    }

    /// Deterministic white noise so every FFT bin carries energy; then two
    /// adjacent display bins are *exactly* equal only when they were forced to
    /// read the same FFT bin (the plateau that looks like a flat line).
    private func whiteNoise(count: Int) -> [Float] {
        var state: UInt64 = 0x1234_5678_9abc_def0
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max) * 0.5
        }
    }

    /// Counts adjacent, identical-valued display-bin pairs whose centers fall
    /// below `maxHz` — i.e. the width of the low-frequency plateau.
    private func lowPlateauPairs(fftSize: Int, sampleRate: Double, maxHz: Float = 80) throws -> Int {
        let processor = try XCTUnwrap(SpectrumProcessor(fftSize: fftSize, sampleRate: sampleRate, binCount: 64))
        let bins = processor.process(whiteNoise(count: fftSize))
        let centers = processor.binCenterFrequencies
        var pairs = 0
        for i in 0..<(bins.count - 1) where centers[i] < maxHz && centers[i + 1] < maxHz {
            if bins[i] == bins[i + 1] { pairs += 1 }
        }
        return pairs
    }

    /// The regression: a fixed 4096-point FFT at 96 kHz forces many sub-80 Hz
    /// display bins onto the same FFT bin, producing a flat plateau. The
    /// sample-rate-adaptive window eliminates it.
    func testAdaptiveSizeRemovesLowFrequencyPlateau() throws {
        let fs = 96000.0
        let baseline = try lowPlateauPairs(fftSize: 4096, sampleRate: fs)
        let adaptive = try lowPlateauPairs(fftSize: SpectrumAnalyzer.fftSize(forSampleRate: fs), sampleRate: fs)

        // Baseline forces a wide plateau; the adaptive window leaves only a few
        // residual pairs in the extreme sub-30 Hz corner (inherent — display
        // bins there are narrower than even ~2.9 Hz FFT spacing).
        XCTAssertGreaterThanOrEqual(baseline, 5, "baseline 4096 FFT should show a wide low-frequency plateau at 96 kHz")
        XCTAssertLessThanOrEqual(adaptive, 3, "adaptive window should collapse only the extreme low corner")
        XCTAssertLessThanOrEqual(adaptive * 2, baseline, "adaptive window should at least halve the plateau")
    }
}
