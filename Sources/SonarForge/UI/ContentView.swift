import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingProfileLibrary = false
    @State private var showingAutoEQImport = false
    @State private var selectedBandID: UUID?
    @State private var dropErrorMessage: String?
    /// Band sidebar visibility (persisted). The sidebar stays mounted and
    /// animates its width — destroying/recreating the AppKit-backed List on
    /// every toggle is what made earlier collapse attempts feel laggy.
    @AppStorage("showBandsPanel") private var showBandsPanel = true

    var body: some View {
        @Bindable var model = appModel

        HSplitView {
            // Left / main editor area
            VStack(spacing: 12) {
                // Engine lifecycle (start/stop/reset) and output device selection.
                AudioEnginePanel()
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Observation-isolated: Pre/Post/Legend toggles re-render only
                // this pane, never the band list, sliders, or engine panel.
                FrequencyPane(selectedBandID: $selectedBandID)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Profile")
                            .font(.subheadline)
                        Menu(appModel.currentProfile.name) {
                            ForEach(appModel.profileManager.profiles) { profile in
                                Button {
                                    appModel.selectProfile(id: profile.id)
                                } label: {
                                    if profile.id == appModel.profileManager.activeProfileID {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                        }
                        .fixedSize()
                        .help("Switch the active EQ profile. Manage and import profiles from the Profiles button in the toolbar.")
                        if appModel.currentProfile.isFactory {
                            Label("Built-in", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                        if appModel.currentProfile.isFactory,
                           appModel.profileManager.isFactoryModified(appModel.currentProfile.id) {
                            Button("Reset to Default") {
                                appModel.resetFactoryPreset(id: appModel.currentProfile.id)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    // Attribution is mandatory and always visible for imported
                    // profiles (D-006 / AutoEQ licensing courtesy).
                    if let attribution = appModel.currentProfile.sourceAttribution {
                        Label(attribution, systemImage: "person.text.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let notes = appModel.currentProfile.notes {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack {
                        Button(appModel.isBypassed ? "Bypass (ON)" : "Bypass") {
                            appModel.toggleBypass()
                        }
                        .tint(appModel.isBypassed ? .orange : .accentColor)
                        .help("Plays unprocessed system audio — no EQ, crossfeed, or gain trim.")

                        Picker("A/B compare", selection: Binding(
                            get: { appModel.showingB },
                            set: { showB in if showB != appModel.showingB { appModel.swapAB() } }
                        )) {
                            Text("A").tag(false)
                            Text("B").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Compare two profiles by ear. Pick a profile while on A, "
                              + "switch to B and pick another, then toggle A/B to compare.")

                        Spacer()

                        Button("Import AutoEQ…") { showingAutoEQImport = true }
                            .help("Import a headphone correction from the AutoEQ project")
                        Button("Reset to Flat") {
                            selectedBandID = nil
                            if appModel.profileManager.profiles.contains(where: { $0.id == FactoryPresetID.flat }) {
                                appModel.selectProfile(id: FactoryPresetID.flat)
                            } else {
                                appModel.loadProfile(.flat)
                            }
                        }
                        .help("Switch to the neutral Flat profile")
                    }

                    // Isolated leaves: slider drags only re-render these panels,
                    // not ContentView + FrequencyPane (which froze bars/LED).
                    GainStagingPanel()
                    CrossfeedPanel()
                }
                .padding(.horizontal)

                Spacer()
            }
            // Lower than the content's natural width on purpose: when the window
            // is narrow enough that HSplitView squeezes this pane, a high minWidth
            // forces the content wider than the pane and it overflows (clips) on
            // both sides. A lower floor lets the row compress to fit instead.
            .frame(minWidth: 440)

            // Right sidebar — numeric band editor. The collapse lives INSIDE this
            // HSplitView pane: AppKit split panes are independent layout worlds,
            // so toggling here never re-measures the left pane, and left-pane
            // toggles never re-measure these rows (that cross-measurement was the
            // lag — see commit message).
            if showBandsPanel {
            // Fixed-width sidebar: the pane is exactly as wide as the editor needs,
            // so there's no dead space on the right and the rows aren't stretched.
            VStack(alignment: .leading, spacing: 8) {
                Text("Bands")
                    .font(.headline)
                    .padding(.top, 4)

                BandListEditor(selectedBandID: $selectedBandID)

                HStack {
                    Button("+ Add Band") {
                        if let added = appModel.addBand(EQBand(type: .peaking, frequency: 1000, gain: 0, q: 1.0)) {
                            selectedBandID = added.id
                        }
                    }
                    .disabled(appModel.currentProfile.bands.count >= RealtimeParametricEQ.maxBands)
                    Spacer()
                }
                .padding(.bottom, 8)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(width: 356)
            } else {
                // Slim reveal strip so the panel is rediscoverable without the toolbar.
                VStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showBandsPanel = true }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .buttonStyle(.plain)
                    .help("Show the bands panel")
                    .accessibilityLabel("Show bands panel")
                    .padding(.top, 10)
                    Spacer()
                }
                .frame(width: 24)
            }
        }
        .navigationTitle("SonarForge")
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showBandsPanel.toggle() }
                } label: {
                    Label("Bands", systemImage: "sidebar.trailing")
                }
                .help(showBandsPanel ? "Hide the bands panel" : "Show the bands panel")
                .accessibilityLabel(showBandsPanel ? "Hide bands panel" : "Show bands panel")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingProfileLibrary = true
                } label: {
                    Label("Profiles", systemImage: "list.bullet")
                }
                .help("Manage profiles (create, rename, import, export)")
            }
        }
        .sheet(isPresented: $showingProfileLibrary) {
            ProfileLibraryView()
        }
        .sheet(isPresented: $showingAutoEQImport) {
            AutoEQImportView()
        }
        .sheet(isPresented: $model.showingShortcutsHelp) {
            ShortcutsHelpView()
        }
        .sheet(isPresented: $model.showingWelcome) {
            WelcomeView()
        }
        .sheet(isPresented: $model.showingTroubleshooting) {
            TroubleshootingView()
        }
        // Drop profile files anywhere on the window. Native profile JSON imports
        // directly; other text files fall back to the AutoEQ parser.
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
            return true
        }
        .alert("Import Problem", isPresented: Binding(
            get: { dropErrorMessage != nil },
            set: { if !$0 { dropErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { dropErrorMessage = nil }
        } message: {
            Text(dropErrorMessage ?? "")
        }
        .alert("Couldn’t Save Profile", isPresented: Binding(
            get: { appModel.profileSaveError != nil },
            set: { if !$0 { appModel.clearProfileSaveError() } }
        )) {
            Button("OK", role: .cancel) { appModel.clearProfileSaveError() }
        } message: {
            Text(appModel.profileSaveError
                  ?? "Your last edit could not be written to disk.")
        }
        .onAppear {
            // Docs/marketing: in-process capture (no Screen Recording TCC).
            WindowSnapshot.scheduleExportIfRequested()
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            // 1. Native profile JSON.
            if (try? appModel.importProfile(from: url)) != nil { continue }
            // 2. AutoEQ text (ParametricEQ.txt / GraphicEQ.txt or pasted-to-file).
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let result = try? AutoEQImporter.parse(text), !result.bands.isEmpty {
                let name = AutoEQImportView.suggestedName(fromFileName: url.deletingPathExtension().lastPathComponent)
                appModel.importAutoEQ(result, name: name.isEmpty ? "Imported Profile" : name, measuredBy: "")
                continue
            }
            failures.append(url.lastPathComponent)
        }
        if !failures.isEmpty {
            dropErrorMessage = "Could not import: \(failures.joined(separator: ", ")). Files must be SonarForge profile JSON or AutoEQ text."
        }
    }
}

/// Gain sliders in their own observation leaf so dragging preamp/output does
/// not re-evaluate ContentView (profile chrome, visualizer host, band list).
/// Both sliders use local `@State` while dragging (same pattern as crossfeed):
/// live DSP + model during the gesture; preamp profile JSON commit once on release.
/// Frequency Response spectrum stays fluid via SpectrumFeed (not MainActor Canvas).
struct GainStagingPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var preamp: Double = 0
    @State private var outputGain: Double = 0
    @State private var isDraggingPreamp = false
    @State private var isDraggingOutput = false

    var body: some View {
        GroupBox("Gain Staging") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Preamp (pre-EQ)")
                        .gridColumnAlignment(.trailing)
                    Slider(
                        value: $preamp,
                        in: -12...12,
                        step: 0.1,
                        onEditingChanged: { editing in
                            isDraggingPreamp = editing
                            if !editing {
                                appModel.setPreamp(preamp, persist: true)
                            }
                        }
                    ) {
                        Text("Preamp")
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 280)
                    .accessibilityLabel("Preamp")
                    .accessibilityValue(String(format: "%+.1f decibels", preamp))
                    .help("Gain applied before the EQ. Lower this to create headroom — "
                        + "AutoEQ profiles typically use a negative preamp to offset boosted bands. "
                        + "Saved with the active profile.")
                    .onChange(of: preamp) { _, newValue in
                        appModel.setPreamp(newValue, persist: false)
                    }
                    Text(String(format: "%+.1f dB", preamp))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                GridRow {
                    Text("Output Gain (master)")
                        .gridColumnAlignment(.trailing)
                    Slider(
                        value: $outputGain,
                        in: -12...12,
                        step: 0.1,
                        onEditingChanged: { editing in
                            isDraggingOutput = editing
                            if !editing {
                                appModel.setOutputGain(outputGain)
                            }
                        }
                    ) {
                        Text("Output Gain")
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 280)
                    .accessibilityLabel("Output gain")
                    .accessibilityValue(String(format: "%+.1f decibels", outputGain))
                    .help("Master volume trim applied after the EQ, before the output device. "
                        + "Session-only — not stored in the profile.")
                    .onChange(of: outputGain) { _, newValue in
                        appModel.setOutputGain(newValue)
                    }
                    Text(String(format: "%+.1f dB", outputGain))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                GridRow {
                    Text("Output level")
                        .gridColumnAlignment(.trailing)
                        .font(.caption)
                    OutputLevelMeter()
                        .frame(minWidth: 160, maxWidth: 280)
                        .frame(height: 9)
                    OutputClipBadge()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .padding(4)
        }
        .onAppear {
            preamp = appModel.preampDB
            outputGain = appModel.outputGainDB
        }
        .onChange(of: appModel.currentProfile.id) { _, _ in
            preamp = appModel.preampDB
        }
        .onChange(of: appModel.preampDB) { _, newValue in
            if !isDraggingPreamp { preamp = newValue }
        }
        .onChange(of: appModel.outputGainDB) { _, newValue in
            if !isDraggingOutput { outputGain = newValue }
        }
    }
}

/// Post-gain sample-peak bar (−60…0 dBFS) with peak-hold. Digital full scale only.
struct OutputLevelMeter: View {
    @Environment(AppModel.self) private var appModel

    private var floor: Float { AppModel.outputMeterFloorDBFS }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let instant = levelFraction(appModel.outputPeakDBFS)
            let hold = levelFraction(appModel.outputPeakHoldDBFS)
            let fillWidth = max(2, width * CGFloat(instant))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                // Gradient is fixed to the *full* track (−60…0 dBFS), then masked
                // to the fill width. If we filled a short bar with the same
                // gradient, mid levels would show red at the tip (wrong).
                Capsule()
                    .fill(meterGradient)
                    .frame(width: width)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: fillWidth, height: height)
                    }
                // Peak-hold tick
                Capsule()
                    .fill(appModel.outputClipActive ? Color.red : Color.primary.opacity(0.85))
                    .frame(width: 1.5, height: height)
                    .offset(x: max(0, width * CGFloat(hold) - 0.75))
            }
        }
        // GeometryReader expands greedily; parent sets a fixed short height.
        .frame(maxHeight: 9)
        .help("Sample-peak of SonarForge’s output after EQ and gain (0 dBFS = digital full scale). "
            + "Does not measure amp, Bluetooth, or speaker clipping. Brief overs often sound subtle.")
        .accessibilityElement()
        .accessibilityLabel("Output level")
        .accessibilityValue(accessibilityValue)
    }

    /// Full-track colors: green through most of the range, yellow near −6 dBFS, red at 0.
    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.75),   // up to ~−15 dBFS
                .init(color: .yellow, location: 0.90),  // ~−6 dBFS
                .init(color: .red, location: 1.0),      // 0 dBFS
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func levelFraction(_ db: Float) -> Float {
        let clamped = min(max(db, floor), 0)
        return (clamped - floor) / (0 - floor)
    }

    private var accessibilityValue: String {
        if appModel.outputClipActive {
            return "clipping, peak \(String(format: "%.1f", appModel.outputPeakHoldDBFS)) dBFS"
        }
        if !appModel.isProcessing {
            return "engine off"
        }
        return "\(String(format: "%.1f", appModel.outputPeakDBFS)) dBFS, hold \(String(format: "%.1f", appModel.outputPeakHoldDBFS))"
    }
}

