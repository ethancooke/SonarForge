import Foundation

/// Stable identities for the built-in factory presets. These UUIDs are the
/// on-disk keys — never change them once shipped, or reset/sync will orphan files.
enum FactoryPresetID {
    static let flat = UUID(uuidString: "11111111-1111-1111-1111-111111110001")!
    static let bassBoost = UUID(uuidString: "11111111-1111-1111-1111-111111110002")!
    static let trebleBoost = UUID(uuidString: "11111111-1111-1111-1111-111111110003")!
    static let smileCurve = UUID(uuidString: "11111111-1111-1111-1111-111111110004")!
    static let midScoop = UUID(uuidString: "11111111-1111-1111-1111-111111110005")!
    static let vocalPresence = UUID(uuidString: "11111111-1111-1111-1111-111111110006")!
    static let telephone = UUID(uuidString: "11111111-1111-1111-1111-111111110007")!
    static let loudness = UUID(uuidString: "11111111-1111-1111-1111-111111110008")!
    static let rock = UUID(uuidString: "11111111-1111-1111-1111-111111110009")!
    static let filterShowcase = UUID(uuidString: "11111111-1111-1111-1111-11111111000A")!
    static let sonarWave = UUID(uuidString: "11111111-1111-1111-1111-11111111000B")!
}

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
    /// Built-in factory preset shipped with the app. Factory presets cannot be
    /// deleted or renamed; edits are allowed but can be reset to the canonical
    /// definition in `EQProfile.factoryPresets`.
    public var isFactory: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        preamp: Double = 0.0,
        bands: [EQBand] = [],
        isFavorite: Bool = false,
        sourceAttribution: String? = nil,
        notes: String? = nil,
        isFactory: Bool = false
    ) {
        self.id = id
        self.name = name
        self.preamp = preamp
        self.bands = bands
        self.isFavorite = isFavorite
        self.sourceAttribution = sourceAttribution
        self.notes = notes
        self.isFactory = isFactory
    }

    /// A completely neutral (unity) profile.
    public static let flat: EQProfile = factoryPresets.first(where: { $0.id == FactoryPresetID.flat })!

    /// Legacy starter names removed when the factory catalog was expanded.
    static let obsoleteFactoryNames = ["Mid Cut"]

    /// Ten industry-recognizable factory presets shipped with the app.
    /// Preamp is 0 dB on all boost presets — users hear the lift directly.
    public static let factoryPresets: [EQProfile] = [
        factory(id: FactoryPresetID.flat, name: "Flat", bands: [],
                notes: "Unity reference — no EQ applied"),

        factory(id: FactoryPresetID.bassBoost, name: "Bass Boost",
                bands: [EQBand(type: .lowShelf, frequency: 80, gain: 5, q: 0.707)],
                notes: "Warmth — +5 dB low shelf @ 80 Hz"),

        factory(id: FactoryPresetID.trebleBoost, name: "Treble Boost",
                bands: [EQBand(type: .highShelf, frequency: 10000, gain: 5, q: 0.707)],
                notes: "Clarity — +5 dB high shelf @ 10 kHz"),

        factory(id: FactoryPresetID.smileCurve, name: "Smile Curve",
                bands: [
                    EQBand(type: .lowShelf, frequency: 100, gain: 4, q: 0.707),
                    EQBand(type: .highShelf, frequency: 12000, gain: 4, q: 0.707),
                ],
                notes: "Classic hi-fi smile — gentle bass and treble lift"),

        factory(id: FactoryPresetID.midScoop, name: "Mid Scoop",
                bands: [
                    EQBand(type: .lowShelf, frequency: 120, gain: 3, q: 0.707),
                    EQBand(type: .peaking, frequency: 1000, gain: -6, q: 1.4),
                    EQBand(type: .highShelf, frequency: 8000, gain: 3, q: 0.707),
                ],
                notes: "Rock/metal scoop — recessed mids, forward bass and treble"),

        factory(id: FactoryPresetID.vocalPresence, name: "Vocal Presence",
                bands: [
                    EQBand(type: .peaking, frequency: 350, gain: -2.5, q: 1.0),
                    EQBand(type: .peaking, frequency: 3000, gain: 4, q: 1.2),
                ],
                notes: "Speech and vocals — cut mud, boost presence"),

        factory(id: FactoryPresetID.telephone, name: "Telephone",
                bands: [
                    EQBand(type: .highPass, frequency: 300, gain: 0, q: 0.707),
                    EQBand(type: .lowPass, frequency: 3400, gain: 0, q: 0.707),
                ],
                notes: "Narrowband voice — 300 Hz–3.4 kHz bandpass"),

        factory(id: FactoryPresetID.loudness, name: "Loudness",
                bands: [
                    EQBand(type: .lowShelf, frequency: 100, gain: 2.5, q: 0.707),
                    EQBand(type: .highShelf, frequency: 12000, gain: 2.5, q: 0.707),
                ],
                notes: "Subtle loudness contour — gentle bass and treble lift"),

        factory(id: FactoryPresetID.rock, name: "Rock",
                bands: [
                    EQBand(type: .lowShelf, frequency: 90, gain: 2.5, q: 0.707),
                    EQBand(type: .peaking, frequency: 700, gain: -3, q: 2.0),
                    EQBand(type: .peaking, frequency: 4000, gain: 2.5, q: 1.0),
                    EQBand(type: .highShelf, frequency: 10000, gain: 1.5, q: 0.707),
                ],
                notes: "Rock mix — punchy lows, scooped low-mids, present highs"),

        factory(id: FactoryPresetID.filterShowcase, name: "Filter Showcase",
                bands: [
                    EQBand(type: .highPass, frequency: 35, gain: 0, q: 0.707),
                    EQBand(type: .lowShelf, frequency: 90, gain: 4, q: 0.707),
                    EQBand(type: .peaking, frequency: 220, gain: -2, q: 1.2),
                    EQBand(type: .peaking, frequency: 600, gain: 1.5, q: 1.0),
                    EQBand(type: .peaking, frequency: 1200, gain: -1, q: 1.5),
                    EQBand(type: .peaking, frequency: 2800, gain: 3, q: 1.0),
                    EQBand(type: .notch, frequency: 4500, gain: -4, q: 3.0),
                    EQBand(type: .peaking, frequency: 7000, gain: 2, q: 1.4),
                    EQBand(type: .highShelf, frequency: 11000, gain: 4, q: 0.707),
                    EQBand(type: .lowPass, frequency: 18000, gain: 0, q: 0.707),
                ],
                notes: "Demo of all filter types — 10 bands (pass, shelf, peak, notch)"),

        // A sine wave traced across the spectrum with 16 log-spaced peaking bands
        // (gains follow sin over 2.5 cycles, ±8.7 dB, Q 1.8). Purely artistic —
        // the summed response draws a clean wave on the graph; not corrective.
        factory(id: FactoryPresetID.sonarWave, name: "Sonar Wave",
                bands: [
                    EQBand(type: .peaking, frequency: 28, gain: 0, q: 1.8),
                    EQBand(type: .peaking, frequency: 43, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 66, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 101, gain: 0, q: 1.8),
                    EQBand(type: .peaking, frequency: 155, gain: -8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 237, gain: -8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 363, gain: 0, q: 1.8),
                    EQBand(type: .peaking, frequency: 557, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 854, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 1310, gain: 0, q: 1.8),
                    EQBand(type: .peaking, frequency: 2008, gain: -8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 3078, gain: -8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 4718, gain: 0, q: 1.8),
                    EQBand(type: .peaking, frequency: 7233, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 11089, gain: 8.7, q: 1.8),
                    EQBand(type: .peaking, frequency: 17000, gain: 0, q: 1.8),
                ],
                notes: "A sine wave across the spectrum — a playful, artistic profile (not corrective EQ)"),
    ]

    /// Returns the canonical factory definition for a built-in preset id.
    public static func canonicalFactory(id: UUID) -> EQProfile? {
        factoryPresets.first { $0.id == id }
    }

    /// Convenience for creating a new user profile.
    public static func newUserProfile(name: String = "New Profile") -> EQProfile {
        EQProfile(
            id: UUID(),
            name: name,
            preamp: 0.0,
            bands: [],
            isFavorite: false,
            sourceAttribution: nil,
            notes: nil,
            isFactory: false
        )
    }

    /// Whether this profile's EQ content differs from the shipped factory default.
    /// Compares band *parameters*, not band identity: the canonical presets mint
    /// fresh band UUIDs every process launch, so an id-sensitive comparison would
    /// flag every loaded factory preset as "modified" after a relaunch.
    public func differsFromFactoryDefault() -> Bool {
        guard isFactory, let canonical = Self.canonicalFactory(id: id) else { return false }
        if preamp != canonical.preamp || notes != canonical.notes { return true }
        guard bands.count == canonical.bands.count else { return true }
        return !zip(bands, canonical.bands).allSatisfy { $0.hasSameParameters(as: $1) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, preamp, bands, isFavorite, sourceAttribution, notes, isFactory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        preamp = try container.decode(Double.self, forKey: .preamp)
        bands = try container.decode([EQBand].self, forKey: .bands)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        sourceAttribution = try container.decodeIfPresent(String.self, forKey: .sourceAttribution)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        isFactory = try container.decodeIfPresent(Bool.self, forKey: .isFactory) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(preamp, forKey: .preamp)
        try container.encode(bands, forKey: .bands)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(sourceAttribution, forKey: .sourceAttribution)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(isFactory, forKey: .isFactory)
    }

    private static func factory(
        id: UUID,
        name: String,
        preamp: Double = 0,
        bands: [EQBand],
        notes: String
    ) -> EQProfile {
        EQProfile(
            id: id,
            name: name,
            preamp: preamp,
            bands: bands,
            isFavorite: false,
            sourceAttribution: nil,
            notes: notes,
            isFactory: true
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

    /// Equality of the audible parameters, ignoring the band's identity.
    public func hasSameParameters(as other: EQBand) -> Bool {
        type == other.type && frequency == other.frequency && gain == other.gain && q == other.q
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
