import Foundation

/// Normalized biquad coefficients (a0 == 1), computed with the RBJ Audio EQ
/// Cookbook formulas. Pure value type: calculation happens off the audio
/// thread; the realtime processor only ever copies these five doubles.
///
/// All factory methods clamp their inputs to numerically safe ranges so that
/// no combination of user/profile input can produce NaN, Inf, or an unstable
/// filter (poles outside the unit circle):
/// - frequency: [10 Hz, 0.49 × sampleRate]
/// - Q:         [0.025, 40]
/// - gain:      ±24 dB (matches the engine's gain clamp, see D-009)
/// - shelf alpha radicand floored at 0.05 (the Q-based shelf formula goes
///   negative for high Q × high gain; flooring at exactly 0 would put the pole
///   on the unit circle, so a small positive floor keeps the filter strictly
///   stable while degrading gracefully to a very steep shelf)
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Pass-through (unity) filter.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    // MARK: - Input clamping

    public static let gainRangeDB = -24.0...24.0
    public static let qRange = 0.025...40.0

    static func clampedFrequency(_ frequency: Double, sampleRate: Double) -> Double {
        min(max(frequency, 10.0), sampleRate * 0.49)
    }

    static func clampedQ(_ q: Double) -> Double {
        min(max(q, qRange.lowerBound), qRange.upperBound)
    }

    static func clampedGain(_ db: Double) -> Double {
        min(max(db, gainRangeDB.lowerBound), gainRangeDB.upperBound)
    }

    // MARK: - RBJ factories

    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let A = pow(10.0, clampedGain(gainDB) / 40.0)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1.0 + alpha / A
        return BiquadCoefficients(
            b0: (1.0 + alpha * A) / a0,
            b1: (-2.0 * cosw0) / a0,
            b2: (1.0 - alpha * A) / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha / A) / a0
        )
    }

    public static func lowShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let A = pow(10.0, clampedGain(gainDB) / 40.0)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        // The Q-form shelf alpha can go imaginary for high Q × high gain; floor the
        // radicand at a small positive value: 0 exactly would place the pole on the
        // unit circle (marginally stable), so keep alpha strictly > 0.
        let radicand = max((A + 1.0 / A) * (1.0 / q - 1.0) + 2.0, 0.05)
        let alpha = sin(w0) / 2.0 * sqrt(radicand)
        let twoRootAAlpha = 2.0 * sqrt(A) * alpha

        let a0 = (A + 1.0) + (A - 1.0) * cosw0 + twoRootAAlpha
        return BiquadCoefficients(
            b0: A * ((A + 1.0) - (A - 1.0) * cosw0 + twoRootAAlpha) / a0,
            b1: 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw0) / a0,
            b2: A * ((A + 1.0) - (A - 1.0) * cosw0 - twoRootAAlpha) / a0,
            a1: -2.0 * ((A - 1.0) + (A + 1.0) * cosw0) / a0,
            a2: ((A + 1.0) + (A - 1.0) * cosw0 - twoRootAAlpha) / a0
        )
    }

    public static func highShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let A = pow(10.0, clampedGain(gainDB) / 40.0)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        let radicand = max((A + 1.0 / A) * (1.0 / q - 1.0) + 2.0, 0.05)
        let alpha = sin(w0) / 2.0 * sqrt(radicand)
        let twoRootAAlpha = 2.0 * sqrt(A) * alpha

        let a0 = (A + 1.0) - (A - 1.0) * cosw0 + twoRootAAlpha
        return BiquadCoefficients(
            b0: A * ((A + 1.0) + (A - 1.0) * cosw0 + twoRootAAlpha) / a0,
            b1: -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw0) / a0,
            b2: A * ((A + 1.0) + (A - 1.0) * cosw0 - twoRootAAlpha) / a0,
            a1: 2.0 * ((A - 1.0) - (A + 1.0) * cosw0) / a0,
            a2: ((A + 1.0) - (A - 1.0) * cosw0 - twoRootAAlpha) / a0
        )
    }

    public static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: ((1.0 - cosw0) / 2.0) / a0,
            b1: (1.0 - cosw0) / a0,
            b2: ((1.0 - cosw0) / 2.0) / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: ((1.0 + cosw0) / 2.0) / a0,
            b1: (-(1.0 + cosw0)) / a0,
            b2: ((1.0 + cosw0) / 2.0) / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    public static func notch(frequency: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        let f = clampedFrequency(frequency, sampleRate: sampleRate)
        let q = clampedQ(q)
        let w0 = 2.0 * .pi * f / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2.0 * q)

        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: 1.0 / a0,
            b1: (-2.0 * cosw0) / a0,
            b2: 1.0 / a0,
            a1: (-2.0 * cosw0) / a0,
            a2: (1.0 - alpha) / a0
        )
    }

    /// Maps an `EQBand` model value to coefficients.
    public static func forBand(_ band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        switch band.type {
        case .peaking:
            peaking(frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
        case .lowShelf:
            lowShelf(frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
        case .highShelf:
            highShelf(frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
        case .lowPass:
            lowPass(frequency: band.frequency, q: band.q, sampleRate: sampleRate)
        case .highPass:
            highPass(frequency: band.frequency, q: band.q, sampleRate: sampleRate)
        case .notch:
            notch(frequency: band.frequency, q: band.q, sampleRate: sampleRate)
        }
    }

    // MARK: - Analysis

    /// Exact magnitude response in dB at a frequency, evaluated analytically from
    /// the transfer function H(e^{-jω}). Used by tests now and by the frequency
    /// response curve UI later (sum the dB of all bands).
    public func magnitudeDB(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * .pi * frequency / sampleRate
        let cw = cos(w), sw = sin(w)
        let c2w = cos(2.0 * w), s2w = sin(2.0 * w)

        let numRe = b0 + b1 * cw + b2 * c2w
        let numIm = -(b1 * sw + b2 * s2w)
        let denRe = 1.0 + a1 * cw + a2 * c2w
        let denIm = -(a1 * sw + a2 * s2w)

        let magnitude = sqrt((numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-30))
        return 20.0 * log10(max(magnitude, 1e-12))
    }

    /// True when both poles are strictly inside the unit circle (stable filter).
    public var isStable: Bool {
        // Jury stability criterion for a 2nd-order polynomial z² + a1·z + a2.
        abs(a2) < 1.0 && abs(a1) < 1.0 + a2
    }
}