/// Sticky CLIP badge when any output sample reached digital full scale.
struct OutputClipBadge: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            appModel.clearOutputClipIndicator()
        } label: {
            Text(appModel.outputClipActive ? "CLIP" : "—")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(appModel.outputClipActive ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(appModel.outputClipActive ? Color.red : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(appModel.outputClipActive ? Color.red : Color.secondary.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!appModel.outputClipActive)
        .help(appModel.outputClipActive
              ? "Output hit digital full scale (0 dBFS). Lower preamp or band gains. Click to clear."
              : "Digital clip indicator — lights when SonarForge’s output reaches 0 dBFS.")
        .accessibilityLabel(appModel.outputClipActive ? "Output clipping" : "No digital clip")
        .accessibilityHint(appModel.outputClipActive ? "Click to clear the clip indicator" : "")
    }
}

/// Crossfeed controls. Amount uses local `@State` while dragging so continuous
/// updates only hit the audio engine — not `currentProfile` / the whole window.
struct CrossfeedPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var amount: Double = 0
    @State private var isDragging = false

    var body: some View {
        let enabled = appModel.currentProfile.crossfeedEnabled
        GroupBox("Crossfeed") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { appModel.currentProfile.crossfeedEnabled },
                    set: { appModel.setCrossfeedEnabled($0) }
                )) {
                    Text("Enable crossfeed")
                }
                .help("Blends each channel's lower frequencies into the opposite ear, "
                    + "like speakers in a room — pulls hard-panned mixes out of your head. "
                    + "Highs keep full stereo separation. Saved per profile.")

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Amount")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(enabled ? .primary : .secondary)
                        Slider(
                            value: $amount,
                            in: 0...1,
                            step: 0.01,
                            onEditingChanged: { editing in
                                isDragging = editing
                                if !editing {
                                    appModel.setCrossfeedAmount(amount, persist: true)
                                }
                            }
                        )
                        .labelsHidden()
                        .frame(minWidth: 160, maxWidth: 280)
                        .disabled(!enabled)
                        .accessibilityLabel("Crossfeed amount")
                        .accessibilityValue("\(Int((amount * 100).rounded())) percent")
                        .help("Wider = more blend (more speaker-like). "
                            + "The default sits at a natural, moderate position.")
                        .onChange(of: amount) { _, newValue in
                            // Live DSP only while dragging / scrubbing — no profile write.
                            appModel.setCrossfeedAmount(newValue, persist: false)
                        }
                        Text("\(Int((amount * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                            .foregroundStyle(enabled ? .primary : .secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(4)
        }
        .onAppear { amount = appModel.currentProfile.crossfeedAmount }
        .onChange(of: appModel.currentProfile.id) { _, _ in
            amount = appModel.currentProfile.crossfeedAmount
        }
        .onChange(of: appModel.currentProfile.crossfeedAmount) { _, newValue in
            if !isDragging { amount = newValue }
        }
    }
}

