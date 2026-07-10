import SwiftUI

/// Graphical EQ editor (Chunk 5.2 core): the summed frequency-response curve
/// with a draggable handle per band.
///
/// Interactions:
/// - Drag a handle: sets frequency (x, log axis) and gain (y) live; the engine
///   updates during the drag, the profile file is written once on release.
/// - ⌥-drag a handle vertically: adjusts Q (narrower up, wider down).
/// - Arrow keys (after clicking the editor): nudge the selected band —
///   ←/→ frequency by 1/24 octave, ↑/↓ gain by 0.5 dB.
/// - Double-click empty space: adds a peaking band there.
/// - Right-click a handle: delete the band.
/// - Click a handle: select (highlights; numeric editing in the sidebar).
///
/// Zone strip + handle tooltips teach which instruments sit in which band
/// (see `FrequencyGuide.swift`). Deferred: snapping, zoom.
///
/// Performance note: this view observes only the current profile and selection
/// (it re-renders on edits, not at the spectrum's 20 Hz — see AUDIO_PATH.md on
/// observation isolation).
struct FrequencyResponseEditor: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedBandID: UUID?

    /// Band values at drag start — Q drags are relative to these.
    @State private var dragStartBand: EQBand?
    /// Handle under the pointer (for guide badge when nothing is selected).
    @State private var hoveredBandID: UUID?

    private static let minFrequency = 20.0
    private static let maxFrequency = 20000.0
    private static let minDB = -15.0
    private static let maxDB = 15.0
    private static let curvePointCount = 160
    /// Fixed sample frequencies for the curve — static so resize animation
    /// frames never recompute them.
    private static let curveFrequencies = EQResponseCurve.logSpacedFrequencies(count: curvePointCount)
    /// Display-only sample rate; curve shape below 20 kHz is visually identical
    /// across the supported device rates.
    private static let displaySampleRate = 48000.0

    var body: some View {
        // Computed once per body evaluation (band edits) and *captured* by the
        // Canvas closure: window/panel resizes re-invoke the closure with a new
        // size but must not redo the 160-point biquad sum per frame. This was
        // the band-panel toggle lag (the resize animation recomputed the curve
        // every frame, in a Debug build, while the spectrum also redrew).
        let bands = appModel.currentProfile.bands
        let response = bands.isEmpty ? [] : EQResponseCurve.responseDB(
            bands: bands, sampleRate: Self.displaySampleRate, frequencies: Self.curveFrequencies)
        // Each band's own contribution (color + its response + selection), so its
        // footprint can be drawn in the band's color behind the summed curve.
        let bandCurves: [(color: Color, response: [Double], selected: Bool)] = bands.map { band in
            (BandPalette.color(forFrequency: band.frequency),
             EQResponseCurve.responseDB(bands: [band], sampleRate: Self.displaySampleRate, frequencies: Self.curveFrequencies),
             band.id == selectedBandID)
        }
        let guideBand = bands.first(where: { $0.id == selectedBandID })
            ?? bands.first(where: { $0.id == hoveredBandID })

        VStack(spacing: 4) {
            GeometryReader { geometry in
                let size = geometry.size

                ZStack {
                    Canvas { context, size in
                        drawGrid(in: &context, size: size)
                        for bandCurve in bandCurves {
                            drawBandFootprint(bandCurve.response, color: bandCurve.color,
                                              emphasized: bandCurve.selected, in: &context, size: size)
                        }
                        drawTotalCurve(response: response, in: &context, size: size)
                    }

                    ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                        handle(for: band, at: index, in: size)
                    }

                    // Live teaching badge for the focused handle (select or hover).
                    if let band = guideBand {
                        FrequencyGuideBadge(
                            frequency: band.frequency,
                            gainDB: (band.type == .lowPass || band.type == .highPass || band.type == .notch)
                                ? nil : band.gain
                        )
                        .position(
                            x: min(max(x(forFrequency: band.frequency, width: size.width), 90),
                                   size.width - 90),
                            y: max(y(forDB: band.gain, height: size.height) - 44, 36)
                        )
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        addBand(at: value.location, in: size)
                    }
                )
            }

            FrequencyZoneStrip(activeFrequency: guideBand?.frequency)
                .padding(.horizontal, 2)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudgeSelected(frequencyFactor: pow(2, -1.0 / 24)) }
        .onKeyPress(.rightArrow) { nudgeSelected(frequencyFactor: pow(2, 1.0 / 24)) }
        .onKeyPress(.upArrow) { nudgeSelected(gainDelta: 0.5) }
        .onKeyPress(.downArrow) { nudgeSelected(gainDelta: -0.5) }
        .accessibilityLabel("Frequency response editor")
    }

    /// Arrow-key nudging of the selected band (requires the editor focused —
    /// clicking a handle does both).
    private func nudgeSelected(frequencyFactor: Double = 1, gainDelta: Double = 0) -> KeyPress.Result {
        guard let id = selectedBandID,
              let index = appModel.currentProfile.bands.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        var band = appModel.currentProfile.bands[index]
        band.frequency = min(max(band.frequency * frequencyFactor, Self.minFrequency), Self.maxFrequency)
        if band.type != .lowPass && band.type != .highPass && band.type != .notch {
            band.gain = min(max(band.gain + gainDelta, Self.minDB), Self.maxDB)
        }
        appModel.updateBand(at: index, band)
        return .handled
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

        drawAxisLabels(in: &context, size: size)
    }

    /// Frequency labels along the bottom, dB (EQ gain) labels on the left.
    private func drawAxisLabels(in context: inout GraphicsContext, size: CGSize) {
        let labelFont = Font.system(size: 9)

        let frequencyLabels: [(Double, String)] = [
            (31.5, "31"), (63, "63"), (125, "125"), (250, "250"), (500, "500"),
            (1000, "1k"), (2000, "2k"), (4000, "4k"), (8000, "8k"), (16000, "16k"),
        ]
        for (frequency, label) in frequencyLabels {
            let text = context.resolve(Text(label).font(labelFont).foregroundStyle(.secondary))
            let textSize = text.measure(in: size)
            context.draw(text, at: CGPoint(x: x(forFrequency: frequency, width: size.width),
                                           y: size.height - textSize.height / 2 - 2))
        }

        for db in [-12.0, -6, 0, 6, 12] {
            let label = db == 0 ? "0 dB" : String(format: "%+.0f", db)
            let text = context.resolve(Text(label).font(labelFont).foregroundStyle(.secondary))
            let textSize = text.measure(in: size)
            context.draw(text, at: CGPoint(x: textSize.width / 2 + 4,
                                           y: y(forDB: db, height: size.height) - textSize.height / 2 - 2))
        }
    }

    /// A single band's contribution: a translucent fill from 0 dB to its own
    /// response plus a line, both in the band's color. The selected band is
    /// emphasized so "what does this band do" reads at a glance.
    private func drawBandFootprint(_ response: [Double], color: Color, emphasized: Bool,
                                   in context: inout GraphicsContext, size: CGSize) {
        guard !response.isEmpty else { return }

        var curve = Path()
        for (i, frequency) in Self.curveFrequencies.enumerated() {
            let point = CGPoint(x: x(forFrequency: frequency, width: size.width),
                                y: y(forDB: response[i], height: size.height))
            if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }

        var fill = curve
        let zeroY = y(forDB: 0, height: size.height)
        fill.addLine(to: CGPoint(x: size.width, y: zeroY))
        fill.addLine(to: CGPoint(x: 0, y: zeroY))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(emphasized ? 0.22 : 0.09)))
        context.stroke(curve, with: .color(color.opacity(emphasized ? 1.0 : 0.5)),
                       style: StrokeStyle(lineWidth: emphasized ? 2 : 1.2, lineJoin: .round))
    }

    /// The summed response — the "what you actually hear" curve — drawn neutral
    /// and bold on top of the colored band footprints.
    private func drawTotalCurve(response: [Double], in context: inout GraphicsContext, size: CGSize) {
        guard !response.isEmpty else { return }

        var curve = Path()
        for (i, frequency) in Self.curveFrequencies.enumerated() {
            let point = CGPoint(x: x(forFrequency: frequency, width: size.width),
                                y: y(forDB: response[i], height: size.height))
            if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(.primary.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    // MARK: - Handles

    @ViewBuilder
    private func handle(for band: EQBand, at index: Int, in size: CGSize) -> some View {
        let isSelected = band.id == selectedBandID
        let color = BandPalette.color(forFrequency: band.frequency)
        let position = CGPoint(x: x(forFrequency: band.frequency, width: size.width),
                               y: y(forDB: band.gain, height: size.height))

        let zone = FrequencyZone.zone(forHz: band.frequency)
        let helpText = """
            \(band.type.displayName) — \(FrequencyZone.formatHz(band.frequency))Hz, \
            \(String(format: "%+.1f", band.gain)) dB, Q \(String(format: "%.2f", band.q))
            \(zone.tooltip)
            """

        Circle()
            .fill(isSelected ? color : Color(nsColor: .controlBackgroundColor))
            .stroke(color, lineWidth: 2)
            .frame(width: isSelected ? 16 : 12, height: isSelected ? 16 : 12)
            .position(position)
            .onHover { inside in
                if inside {
                    hoveredBandID = band.id
                } else if hoveredBandID == band.id {
                    hoveredBandID = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedBandID = band.id
                        if dragStartBand?.id != band.id {
                            dragStartBand = band
                        }
                        var updated = band

                        if NSEvent.modifierFlags.contains(.option), let start = dragStartBand {
                            // ⌥-drag: vertical motion adjusts Q multiplicatively
                            // relative to the drag start (up = narrower).
                            let octavesOfQ = Double(-value.translation.height) / 60.0
                            updated.q = min(max(start.q * pow(2, octavesOfQ), 0.1), 18.0)
                            updated.frequency = start.frequency
                            updated.gain = start.gain
                        } else {
                            updated.frequency = frequency(forX: value.location.x, width: size.width)
                            // Pass filters have no gain; dragging them only moves frequency.
                            if band.type != .lowPass && band.type != .highPass && band.type != .notch {
                                updated.gain = db(forY: value.location.y, height: size.height)
                            }
                        }
                        appModel.updateBand(at: index, updated, persist: false)
                    }
                    .onEnded { _ in
                        dragStartBand = nil
                        appModel.commitProfileEdit()
                    }
            )
            .contextMenu {
                Button("Delete Band", role: .destructive) {
                    if selectedBandID == band.id { selectedBandID = nil }
                    appModel.removeBand(at: index)
                }
            }
            .help(helpText)
            .accessibilityElement()
            .accessibilityLabel("Band \(index + 1), \(band.type.displayName), \(zone.name)")
            .accessibilityValue(
                "\(Int(band.frequency)) hertz, \(String(format: "%+.1f", band.gain)) decibels, "
                    + "Q \(String(format: "%.2f", band.q)). \(zone.sounds). Too much: \(zone.tooMuch)"
            )
            .accessibilityHint("Adjust to change gain in half-decibel steps")
            .accessibilityAdjustableAction { direction in
                selectedBandID = band.id
                switch direction {
                case .increment: _ = nudgeSelected(gainDelta: 0.5)
                case .decrement: _ = nudgeSelected(gainDelta: -0.5)
                @unknown default: break
                }
            }
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
