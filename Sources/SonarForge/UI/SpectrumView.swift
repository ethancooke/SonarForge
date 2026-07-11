import SwiftUI

/// Spectrum display behind the EQ response curve (pre + post traces).
///
/// Implementation uses `SpectrumFeed` + CVDisplayLink (via
/// `SpectrumVisualizerMode.curveTraces`), **not** a SwiftUI `Canvas` bound to
/// `@Observable` level arrays. Main-thread Canvas redraws freeze during
/// preamp/output slider tracking; the feed path keeps traces moving
/// (same lesson as bars / LED / Reactor — see AUDIO_PATH.md).
struct SpectrumView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumModeView(mode: .curveTraces, label: "Spectrum analyzer")
    }
}
