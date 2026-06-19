import Foundation

/// Parser for the two text formats the AutoEQ project publishes
/// (https://github.com/jaakkopasanen/AutoEq):
///
/// **Parametric** (`… ParametricEQ.txt`):
/// ```
/// Preamp: -6.8 dB
/// Filter 1: ON PK Fc 21 Hz Gain 6.5 dB Q 1.06
/// Filter 9: ON HSC Fc 10000 Hz Gain -4.2 dB Q 0.70
/// ```
/// Filter types: PK (peaking), LSC/LS (low shelf), HSC/HS (high shelf), and the
/// rarer LP/HP/NO. `OFF` rows and unsupported types are skipped with a warning.
/// A missing Q defaults to 0.707 (AutoEQ's shelf convention in older outputs).
///
/// **GraphicEQ** (`… GraphicEQ.txt`):
/// ```
/// GraphicEQ: 20 -1.1; 21 -1.2; … ; 20000 -4.0
/// ```
/// Up to ~127 frequency/gain points, reduced here to at most 15 log-spaced
/// peaking bands (gain = mean of the points in each band's region, Q derived
/// from the band width). This is an approximation of the full curve — the
/// parametric format is preferred when available, and the importer says so.
///
/// Pure functions, no UI/engine dependencies — fully unit-testable.
public enum AutoEQImporter {

    public struct ParseResult: Equatable {
        public enum Format: Equatable { case parametric, graphic }
        public var format: Format
        public var bands: [EQBand]
        public var preamp: Double
        /// Non-fatal notes for the user ("2 OFF filters skipped", …).
        public var warnings: [String]
    }

