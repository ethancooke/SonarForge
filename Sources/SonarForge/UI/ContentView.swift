import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showingProfileLibrary = false
    @State private var showingAutoEQImport = false
    @State private var showingBandsPanel = true
    @State private var selectedBandID: UUID?
    @State private var dropErrorMessage: String?

    var body: some View {
        @Bindable var model = appModel

        HSplitView {
            // Left / main editor area
            VStack(spacing: 12) {
                // Chunk 1.1 debug controls: capture/passthrough lifecycle, device
                // selection, and error surfacing. Will be folded into proper UI later.
                AudioEngineDebugView()
                    .padding(.horizontal)
                    .padding(.top, 8)

                HStack {
                    Text("Frequency Response")
                        .font(.headline)
                    Spacer()
                    Toggle("Pre", isOn: $model.showPreSpectrum)
                        .toggleStyle(.checkbox)
                        .help("Show the spectrum of the unprocessed system audio")
                    Toggle("Post", isOn: $model.showPostSpectrum)
                        .toggleStyle(.checkbox)
                        .help("Show the spectrum of the processed output. Turning both off disables analysis entirely (saves CPU).")
                    Toggle("Legend", isOn: $model.showSpectrumLegend)
                        .toggleStyle(.checkbox)
                        .help("Show or hide the spectrum and EQ curve legend on the graph.")
                }
                .padding(.horizontal)

                // Spectrum traces (3.1) behind the graphical EQ editor (5.2).
                // Siblings, not nested: the spectrum re-renders at 20 Hz in
                // isolation, the editor re-renders only on profile edits.
                ZStack(alignment: .topTrailing) {
                    SpectrumSection()
                    FrequencyResponseEditor(selectedBandID: $selectedBandID)
                        .padding(6)
                    if appModel.showSpectrumLegend {
                        SpectrumLegend(
                            showPre: appModel.showPreSpectrum,
                            showPost: appModel.showPostSpectrum,
                            hasEQCurve: !appModel.currentProfile.bands.isEmpty
                        )
                        .padding(12)
                    }
                }
                .frame(minHeight: 260)
                .padding(.horizontal)

                // Temporary numeric controls until the full editor exists
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Current Profile: \(appModel.currentProfile.name)")
                            .font(.subheadline)
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

                    HStack {
                        Button(appModel.isBypassed ? "Bypass (ON)" : "Bypass") {
                            appModel.toggleBypass()
                        }
                        .tint(appModel.isBypassed ? .orange : .accentColor)
                        .help("Compare against unprocessed audio. Excludes preamp, output gain, and (later) the EQ.")

                        Button("A / B Swap") {
                            appModel.swapAB()
                        }
                        .help("Switch between the A and B profiles for quick comparison.")

                        Spacer()
                    }

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
                                .help("Gain applied before the EQ. Lower this to create headroom — AutoEQ profiles typically use a negative preamp to offset boosted bands.")
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

                    HStack(spacing: 8) {
                        Button("+ Add Band") {
                            showingBandsPanel = true
                            if let added = appModel.addBand(EQBand(type: .peaking, frequency: 1000, gain: 0, q: 1.0)) {
                                selectedBandID = added.id
                            }
                        }
                        .disabled(appModel.currentProfile.bands.count >= RealtimeParametricEQ.maxBands)

                        Button("Import AutoEQ…") { showingAutoEQImport = true }

                        Button("Reset to Flat") {
                            selectedBandID = nil
                            if let flat = appModel.profileManager.profiles.first(where: { $0.name == "Flat" }) {
                                appModel.selectProfile(id: flat.id)
                            } else {
                                appModel.loadProfile(.flat)
                            }
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .frame(minWidth: 520)

            // Right sidebar — numeric band editor (Chunk 5.2/5.3). Collapsible
            // so the frequency response and profile controls can take center stage.
            if showingBandsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Bands")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingBandsPanel = false
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Hide band details")
                        .accessibilityLabel("Hide band details")
                    }
                    .padding(.top, 4)

                    BandListEditor(selectedBandID: $selectedBandID)
                }
                .frame(minWidth: 300)
                .padding(.horizontal, 8)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .navigationTitle("SonarForge")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingProfileLibrary = true
                } label: {
                    Label("Profiles", systemImage: "list.bullet")
                }
                .help("Manage profiles (create, rename, import, export)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingBandsPanel.toggle()
                    }
                } label: {
                    Label(
                        showingBandsPanel ? "Hide Bands" : "Show Bands",
                        systemImage: showingBandsPanel ? "sidebar.right" : "slider.horizontal.3"
                    )
                }
                .help(showingBandsPanel ? "Hide the band detail panel" : "Show the band detail panel")
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
        // Chunk 5.5: drop profile files anywhere on the window. Native profile
        // JSON imports directly; other text files fall back to the AutoEQ parser.
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

/// Numeric band editor rows (Chunk 5.3 essentials): type, frequency, gain, Q,
/// delete. Edits flow through AppModel.updateBand → engine + persistence.
struct BandListEditor: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedBandID: UUID?

    var body: some View {
        List(selection: $selectedBandID) {
            ForEach(Array(appModel.currentProfile.bands.enumerated()), id: \.element.id) { index, band in
                row(index: index, band: band)
                    .tag(band.id)
            }
            if appModel.currentProfile.bands.isEmpty {
                Text("No bands — double-click the curve area or use + Add Band")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(index: Int, band: EQBand) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: binding(index, \.type)) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 92)
            .accessibilityLabel("Band \(index + 1) filter type")

            TextField("Hz", value: binding(index, \.frequency), format: .number.precision(.fractionLength(0)))
                .frame(width: 58)
                .accessibilityLabel("Band \(index + 1) frequency in hertz")
            Text("Hz").font(.caption2).foregroundStyle(.secondary)

            TextField("dB", value: binding(index, \.gain), format: .number.precision(.fractionLength(1)))
                .frame(width: 44)
                .disabled(band.type == .lowPass || band.type == .highPass || band.type == .notch)
                .accessibilityLabel("Band \(index + 1) gain in decibels")
            Text("dB").font(.caption2).foregroundStyle(.secondary)

            TextField("Q", value: binding(index, \.q), format: .number.precision(.fractionLength(2)))
                .frame(width: 44)
                .accessibilityLabel("Band \(index + 1) Q factor")
            Text("Q").font(.caption2).foregroundStyle(.secondary)

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
                postLevels: appModel.postEQLevels,
                showPre: appModel.showPreSpectrum,
                showPost: appModel.showPostSpectrum
            )
            .padding(6)
            if !appModel.isProcessing {
                Text("Start the engine to see the spectrum")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { appModel.spectrumViewVisible = true }
        .onDisappear { appModel.spectrumViewVisible = false }
    }
}

