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
}
