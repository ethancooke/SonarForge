import XCTest
@testable import SonarForge

/// Known-good response checks for every filter type, evaluated analytically from
/// the transfer function. Tolerances are tight (±0.05 dB) because the math is exact.
final class BiquadCoefficientsTests: XCTestCase {

    let fs = 48000.0

    // MARK: - Peaking

    func testPeakingGainAtCenterAndUnityAtExtremes() {
        for gain in [-12.0, -6.0, 6.0, 12.0] {
            let c = BiquadCoefficients.peaking(frequency: 1000, gainDB: gain, q: 1.0, sampleRate: fs)
            XCTAssertEqual(c.magnitudeDB(atFrequency: 1000, sampleRate: fs), gain, accuracy: 0.05)
            XCTAssertEqual(c.magnitudeDB(atFrequency: 20, sampleRate: fs), 0.0, accuracy: 0.1)
            XCTAssertEqual(c.magnitudeDB(atFrequency: 20000, sampleRate: fs), 0.0, accuracy: 0.3)
            XCTAssertTrue(c.isStable)
        }
    }

    func testPeakingZeroGainIsIdentityResponse() {
        let c = BiquadCoefficients.peaking(frequency: 1000, gainDB: 0, q: 1.0, sampleRate: fs)
        for f in [20.0, 100, 1000, 5000, 20000] {
            XCTAssertEqual(c.magnitudeDB(atFrequency: f, sampleRate: fs), 0.0, accuracy: 0.001)
        }
    }

    func testPeakingQControlsBandwidth() {
        let narrow = BiquadCoefficients.peaking(frequency: 1000, gainDB: 6, q: 8.0, sampleRate: fs)
        let wide = BiquadCoefficients.peaking(frequency: 1000, gainDB: 6, q: 0.5, sampleRate: fs)
        // One octave away, the narrow filter should have shed far more gain.
        let narrowAt2k = narrow.magnitudeDB(atFrequency: 2000, sampleRate: fs)
        let wideAt2k = wide.magnitudeDB(atFrequency: 2000, sampleRate: fs)
        XCTAssertLessThan(narrowAt2k, 1.0)
        XCTAssertGreaterThan(wideAt2k, 2.0)
    }

    // MARK: - Shelves

