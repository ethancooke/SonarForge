import Foundation

/// Thread-safe latest spectrum snapshot for visualizers that must **not** route
/// through SwiftUI/`@Observable` to animate.
///
/// The analyzer publishes here from its callback queue; GPU/CPU visualizers
/// poll on their own display-link threads. This keeps motion alive while the
/// main thread is busy with button tracking, layout, or other UI work — the
/// classic "visual freezes when I click anything" failure mode of main-thread
/// `MTKView` / SwiftUI `Canvas` redraws.
final class SpectrumFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var preLevels: [Float] = []
    private var postLevels: [Float] = []
    /// Monotonic counter so renderers can skip work when nothing changed.
    private(set) var generation: UInt64 = 0

    func publish(pre: [Float], post: [Float]) {
        lock.lock()
        preLevels = pre
        postLevels = post
        generation &+= 1
        lock.unlock()
    }

    func clear() {
        publish(pre: [], post: [])
    }

    func copyPost() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return postLevels
    }

    func copyPre() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return preLevels
    }

    /// Copies post-EQ bins into `buffer`, reusing storage when the count matches.
    /// Returns the current generation.
    @discardableResult
    func copyPost(into buffer: inout [Float]) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count != postLevels.count {
            buffer = postLevels
        } else {
            for i in postLevels.indices {
                buffer[i] = postLevels[i]
            }
        }
        return generation
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}
