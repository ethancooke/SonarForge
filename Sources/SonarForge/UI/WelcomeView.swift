import SwiftUI

/// First-run welcome + permission explainer (Chunk 6.3). Shown automatically
/// once, and reachable any time from Help ▸ Welcome to SonarForge.
struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Welcome to SonarForge")
                        .font(.title2.bold())
                    Text("System-wide parametric EQ for macOS")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Image(systemName: "1.circle.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How it works").bold()
                        Text("SonarForge captures your Mac's audio with a macOS audio tap, applies your EQ, and plays the result to your output device. Everything stays on this Mac — nothing is recorded or sent anywhere.")
                    }
                }
                GridRow {
                    Image(systemName: "2.circle.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One permission").bold()
                        Text("The first time you start the engine, macOS asks for **System Audio Recording** permission — that's the audio tap. If you deny it, SonarForge can't hear anything to equalize. You can change it later in System Settings ▸ Privacy & Security.")
                    }
                }
                GridRow {
                    Image(systemName: "3.circle.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get a headphone profile").bold()
                        Text("Use **Import AutoEQ…** with a correction from autoeq.app for your headphones, drag the file onto the window, or build your own curve by double-clicking the graph.")
                    }
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Button("Open Privacy Settings") {
                    appModel.openPrivacySettings()
                }
                Spacer()
                Button("Not Now") { dismiss() }
                Button(appModel.isProcessing ? "Engine Running ✓" : "Start the Engine") {
                    appModel.startEngine()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isProcessing)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear {
            appModel.markWelcomeSeen()
        }
    }
}
