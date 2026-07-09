import SwiftUI
import AppKit

/// Ways to visualize the playing audio in the main display pane.
enum VisualizationStyle: String, CaseIterable, Identifiable {
    case curve
    case bars
    case mirroredBars
    case ledBars
    case spectrogram
    case oscilloscope
    case vectorscope
    case correlation
    case vuMeters
    case reactor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curve:         "Frequency Response"
        case .bars:          "Spectrum Bars"
        case .mirroredBars:  "Mirrored Bars"
        case .ledBars:       "LED Meters"
        case .spectrogram:   "Spectrogram"
        case .oscilloscope:  "Oscilloscope"
        case .vectorscope:   "Vectorscope"
        case .correlation:   "Correlation"
        case .vuMeters:      "VU / PPM"
        case .reactor:       "Reactor"
        }
    }

    var systemImage: String {
        switch self {
        case .curve:         "waveform.path"
        case .bars:          "chart.bar.fill"
        case .mirroredBars:  "arrow.left.and.right"
        case .ledBars:       "rectangle.split.3x1.fill"
        case .spectrogram:   "square.grid.3x3.fill"
        case .oscilloscope:  "waveform"
        case .vectorscope:   "circle.grid.cross"
        case .correlation:   "arrow.left.arrow.right"
        case .vuMeters:      "gauge.with.dots.needle.33percent"
        case .reactor:       "hurricane"
        }
    }

    /// Styles that make sense in the pop-out window (no band editor).
    static var popoutCases: [VisualizationStyle] {
        allCases.filter { $0 != .curve }
    }
}

/// Shared dBFS → 0…1 mapping, matching `SpectrumView`'s floor/ceiling so every
/// visualization reads at the same vertical scale.
enum VizScale {
    static let floorDB: Float = -100
    static let ceilingDB: Float = 0

    static func norm(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1))
    }

    static func normFloat(_ db: Float) -> Float {
        min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    /// Linear amplitude → dBFS (0 dB = full scale).
    static func linearToDB(_ linear: Float) -> Float {
        let mag = max(linear, 1e-10)
        return 20 * log10(mag)
    }

    /// dB → 0…1 for meter ballistics displays (floor −60 dB for VU-style).
    static func meterNorm(_ db: Float, floor: Float = -60, ceiling: Float = 0) -> CGFloat {
        CGFloat(min(max((db - floor) / (ceiling - floor), 0), 1))
    }
}

// MARK: - SwiftUI hosts

struct SpectrumBarsView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .bars,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Spectrum bars visualization")
    }
}

struct MirroredBarsView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .mirroredBars,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Mirrored spectrum bars visualization")
    }
}

struct LEDBarsView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .ledBars,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("LED meter visualization")
    }
}

struct SpectrogramView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .spectrogram,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Spectrogram visualization")
    }
}

struct OscilloscopeView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .oscilloscope,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Oscilloscope visualization")
    }
}

struct VectorscopeView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .vectorscope,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Stereo vectorscope visualization")
    }
}

struct CorrelationMeterView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .correlation,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("Phase correlation meter")
    }
}

struct VUMetersView: View {
    @Environment(AppModel.self) private var appModel
    var body: some View {
        SpectrumVisualizerRepresentable(mode: .vuMeters,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .accessibilityLabel("VU and PPM meters")
    }
}

/// Shared host for non-editor visualization styles (main pane + pop-out window).
struct VisualizerStage: View {
    let style: VisualizationStyle
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            visualizer
                .padding(6)
            if !appModel.isProcessing {
                Text("Start the engine to see the visualizer")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var visualizer: some View {
        switch style {
        case .bars:         SpectrumBarsView()
        case .mirroredBars: MirroredBarsView()
        case .ledBars:      LEDBarsView()
        case .spectrogram:  SpectrogramView()
        case .oscilloscope: OscilloscopeView()
        case .vectorscope:  VectorscopeView()
        case .correlation:  CorrelationMeterView()
        case .vuMeters:     VUMetersView()
        case .reactor:      ReactorContainer()
        case .curve:
            SpectrumView(preLevels: appModel.preEQLevels, postLevels: appModel.postEQLevels)
                .padding(6)
        }
    }
}

enum SpectrumVisualizerMode {
    case bars
    case mirroredBars
    case ledBars
    case spectrogram
    case oscilloscope
    case vectorscope
    case correlation
    case vuMeters
}

private struct SpectrumVisualizerRepresentable: NSViewRepresentable {
    let mode: SpectrumVisualizerMode
    let spectrumFeed: SpectrumFeed
    let waveformFeed: WaveformFeed

    func makeNSView(context: Context) -> SpectrumVisualizerNSView {
        let view = SpectrumVisualizerNSView(mode: mode)
        view.spectrumFeed = spectrumFeed
        view.waveformFeed = waveformFeed
        view.start()
        return view
    }

    func updateNSView(_ nsView: SpectrumVisualizerNSView, context: Context) {
        nsView.spectrumFeed = spectrumFeed
        nsView.waveformFeed = waveformFeed
    }

    static func dismantleNSView(_ nsView: SpectrumVisualizerNSView, coordinator: ()) {
        nsView.stop()
    }
}
