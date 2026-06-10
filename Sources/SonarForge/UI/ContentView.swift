import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        HSplitView {
            // Left / main editor area
            VStack(spacing: 12) {
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

                        Button("A / B Swap") {
                            appModel.swapAB()
                        }

                        Spacer()

                        Text("Preamp")
                        Slider(value: $model.preampDB, in: -12...12, step: 0.1)
                            .frame(width: 180)
                        Text(String(format: "%+.1f dB", model.preampDB))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
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
        .task {
            await appModel.requestPermissionsIfNeeded()
        }
    }
}
