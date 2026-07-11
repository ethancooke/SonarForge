import AppKit

/// Offline window capture for marketing assets / docs (no Screen Recording TCC).
///
/// Usage: launch with
///   `--export-window-snapshot <path.png>`
/// Optionally pair with `--autostart-engine` and a profile so the UI is populated.
///
/// Uses `NSView.cacheDisplay` on the window's theme frame. Modern liquid-glass
/// toolbar buttons rasterize as solid white pills via that path, so for export
/// we hide the real toolbar and install classic (non-glass) titlebar icon
/// stand-ins for Bands / Profiles so the chrome still looks complete.
enum WindowSnapshot {
    static var exportPath: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--export-window-snapshot"),
              CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static var isExportRequested: Bool { exportPath != nil }

    /// Captures the main window after layout and writes PNG to `path`.
    @MainActor
    static func captureMainWindow(to path: String) -> Bool {
        // Prefer the largest ordinary window (main UI), not About / menu-bar popover.
        let candidates = NSApp.windows.filter { window in
            window.isVisible
                && window.frame.width > 400
                && window.frame.height > 300
                && window.styleMask.contains(.titled)
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            fputs("WindowSnapshot: no suitable window\n", stderr)
            return false
        }

        // --- Normalize appearance before rasterizing ---
        let previousAppAppearance = NSApp.appearance
        let previousWindowAppearance = window.appearance
        let dark = NSAppearance(named: .darkAqua)
        NSApp.appearance = dark
        window.appearance = dark

        // Drop focus rings (keyboard focus draws bright outlines on TextFields).
        window.makeFirstResponder(nil)

        // Glass toolbar → white blobs under cacheDisplay. Replace with classic
        // titlebar icon buttons that rasterize cleanly and still read as the
        // Bands / Profiles controls.
        let previousToolbarVisible = window.toolbar?.isVisible ?? true
        window.toolbar?.isVisible = false
        let accessory = installToolbarStandIns(on: window)

        // Theme frame includes title bar / traffic lights for a README-ready shot.
        guard let view = window.contentView?.superview ?? window.contentView else {
            fputs("WindowSnapshot: no content view\n", stderr)
            restore(window: window,
                    appAppearance: previousAppAppearance,
                    windowAppearance: previousWindowAppearance,
                    toolbarVisible: previousToolbarVisible,
                    accessory: accessory)
            return false
        }

        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            fputs("WindowSnapshot: empty bounds\n", stderr)
            restore(window: window,
                    appAppearance: previousAppAppearance,
                    windowAppearance: previousWindowAppearance,
                    toolbarVisible: previousToolbarVisible,
                    accessory: accessory)
            return false
        }

        // Explicit Retina bitmap (cacheDisplay into a 1× rep looks soft / wrong).
        let scale = max(window.backingScaleFactor, 2.0)
        let pxWidth = Int(ceil(bounds.width * scale))
        let pxHeight = Int(ceil(bounds.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxWidth,
            pixelsHigh: pxHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fputs("WindowSnapshot: could not create bitmap rep\n", stderr)
            restore(window: window,
                    appAppearance: previousAppAppearance,
                    windowAppearance: previousWindowAppearance,
                    toolbarVisible: previousToolbarVisible,
                    accessory: accessory)
            return false
        }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            view.cacheDisplay(in: bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()

        restore(window: window,
                appAppearance: previousAppAppearance,
                windowAppearance: previousWindowAppearance,
                toolbarVisible: previousToolbarVisible,
                accessory: accessory)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("WindowSnapshot: PNG encode failed\n", stderr)
            return false
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            fputs(
                "WindowSnapshot: wrote \(path) "
                    + "(\(Int(bounds.width))×\(Int(bounds.height)) pt @\(scale)x)\n",
                stderr
            )
            return true
        } catch {
            fputs("WindowSnapshot: write failed: \(error)\n", stderr)
            return false
        }
    }

    /// Classic (non-glass) titlebar buttons matching the live toolbar icons.
    private static func installToolbarStandIns(on window: NSWindow) -> NSTitlebarAccessoryViewController {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 10)
        stack.alignment = .centerY

        // Match the live toolbar: Bands (sidebar.trailing) + Profiles (list.bullet).
        for symbol in ["sidebar.trailing", "list.bullet"] {
            stack.addArrangedSubview(toolbarIconButton(systemName: symbol))
        }

        // Fixed height so the accessory sits cleanly in the unified titlebar.
        let height: CGFloat = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: height))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: height),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        return accessory
    }

    private static func toolbarIconButton(systemName: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.isEnabled = false // decorative for the PNG only
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.secondaryLabelColor
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    private static func restore(
        window: NSWindow,
        appAppearance: NSAppearance?,
        windowAppearance: NSAppearance?,
        toolbarVisible: Bool,
        accessory: NSTitlebarAccessoryViewController?
    ) {
        if let accessory,
           let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        window.toolbar?.isVisible = toolbarVisible
        window.appearance = windowAppearance
        NSApp.appearance = appAppearance
    }

    /// Schedules capture after the UI has a moment to settle, then quits.
    @MainActor
    static func scheduleExportIfRequested(delay: TimeInterval = 2.5) {
        guard let path = exportPath else { return }
        // Suppress first-run sheets so they don't cover the hero UI.
        UserDefaults.standard.set(true, forKey: "hasSeenWelcome")

        // Apply dark appearance as early as possible so SwiftUI settles into it.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Second runloop tick after appearance/toolbar changes so materials redraw.
            DispatchQueue.main.async {
                _ = captureMainWindow(to: path)
                NSApp.terminate(nil)
            }
        }
    }
}
