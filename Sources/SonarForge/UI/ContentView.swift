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
                        .help("Compare against unprocessed audio. Excludes preamp, output gain, and (later) the EQ.")

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
                            if let flat = appModel.profileManager.profiles.first(where: { $0.name == "Flat" }) {
                                appModel.selectProfile(id: flat.id)
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
struct GainStagingPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        GroupBox("Gain Staging") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Preamp (pre-EQ)")
                        .gridColumnAlignment(.trailing)
                    Slider(value: $model.preampDB, in: -12...12, step: 0.1) {
                        Text("Preamp")
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 280)
                    .help("Gain applied before the EQ. Lower this to create headroom — "
                        + "AutoEQ profiles typically use a negative preamp to offset boosted bands.")
                    Text(String(format: "%+.1f dB", model.preampDB))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                GridRow {
                    Text("Output Gain (master)")
                        .gridColumnAlignment(.trailing)
                    Slider(value: $model.outputGainDB, in: -12...12, step: 0.1) {
                        Text("Output Gain")
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 280)
                    .help("Master volume trim applied after the EQ, before the output device.")
                    Text(String(format: "%+.1f dB", model.outputGainDB))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            .padding(4)
        }
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
        let style = VisualizationStyle(rawValue: styleRaw) ?? .curve

        VStack(spacing: 12) {
            HStack {
                Text(style.displayName)
                    .font(.headline)
                Spacer()
                Picker("Visualization", selection: $styleRaw) {
                    ForEach(VisualizationStyle.allCases) { option in
                        Label(option.displayName, systemImage: option.systemImage).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Choose how to visualize the playing audio")

                Button {
                    openWindow(id: "visualizer")
                } label: {
                    Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Open a detached visualizer window (supports fullscreen)")
            }
            .padding(.horizontal)

            content(for: style)
                .frame(minHeight: 260)
                .padding(.horizontal)
        }
        // Enables analysis (capture + FFT + waveform) whenever the main
        // visualization pane is on screen. Pop-out window has its own flag.
        .onAppear { appModel.spectrumViewVisible = true }
        .onDisappear { appModel.spectrumViewVisible = false }
    }

    @ViewBuilder
    private func content(for style: VisualizationStyle) -> some View {
        if style == .curve {
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

            TextField("Hz", value: binding(index, \.frequency), format: .number.precision(.fractionLength(0)))
                .frame(width: 60)
                .accessibilityLabel("Band \(index + 1) frequency in hertz")

            TextField("dB", value: binding(index, \.gain), format: .number.precision(.fractionLength(1)))
                .frame(width: 48)
                .disabled(band.type == .lowPass || band.type == .highPass || band.type == .notch)
                .accessibilityLabel("Band \(index + 1) gain in decibels")

            TextField("Q", value: binding(index, \.q), format: .number.precision(.fractionLength(2)))
                .frame(width: 48)
                .accessibilityLabel("Band \(index + 1) Q factor")

            Spacer()

            Button {
                if selectedBandID == band.id { selectedBandID = nil }
                appModel.removeBand(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove band")
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
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

/// Observation-scoped container for the spectrum traces: only this view
/// re-evaluates when the ~20 Hz level arrays update.
struct SpectrumSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            SpectrumView(
                preLevels: appModel.preEQLevels,
                postLevels: appModel.postEQLevels
            )
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
                    Picker("Output Device", selection: $model.selectedOutputUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(appModel.outputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .labelsHidden()
                    // Value only (the inline "Output Device" label ate the width and
                    // collapsed the value); the speaker icon conveys the purpose. Sizes
                    // to the device name and compresses gracefully on a narrow window.
                    .frame(minWidth: 110, maxWidth: 260)

                    Spacer()

                    Button(appModel.isProcessing ? "Stop Engine" : "Start Engine") {
                        appModel.toggleEngine()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .fixedSize()   // never truncate the primary action; the picker absorbs compression
                    Button {
                        appModel.resetAudioEngine()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Reset the audio engine — full teardown and rebuild of the capture path. Use if audio gets into a bad state.")
                    .accessibilityLabel("Reset audio engine")
                    .disabled(!appModel.isProcessing)
                }

                if case .failed = appModel.engineState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The engine could not start. If this is a permission problem, "
                            + "grant SonarForge access under System Audio Recording and retry.")
                            .font(.caption)
                            .foregroundStyle(.red)
                        HStack {
                            Button("Open Privacy Settings") {
                                appModel.openPrivacySettings()
                            }
                            Button("Retry") {
                                appModel.startEngine()
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

    private var stateColor: Color {
        switch appModel.engineState {
        case .idle:     .gray
        case .starting: .yellow
        case .running:  .green
        case .failed:   .red
        }
    }
}