/// Frequency-response header + graph stack, observation-isolated (the same
/// lesson as SpectrumSection, see AUDIO_PATH.md): Pre/Post/Legend toggles and
/// 20 Hz spectrum updates re-render only this subtree — never the band list,
/// gain sliders, or engine panel above it.
struct FrequencyPane: View {
    @Binding var selectedBandID: UUID?
    // Reads only `isProcessing` (changes rarely) — not the level arrays — so the
    // 20 Hz spectrum updates still re-render only the leaf renderer, never this
    // whole pane. (See AUDIO_PATH.md on observation isolation.)
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("visualizationStyle") private var styleRaw = VisualizationStyle.curve.rawValue

    var body: some View {
        @Bindable var model = appModel
        let style = VisualizationStyle.resolved(styleRaw)
        let vizOn = model.visualizationsEnabled

        VStack(spacing: 12) {
            // Mode title lives only in the picker; no duplicate headline.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Toggle(isOn: $model.visualizationsEnabled) {
                    Image(systemName: vizOn ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .accessibilityLabel(vizOn ? "Visualizations on" : "Visualizations off")
                .help(vizOn
                      ? "Turn off spectrum analysis and all visualizers to save CPU and battery. EQ audio is unaffected."
                      : "Turn on spectrum analysis and visualizers.")

                Picker("Visualization", selection: $styleRaw) {
                    ForEach(VisualizationStyle.menuCases) { option in
                        Label(option.displayName, systemImage: option.systemImage).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!vizOn)
                .help("Choose how to visualize the playing audio")

                Button {
                    openWindow(id: "visualizer")
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .disabled(!vizOn)
                .accessibilityLabel("Pop out visualizer")
                .help("Open a detached visualizer window (supports fullscreen)")
            }
            .padding(.horizontal)

            content(for: style, visualizationsEnabled: vizOn)
                .frame(minHeight: 260)
                .padding(.horizontal)
        }
        // Visibility only requests analysis; AppModel also requires
        // visualizationsEnabled (master battery/CPU switch).
        .onAppear {
            migrateHiddenVisualizationStyle()
            appModel.spectrumViewVisible = true
        }
        .onDisappear { appModel.spectrumViewVisible = false }
        .onChange(of: styleRaw) { _, _ in migrateHiddenVisualizationStyle() }
    }

    /// If AppStorage still points at a tucked-away style, snap to bars.
    private func migrateHiddenVisualizationStyle() {
        if let stored = VisualizationStyle(rawValue: styleRaw), !stored.isListedInMenu {
            styleRaw = VisualizationStyle.bars.rawValue
        }
    }

    @ViewBuilder
    private func content(for style: VisualizationStyle, visualizationsEnabled: Bool) -> some View {
        if !visualizationsEnabled {
            // EQ editor only — no spectrum overlay, no display-link visualizers.
            // No on-graph caption: it collided with the frequency zone strip.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                FrequencyResponseEditor(selectedBandID: $selectedBandID)
                    .padding(6)
            }
        } else if style == .curve {
            // Live pre + post spectrum traces behind the graphical EQ editor.
            ZStack {
                SpectrumSection()
                FrequencyResponseEditor(selectedBandID: $selectedBandID)
                    .padding(6)
            }
        } else {
            VisualizerStage(style: style)
        }
    }
}

/// Numeric band editor rows: type, frequency, gain, Q, delete. Edits flow
/// through AppModel.updateBand → engine + persistence.
struct BandListEditor: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedBandID: UUID?