/// Temporary Chunk 1.1 debug panel: engine lifecycle, output device picker, and
/// permission/error guidance. Replaced by real UI in Phase 5.
struct AudioEngineDebugView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 10, height: 10)
                    Text(appModel.engineState.description)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Button(appModel.isProcessing ? "Stop Engine" : "Start Engine") {
                        appModel.toggleEngine()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button {
                        appModel.resetAudioEngine()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Reset the audio engine — full teardown and rebuild of the capture path. Use if audio gets into a bad state.")
                    .accessibilityLabel("Reset audio engine")
                    .disabled(!appModel.isProcessing)
                }

                HStack {
                    Picker("Output Device", selection: $model.selectedOutputUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(appModel.outputDevices) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .frame(maxWidth: 360)

                    Button {
                        appModel.refreshOutputDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh device list")
                    .accessibilityLabel("Refresh output device list")
                }

                HStack {
                    Text("Profile")
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
                    .frame(maxWidth: 200)
                    .help("Profiles persist across launches (Chunk 4.1). Management UI and AutoEQ import arrive in 4.1.3/4.2.")
                    if let notes = appModel.currentProfile.notes {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if case .failed = appModel.engineState {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The engine could not start. If this is a permission problem, grant SonarForge access under System Audio Recording and retry.")
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
                    Text("Start the engine while playing audio in another app. macOS will ask for System Audio Recording permission on first start. If you hear silence afterwards, check Privacy & Security and retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Audio Engine (Chunk 1.1 Debug)", systemImage: "waveform.badge.mic")
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
