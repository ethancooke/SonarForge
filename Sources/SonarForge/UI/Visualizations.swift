import SwiftUI

/// Ways to visualize the playing audio in the main display pane. `curve` is the
/// original frequency-response editor (the default); the others are read-only
/// visualizers driven by the same ~20 Hz spectrum bins the analyzer produces.
enum VisualizationStyle: String, CaseIterable, Identifiable {
    case curve
    case bars
    case ledBars
    case spectrogram
    case reactor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curve:       "Frequency Response"
        case .bars:        "Spectrum Bars"
        case .ledBars:     "LED Meters"
        case .spectrogram: "Spectrogram"
        case .reactor:     "Reactor"
        }
    }

    var systemImage: String {
        switch self {
        case .curve:       "waveform.path"
        case .bars:        "chart.bar.fill"
        case .ledBars:     "rectangle.split.3x1.fill"
        case .spectrogram: "square.grid.3x3.fill"
        case .reactor:     "hurricane"
        }
    }
}

/// Shared dBFS → 0…1 mapping, matching `SpectrumView`'s floor/ceiling so every
/// visualization reads at the same vertical scale.
enum VizScale {
    static let floorDB: Float = -100
    static let ceilingDB: Float = 0

    static func norm(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1))
    }
}

// MARK: - Spectrum Bars (WinAmp-style)

/// Vertical bars per frequency bin with slowly-falling peak-hold caps.
struct SpectrumBarsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var peaks: [Float] = []

    /// Peak caps fall this many dB per 20 Hz frame (~40 dB/s).
    private static let peakFallDBPerFrame: Float = 2.0

    var body: some View {
        let levels = appModel.postEQLevels
        Canvas { context, size in
            guard levels.count > 1 else { return }
            let n = levels.count
            let gap: CGFloat = n > 48 ? 1.5 : 3
            let barWidth = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))

            for i in 0..<n {
                let x = CGFloat(i) * (barWidth + gap)
                let height = VizScale.norm(levels[i]) * size.height
                let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2)),
                    with: .linearGradient(
                        Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.35)]),
                        startPoint: CGPoint(x: 0, y: size.height - height),
                        endPoint: CGPoint(x: 0, y: size.height))
                )
                // Peak-hold cap.
                if i < peaks.count {
                    let capY = size.height - VizScale.norm(peaks[i]) * size.height
                    let cap = CGRect(x: x, y: max(0, capY - 2), width: barWidth, height: 2)
                    context.fill(Path(cap), with: .color(.primary.opacity(0.85)))
                }
            }
        }
        .onChange(of: levels) { _, new in updatePeaks(new) }
        .accessibilityLabel("Spectrum bars visualization")
    }

    private func updatePeaks(_ new: [Float]) {
        guard peaks.count == new.count else { peaks = new; return }
        for i in new.indices {
            peaks[i] = max(new[i], peaks[i] - Self.peakFallDBPerFrame)
        }
    }
}

// MARK: - LED Meters (physical stereo-rack style)