    var body: some View {
        // Column headers once, instead of cramped per-row unit labels.
        HStack(spacing: 6) {
            Text("Type").frame(width: 110, alignment: .leading)
            Text("Hz").frame(width: 60, alignment: .center)
            Text("dB").frame(width: 48, alignment: .center)
            Text("Q").frame(width: 48, alignment: .center)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)

        // ScrollView + LazyVStack, deliberately not List: the AppKit-backed
        // List re-measures expensively on every window layout pass, which made
        // unrelated toggles feel laggy (sizeThatFits dominated the profile).
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(appModel.currentProfile.bands.enumerated()), id: \.element.id) { index, band in
                    row(index: index, band: band)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(
                            selectedBandID == band.id ? BandPalette.color(forFrequency: band.frequency).opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay(alignment: .leading) {
                            // Color tag tying the row to its graph footprint + handle.
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(BandPalette.color(forFrequency: band.frequency))
                                .frame(width: 3)
                                .padding(.vertical, 4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedBandID = band.id }
                }
                if appModel.currentProfile.bands.isEmpty {
                    Text("No bands — double-click the curve area or use + Add Band")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, band: EQBand) -> some View {
        HStack(spacing: 6) {
            // Units live in the column header row above the list — inline unit
            // labels wrapped vertically at this width and read as clutter.
            Picker("", selection: binding(index, \.type)) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("Band \(index + 1) filter type")

            bandNumericField(
                "Hz",
                value: binding(index, \.frequency),
                format: .number.precision(.fractionLength(0)),
                width: 60,
                accessibilityLabel: "Band \(index + 1) frequency in hertz"
            )

            bandNumericField(
                "dB",
                value: binding(index, \.gain),
                format: .number.precision(.fractionLength(1)),
                width: 48,
                accessibilityLabel: "Band \(index + 1) gain in decibels"
            )
            .disabled(band.type == .lowPass || band.type == .highPass || band.type == .notch)

            bandNumericField(
                "Q",
                value: binding(index, \.q),
                format: .number.precision(.fractionLength(2)),
                width: 48,
                accessibilityLabel: "Band \(index + 1) Q factor"
            )

            Spacer()

            Button {
                if selectedBandID == band.id { selectedBandID = nil }
                appModel.removeBand(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove band")
            .accessibilityLabel("Remove band \(index + 1)")
        }
        .font(.callout)
    }

    /// Compact numeric field for the band sidebar.
    /// Avoids system `.roundedBorder` chrome (bright silver outlines in dark mode
    /// that also rasterize poorly in marketing snapshots).
    private func bandNumericField<F: ParseableFormatStyle>(
        _ title: String,
        value: Binding<F.FormatInput>,
        format: F,
        width: CGFloat,
        accessibilityLabel: String
    ) -> some View where F.FormatOutput == String {
        TextField(title, value: value, format: format)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .accessibilityLabel(accessibilityLabel)
    }

    /// Field binding that routes edits through AppModel (engine + persistence).
    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<EQBand, T>) -> Binding<T> {
        Binding(
            get: {
                guard appModel.currentProfile.bands.indices.contains(index) else {
                    return EQBand()[keyPath: keyPath]
                }
                return appModel.currentProfile.bands[index][keyPath: keyPath]
            },
            set: { newValue in
                guard appModel.currentProfile.bands.indices.contains(index) else { return }
                var band = appModel.currentProfile.bands[index]
                band[keyPath: keyPath] = newValue
                appModel.updateBand(at: index, band)
            }
        )
    }
}

/// Host for the pre/post spectrum behind the EQ curve.
/// Traces are feed-driven (CVDisplayLink); this view only observes engine
/// run-state for the idle caption — not the 20 Hz level arrays.
struct SpectrumSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            SpectrumView()
                .padding(6)
            if !appModel.isProcessing {
                Text("Start the engine to see the spectrum")
                    .foregroundStyle(.secondary)
            }
        }
        // Analysis enable/disable is owned by the enclosing FrequencyPane so it
        // stays on across visualization-mode switches (this view unmounts when
        // a non-curve mode is selected).
    }
}

