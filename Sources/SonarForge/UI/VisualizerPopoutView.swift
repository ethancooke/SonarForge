import SwiftUI
import AppKit

/// Detached visualizer window (D-014 follow-up): same visualization styles as
/// the main pane (without the band editor), with a fullscreen control.
/// Shares `@AppStorage("visualizationStyle")` with the main window so the
/// mode picker stays in sync.
struct VisualizerPopoutView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visualizationStyle") private var styleRaw = VisualizationStyle.bars.rawValue

    /// Hosting `NSWindow` resolved from the view hierarchy (SwiftUI scene ids
    /// are not reliable for `NSApp.windows` lookup).
    @State private var hostWindow: NSWindow?
    @State private var isFullScreen = false

    var body: some View {
        let style = VisualizationStyle.resolved(styleRaw)
        // Curve is editor-only; map to bars for the pop-out stage.
        let displayStyle = style == .curve ? VisualizationStyle.bars : style

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(displayStyle.displayName)
                    .font(.headline)
                Spacer()
                Picker("Visualization", selection: $styleRaw) {
                    ForEach(VisualizationStyle.popoutCases) { option in
                        Label(option.displayName, systemImage: option.systemImage)
                            .tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Choose how to visualize the playing audio")

                Button {
                    toggleFullScreen()
                } label: {
                    Label(
                        isFullScreen ? "Exit Full Screen" : "Full Screen",
                        systemImage: isFullScreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                }
                .help(isFullScreen
                      ? "Exit fullscreen"
                      : "Enter fullscreen for this visualizer window")

                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .help("Close the visualizer window")
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VisualizerStage(style: displayStyle)
                .padding(.horizontal, isFullScreen ? 0 : 12)
                .padding(.bottom, isFullScreen ? 0 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Capture the real NSWindow this view lives in.
        .background(WindowAccessor { window in
            hostWindow = window
            configureWindowIfNeeded(window)
            syncFullScreenState(from: window)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            isFullScreen = false
        }
        .onAppear {
            // Curve / hidden styles → a real listed visual.
            if style == .curve || !style.isListedInMenu {
                styleRaw = VisualizationStyle.bars.rawValue
            }
            appModel.visualizerPopoutVisible = true
        }
        .onDisappear {
            appModel.visualizerPopoutVisible = false
        }
    }

    private func toggleFullScreen() {
        guard let window = hostWindow ?? NSApp.keyWindow else { return }
        // Ensure this window can enter the system fullscreen space.
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    private func configureWindowIfNeeded(_ window: NSWindow?) {
        guard let window else { return }
        // SwiftUI's `.contentSize` resizability can leave windows without
        // fullScreenPrimary; force the collection behavior so the green
        // traffic-light / our button both work.
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.title = "Visualizer"
        window.isMovableByWindowBackground = true
    }

    private func syncFullScreenState(from window: NSWindow?) {
        guard let window else { return }
        isFullScreen = window.styleMask.contains(.fullScreen)
    }
}

// MARK: - Host window access

/// Resolves the `NSWindow` hosting a SwiftUI hierarchy. Scene `id` / title
/// lookups on `NSApp.windows` are fragile under SwiftUI's window management.
private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Window is often nil on first update; hop so the view is attached.
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
