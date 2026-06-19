import SwiftUI

/// Custom About window (Chunk 6.3) with the project's mandatory attribution
/// (VISION.md / D-006): AutoEQ and measurement authors, eqMac inspiration,
/// Apple sample code, license.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 2) {
                Text("SonarForge")
                    .font(.title.bold())
                Text(version)
                    .foregroundStyle(.secondary)
                Text("Precise. Native. Free.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                attribution("AutoEQ & measurement authors",
                            "Headphone correction profiles are powered by the AutoEQ project "
                            + "(Jaakko Pasanen) and the measurement community, including oratory1990. "
                            + "Imported profiles always display their source.",
                            link: "https://autoeq.app")
                attribution("eqMac",
                            "An inspiration for system-wide EQ on macOS. SonarForge shares no code with eqMac (Apache 2.0).",
                            link: "https://github.com/bitgapp/eqMac")
                attribution("Apple",
                            "Built on Core Audio process taps, Accelerate/vDSP, and Apple's audio sample code.",
                            link: nil)
            }
            .font(.caption)

            Divider()

            Text("Apache License 2.0 — free and open source, no paywalls. All audio processing is strictly local.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(width: 440)
        // Let the window adopt the content's full natural height — a fixed
        // height clipped the license line on some text-size settings.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func attribution(_ title: String, _ text: String, link: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).bold()
                if let link, let url = URL(string: link) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open \(title) website")
                }
            }
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
