import Foundation

/// Small, pure helpers for gain staging. Kept separate from the engine so the
/// math is unit-testable without any Core Audio dependency.
public enum GainMath {

    /// Decibels → linear amplitude (0 dB == 1.0).
    public static func linearGain(fromDB db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    /// One-pole smoothing coefficient for a given time constant at a sample rate.
    /// Usage per sample: `g += k * (target - g)` — reaches ~63% of a step after
    /// `timeConstant` seconds, ~95% after 3× that.
    public static func smoothingCoefficient(timeConstant seconds: Double, sampleRate: Double) -> Float {
        guard seconds > 0, sampleRate > 0 else { return 1.0 }
        return Float(1.0 - exp(-1.0 / (seconds * sampleRate)))
    }
}
