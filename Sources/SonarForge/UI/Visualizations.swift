import SwiftUI
import AppKit

/// Ways to visualize the playing audio in the main display pane.
enum VisualizationStyle: String, CaseIterable, Identifiable {
    case curve
    case bars
    case mirroredBars
    case ghostBars
    case polar
    case ledBars
    case spectrogram
    case oscilloscope
    case crt
    case vectorscope
    case correlation
    case vuMeters
    case particles
    case reactor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curve:         "Frequency Response"
        case .bars:          "Spectrum Bars"
        case .mirroredBars:  "Mirrored Bars"
        case .ghostBars:     "Ghost Bars"
        case .polar:         "Polar Spectrum"
        case .ledBars:       "LED Meters"
        case .spectrogram:   "Spectrogram"
        case .oscilloscope:  "Oscilloscope"
        case .crt:           "CRT Scope"
        case .vectorscope:   "Vectorscope"
        case .correlation:   "Correlation"
        case .vuMeters:      "VU / PPM"
        case .particles:     "Particles"
        case .reactor:       "Reactor"
        }
    }

    var systemImage: String {
        switch self {
        case .curve:         "waveform.path"
        case .bars:          "chart.bar.fill"
        case .mirroredBars:  "arrow.left.and.right"
        case .ghostBars:     "chart.bar.xaxis"
        case .polar:         "circle.circle"
        case .ledBars:       "rectangle.split.3x1.fill"
        case .spectrogram:   "square.grid.3x3.fill"
        case .oscilloscope:  "waveform"
        case .crt:           "tv"
        case .vectorscope:   "circle.grid.cross"
        case .correlation:   "arrow.left.arrow.right"
        case .vuMeters:      "gauge.with.dots.needle.33percent"
        case .particles:     "sparkles"
        case .reactor:       "hurricane"
        }
    }

    /// Styles that make sense in the pop-out window (no band editor).
    static var popoutCases: [VisualizationStyle] {
        allCases.filter { $0 != .curve }
    }

    var visualizerMode: SpectrumVisualizerMode? {
        switch self {
        case .bars:         return .bars
        case .mirroredBars: return .mirroredBars
        case .ghostBars:    return .ghostBars
        case .polar:        return .polar
        case .ledBars:      return .ledBars
        case .spectrogram:  return .spectrogram
        case .oscilloscope: return .oscilloscope
        case .crt:          return .crt
        case .vectorscope:  return .vectorscope
        case .correlation:  return .correlation
        case .vuMeters:     return .vuMeters
        case .particles:    return .particles
        case .reactor, .curve: return nil
        }
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

/// Generic spectrum/PCM visualizer host keyed by mode.
struct SpectrumModeView: View {
    let mode: SpectrumVisualizerMode
    let label: String
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumVisualizerRepresentable(mode: mode,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            // Force a fresh representable identity when the mode changes so
            // SwiftUI doesn't reuse an NSView still drawing the previous style.
            .id(mode)
            .accessibilityLabel(label)
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
        Group {
            if let mode = style.visualizerMode {
                SpectrumModeView(mode: mode, label: style.displayName)
            } else if style == .reactor {
                ReactorContainer()
            } else {
                SpectrumView(preLevels: appModel.preEQLevels, postLevels: appModel.postEQLevels)
                    .padding(6)
            }
        }
        // Identity by style so bar-family switches always remount cleanly.
        .id(style)
    }
}

/// Compact spectrum strip for the menu-bar panel.
struct MenuBarMiniMeter: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumVisualizerRepresentable(mode: .miniBars,
                                        spectrumFeed: appModel.spectrumFeed,
                                        waveformFeed: appModel.waveformFeed)
            .frame(height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Menu bar spectrum meter")
            .onAppear { appModel.menuBarVisualizerVisible = true }
            .onDisappear { appModel.menuBarVisualizerVisible = false }
    }
}

enum SpectrumVisualizerMode {
    case bars
    case mirroredBars
    case ghostBars
    case polar
    case ledBars
    case spectrogram
    case oscilloscope
    case crt
    case vectorscope
    case correlation
    case vuMeters
    case particles
    case miniBars
}

struct SpectrumVisualizerRepresentable: NSViewRepresentable {
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
        nsView.setMode(mode)
        nsView.spectrumFeed = spectrumFeed
        nsView.waveformFeed = waveformFeed
    }

    static func dismantleNSView(_ nsView: SpectrumVisualizerNSView, coordinator: ()) {
        nsView.stop()
    }
}
