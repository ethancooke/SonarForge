import XCTest
@testable import SonarForge

final class EQResponseCurveTests: XCTestCase {

    func testLogSpacedFrequenciesSpanAndMonotonic() {
        let freqs = EQResponseCurve.logSpacedFrequencies(count: 160)
        XCTAssertEqual(freqs.count, 160)
        XCTAssertEqual(freqs.first!, 20, accuracy: 0.001)
        XCTAssertEqual(freqs.last!, 20000, accuracy: 0.1)
        XCTAssertTrue(zip(freqs, freqs.dropFirst()).allSatisfy { $0 < $1 })
        // Log spacing: equal ratios, not equal differences.
        let r1 = freqs[1] / freqs[0]
        let r2 = freqs[80] / freqs[79]
        XCTAssertEqual(r1, r2, accuracy: 1e-9)
    }

    func testEmptyBandsAreFlatZero() {
        let freqs = EQResponseCurve.logSpacedFrequencies(count: 32)
        let response = EQResponseCurve.responseDB(bands: [], sampleRate: 48000, frequencies: freqs)
        XCTAssertTrue(response.allSatisfy { $0 == 0 })
    }

    func testShelfResponseMatchesFilterAnalysis() {
        let bands = [EQBand(type: .lowShelf, frequency: 100, gain: 6, q: 0.707)]
        let response = EQResponseCurve.responseDB(bands: bands, sampleRate: 48000, frequencies: [20, 10000])
        XCTAssertEqual(response[0], 6.0, accuracy: 0.15, "low shelf plateau")
        XCTAssertEqual(response[1], 0.0, accuracy: 0.15, "unity far above the shelf")
    }

    func testCascadedBandsAddInDB() {
        let one = [EQBand(type: .peaking, frequency: 1000, gain: 4, q: 1.0)]
        let two = one + one
        let single = EQResponseCurve.responseDB(bands: one, sampleRate: 48000, frequencies: [1000])[0]
        let double = EQResponseCurve.responseDB(bands: two, sampleRate: 48000, frequencies: [1000])[0]
        XCTAssertEqual(double, single * 2, accuracy: 0.01, "dB responses of cascaded filters add")
    }
}
