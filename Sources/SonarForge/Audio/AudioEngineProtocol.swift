import Foundation
import CoreAudio

/// Lifecycle state of the audio engine, surfaced to the UI layer.
public enum AudioEngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(String)

    public var description: String {
        switch self {
        case .idle:               "Idle"
        case .starting:           "Starting…"
        case .running:            "Running"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Narrow boundary between the UI layer and the real-time audio engine (see DECISIONS.md D-004).
/// The engine has no SwiftUI/AppKit dependencies; the UI talks to it only through this protocol.
///
/// Threading contract:
/// - All methods are safe to call from the main thread; they hand work off internally.
/// - `onStateChange` is invoked on an arbitrary background queue; the observer is
///   responsible for hopping to the main actor before touching UI state.
public protocol AudioEngineProtocol: AnyObject {
    var state: AudioEngineState { get }
    var onStateChange: ((AudioEngineState) -> Void)? { get set }

    /// Spectrum snapshots (preEQ dB bins, postEQ dB bins), ~30 Hz while enabled
    /// and running. Called on a background queue.
    var onSpectrum: (([Float], [Float]) -> Void)? { get set }
    /// Enables/disables spectrum capture + analysis entirely (CPU saver).
    func setSpectrumEnabled(_ enabled: Bool)

    func start()
    func stop()

    func setBypass(_ bypassed: Bool)
    func setPreamp(_ db: Double)
    func setOutputGain(_ db: Double)
    func loadProfile(_ profile: EQProfile)

    /// Selects the output device by UID. Pass nil to follow the system default output.
    /// Takes effect immediately if the engine is running (brief reconfiguration).
    func selectOutputDevice(uid: String?)
}
