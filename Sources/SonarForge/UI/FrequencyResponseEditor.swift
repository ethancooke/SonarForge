import SwiftUI

/// Graphical EQ editor (Chunk 5.2 core): the summed frequency-response curve
/// with a draggable handle per band.
///
/// Interactions:
/// - Drag a handle: sets frequency (x, log axis) and gain (y) live; the engine
///   updates during the drag, the profile file is written once on release.
/// - Double-click empty space: adds a peaking band there.
/// - Right-click a handle: delete the band.
/// - Click a handle: select (highlights; numeric editing in the sidebar).
///
/// Deferred 5.2 polish: Q via scroll-wheel/modifier drag, snapping, keyboard
/// nudging, zoom. Q is numerically editable in the sidebar.
///
/// Performance note: this view observes only the current profile and selection
/// (it re-renders on edits, not at the spectrum's 20 Hz — see AUDIO_PATH.md on
/// observation isolation).
struct FrequencyResponseEditor: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedBandID: UUID?

    private static let minFrequency = 20.0
    private static let maxFrequency = 20000.0
    private static let minDB = -15.0
    private static let maxDB = 15.0
    private static let curvePointCount = 160
    /// Display-only sample rate; curve shape below 20 kHz is visually identical
    /// across the supported device rates.
    private static let displaySampleRate = 48000.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let bands = appModel.currentProfile.bands

            ZStack {
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                    drawCurve(for: bands, in: &context, size: size)
                }

                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    handle(for: band, at: index, in: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    addBand(at: value.location, in: size)
                }
            )
        }
        .accessibilityLabel("Frequency response editor")
    }

    // MARK: - Coordinate mapping (log frequency ↔ x, dB ↔ y)

    private func x(forFrequency frequency: Double, width: CGFloat) -> CGFloat {
        let ratio = log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency)
        return width * CGFloat(min(max(ratio, 0), 1))
    }

    private func frequency(forX x: CGFloat, width: CGFloat) -> Double {
        let ratio = Double(min(max(x / max(width, 1), 0), 1))
        return Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, ratio)
    }

    private func y(forDB db: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, Self.minDB), Self.maxDB)
        return height * CGFloat(1 - (clamped - Self.minDB) / (Self.maxDB - Self.minDB))
    }

    private func db(forY y: CGFloat, height: CGFloat) -> Double {
        let ratio = Double(min(max(1 - y / max(height, 1), 0), 1))
        return Self.minDB + ratio * (Self.maxDB - Self.minDB)
    }

    // MARK: - Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        // Octave gridlines.
        for frequency in [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
            let lineX = x(forFrequency: frequency, width: size.width)
            lines.move(to: CGPoint(x: lineX, y: 0))
            lines.addLine(to: CGPoint(x: lineX, y: size.height))
        }
        // ±6 / ±12 dB gridlines.
        for db in [-12.0, -6, 6, 12] {
            let lineY = y(forDB: db, height: size.height)
            lines.move(to: CGPoint(x: 0, y: lineY))
            lines.addLine(to: CGPoint(x: size.width, y: lineY))
        }
        context.stroke(lines, with: .color(.secondary.opacity(0.12)), lineWidth: 1)

        // 0 dB reference line, slightly stronger.
        var zero = Path()
        let zeroY = y(forDB: 0, height: size.height)
        zero.move(to: CGPoint(x: 0, y: zeroY))
        zero.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zero, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
    }

    private func drawCurve(for bands: [EQBand], in context: inout GraphicsContext, size: CGSize) {
        guard !bands.isEmpty else { return }
        let frequencies = EQResponseCurve.logSpacedFrequencies(count: Self.curvePointCount)
        let response = EQResponseCurve.responseDB(bands: bands, sampleRate: Self.displaySampleRate, frequencies: frequencies)

        var curve = Path()
        for (i, frequency) in frequencies.enumerated() {
            let point = CGPoint(x: x(forFrequency: frequency, width: size.width),
                                y: y(forDB: response[i], height: size.height))
            if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        // Soft fill between the curve and 0 dB for readability.
        var fill = curve
        let zeroY = y(forDB: 0, height: size.height)
        fill.addLine(to: CGPoint(x: size.width, y: zeroY))
        fill.addLine(to: CGPoint(x: 0, y: zeroY))
        fill.closeSubpath()
        context.fill(fill, with: .color(.accentColor.opacity(0.08)))
    }

    // MARK: - Handles

    @ViewBuilder
    private func handle(for band: EQBand, at index: Int, in size: CGSize) -> some View {
        let isSelected = band.id == selectedBandID
        let position = CGPoint(x: x(forFrequency: band.frequency, width: size.width),
                               y: y(forDB: band.gain, height: size.height))

        Circle()
            .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: isSelected ? 16 : 12, height: isSelected ? 16 : 12)
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedBandID = band.id
                        var updated = band
                        updated.frequency = frequency(forX: value.location.x, width: size.width)
                        // Pass filters have no gain; dragging them only moves frequency.
                        if band.type != .lowPass && band.type != .highPass && band.type != .notch {
                            updated.gain = db(forY: value.location.y, height: size.height)
                        }
                        appModel.updateBand(at: index, updated, persist: false)
                    }
                    .onEnded { _ in
                        appModel.commitProfileEdit()
                    }
            )
            .contextMenu {
                Button("Delete Band", role: .destructive) {
                    if selectedBandID == band.id { selectedBandID = nil }
                    appModel.removeBand(at: index)
                }
            }
            .help("\(band.type.displayName) — \(Int(band.frequency)) Hz, \(String(format: "%+.1f", band.gain)) dB, Q \(String(format: "%.2f", band.q))")
    }

    private func addBand(at location: CGPoint, in size: CGSize) {
        let band = EQBand(
            type: .peaking,
            frequency: frequency(forX: location.x, width: size.width),
            gain: db(forY: location.y, height: size.height),
            q: 1.0
        )
        if let added = appModel.addBand(band) {
            selectedBandID = added.id
        }
    }
}
