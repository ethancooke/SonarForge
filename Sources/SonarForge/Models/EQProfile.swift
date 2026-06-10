import Foundation

/// Represents a complete, serializable EQ configuration.
/// This is the canonical model for persistence, import/export, A/B, and
/// communication with the audio engine.
public struct EQProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var preamp: Double          // dB, applied before the band filters
    public var bands: [EQBand]
    public var isFavorite: Bool
    public var sourceAttribution: String?   // e.g. "AutoEQ / oratory1990 - HD 600"
    public var notes: String?

    /// A completely neutral (unity) profile.
    public static let flat: EQProfile = EQProfile(
        id: UUID(),
        name: "Flat",
        preamp: 0.0,
        bands: [],
        isFavorite: false,
        sourceAttribution: nil,
        notes: "Unity / reference"
    )

    /// Built-in presets for exercising the EQ before the profile system exists
    /// (Phase 4). Deliberately obvious-sounding so render-path problems are audible.
    public static let debugPresets: [EQProfile] = [
        .flat,
        EQProfile(id: UUID(), name: "Bass Boost", preamp: -6.0,
                  bands: [EQBand(type: .lowShelf, frequency: 100, gain: 6, q: 0.707)],
                  isFavorite: false, sourceAttribution: nil,
                  notes: "Debug preset — +6 dB low shelf @ 100 Hz, −6 dB preamp headroom"),
        EQProfile(id: UUID(), name: "Treble Boost", preamp: -6.0,
                  bands: [EQBand(type: .highShelf, frequency: 8000, gain: 6, q: 0.707)],
                  isFavorite: false, sourceAttribution: nil,
                  notes: "Debug preset — +6 dB high shelf @ 8 kHz, −6 dB preamp headroom"),
        EQProfile(id: UUID(), name: "Mid Cut", preamp: 0.0,
                  bands: [EQBand(type: .peaking, frequency: 1000, gain: -12, q: 2.0)],
                  isFavorite: false, sourceAttribution: nil,
                  notes: "Debug preset — −12 dB peaking @ 1 kHz (hollows out vocals)"),
        EQProfile(id: UUID(), name: "Telephone", preamp: 0.0,
                  bands: [
                    EQBand(type: .highPass, frequency: 300, gain: 0, q: 0.707),
                    EQBand(type: .lowPass, frequency: 3400, gain: 0, q: 0.707),
                  ],
                  isFavorite: false, sourceAttribution: nil,
                  notes: "Debug preset — 300 Hz–3.4 kHz bandpass (unmistakable)"),
    ]

    /// Convenience for creating a new user profile.
    public static func newUserProfile(name: String = "New Profile") -> EQProfile {
        EQProfile(
            id: UUID(),
            name: name,
            preamp: 0.0,
            bands: [],
            isFavorite: false,
            sourceAttribution: nil,
            notes: nil
        )
    }
}

public struct EQBand: Codable, Hashable, Sendable {
    public var id: UUID
    public var type: FilterType
    public var frequency: Double   // Hz
    public var gain: Double        // dB
    public var q: Double           // Quality factor (bandwidth control)

    public init(id: UUID = UUID(), type: FilterType = .peaking, frequency: Double = 1000, gain: Double = 0, q: Double = 1.0) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

public enum FilterType: String, Codable, CaseIterable, Hashable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    public var displayName: String {
        switch self {
        case .peaking:   "Peaking"
        case .lowShelf:  "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass:   "Low Pass"
        case .highPass:  "High Pass"
        case .notch:     "Notch"
        }
    }
}
