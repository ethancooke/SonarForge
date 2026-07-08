import Foundation
import Atomics

/// Headphone crossfeed: mixes a low-passed copy of each channel into the
/// opposite ear to approximate the acoustic bleed you'd get from speakers in a
/// room. Hard-panned mixes stop feeling like they're *inside* your head and
/// move out in front of you ("out-of-head" localization).
///
/// ## Algorithm (see DECISIONS.md D-012)
/// A complementary-filter crossfeed that is provably tonally neutral for mono
/// content. For each channel we split the signal with a first-order low-pass
/// `LP` and its exact complement `HP = x − LP(x)`:
///
/// ```
/// outL = HP(L) + (1−b)·LP(L) + b·LP(R)
/// outR = HP(R) + (1−b)·LP(R) + b·LP(L)
/// ```
///
/// - **Highs** (where `LP → 0`) keep full stereo separation — the head fully
///   shadows the far ear at high frequency, so no crossfeed there.
/// - **Lows** (where `LP → 1`) blend toward mono by the *bleed* fraction `b`.
/// - **Mono neutrality**: for `L == R == m`, the sum collapses to
///   `HP(m) + LP(m) = m` for *any* `b` — a centered mix is passed through
///   untouched, so crossfeed never colors the tonal balance.
///
/// `b` ranges 0 (no crossfeed) … 0.5 (bass fully mono). The user-facing
/// *amount* 0…1 maps linearly onto that range; the low-pass cutoff is fixed at
/// `cutoffHz`.
///
/// ## Threading contract (mirrors `RealtimeParametricEQ`)
/// - **Producer** (`setEnabled`, `setAmount`): any non-RT thread; publishes
///   scalar parameters through atomics.
/// - **Prepare** (`prepare(sampleRate:)`, `reset()`): call on the control queue
///   strictly before `AudioDeviceStart`; afterwards the coefficients are read
///   only by the RT thread.
/// - **Consumer** (`processStereoInterleaved`): RT thread only. No allocations,
///   no locks — pointer math over the interleaved buffer plus two atomic loads.
///
/// The target bleed is ramped per-sample toward its published value, so
/// toggling the effect on/off and dragging the slider are click-free without a
/// separate gain crossfade.
public final class Crossfeed {

    /// Low-pass corner for the crossfed (opposite-channel) content. 700 Hz is
    /// the long-standing crossfeed convention (bs2b/Chu Moy): below it the ears
    /// share bass, above it separation is preserved.
    public static let cutoffHz = 700.0

    /// Default "natural" amount surfaced to new profiles — a moderate,
    /// speaker-like blend that widens hard-panned material without smearing.
    public static let defaultAmount = 0.6

    // MARK: - Published parameters (producer → RT)

    private let enabledFlag = ManagedAtomic<Bool>(false)
    /// Target bleed fraction (0…0.5) as a Float bit pattern.
    private let bleedBits = ManagedAtomic<UInt32>(Float(0).bitPattern)

    // MARK: - Coefficients / smoothing (set before start, RT-owned after)

    /// One-pole low-pass: `y = a0·x + b1·y`, DC gain 1.
    private var a0Lo: Double = 0
    private var b1Lo: Double = 0
    /// Per-sample smoothing coefficient for the bleed ramp (~10 ms).
    private var smoothingCoeff: Double = 0.002

    // MARK: - RT-owned state

    private var lpL: Double = 0
    private var lpR: Double = 0
    private var smoothedBleed: Double = 0

    public init() {}

    // MARK: - Producer API (non-RT)

    public func setEnabled(_ enabled: Bool) {
        enabledFlag.store(enabled, ordering: .relaxed)
    }

    /// Sets the crossfeed strength. `amount` is clamped to 0…1 and maps linearly
    /// onto a bleed fraction of 0…0.5 (0.5 = bass fully mono).
    public func setAmount(_ amount: Double) {
        let bleed = min(max(amount, 0), 1) * 0.5
        bleedBits.store(Float(bleed).bitPattern, ordering: .relaxed)
    }

    // MARK: - Prepare (control queue, before start)

    /// Computes the low-pass coefficient and bleed-ramp time constant for the
    /// given sample rate. Call before `AudioDeviceStart`.
    public func prepare(sampleRate: Double) {
        let rate = max(sampleRate, 1)
        let x = exp(-2.0 * .pi * Self.cutoffHz / rate)
        b1Lo = x
        a0Lo = 1.0 - x
        // ~10 ms ramp — one-pole time constant expressed per sample.
        smoothingCoeff = 1.0 - exp(-1.0 / (0.010 * rate))
    }

    /// Clears filter and ramp state. RT thread (or before start) only.
    public func reset() {
        lpL = 0
        lpR = 0
        smoothedBleed = 0
    }

    // MARK: - Consumer API (RT thread only)

    /// Applies crossfeed in place to an interleaved stereo Float32 buffer.
    /// A no-op (and provably sample-preserving) while the effect is disabled and
    /// the bleed ramp has fully settled to zero.
    public func processStereoInterleaved(_ buffer: UnsafeMutablePointer<Float32>, frameCount: Int) {
        guard frameCount > 0 else { return }

        let enabled = enabledFlag.load(ordering: .relaxed)
        let target = enabled ? Double(Float(bitPattern: bleedBits.load(ordering: .relaxed))) : 0.0

        // Settled-off fast path: bleed is zero, so output already equals input.
        // Clear the filter state so a later re-enable starts clean.
        if target == 0, smoothedBleed < 1e-6 {
            lpL = 0
            lpR = 0
            smoothedBleed = 0
            return
        }

        let k = smoothingCoeff
        var b = smoothedBleed
        var yL = lpL
        var yR = lpR

        for frame in 0..<frameCount {
            let xL = Double(buffer[frame * 2])
            let xR = Double(buffer[frame * 2 + 1])

            yL = a0Lo * xL + b1Lo * yL
            yR = a0Lo * xR + b1Lo * yR
            let hiL = xL - yL
            let hiR = xR - yR

            b += k * (target - b)

            buffer[frame * 2] = Float32(hiL + (1.0 - b) * yL + b * yR)
            buffer[frame * 2 + 1] = Float32(hiR + (1.0 - b) * yR + b * yL)
        }

        // Denormal flush — low-pass state decays toward zero on silence.
        if abs(yL) < 1e-15 { yL = 0 }
        if abs(yR) < 1e-15 { yR = 0 }
        lpL = yL
        lpR = yR
        smoothedBleed = b
    }
}
