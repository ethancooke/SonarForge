import SwiftUI

/// Spectral band coloring: a band's color is its place in the audible spectrum —
/// warm reds/oranges for bass, greens/yellows for mids, blues/violets for treble.
/// The color therefore *means* something (what part of the sound the band shapes)
/// and is shown consistently on the graph footprint, the draggable handle, and
/// the band-list row. It updates live as a band is dragged across the spectrum.
enum BandPalette {
    /// Warm → cool stops, evenly spaced in log frequency from 20 Hz to 20 kHz.
    private static let stops: [(r: Double, g: Double, b: Double)] = [
        (0.949, 0.329, 0.357),  // 20 Hz  — red
        (0.984, 0.478, 0.235),  //          orange
        (0.988, 0.639, 0.212),  //          amber
        (0.969, 0.788, 0.282),  //          yellow
        (0.710, 0.800, 0.247),  //          lime
        (0.373, 0.702, 0.392),  //          green
        (0.184, 0.718, 0.651),  //          teal
        (0.239, 0.627, 0.910),  //          blue
        (0.369, 0.471, 0.878),  //          indigo
        (0.604, 0.420, 0.878),  // 20 kHz — violet
    ]

    /// Color for a band centered at `frequency`, interpolated along the spectral
    /// ramp by log position between 20 Hz and 20 kHz.
    static func color(forFrequency frequency: Double) -> Color {
        let low = 20.0, high = 20_000.0
        let clamped = min(max(frequency, low), high)
        let p = log(clamped / low) / log(high / low)          // 0…1
        let scaled = p * Double(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        let t = scaled - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red:   a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue:  a.b + (b.b - a.b) * t)
    }
}
