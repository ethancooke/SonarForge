import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

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
                    Toggle("Pre", isOn: .constant(true))
                        .toggleStyle(.checkbox)
                    Toggle("Post", isOn: .constant(true))
                        .toggleStyle(.checkbox)
                }
                .padding(.horizontal)

                // Placeholder for the graphical EQ curve + handles
                // This will become FrequencyResponseView in Chunk 5.2
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            Text("Frequency Response Curve\n(Chunk 5.2: Draggable nodes + summed response)")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(minHeight: 260)
                .padding(.horizontal)

                // Temporary numeric controls until the full editor exists
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Profile: \(appModel.currentProfile.name)")
                        .font(.subheadline)

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
                }
                .padding(.horizontal)

                Spacer()
            }
            .frame(minWidth: 520)

            // Right sidebar - Band list (stub)
            VStack(alignment: .leading, spacing: 8) {
                Text("Bands")
                    .font(.headline)
                    .padding(.top, 4)

                // Placeholder list — will be replaced with real editable band rows
                List {
                    Text("No bands (add via graphical editor or + button)")
                        .foregroundStyle(.secondary)
                }
                .listStyle(.plain)

                HStack {
                    Button("+ Add Band") { /* TODO */ }
                    Button("Import AutoEQ…") { /* TODO in Chunk 4.2 */ }
                    Spacer()
                    Button("Reset to Flat") {
                        appModel.loadProfile(.flat)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(minWidth: 240)
            .padding(.horizontal, 8)
        }
        .navigationTitle("SonarForge")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Open profile manager or save current
                } label: {
                    Label("Profiles", systemImage: "list.bullet")
                }
            }
        }
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
                }

                HStack {
                    Text("Test Profile")
                    Menu(appModel.currentProfile.name) {
                        ForEach(EQProfile.debugPresets) { preset in
                            Button(preset.name) {
                                appModel.loadProfile(preset)
                            }
                        }
                    }
                    .frame(maxWidth: 200)
                    .help("Built-in EQ presets for validating the live render path (Chunk 2.2). The real profile system arrives in Phase 4.")
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
