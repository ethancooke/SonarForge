import Foundation

/// Computes the summed frequency response of a band set for display
/// (Chunk 5.2). Pure math over `BiquadCoefficients.magnitudeDB`; cascaded
/// filters multiply in linear magnitude, so their dB responses add.
public enum EQResponseCurve {

    /// Log-spaced sample frequencies for drawing, 20 Hz – 20 kHz by default.
    public static func logSpacedFrequencies(count: Int, from low: Double = 20, to high: Double = 20000) -> [Double] {
        guard count > 1 else { return [low] }
        let ratio = high / low
        return (0..<count).map { low * pow(ratio, Double($0) / Double(count - 1)) }
    }

    /// Total response in dB (excluding preamp — that is a flat offset shown on
    /// the fader, not a curve feature) at each frequency.
    public static func responseDB(bands: [EQBand], sampleRate: Double, frequencies: [Double]) -> [Double] {
        guard !bands.isEmpty else { return [Double](repeating: 0, count: frequencies.count) }
        let coefficients = bands.map { BiquadCoefficients.forBand($0, sampleRate: sampleRate) }
        return frequencies.map { frequency in
            coefficients.reduce(0.0) { $0 + $1.magnitudeDB(atFrequency: frequency, sampleRate: sampleRate) }
        }
    }
}