    public enum ImportError: LocalizedError, Equatable {
        case emptyInput
        case noRecognizableContent

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                "Nothing to import — paste the contents of an AutoEQ file first."
            case .noRecognizableContent:
                "No “Filter N: …” lines or “GraphicEQ: …” line found. Paste the contents of an AutoEQ ParametricEQ.txt or GraphicEQ.txt file."
            }
        }
    }

    static let defaultQ = 0.707
    static let maxGraphicBands = 15
    /// Bands quieter than this after reduction are dropped (inaudible, saves slots).
    static let negligibleGainDB = 0.25

    // MARK: - Entry point

    public static func parse(_ text: String) throws -> ParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyInput }

        if let graphic = try parseGraphicEQ(trimmed) {
            return graphic
        }
        if let parametric = parseParametric(trimmed) {
            return parametric
        }
        throw ImportError.noRecognizableContent
    }

    // MARK: - Parametric format

    // swiftlint:disable:next line_length
    private static let filterLine = #/Filter\s+\d+\s*:\s*(?<state>ON|OFF)\s+(?<type>[A-Za-z]+)\s+Fc\s+(?<fc>[0-9]+(?:\.[0-9]+)?)\s*Hz\s+Gain\s+(?<gain>-?[0-9]+(?:\.[0-9]+)?)\s*dB(?:\s+Q\s+(?<q>[0-9]+(?:\.[0-9]+)?))?/#
        .ignoresCase()

    private static let preampLine =
        #/Preamp:\s*(?<db>-?[0-9]+(?:\.[0-9]+)?)\s*dB/#
        .ignoresCase()

    private static func filterType(fromAutoEQ token: String) -> FilterType? {
        switch token.uppercased() {
        case "PK", "PEQ": .peaking
        case "LSC", "LS", "LSQ": .lowShelf
        case "HSC", "HS", "HSQ": .highShelf
        case "LP", "LPQ": .lowPass
        case "HP", "HPQ": .highPass
        case "NO", "NOTCH": .notch
        default: nil
        }
    }

    private static func parseParametric(_ text: String) -> ParseResult? {
        var bands: [EQBand] = []
        var warnings: [String] = []
        var offCount = 0
        var sawFilterLine = false

        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = try? filterLine.firstMatch(in: String(line)) else { continue }
            sawFilterLine = true

            if String(match.state).uppercased() == "OFF" {
                offCount += 1
                continue
            }
            guard let type = filterType(fromAutoEQ: String(match.type)) else {
                warnings.append("Skipped unsupported filter type “\(match.type)”.")
                continue
            }
            let frequency = Double(match.fc) ?? 1000
            let gain = Double(match.gain) ?? 0
            let q = match.q.flatMap { Double($0) } ?? defaultQ
            bands.append(EQBand(type: type, frequency: frequency, gain: gain, q: q))
        }

        guard sawFilterLine else { return nil }

        if offCount > 0 {
            warnings.append("Skipped \(offCount) filter\(offCount == 1 ? "" : "s") marked OFF.")
        }
        if bands.count > RealtimeParametricEQ.maxBands {
            warnings.append("Profile has \(bands.count) bands; only the first \(RealtimeParametricEQ.maxBands) will be used.")
            bands = Array(bands.prefix(RealtimeParametricEQ.maxBands))
        }

        let preamp: Double
        if let match = try? preampLine.firstMatch(in: text), let db = Double(match.db) {
            preamp = db
        } else {
            // No Preamp line: derive headroom from the largest boost (AutoEQ convention).
            let maxBoost = bands.map(\.gain).max() ?? 0
            preamp = min(0, -maxBoost)
            if maxBoost > 0 {
                warnings.append("No Preamp line found — using \(String(format: "%.1f", preamp)) dB to offset the largest boost.")
            }
        }

        return ParseResult(format: .parametric, bands: bands, preamp: preamp, warnings: warnings)
    }

    // MARK: - GraphicEQ format

    /// Returns nil when the text has no GraphicEQ line; throws only for a
    /// GraphicEQ line whose payload is unusable.
    private static func parseGraphicEQ(_ text: String) throws -> ParseResult? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .first(where: { $0.lowercased().hasPrefix("graphiceq:") }) else { return nil }

        let payload = line.dropFirst("graphiceq:".count)
        var points: [(frequency: Double, gain: Double)] = []
        for pair in payload.split(separator: ";") {
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2,
                  let frequency = Double(parts[0]),
                  let gain = Double(parts[1]),
                  frequency > 0 else { continue }
            points.append((frequency, gain))
        }
        guard points.count >= 2 else { throw ImportError.noRecognizableContent }
        points.sort { $0.frequency < $1.frequency }

        let bands = reduceToBands(points: points, maxBands: maxGraphicBands)
        let maxBoost = bands.map(\.gain).max() ?? 0
        var warnings = [
            "GraphicEQ format: \(points.count) points approximated with "
                + "\(bands.count) parametric bands. Prefer the ParametricEQ file when available.",
        ]
        let preamp = min(0, -maxBoost)
        if preamp < 0 {
            warnings.append("Preamp set to \(String(format: "%.1f", preamp)) dB to offset the largest boost.")
        }
        return ParseResult(format: .graphic, bands: bands, preamp: preamp, warnings: warnings)
    }

    /// Reduces a dense frequency/gain curve to ≤ maxBands log-spaced peaking
    /// bands over 20 Hz–20 kHz. Band gain is the mean of the curve points in
    /// the band's region; Q matches the band width.
    static func reduceToBands(points: [(frequency: Double, gain: Double)], maxBands: Int) -> [EQBand] {
        let low = 20.0, high = 20000.0
        let octaves = log2(high / low)
        let width = octaves / Double(maxBands)
        // Q for a peaking filter whose bandwidth is `width` octaves.
        let q = pow(2, width / 2) / (pow(2, width) - 1)

        var bands: [EQBand] = []
        for i in 0..<maxBands {
            let fLo = low * pow(2, Double(i) * width)
            let fHi = fLo * pow(2, width)
            let center = (fLo * fHi).squareRoot()
            let regionGains = points.lazy
                .filter { $0.frequency >= fLo && $0.frequency < fHi }
                .map(\.gain)
            guard !regionGains.isEmpty else { continue }
            let mean = regionGains.reduce(0, +) / Double(regionGains.count)
            guard abs(mean) >= negligibleGainDB else { continue }
            bands.append(EQBand(type: .peaking, frequency: center, gain: (mean * 10).rounded() / 10, q: (q * 100).rounded() / 100))
        }
        return bands
    }

    // MARK: - Export (round trips + sharing)

    /// Renders a profile in AutoEQ's parametric text format. Pass/notch bands
    /// (which AutoEQ writes without meaningful gain) keep their Q.
    public static func exportParametricText(preamp: Double, bands: [EQBand]) -> String {
        var lines = ["Preamp: \(format(preamp)) dB"]
        for (index, band) in bands.enumerated() {
            let token: String = switch band.type {
            case .peaking:   "PK"
            case .lowShelf:  "LSC"
            case .highShelf: "HSC"
            case .lowPass:   "LP"
            case .highPass:  "HP"
            case .notch:     "NO"
            }
            lines.append("Filter \(index + 1): ON \(token) Fc \(format(band.frequency)) Hz Gain \(format(band.gain)) dB Q \(format(band.q))")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
