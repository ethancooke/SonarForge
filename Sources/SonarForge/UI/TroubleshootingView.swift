import SwiftUI

/// In-app troubleshooting reference (Chunk 6.3) — Help ▸ Troubleshooting.
/// Covers the support cases anticipated in DEVELOPMENT_PLAN 6.3 plus the ones
/// found during validation.
struct TroubleshootingView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        let symptom: String
        let advice: String
    }

    private let items: [Item] = [
        Item(symptom: "Engine stuck on “Starting…” or times out",
             advice: "macOS is usually blocking System Audio Recording (a separate toggle from "
                + "Screen Recording on recent macOS). A stale permission after a rebuild is the "
                + "usual cause: open Privacy Settings → Screen & System Audio Recording (and "
                + "System Audio Recording Only if shown), toggle SonarForge off/on, or run "
                + "`tccutil reset All com.sonarforge.SonarForge`, relaunch, and re-grant. "
                + "The engine reports a timeout after about 10 seconds."),
        Item(symptom: "Engine runs but you hear silence",
             advice: "Check that the Output Device picker matches the device you're actually listening on, "
                + "and that System Audio Recording is granted (a denied tap delivers silence rather than an error). "
                + "The Reset Audio Engine button (circular arrows) rebuilds the whole path."),
        Item(symptom: "EQ doesn't seem to change the sound",
             advice: "Check Bypass is off, the active profile actually has bands, and their gains aren't 0 dB. "
                + "The Post spectrum trace should visibly follow your curve."),
        Item(symptom: "Some apps aren't affected",
             advice: "Apps using exclusive audio access or certain DRM paths can bypass the system tap. "
                + "Netflix in a browser is confirmed to work; some protected players may not. "
                + "This is a macOS limitation of the driverless approach."),
        Item(symptom: "On a call, the other person hears an echo of themselves",
             advice: "SonarForge re-renders system audio, which interferes with the echo "
                + "cancellation in apps like Discord, Zoom, and Teams. On a voice or video call "
                + "played through speakers, stop the engine or switch to headphones for the call. "
                + "Bypass isn't enough — it still re-renders the audio; only stopping the engine "
                + "restores the direct (uncancelled) path."),
        Item(symptom: "Audio glitch when switching devices",
             advice: "A brief gap during a device switch is expected — the capture path is rebuilt "
                + "for the new device (with a fade, not a click). If audio doesn't come back "
                + "within a couple of seconds, use Reset Audio Engine."),
        Item(symptom: "Sound is fine but CPU seems high",
             advice: "Spectrum analysis only runs while the graph is on screen. Close the main "
                + "window (the menu bar item keeps working) and analysis pauses automatically."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Troubleshooting")
                    .font(.headline)
                Spacer()
                Button("Open Privacy Settings") { appModel.openPrivacySettings() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(item.symptom, systemImage: "questionmark.circle")
                                .font(.callout.bold())
                            Text(item.advice)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Text("Still stuck? Open an issue on GitHub with your macOS version, output device, and Console logs filtered by “com.sonarforge”.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
