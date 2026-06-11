import Foundation
import Accelerate

/// Pure FFT → display-bins pipeline (Chunk 3.1). Runs on the analysis queue,
/// never the realtime thread. Fully unit-testable: feed samples, get dBFS bins.
///
/// Pipeline: Hann window → real DFT (vDSP) → power spectrum → calibration to
/// dBFS (a full-scale sine reads ~0 dB) → max-power reduction into log-spaced
/// display bins over 20 Hz–20 kHz.
final class SpectrumProcessor {

    let fftSize: Int
    let sampleRate: Double
    let binCount: Int

    /// Center frequency of each display bin (for axis drawing and tests).
    let binCenterFrequencies: [Float]

    private let dftSetup: OpaquePointer
    private let window: [Float]
    /// Subtracted from 10·log10(power) so a full-scale sine reads 0 dBFS.
    private let dbCalibration: Float
    /// Inclusive FFT-bin range feeding each display bin.
    private let binRanges: [ClosedRange<Int>]

    /// Display floor; bins clamp here (and silence reads here).
    static let floorDB: Float = -100

    init?(fftSize: Int = 4096, sampleRate: Double, binCount: Int = 64) {
        guard fftSize > 0, fftSize & (fftSize - 1) == 0, sampleRate > 0, binCount > 0 else { return nil }
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else { return nil }
        self.dftSetup = setup
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.binCount = binCount

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = hann

        // vDSP's zrop forward DFT scales the half-spectrum such that a windowed
        // sine of amplitude A peaks at |X| ≈ A · Σw. Calibrate so that reads 0 dBFS.
        let windowSum = hann.reduce(0, +)
        self.dbCalibration = 20 * log10(max(windowSum, 1e-12))

        // Log-spaced display bins over 20 Hz – 20 kHz.
        let lowEdge = 20.0
        let highEdge = min(20000.0, sampleRate / 2)
        let hzPerFFTBin = sampleRate / Double(fftSize)
        var ranges: [ClosedRange<Int>] = []
        var centers: [Float] = []
        for i in 0..<binCount {
            let f0 = lowEdge * pow(highEdge / lowEdge, Double(i) / Double(binCount))
            let f1 = lowEdge * pow(highEdge / lowEdge, Double(i + 1) / Double(binCount))
            centers.append(Float((f0 * f1).squareRoot()))
            let k0 = max(1, Int(f0 / hzPerFFTBin))                       // skip DC bin
            let k1 = min(fftSize / 2 - 1, max(k0, Int(f1 / hzPerFFTBin)))
            ranges.append(k0...k1)
        }
        self.binRanges = ranges
        self.binCenterFrequencies = centers
    }

    deinit {
        vDSP_DFT_DestroySetup(dftSetup)
    }

    /// Computes display bins (dBFS, clamped to `floorDB`) from exactly
    /// `fftSize` time-domain samples.
    func process(_ samples: [Float]) -> [Float] {
        precondition(samples.count == fftSize, "needs exactly fftSize samples")
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var inReal = [Float](repeating: 0, count: half)
        var inImag = [Float](repeating: 0, count: half)
        var outReal = [Float](repeating: 0, count: half)
        var outImag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        // Pack even/odd samples into split-complex form, run the real DFT,
        // then take squared magnitudes.
        windowed.withUnsafeBufferPointer { samplesPtr in
            inReal.withUnsafeMutableBufferPointer { realPtr in
                inImag.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        vDSP_DFT_Execute(dftSetup, inReal, inImag, &outReal, &outImag)
        outReal.withUnsafeMutableBufferPointer { realPtr in
            outImag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        power[0] = 0   // DC & Nyquist are packed into bin 0 — not displayed.

        // Reduce to display bins: max power in each bin's FFT range, in dBFS.
        var bins = [Float](repeating: Self.floorDB, count: binCount)
        for (i, range) in binRanges.enumerated() {
            var maxPower: Float = 0
            for k in range where power[k] > maxPower {
                maxPower = power[k]
            }
            guard maxPower > 0 else { continue }
            let db = 10 * log10(maxPower) - dbCalibration
            bins[i] = max(db, Self.floorDB)
        }
        return bins
    }
}