/// Engine controls: start/stop/reset lifecycle, output device selection, and
/// permission/error guidance.
struct AudioEnginePanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 10, height: 10)
                    Text(appModel.engineState.description)
                        .font(.subheadline)
                        .lineLimit(1)

                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                        .help("Output device")
                        .accessibilityHidden(true)
                    Picker("Output Device", selection: $model.selectedOutputUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(appModel.outputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Output device")
                    // Value only (the inline "Output Device" label ate the width and
                    // collapsed the value); the speaker icon conveys the purpose. Sizes
                    // to the device name and compresses gracefully on a narrow window.
                    .frame(minWidth: 110, maxWidth: 260)

                    Spacer()

                    Button(startStopTitle) {
                        appModel.toggleEngine()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .fixedSize()   // never truncate the primary action; the picker absorbs compression
                    .disabled(isStarting)
                    Button {
                        appModel.resetAudioEngine()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Reset the audio engine — full teardown and rebuild of the capture path. Use if audio gets into a bad state.")
                    .accessibilityLabel("Reset audio engine")
                    .disabled(!appModel.isProcessing)
                }

                if case .starting = appModel.engineState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Starting… If this hangs, macOS is often waiting on or blocking "
                            + "System Audio Recording permission (especially after a rebuild). "
                            + "A timeout is reported after about 10 seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Privacy Settings") {
                            appModel.openPrivacySettings()
                        }
                    }
                } else if case .failed(let reason) = appModel.engineState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if looksLikePermissionFailure(reason) {
                            Text("Tip: after a Debug rebuild the system sometimes keeps a stale "
                                + "permission entry. Open Privacy Settings, toggle SonarForge off/on, "
                                + "or run: tccutil reset All com.sonarforge.SonarForge — then relaunch.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Open Privacy Settings") {
                                appModel.openPrivacySettings()
                            }
                            Button("Retry") {
                                appModel.startEngine()
                            }
                            Button("Troubleshooting…") {
                                appModel.showingTroubleshooting = true
                            }
                        }
                    }
                } else if !appModel.isProcessing {
                    Text("Start the engine while playing audio in another app. macOS will ask for "
                        + "System Audio Recording permission on first start. If you hear silence "
                        + "afterwards, check Privacy & Security and retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Audio Engine", systemImage: "waveform.badge.mic")
        }
    }

    private var isStarting: Bool {
        if case .starting = appModel.engineState { return true }
        return false
    }

    private var startStopTitle: String {
        if appModel.isProcessing { return "Stop Engine" }
        if isStarting { return "Starting…" }
        return "Start Engine"
    }

    private func looksLikePermissionFailure(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        return lower.contains("permission")
            || lower.contains("timed out")
            || lower.contains("tccutil")
            || lower.contains("screen")
            || lower.contains("recording")
    }

    private var stateColor: Color {
        switch appModel.engineState {
        case .idle:     .gray
        case .starting: .yellow
        case .running:  .green
        case .failed:   .red
        }
    }
}