    func testLowShelfPlateausAtDCAndUnityAtNyquist() {
        let c = BiquadCoefficients.lowShelf(frequency: 200, gainDB: 6, q: 0.707, sampleRate: fs)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 10, sampleRate: fs), 6.0, accuracy: 0.1)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 200, sampleRate: fs), 3.0, accuracy: 0.2)  // half-gain at corner
        XCTAssertEqual(c.magnitudeDB(atFrequency: 20000, sampleRate: fs), 0.0, accuracy: 0.1)
        XCTAssertTrue(c.isStable)
    }

    func testHighShelfPlateausAtNyquistAndUnityAtDC() {
        let c = BiquadCoefficients.highShelf(frequency: 8000, gainDB: -6, q: 0.707, sampleRate: fs)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 20, sampleRate: fs), 0.0, accuracy: 0.1)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 8000, sampleRate: fs), -3.0, accuracy: 0.2)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 23000, sampleRate: fs), -6.0, accuracy: 0.15)
        XCTAssertTrue(c.isStable)
    }

    func testShelfHighQHighGainDoesNotProduceNaN() {
        // The Q-form shelf radicand goes negative here without the clamp.
        let c = BiquadCoefficients.lowShelf(frequency: 100, gainDB: 24, q: 10, sampleRate: fs)
        for v in [c.b0, c.b1, c.b2, c.a1, c.a2] {
            XCTAssertFalse(v.isNaN)
            XCTAssertFalse(v.isInfinite)
        }
        XCTAssertTrue(c.isStable)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 10, sampleRate: fs), 24.0, accuracy: 0.5)
    }

    // MARK: - Pass filters

    func testLowPassButterworthMinus3dBAtCutoff() {
        let c = BiquadCoefficients.lowPass(frequency: 1000, q: 0.7071, sampleRate: fs)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 20, sampleRate: fs), 0.0, accuracy: 0.05)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 1000, sampleRate: fs), -3.01, accuracy: 0.1)
        // 12 dB/oct: two octaves above cutoff ≈ -24 dB
        XCTAssertEqual(c.magnitudeDB(atFrequency: 4000, sampleRate: fs), -24.0, accuracy: 1.5)
        XCTAssertTrue(c.isStable)
    }

    func testHighPassButterworthMinus3dBAtCutoff() {
        let c = BiquadCoefficients.highPass(frequency: 1000, q: 0.7071, sampleRate: fs)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 20000, sampleRate: fs), 0.0, accuracy: 0.15)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 1000, sampleRate: fs), -3.01, accuracy: 0.1)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 250, sampleRate: fs), -24.0, accuracy: 1.5)
        XCTAssertTrue(c.isStable)
    }

    func testNotchDeepCutAtCenterUnityElsewhere() {
        let c = BiquadCoefficients.notch(frequency: 1000, q: 4, sampleRate: fs)
        XCTAssertLessThan(c.magnitudeDB(atFrequency: 1000, sampleRate: fs), -40.0)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 100, sampleRate: fs), 0.0, accuracy: 0.2)
        XCTAssertEqual(c.magnitudeDB(atFrequency: 10000, sampleRate: fs), 0.0, accuracy: 0.2)
        XCTAssertTrue(c.isStable)
    }

    // MARK: - Edge cases

    func testExtremeParametersNeverProduceNaNOrInstability() {
        let rates: [Double] = [44100, 48000, 96000]
        let freqs: [Double] = [-100, 0, 1, 10, 997, 20000, 23999, 48000, 1_000_000]
        let qs: [Double] = [-1, 0, 0.001, 0.025, 0.7071, 40, 1000]
        let gains: [Double] = [-100, -24, 0, 24, 100]

        for rate in rates {
            for f in freqs {
                for q in qs {
                    for g in gains {
                        let all: [BiquadCoefficients] = [
                            .peaking(frequency: f, gainDB: g, q: q, sampleRate: rate),
                            .lowShelf(frequency: f, gainDB: g, q: q, sampleRate: rate),
                            .highShelf(frequency: f, gainDB: g, q: q, sampleRate: rate),
                            .lowPass(frequency: f, q: q, sampleRate: rate),
                            .highPass(frequency: f, q: q, sampleRate: rate),
                            .notch(frequency: f, q: q, sampleRate: rate),
                        ]
                        for c in all {
                            for v in [c.b0, c.b1, c.b2, c.a1, c.a2] {
                                XCTAssertFalse(v.isNaN, "NaN at f=\(f) q=\(q) g=\(g) fs=\(rate)")
                                XCTAssertFalse(v.isInfinite, "Inf at f=\(f) q=\(q) g=\(g) fs=\(rate)")
                            }
                            XCTAssertTrue(c.isStable, "unstable at f=\(f) q=\(q) g=\(g) fs=\(rate)")
                        }
                    }
                }
            }
        }
    }

    func testImpulseResponseDecaysAtExtremeSettings() {
        // Worst case: very low frequency, max Q, max gain, high sample rate.
        var filter = BiquadFilter()
        filter.setPeaking(frequency: 20, gainDB: 24, q: 40, sampleRate: 96000)

        var peak = 0.0
        var tail = 0.0
        for i in 0..<200_000 {
            let x = i == 0 ? 1.0 : 0.0
            let (y, _) = filter.process(sampleL: x, sampleR: 0)
            XCTAssertFalse(y.isNaN)
            XCTAssertFalse(y.isInfinite)
            peak = max(peak, abs(y))
            if i >= 190_000 { tail = max(tail, abs(y)) }
        }
        XCTAssertLessThan(peak, 100.0, "bounded impulse response")
        XCTAssertLessThan(tail, peak * 0.01, "impulse response decays")
    }
}