/// Discrete LED segments per band with green/amber/red zones and a bright
/// peak-hold segment — the graphic-EQ look of hi-fi rack equipment.
struct LEDBarsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var peaks: [Float] = []

    private static let segments = 22
    private static let peakFallDBPerFrame: Float = 1.6
    /// Fraction of the ladder that is green / amber before turning red.
    private static let greenTop = 0.6
    private static let amberTop = 0.82

    var body: some View {
        let levels = appModel.postEQLevels
        Canvas { context, size in
            guard levels.count > 1 else { return }
            let n = levels.count
            let gap: CGFloat = n > 48 ? 1.5 : 3
            let colWidth = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let segGap: CGFloat = 1.5
            let segHeight = max(1, (size.height - segGap * CGFloat(Self.segments - 1)) / CGFloat(Self.segments))

            for i in 0..<n {
                let x = CGFloat(i) * (colWidth + gap)
                let lit = Int((VizScale.norm(levels[i]) * CGFloat(Self.segments)).rounded())
                let peakSeg = i < peaks.count
                    ? Int((VizScale.norm(peaks[i]) * CGFloat(Self.segments)).rounded())
                    : 0

                for j in 0..<Self.segments {
                    let y = size.height - CGFloat(j + 1) * segHeight - CGFloat(j) * segGap
                    let rect = CGRect(x: x, y: y, width: colWidth, height: segHeight)
                    let base = Self.color(forSegment: j)
                    let isLit = j < lit
                    let isPeak = j == peakSeg - 1 && peakSeg > 0
                    let color = isPeak ? base : (isLit ? base : base.opacity(0.10))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .onChange(of: levels) { _, new in updatePeaks(new) }
        .accessibilityLabel("LED meter visualization")
    }

    private static func color(forSegment j: Int) -> Color {
        let frac = Double(j) / Double(segments - 1)
        if frac < greenTop { return .green }
        if frac < amberTop { return .yellow }
        return .red
    }

    private func updatePeaks(_ new: [Float]) {
        guard peaks.count == new.count else { peaks = new; return }
        for i in new.indices {
            peaks[i] = max(new[i], peaks[i] - Self.peakFallDBPerFrame)
        }
    }
}

// MARK: - Spectrogram (scrolling waterfall)

/// Time × frequency heatmap that scrolls right-to-left, colour mapped to
/// magnitude. Frequency runs low (bottom) to high (top); newest column is at
/// the right edge.
struct SpectrogramView: View {
    @Environment(AppModel.self) private var appModel
    @State private var history: [[Float]] = []

    /// Retained columns (also the horizontal resolution). One 20 Hz frame per
    /// column ⇒ ~12 s of scrollback.
    private static let maxColumns = 240

    var body: some View {
        let levels = appModel.postEQLevels
        Canvas { context, size in
            guard !history.isEmpty, let bins = history.last?.count, bins > 0 else { return }
            let colWidth = size.width / CGFloat(Self.maxColumns)
            let rowHeight = size.height / CGFloat(bins)
            let startCol = Self.maxColumns - history.count

            for (c, column) in history.enumerated() {
                let x = CGFloat(startCol + c) * colWidth
                for (b, db) in column.enumerated() {
                    // Frequency low→high maps bottom→top.
                    let y = size.height - CGFloat(b + 1) * rowHeight
                    let rect = CGRect(x: x, y: y, width: colWidth + 0.5, height: rowHeight + 0.5)
                    context.fill(Path(rect), with: .color(Self.heat(VizScale.norm(db))))
                }
            }
        }
        .background(Color.black.opacity(0.25))
        .onChange(of: levels) { _, new in
            guard new.count > 1 else { return }
            history.append(new)
            if history.count > Self.maxColumns {
                history.removeFirst(history.count - Self.maxColumns)
            }
        }
        .accessibilityLabel("Spectrogram visualization")
    }

    private struct HeatStop {
        let t: CGFloat
        let r: Double
        let g: Double
        let b: Double
    }

    /// Magnitude → colour: near-black → indigo → magenta → orange → white,
    /// legible over the dark backing in both light and dark app themes.
    private static let heatStops = [
        HeatStop(t: 0.00, r: 0.02, g: 0.02, b: 0.08),
        HeatStop(t: 0.30, r: 0.25, g: 0.05, b: 0.45),
        HeatStop(t: 0.55, r: 0.75, g: 0.10, b: 0.55),
        HeatStop(t: 0.78, r: 0.98, g: 0.55, b: 0.20),
        HeatStop(t: 1.00, r: 1.00, g: 0.98, b: 0.85),
    ]

    private static func heat(_ t: CGFloat) -> Color {
        var lower = heatStops[0], upper = heatStops[heatStops.count - 1]
        for k in 1..<heatStops.count where heatStops[k].t >= t {
            upper = heatStops[k]
            lower = heatStops[k - 1]
            break
        }
        let span = upper.t - lower.t
        let f = span > 0 ? Double((t - lower.t) / span) : 0
        return Color(
            red: lower.r + (upper.r - lower.r) * f,
            green: lower.g + (upper.g - lower.g) * f,
            blue: lower.b + (upper.b - lower.b) * f)
    }
}
