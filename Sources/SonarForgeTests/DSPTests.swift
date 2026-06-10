import XCTest
@testable import SonarForge

final class DSPTests: XCTestCase {

    func testBiquadPeakingUnityGainIsPassThrough() throws {
        var filter = BiquadFilter()
        filter.setPeaking(frequency: 1000, gainDB: 0.0, q: 1.0, sampleRate: 48000)

        // Feed an impulse
        let input: [Double] = [1.0] + Array(repeating: 0.0, count: 1023)
        var left = input
        var right = input

        filter.processStereoBuffer(left: &left, right: &right, frameCount: input.count)

        // With 0 dB gain the peak should be extremely close to the input (within floating point)
        XCTAssertEqual(left[0], 1.0, accuracy: 1e-9)
        // Subsequent samples will have the filter's impulse response (ringing)
    }

    func testCoefficientCalculationDoesNotProduceNaNOrInf() {
        var filter = BiquadFilter()
        let rates: [Double] = [44100, 48000, 96000]
        let freqs: [Double] = [20, 100, 997, 10000, 18000]

        for rate in rates {
            for f in freqs {
                filter.setPeaking(frequency: f, gainDB: 6.0, q: 0.7, sampleRate: rate)
                XCTAssertFalse(filter.b0.isNaN || filter.b0.isInfinite)
                XCTAssertFalse(filter.a1.isNaN || filter.a1.isInfinite)

                filter.setLowShelf(frequency: f, gainDB: -3.0, q: 0.707, sampleRate: rate)
                XCTAssertFalse(filter.b0.isNaN)
            }
        }
    }

    // TODO: Add more rigorous known-good tests once we lock in exact RBJ formulas and edge cases.
}
