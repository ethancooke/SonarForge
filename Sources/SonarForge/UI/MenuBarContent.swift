import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SonarForge")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            .padding(.bottom, 4)

            Divider()

            Toggle("Engine Running", isOn: Binding(
                get: { appModel.isProcessing },
                set: { _ in appModel.toggleEngine() }
            ))

            Toggle("Bypass", isOn: Binding(
                get: { appModel.isBypassed },
                set: { _ in appModel.toggleBypass() }
            ))
            .disabled(!appModel.isProcessing)

            Button("Open Main Window") {
                // Activate the main window / bring to front
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            // Quick profile switcher. Favorites + ⌘1–9 shortcuts come in Chunk 4.3;
            // for now list the library (small at this stage).
            Text("Profiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(appModel.profileManager.profiles) { profile in
                Button {
                    appModel.selectProfile(id: profile.id)
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == appModel.profileManager.activeProfileID {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("Quit SonarForge") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 240)
    }

    private var statusText: String {
        switch appModel.engineState {
        case .running: appModel.isBypassed ? "Bypassed" : "Active"
        case .idle:     "Off"
        case .starting: "Starting…"
        case .failed:   "Error"
        }
    }

    private var statusColor: Color {
        switch appModel.engineState {
        case .running: appModel.isBypassed ? .orange : .green
        case .idle:     .secondary
        case .starting: .yellow
        case .failed:   .red
        }
    }
}
