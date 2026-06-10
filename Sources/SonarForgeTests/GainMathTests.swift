import XCTest
@testable import SonarForge

final class GainMathTests: XCTestCase {

    func testLinearGainConversion() {
        XCTAssertEqual(GainMath.linearGain(fromDB: 0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(GainMath.linearGain(fromDB: 6.0205999), 2.0, accuracy: 1e-4)
        XCTAssertEqual(GainMath.linearGain(fromDB: -6.0205999), 0.5, accuracy: 1e-4)
        XCTAssertEqual(GainMath.linearGain(fromDB: 20), 10.0, accuracy: 1e-4)
        XCTAssertEqual(GainMath.linearGain(fromDB: -20), 0.1, accuracy: 1e-5)
    }

    func testSmoothingCoefficientRange() {
        for rate in [44100.0, 48000.0, 96000.0] {
            let k = GainMath.smoothingCoefficient(timeConstant: 0.015, sampleRate: rate)
            XCTAssertGreaterThan(k, 0)
            XCTAssertLessThan(k, 1)
        }
        // Degenerate inputs fall back to instant (no smoothing) rather than NaN/stall.
        XCTAssertEqual(GainMath.smoothingCoefficient(timeConstant: 0, sampleRate: 48000), 1.0)
        XCTAssertEqual(GainMath.smoothingCoefficient(timeConstant: 0.015, sampleRate: 0), 1.0)
    }

    /// Simulates the render-thread smoother: `g += k * (target - g)` per sample.
    /// Verifies the documented convergence (≈63% after τ, ≈95% after 3τ) and that
    /// the value approaches the target monotonically (no overshoot → no artifacts).
    func testSmootherConvergence() {
        let sampleRate = 48000.0
        let tau = 0.015
        let k = GainMath.smoothingCoefficient(timeConstant: tau, sampleRate: sampleRate)
        let target: Float = 1.0
        var g: Float = 0.0
        var previous: Float = 0.0

        let samplesPerTau = Int(tau * sampleRate)
        for sample in 1...(samplesPerTau * 5) {
            g += k * (target - g)
            XCTAssertGreaterThanOrEqual(g, previous, "smoother must be monotonic")
            XCTAssertLessThanOrEqual(g, target, "smoother must not overshoot")
            previous = g

            if sample == samplesPerTau {
                XCTAssertEqual(g, 0.632, accuracy: 0.01, "≈63% after one time constant")
            }
            if sample == samplesPerTau * 3 {
                XCTAssertEqual(g, 0.950, accuracy: 0.01, "≈95% after three time constants")
            }
        }
    }
}
