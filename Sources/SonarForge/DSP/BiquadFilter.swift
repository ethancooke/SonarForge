import Foundation
import Accelerate

/// A single second-order IIR biquad filter (Direct Form II Transposed).
/// This is the fundamental building block for the parametric EQ.
///
/// Design goals for real-time use:
/// - Stable coefficients (use Double for calculation).
/// - Minimal state (two per channel for stereo).
/// - Safe for parameter updates via coefficient swap at block boundaries.
/// - Denormal protection.
public struct BiquadFilter {

    // MARK: - Coefficients (b0, b1, b2, a1, a2)
    // Normalized such that a0 == 1.0
    public var b0: Double = 1.0
    public var b1: Double = 0.0
    public var b2: Double = 0.0
    public var a1: Double = 0.0
    public var a2: Double = 0.0

    // MARK: - Per-channel state (Direct Form II Transposed)
    // For stereo we keep separate state. Extend for more channels as needed.
    private var z1L: Double = 0.0
    private var z2L: Double = 0.0
    private var z1R: Double = 0.0
    private var z2R: Double = 0.0

    public init() {}

    /// Process a single stereo sample pair (in place or returning new values).
    /// For hot paths we usually process buffers.
    @inline(__always)
    public mutating func process(sampleL: Double, sampleR: Double) -> (Double, Double) {
        // Direct Form II Transposed
        let outL = b0 * sampleL + z1L
        z1L = b1 * sampleL + z2L - a1 * outL
        z2L = b2 * sampleL - a2 * outL

        let outR = b0 * sampleR + z1R
        z1R = b1 * sampleR + z2R - a1 * outR
        z2R = b2 * sampleR - a2 * outR

        // Denormal protection (very cheap)
        if abs(z1L) < 1e-300 { z1L = 0 }
        if abs(z2L) < 1e-300 { z2L = 0 }
        if abs(z1R) < 1e-300 { z1R = 0 }
        if abs(z2R) < 1e-300 { z2R = 0 }

        return (outL, outR)
    }

    /// Process an interleaved stereo buffer.
    /// `buffer` is expected to be non-interleaved or interleaved float/double as convenient.
    /// For the MVP we provide a simple stereo pair version; vectorized versions can come later.
    public mutating func processStereoBuffer(left: UnsafeMutablePointer<Double>,
                                             right: UnsafeMutablePointer<Double>,
                                             frameCount: Int) {
        for i in 0..<frameCount {
            let (l, r) = process(sampleL: left[i], sampleR: right[i])
            left[i] = l
            right[i] = r
        }
    }

    /// Reset internal state (call on major discontinuities).
    public mutating func reset() {
        z1L = 0; z2L = 0
        z1R = 0; z2R = 0
    }

    // MARK: - Coefficient Calculation (RBJ / Audio EQ Cookbook style)

    /// Calculates coefficients for a peaking (bell) filter.
    public mutating func setPeaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * q)

        let A = pow(10.0, gainDB / 40.0)

        let b0 =  1.0 + alpha * A
        let b1 = -2.0 * cosw0
        let b2 =  1.0 - alpha * A
        let a0 =  1.0 + alpha / A
        let a1 = -2.0 * cosw0
        let a2 =  1.0 - alpha / A

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Low shelf (standard RBJ).
    public mutating func setLowShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let A = pow(10.0, gainDB / 40.0)
        let alpha = sinw0 / 2.0 * sqrt((A + 1.0 / A) * (1.0 / q - 1.0) + 2.0)

        let b0 =    A * ((A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sqrt(A) * alpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw0)
        let b2 =    A * ((A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sqrt(A) * alpha)
        let a0 =        (A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sqrt(A) * alpha
        let a1 =    2.0 * ((A - 1.0) - (A + 1.0) * cosw0)
        let a2 =        (A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sqrt(A) * alpha

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// High shelf.
    public mutating func setHighShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let A = pow(10.0, gainDB / 40.0)
        let alpha = sinw0 / 2.0 * sqrt((A + 1.0 / A) * (1.0 / q - 1.0) + 2.0)

        let b0 =    A * ((A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sqrt(A) * alpha)
        let b1 =  2.0 * A * ((A - 1.0) - (A + 1.0) * cosw0)
        let b2 =    A * ((A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sqrt(A) * alpha)
        let a0 =        (A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sqrt(A) * alpha
        let a1 =   -2.0 * ((A - 1.0) + (A + 1.0) * cosw0)
        let a2 =        (A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sqrt(A) * alpha

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Simple 2nd-order low-pass (Butterworth-like via RBJ).
    public mutating func setLowPass(frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * q)

        let b0 = (1.0 - cosw0) / 2.0
        let b1 =  1.0 - cosw0
        let b2 = (1.0 - cosw0) / 2.0
        let a0 =  1.0 + alpha
        let a1 = -2.0 * cosw0
        let a2 =  1.0 - alpha

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Simple 2nd-order high-pass.
    public mutating func setHighPass(frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * q)

        let b0 =  (1.0 + cosw0) / 2.0
        let b1 = -(1.0 + cosw0)
        let b2 =  (1.0 + cosw0) / 2.0
        let a0 =   1.0 + alpha
        let a1 =  -2.0 * cosw0
        let a2 =   1.0 - alpha

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// Notch filter.
    public mutating func setNotch(frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2.0 * .pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * q)

        let b0 = 1.0
        let b1 = -2.0 * cosw0
        let b2 = 1.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw0
        let a2 = 1.0 - alpha

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }
}
