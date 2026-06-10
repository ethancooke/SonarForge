import Foundation

/// A single second-order IIR filter (Direct Form II Transposed) for offline use:
/// unit tests, analysis, and prototyping. The live render path uses
/// `RealtimeParametricEQ`, which processes the same `BiquadCoefficients` with
/// preallocated state suitable for the realtime thread.
///
/// Coefficient math lives in `BiquadCoefficients` (RBJ Audio EQ Cookbook with
/// input clamping); this type just owns per-channel state and the DF2T kernel.
public struct BiquadFilter {

    public var coefficients: BiquadCoefficients = .identity

    // Direct Form II Transposed state, stereo.
    private var z1L: Double = 0.0
    private var z2L: Double = 0.0
    private var z1R: Double = 0.0
    private var z2R: Double = 0.0

    public init() {}

    // Convenience accessors used by tests and analysis code.
    public var b0: Double { coefficients.b0 }
    public var b1: Double { coefficients.b1 }
    public var b2: Double { coefficients.b2 }
    public var a1: Double { coefficients.a1 }
    public var a2: Double { coefficients.a2 }

    /// Process a single stereo sample pair.
    @inline(__always)
    public mutating func process(sampleL: Double, sampleR: Double) -> (Double, Double) {
        let c = coefficients

        let outL = c.b0 * sampleL + z1L
        z1L = c.b1 * sampleL + z2L - c.a1 * outL
        z2L = c.b2 * sampleL - c.a2 * outL

        let outR = c.b0 * sampleR + z1R
        z1R = c.b1 * sampleR + z2R - c.a1 * outR
        z2R = c.b2 * sampleR - c.a2 * outR

        return (outL, outR)
    }

    /// Process non-interleaved stereo buffers in place.
    public mutating func processStereoBuffer(left: UnsafeMutablePointer<Double>,
                                             right: UnsafeMutablePointer<Double>,
                                             frameCount: Int) {
        for i in 0..<frameCount {
            let (l, r) = process(sampleL: left[i], sampleR: right[i])
            left[i] = l
            right[i] = r
        }
        flushDenormals()
    }

    /// Reset internal state (call on major discontinuities).
    public mutating func reset() {
        z1L = 0; z2L = 0
        z1R = 0; z2R = 0
    }

    /// Flush subnormal state once per buffer (cheap, avoids denormal slowdowns).
    @inline(__always)
    public mutating func flushDenormals() {
        if abs(z1L) < 1e-15 { z1L = 0 }
        if abs(z2L) < 1e-15 { z2L = 0 }
        if abs(z1R) < 1e-15 { z1R = 0 }
        if abs(z2R) < 1e-15 { z2R = 0 }
    }

    // MARK: - Coefficient setters (thin wrappers over BiquadCoefficients)

    public mutating func setPeaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        coefficients = .peaking(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    public mutating func setLowShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        coefficients = .lowShelf(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    public mutating func setHighShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        coefficients = .highShelf(frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    public mutating func setLowPass(frequency: Double, q: Double, sampleRate: Double) {
        coefficients = .lowPass(frequency: frequency, q: q, sampleRate: sampleRate)
    }

    public mutating func setHighPass(frequency: Double, q: Double, sampleRate: Double) {
        coefficients = .highPass(frequency: frequency, q: q, sampleRate: sampleRate)
    }

    public mutating func setNotch(frequency: Double, q: Double, sampleRate: Double) {
        coefficients = .notch(frequency: frequency, q: q, sampleRate: sampleRate)
    }
}
