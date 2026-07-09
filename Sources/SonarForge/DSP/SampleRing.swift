import Foundation
import Atomics

/// Lock-free single-producer/single-consumer ring of Float samples, used to
/// hand audio from the realtime IO thread to the spectrum analysis queue.
///
/// Producer (realtime thread): `writeMonoFromInterleavedStereo` — no
/// allocations, no locks; when the ring is full, excess samples are dropped
/// (analysis is best-effort; correctness of playback is never at stake).
/// Consumer (analysis queue): `read(into:maxCount:)`.
final class SampleRing {

    private let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    /// Consumer (read) index — stored by the consumer, loaded by the producer.
    private let head = ManagedAtomic<Int>(0)
    /// Producer (write) index — stored by the producer, loaded by the consumer.
    private let tail = ManagedAtomic<Int>(0)

    /// - Parameter capacity: rounded up to the next power of two.
    init(capacity: Int) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        self.mask = size - 1
        self.buffer = .allocate(capacity: size)
        self.buffer.initialize(repeating: 0, count: size)
    }

    deinit {
        buffer.deallocate()
    }

    /// Realtime-safe: mixes interleaved stereo down to mono ((L+R)/2) and
    /// writes as many frames as fit. Returns silently when full.
    @inline(__always)
    func writeMonoFromInterleavedStereo(_ samples: UnsafePointer<Float32>, frames: Int) {
        writeChannelFromInterleavedStereo(samples, frames: frames, channel: -1)
    }

    /// Realtime-safe: copies one channel of interleaved stereo (`channel` 0 = L,
    /// 1 = R). Pass `channel: -1` for mono mixdown ((L+R)/2).
    @inline(__always)
    func writeChannelFromInterleavedStereo(_ samples: UnsafePointer<Float32>,
                                           frames: Int,
                                           channel: Int) {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)
        let free = capacity - (currentTail - currentHead)
        let count = min(frames, free)
        guard count > 0 else { return }

        if channel < 0 {
            for i in 0..<count {
                buffer[(currentTail + i) & mask] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
            }
        } else {
            let ch = channel & 1
            for i in 0..<count {
                buffer[(currentTail + i) & mask] = samples[i * 2 + ch]
            }
        }
        tail.store(currentTail + count, ordering: .releasing)
    }

    /// Consumer side: copies up to `maxCount` available samples into `dest`.
    /// Returns the number of samples read.
    func read(into dest: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        let available = currentTail - currentHead
        let count = min(maxCount, available)
        guard count > 0 else { return 0 }

        for i in 0..<count {
            dest[i] = buffer[(currentHead + i) & mask]
        }
        head.store(currentHead + count, ordering: .releasing)
        return count
    }

    /// Realtime-safe: writes interleaved stereo frames as L,R,L,R… (capacity is
    /// in *floats*, so one frame = 2 slots). Always writes an even number of
    /// samples so L/R pairs never tear. Prefer this for stereo meters over two
    /// independent mono rings (those can desync when either drops).
    @inline(__always)
    func writeInterleavedStereoFrames(_ samples: UnsafePointer<Float32>, frames: Int) {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)
        let free = capacity - (currentTail - currentHead)
        // Even free count so pairs stay intact.
        let freeEven = free & ~1
        let want = frames * 2
        let count = min(want, freeEven)
        guard count > 0 else { return }
        for i in 0..<count {
            buffer[(currentTail + i) & mask] = samples[i]
        }
        tail.store(currentTail + count, ordering: .releasing)
    }

    /// Reads up to `maxFrames` L/R pairs into separate channel buffers.
    /// Returns the number of *frames* read (always lockstep).
    func readStereoFrames(left: UnsafeMutablePointer<Float>,
                          right: UnsafeMutablePointer<Float>,
                          maxFrames: Int) -> Int {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        let availableFloats = currentTail - currentHead
        let availableFrames = availableFloats / 2
        let count = min(maxFrames, availableFrames)
        guard count > 0 else { return 0 }
        for i in 0..<count {
            let base = currentHead + i * 2
            left[i] = buffer[base & mask]
            right[i] = buffer[(base + 1) & mask]
        }
        head.store(currentHead + count * 2, ordering: .releasing)
        return count
    }
}
