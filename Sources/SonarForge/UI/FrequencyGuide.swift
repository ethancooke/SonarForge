import Foundation
import SwiftUI

/// Teaching zones along the audible range: short names + typical sounds so
/// users can link "this Hz" to "that instrument" without a reference panel.
struct FrequencyZone: Identifiable, Equatable {
    let id: String
    /// Inclusive lower bound (Hz).
    let minHz: Double
    /// Exclusive upper bound (Hz), except the last zone which is inclusive.
    let maxHz: Double
    let name: String
    /// Short list of typical sources (UI chips / tooltips).
    let sounds: String
    /// What too much boost often does.
    let tooMuch: String

    /// Compact one-liner for tooltips and the live guide badge.
    var summary: String {
        "\(name) · \(sounds)"
    }

    var tooltip: String {
        "\(name) (\(formatRange))\n\(sounds)\nToo much: \(tooMuch)"
    }

    var formatRange: String {
        "\(Self.formatHz(minHz))–\(Self.formatHz(maxHz))"
    }

    static func formatHz(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k == floor(k) ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz.rounded()))"
    }

    /// Canonical teaching bands (log-friendly breakpoints).
    static let all: [FrequencyZone] = [
        FrequencyZone(id: "sub", minHz: 20, maxHz: 60,
                      name: "Sub",
                      sounds: "kick thump, synth sub",
                      tooMuch: "boom, speakers struggle"),
        FrequencyZone(id: "bass", minHz: 60, maxHz: 120,
                      name: "Bass",
                      sounds: "bass guitar, kick body",
                      tooMuch: "muddy low end"),
        FrequencyZone(id: "lowmids", minHz: 120, maxHz: 250,
                      name: "Low mids",
                      sounds: "warmth, boxiness, body",
                      tooMuch: "cardboard / mud"),
        FrequencyZone(id: "mids", minHz: 250, maxHz: 500,
                      name: "Mids body",
                      sounds: "guitars, male vocals",
                      tooMuch: "boxy, nasal"),
        FrequencyZone(id: "midhi", minHz: 500, maxHz: 2000,
                      name: "Mids",
                      sounds: "horns, instruments, speech",
                      tooMuch: "honk, telephone"),
        FrequencyZone(id: "presence", minHz: 2000, maxHz: 4000,
                      name: "Presence",
                      sounds: "vocals, snare crack, attack",
                      tooMuch: "harsh, fatiguing"),
        FrequencyZone(id: "brilliance", minHz: 4000, maxHz: 8000,
                      name: "Brilliance",
                      sounds: "cymbals, air, sibilance",
                      tooMuch: "sizzle, lispy “s”"),
        FrequencyZone(id: "air", minHz: 8000, maxHz: 20000.01,
                      name: "Air",
                      sounds: "sheen, room, sparkle",
                      tooMuch: "hiss, empty boost"),
    ]

    static func zone(forHz hz: Double) -> FrequencyZone {
        let f = min(max(hz, 20), 20000)
        for z in all where f >= z.minHz && f < z.maxHz {
            return z
        }
        return all[all.count - 1]
    }

    /// Log-axis span of this zone within [fMin, fMax], as 0…1 x fractions.
    func xSpan(fMin: Double = 20, fMax: Double = 20000) -> (start: CGFloat, end: CGFloat) {
        func x(_ f: Double) -> CGFloat {
            let clamped = min(max(f, fMin), fMax)
            return CGFloat(log(clamped / fMin) / log(fMax / fMin))
        }
        return (x(minHz), x(min(maxHz, fMax)))
    }
}

// MARK: - Zone strip (under the EQ curve)

/// Thin log-frequency legend: zone chips; highlights the zone under the
/// selected or hovered band frequency.
struct FrequencyZoneStrip: View {
    /// Hz of the active band (selected or hovered); nil = no emphasis.
    var activeFrequency: Double?

    private let fMin = 20.0
    private let fMax = 20000.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let active = activeFrequency.map { FrequencyZone.zone(forHz: $0) }
            ZStack(alignment: .leading) {
                // Soft zone backgrounds.
                ForEach(FrequencyZone.all) { zone in
                    let span = zone.xSpan(fMin: fMin, fMax: fMax)
                    let x0 = span.start * w
                    let x1 = span.end * w
                    let isActive = active?.id == zone.id
                    Rectangle()
                        .fill(BandPalette.color(forFrequency: (zone.minHz + min(zone.maxHz, fMax)) / 2)
                            .opacity(isActive ? 0.28 : 0.10))
                        .frame(width: max(1, x1 - x0), height: geo.size.height)
                        .offset(x: x0)
                }
                // Zone names (skip if too narrow).
                ForEach(FrequencyZone.all) { zone in
                    let span = zone.xSpan(fMin: fMin, fMax: fMax)
                    let x0 = span.start * w
                    let width = (span.end - span.start) * w
                    let isActive = active?.id == zone.id
                    if width >= 36 {
                        Text(zone.name)
                            .font(.system(size: 9, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: width - 4, alignment: .center)
                            .offset(x: x0 + 2)
                    }
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if let f = activeFrequency {
            let z = FrequencyZone.zone(forHz: f)
            return "Frequency guide: \(Int(f)) hertz, \(z.name). \(z.sounds). Too much: \(z.tooMuch)"
        }
        return "Frequency guide: sub through air zones under the EQ curve"
    }
}

// MARK: - Live badge (selected / hovered band)

struct FrequencyGuideBadge: View {
    let frequency: Double
    let gainDB: Double?

    var body: some View {
        let zone = FrequencyZone.zone(forHz: frequency)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(FrequencyZone.formatHz(frequency) + "Hz")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(zone.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BandPalette.color(forFrequency: frequency))
                if let gainDB {
                    Text(String(format: "%+.1f dB", gainDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(zone.sounds)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Too much: \(zone.tooMuch)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(BandPalette.color(forFrequency: frequency).opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
