import Foundation

/// Latest post-EQ time-domain snapshot for oscilloscope, vectorscope, VU/PPM,
/// and correlation. Published from the analysis queue; display-link renderers
/// poll without going through SwiftUI observation.
public struct WaveformSnapshot: Sendable {
    /// Mono mix ((L+R)/2) over the same window as L/R.
    public var mono: [Float]
    /// Matched L/R windows (always the same length / time base).
    public var left: [Float]
    public var right: [Float]
    /// Linear peak (0…∞, typically ≤1) over the analysis window.
    public var leftPeak: Float
    public var rightPeak: Float
    /// Linear RMS over the analysis window.
    public var leftRMS: Float
    public var rightRMS: Float
    /// Pearson correlation of L vs R in [-1, 1]. +1 = same shape/polarity
    /// (mono-compatible), 0 = uncorrelated, −1 = inverted. Note: a *hard pan*
    /// of mono content can read near 0 because one channel is silent — use
    /// `balance` for left↔right position.
    public var correlation: Float
    /// Stereo balance from RMS energy in [-1, 1]: −1 = hard left, 0 = center,
    /// +1 = hard right. This is what tracks ear-to-ear pans.
    public var balance: Float

    public static let empty = WaveformSnapshot(
        mono: [], left: [], right: [],
        leftPeak: 0, rightPeak: 0, leftRMS: 0, rightRMS: 0,
        correlation: 0, balance: 0
    )

    public init(mono: [Float] = [], left: [Float] = [], right: [Float] = [],
                leftPeak: Float = 0, rightPeak: Float = 0,
                leftRMS: Float = 0, rightRMS: Float = 0,
                correlation: Float = 0, balance: Float = 0) {
        self.mono = mono
        self.left = left
        self.right = right
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
        self.leftRMS = leftRMS
        self.rightRMS = rightRMS
        self.correlation = correlation
        self.balance = balance
    }
}

/// Thread-safe holder for the latest `WaveformSnapshot`.
final class WaveformFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = WaveformSnapshot.empty
    private(set) var generation: UInt64 = 0

    func publish(_ newSnapshot: WaveformSnapshot) {
        lock.lock()
        snapshot = newSnapshot
        generation &+= 1
        lock.unlock()
    }

    func clear() {
        publish(.empty)
    }

    func copySnapshot() -> WaveformSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Copies mono samples into `buffer` (oscilloscope path).
    @discardableResult
    func copySamples(into buffer: inout [Float]) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let mono = snapshot.mono
        if buffer.count != mono.count {
            buffer = mono
        } else {
            for i in mono.indices { buffer[i] = mono[i] }
        }
        return generation
    }

    /// Copies L/R into the provided buffers.
    @discardableResult
    func copyStereo(left: inout [Float], right: inout [Float]) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let l = snapshot.left
        let r = snapshot.right
        if left.count != l.count { left = l } else {
            for i in l.indices { left[i] = l[i] }
        }
        if right.count != r.count { right = r } else {
            for i in r.indices { right[i] = r[i] }
        }
        return generation
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}
