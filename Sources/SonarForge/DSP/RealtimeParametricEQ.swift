import Foundation
import Atomics

/// The live parametric EQ: a bank of cascaded biquads processed on the realtime
/// audio thread, with a lock-free single-producer/single-consumer command ring
/// for parameter updates (see DECISIONS.md D-010).
///
/// Roles and threading contract:
/// - **Producer side** (`apply(bands:sampleRate:)`, `requestStateReset()`): call
///   from exactly one non-realtime thread at a time (the engine's control queue).
///   Coefficients are computed here, never on the audio thread. If the ring is
///   momentarily full the producer sleeps briefly and retries — it is not RT.
/// - **Consumer side** (`drainCommands()`, `processStereoInterleaved(_:frameCount:)`,
///   `resetState()`): call only from the realtime IO thread. No allocations, no
///   locks, no ObjC — just pointer math over preallocated storage and two atomic
///   index loads per drain.
///
/// Everything is preallocated for `maxBands` at init; nothing grows or frees
/// while audio runs.
public final class RealtimeParametricEQ {

    public static let maxBands = 16

    // MARK: - Commands

    private enum CommandKind: UInt32 {
        case setCoefficients = 0   // index = band slot, payload = coefficients
        case setBandCount = 1      // index = new active band count
        case resetState = 2
    }

    private struct Command {
        var kind: UInt32
        var index: UInt32
        var coefficients: BiquadCoefficients

        init(kind: CommandKind, index: UInt32 = 0, coefficients: BiquadCoefficients = .identity) {
            self.kind = kind.rawValue
            self.index = index
            self.coefficients = coefficients
        }
    }

    // MARK: - SPSC ring buffer

    /// Power of two. 64 slots comfortably hold a full 16-band profile swap
    /// (16 coefficient commands + 1 band count + 1 reset) several times over.
    private static let ringCapacity = 64
    private static let ringMask = ringCapacity - 1

    private let ring: UnsafeMutablePointer<Command>
    /// Consumer (read) index — stored by the RT thread, loaded by the producer.
    private let head = ManagedAtomic<Int>(0)
    /// Producer (write) index — stored by the producer, loaded by the RT thread.
    private let tail = ManagedAtomic<Int>(0)

    // MARK: - Consumer-owned processing state (RT thread only after start)

    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// DF2T state, 4 doubles per band: z1L, z2L, z1R, z2R.
    private let state: UnsafeMutablePointer<Double>
    private var activeBandCount: Int = 0

    // MARK: - Lifecycle

    public init() {
        ring = .allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: Command(kind: .resetState), count: Self.ringCapacity)
        coefficients = .allocate(capacity: Self.maxBands)
        coefficients.initialize(repeating: .identity, count: Self.maxBands)
        state = .allocate(capacity: Self.maxBands * 4)
        state.initialize(repeating: 0, count: Self.maxBands * 4)
    }

    deinit {
        ring.deallocate()
        coefficients.deallocate()
        state.deallocate()
    }

    // MARK: - Producer API (single non-RT thread)

    /// Computes coefficients for `bands` and publishes them to the audio thread.
    /// Bands beyond `maxBands` are ignored. Returns the number of bands applied.
    @discardableResult
    public func apply(bands: [EQBand], sampleRate: Double) -> Int {
        let applied = Array(bands.prefix(Self.maxBands))
        for (index, band) in applied.enumerated() {
            push(Command(kind: .setCoefficients,
                         index: UInt32(index),
                         coefficients: .forBand(band, sampleRate: sampleRate)))
        }
        push(Command(kind: .setBandCount, index: UInt32(applied.count)))
        return applied.count
    }

    /// Asks the audio thread to clear filter state (e.g. after a discontinuity).
    public func requestStateReset() {
        push(Command(kind: .resetState))
    }

    private func push(_ command: Command) {
        // Producer is never the RT thread; if the ring is briefly full (only
        // plausible if audio is stalled), sleep and retry rather than drop.
        while true {
            let currentTail = tail.load(ordering: .relaxed)
            let currentHead = head.load(ordering: .acquiring)
            if currentTail - currentHead < Self.ringCapacity {
                ring[currentTail & Self.ringMask] = command
                tail.store(currentTail + 1, ordering: .releasing)
                return
            }
            usleep(500)
        }
    }

    // MARK: - Consumer API (realtime thread only)

    /// Applies all pending parameter commands. Call once at the top of each IO cycle.
    public func drainCommands() {
        var currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        while currentHead < currentTail {
            let command = ring[currentHead & Self.ringMask]
            switch command.kind {
            case CommandKind.setCoefficients.rawValue:
                let index = Int(command.index)
                if index < Self.maxBands {
                    coefficients[index] = command.coefficients
                }
            case CommandKind.setBandCount.rawValue:
                let newCount = min(Int(command.index), Self.maxBands)
                // Clear state of bands entering the active set so they don't
                // replay stale history.
                if newCount > activeBandCount {
                    for band in activeBandCount..<newCount {
                        clearState(band: band)
                    }
                }
                activeBandCount = newCount
            case CommandKind.resetState.rawValue:
                resetState()
            default:
                break
            }
            currentHead += 1
        }
        head.store(currentHead, ordering: .releasing)
    }

    /// Clears all filter state. RT thread only.
    public func resetState() {
        for i in 0..<(Self.maxBands * 4) {
            state[i] = 0
        }
    }

    @inline(__always)
    private func clearState(band: Int) {
        let base = band * 4
        state[base] = 0; state[base + 1] = 0; state[base + 2] = 0; state[base + 3] = 0
    }

    /// Processes an interleaved stereo Float32 buffer in place through all active
    /// bands in series. Double math internally; per-band state flushed of
    /// denormals once per buffer.
    public func processStereoInterleaved(_ buffer: UnsafeMutablePointer<Float32>, frameCount: Int) {
        guard activeBandCount > 0, frameCount > 0 else { return }

        for band in 0..<activeBandCount {
            let c = coefficients[band]
            let base = band * 4
            var z1L = state[base]
            var z2L = state[base + 1]
            var z1R = state[base + 2]
            var z2R = state[base + 3]

            for frame in 0..<frameCount {
                let xL = Double(buffer[frame * 2])
                let yL = c.b0 * xL + z1L
                z1L = c.b1 * xL + z2L - c.a1 * yL
                z2L = c.b2 * xL - c.a2 * yL
                buffer[frame * 2] = Float32(yL)

                let xR = Double(buffer[frame * 2 + 1])
                let yR = c.b0 * xR + z1R
                z1R = c.b1 * xR + z2R - c.a1 * yR
                z2R = c.b2 * xR - c.a2 * yR
                buffer[frame * 2 + 1] = Float32(yR)
            }

            // Per-buffer denormal flush (state can decay below Float32 relevance).
            if abs(z1L) < 1e-15 { z1L = 0 }
            if abs(z2L) < 1e-15 { z2L = 0 }
            if abs(z1R) < 1e-15 { z1R = 0 }
            if abs(z2R) < 1e-15 { z2R = 0 }

            state[base] = z1L
            state[base + 1] = z2L
            state[base + 2] = z1R
            state[base + 3] = z2R
        }
    }
}
