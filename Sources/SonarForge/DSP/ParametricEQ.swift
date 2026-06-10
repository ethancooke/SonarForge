import Foundation
import Accelerate

/// Manages a collection of biquad filters (the parametric EQ) plus preamp and output gain.
/// This is the primary DSP object that will be called from the audio render thread.
///
/// Design notes for Chunk 2:
/// - Coefficient updates are calculated off-thread and applied at safe points (block start).
/// - The object itself is not thread-safe for parameter changes; use a higher-level
///   coordinator (AudioEngine) to marshal updates.
public final class ParametricEQ {

    public private(set) var bands: [BiquadFilter] = []
    public private(set) var bandParameters: [EQBand] = []

    public var preampDB: Double = 0.0 {
        didSet { preampGain = pow(10.0, preampDB / 20.0) }
    }
    private var preampGain: Double = 1.0

    public var outputGainDB: Double = 0.0 {
        didSet { outputGain = pow(10.0, outputGainDB / 20.0) }
    }
    private var outputGain: Double = 1.0

    private var sampleRate: Double = 48000

    public init(maxBands: Int = 16) {
        bands.reserveCapacity(maxBands)
        bandParameters.reserveCapacity(maxBands)
    }

    /// Completely replaces the active bands. Called when a new profile is loaded.
    public func setBands(_ newBands: [EQBand], sampleRate: Double) {
        self.sampleRate = sampleRate
        self.bandParameters = newBands

        // Recreate filters to match
        bands = newBands.map { _ in BiquadFilter() }
        recalculateAllCoefficients()
    }

    public func updateBand(at index: Int, to newBand: EQBand) {
        guard index < bandParameters.count, index < bands.count else { return }
        bandParameters[index] = newBand
        recalculateCoefficients(at: index)
    }

    public func setSampleRate(_ newRate: Double) {
        guard newRate != sampleRate else { return }
        sampleRate = newRate
        recalculateAllCoefficients()
    }

    private func recalculateAllCoefficients() {
        for i in bandParameters.indices {
            recalculateCoefficients(at: i)
        }
    }

    private func recalculateCoefficients(at index: Int) {
        guard index < bandParameters.count, index < bands.count else { return }
        let p = bandParameters[index]
        var f = bands[index]

        switch p.type {
        case .peaking:
            f.setPeaking(frequency: p.frequency, gainDB: p.gain, q: p.q, sampleRate: sampleRate)
        case .lowShelf:
            f.setLowShelf(frequency: p.frequency, gainDB: p.gain, q: p.q, sampleRate: sampleRate)
        case .highShelf:
            f.setHighShelf(frequency: p.frequency, gainDB: p.gain, q: p.q, sampleRate: sampleRate)
        case .lowPass:
            f.setLowPass(frequency: p.frequency, q: p.q, sampleRate: sampleRate)
        case .highPass:
            f.setHighPass(frequency: p.frequency, q: p.q, sampleRate: sampleRate)
        case .notch:
            f.setNotch(frequency: p.frequency, q: p.q, sampleRate: sampleRate)
        }

        bands[index] = f
    }

    // MARK: - Processing (called on audio thread)

    /// Process a pair of stereo buffers (non-interleaved doubles for the prototype).
    /// In production we will likely work with `AVAudioPCMBuffer` or raw float buffers
    /// from the render callback and vectorize where profitable.
    public func process(left: UnsafeMutablePointer<Double>,
                        right: UnsafeMutablePointer<Double>,
                        frameCount: Int) {

        // Preamp
        if preampGain != 1.0 {
            applyGain(preampGain, to: left, frameCount: frameCount)
            applyGain(preampGain, to: right, frameCount: frameCount)
        }

        // All bands in series
        for i in bands.indices {
            bands[i].processStereoBuffer(left: left, right: right, frameCount: frameCount)
        }

        // Output gain
        if outputGain != 1.0 {
            applyGain(outputGain, to: left, frameCount: frameCount)
            applyGain(outputGain, to: right, frameCount: frameCount)
        }
    }

    @inline(__always)
    private func applyGain(_ gain: Double, to samples: UnsafeMutablePointer<Double>, frameCount: Int) {
        var scalar = gain
        vDSP_vsmulD(samples, 1, &scalar, samples, 1, vDSP_Length(frameCount))
    }

    /// Zero-cost bypass path (or near zero). The engine can choose to skip calling process entirely.
    public func processBypassed(left: UnsafeMutablePointer<Double>,
                                right: UnsafeMutablePointer<Double>,
                                frameCount: Int) {
        // Nothing to do — caller should just copy or use the original buffers.
    }
}
