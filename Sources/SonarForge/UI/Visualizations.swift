import SwiftUI
import AppKit
import CoreGraphics
import QuartzCore

/// Ways to visualize the playing audio in the main display pane. `curve` is the
/// original frequency-response editor (the default); the others are read-only
/// visualizers driven by the same ~20 Hz spectrum bins the analyzer produces.
enum VisualizationStyle: String, CaseIterable, Identifiable {
    case curve
    case bars
    case ledBars
    case spectrogram
    case reactor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .curve:       "Frequency Response"
        case .bars:        "Spectrum Bars"
        case .ledBars:     "LED Meters"
        case .spectrogram: "Spectrogram"
        case .reactor:     "Reactor"
        }
    }

    var systemImage: String {
        switch self {
        case .curve:       "waveform.path"
        case .bars:        "chart.bar.fill"
        case .ledBars:     "rectangle.split.3x1.fill"
        case .spectrogram: "square.grid.3x3.fill"
        case .reactor:     "hurricane"
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
}

// MARK: - SwiftUI hosts (no spectrum observation)

/// Bars / LED / spectrogram hosts only hold a `SpectrumFeed` reference — they
/// do **not** read `postEQLevels`, so SwiftUI body is not on the animation path.
/// Drawing is driven by `CVDisplayLink` inside the NSView (same rationale as
/// Reactor: main-thread Canvas freezes during button/slider tracking).

struct SpectrumBarsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumVisualizerRepresentable(mode: .bars, feed: appModel.spectrumFeed)
            .accessibilityLabel("Spectrum bars visualization")
    }
}

struct LEDBarsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumVisualizerRepresentable(mode: .ledBars, feed: appModel.spectrumFeed)
            .accessibilityLabel("LED meter visualization")
    }
}

struct SpectrogramView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpectrumVisualizerRepresentable(mode: .spectrogram, feed: appModel.spectrumFeed)
            .accessibilityLabel("Spectrogram visualization")
    }
}

enum SpectrumVisualizerMode {
    case bars
    case ledBars
    case spectrogram
}

private struct SpectrumVisualizerRepresentable: NSViewRepresentable {
    let mode: SpectrumVisualizerMode
    let feed: SpectrumFeed

    func makeNSView(context: Context) -> SpectrumVisualizerNSView {
        let view = SpectrumVisualizerNSView(mode: mode)
        view.feed = feed
        view.start()
        return view
    }

    func updateNSView(_ nsView: SpectrumVisualizerNSView, context: Context) {
        nsView.feed = feed
    }

    static func dismantleNSView(_ nsView: SpectrumVisualizerNSView, coordinator: ()) {
        nsView.stop()
    }
}

// MARK: - Off-main raster + layer present

/// CPU visualizer host: rasterizes on a background queue from a CVDisplayLink
/// callback, then assigns `layer.contents` on the main queue (coalesced).
///
/// Visibility policy: keep animating whenever the window is on-screen (including
/// when another app is frontmost). Only stop when the window is miniaturized,
/// fully occluded, the app is hidden, or this view leaves the hierarchy —
/// pausing on `willResignActive` was freezing bars/LED while the window was
/// still visible behind other apps.
final class SpectrumVisualizerNSView: NSView {
    private let mode: SpectrumVisualizerMode
    private let renderQueue: DispatchQueue = {
        let q = DispatchQueue(label: "com.sonarforge.viz.render", qos: .userInteractive)
        q.setSpecific(key: SpectrumVisualizerNSView.renderQueueKey, value: 1)
        return q
    }()

    private var displayLink: CVDisplayLink?
    /// Fallback driver when the system throttles CVDisplayLink for inactive apps.
    private var fallbackTimer: DispatchSourceTimer?
    private var lastFrameTime: CFTimeInterval = 0
    private var renderScheduled = false
    private static let minFrameInterval: CFTimeInterval = 1.0 / 30.0
    /// Cap raster size so Retina panes don't spend 10+ ms/frame on CPU fills
    /// while the main thread is busy with slider tracking.
    private static let maxRasterLongEdge: CGFloat = 560
    private static let renderQueueKey = DispatchSpecificKey<UInt8>()

    // Render-queue state.
    private var levels: [Float] = []
    private var peaks: [Float] = []
    private var lastSpectrumGeneration: UInt64 = 0
    private var peakFallPerFrame: Float = 2.0

    // Spectrogram buffer (render queue only).
    private var spectroPixels: [UInt32] = []
    private var spectroBins = 0
    private var spectroColumns = 0
    private static let spectroMaxColumns = 240

    // Cross-thread state (main writes size/feed/paused; render queue reads).
    private let stateLock = NSLock()
    private var pixelSize: CGSize = .zero
    private var forcePaused = false   // explicit stop() / dismantle
    private var _feed: SpectrumFeed?

    var feed: SpectrumFeed? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _feed }
        set { stateLock.lock(); _feed = newValue; stateLock.unlock() }
    }

    private var activityObservers: [NSObjectProtocol] = []

    init(mode: SpectrumVisualizerMode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.contentsGravity = .resize
        host.backgroundColor = mode == .spectrogram
            ? NSColor.black.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        // Avoid implicit fade animations when swapping frame images.
        host.actions = [
            "contents": NSNull(),
            "contentsScale": NSNull(),
        ]
        layer = host
        peakFallPerFrame = mode == .ledBars ? 1.6 : 2.0
        installActivityObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDrivers()
        for token in activityObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func start() {
        stateLock.lock(); forcePaused = false; stateLock.unlock()
        startDrivers()
    }

    func stop() {
        stateLock.lock(); forcePaused = true; stateLock.unlock()
        stopDrivers()
    }

    override func layout() {
        super.layout()
        updatePixelSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePixelSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updatePixelSize()
            startDrivers()
        } else {
            stopDrivers()
        }
    }

    private func updatePixelSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: max(bounds.width * scale, 1),
                          height: max(bounds.height * scale, 1))
        stateLock.lock()
        pixelSize = size
        stateLock.unlock()
        if let layer {
            layer.contentsScale = scale
        }
    }

    // MARK: Drivers (display link + inactive-app fallback timer)

    private func startDrivers() {
        refreshVisibilityCache()
        startDisplayLink()
        startFallbackTimer()
    }

    private func stopDrivers() {
        stopDisplayLink()
        stopFallbackTimer()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else { return }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<SpectrumVisualizerNSView>.fromOpaque(context).takeUnretainedValue()
            view.requestFrame()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        if let screen = window?.screen {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                ?? CGMainDisplayID()
            CVDisplayLinkSetCurrentCGDisplay(link, displayID)
        }
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    /// `CVDisplayLink` can be heavily throttled for non-frontmost apps; a cheap
    /// 20 Hz timer on our render queue keeps bars/LED alive while the window is
    /// still visible behind another app (Reactor's Metal path is less affected).
    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + Self.minFrameInterval,
                       repeating: Self.minFrameInterval,
                       leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.requestFrame()
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    /// Updated on the main thread from layout / occlusion / miniaturize notes.
    /// "On screen" only — `forcePaused` is checked separately.
    private var cachedWindowVisible = true

    private func refreshVisibilityCache() {
        // Must run on main — touches NSApp / NSWindow.
        let onScreen: Bool = {
            if NSApp.isHidden { return false }
            guard let window, !window.isMiniaturized else { return false }
            return window.occlusionState.contains(.visible)
        }()
        stateLock.lock()
        cachedWindowVisible = onScreen
        stateLock.unlock()
    }

    private func requestFrame() {
        stateLock.lock()
        let forced = forcePaused
        let visible = cachedWindowVisible
        if forced || !visible || renderScheduled {
            stateLock.unlock()
            return
        }
        renderScheduled = true
        stateLock.unlock()

        // Fallback timer already hops here on renderQueue; display-link may not.
        if DispatchQueue.getSpecific(key: Self.renderQueueKey) != nil {
            renderOneFrame()
        } else {
            renderQueue.async { [weak self] in
                self?.renderOneFrame()
            }
        }
    }

    private func renderOneFrame() {
        stateLock.lock()
        renderScheduled = false
        let forced = forcePaused
        let size = pixelSize
        let feed = _feed
        let visible = cachedWindowVisible
        stateLock.unlock()
        guard !forced, visible else { return }

        let now = CACurrentMediaTime()
        if now - lastFrameTime < Self.minFrameInterval { return }
        lastFrameTime = now

        // Downscale raster target — layer.contentsGravity scales it back up.
        var rasterSize = size
        let longEdge = max(size.width, size.height)
        if longEdge > Self.maxRasterLongEdge {
            let scale = Self.maxRasterLongEdge / longEdge
            rasterSize = CGSize(width: max(2, size.width * scale),
                                height: max(2, size.height * scale))
        }

        guard let image = rasterize(size: rasterSize, feed: feed) else { return }
        // Present off the main thread. Pure `contents` swaps with actions
        // disabled do not need the main run loop — critical during slider
        // tracking when main is busy and a main-queue present would freeze.
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    private func installActivityObservers() {
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            self?.refreshVisibilityCache()
        }
        activityObservers = [
            // Do NOT pause on resign-active — window may still be visible.
            center.addObserver(forName: NSApplication.didHideNotification,
                               object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSApplication.didUnhideNotification,
                               object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityCache()
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityCache()
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityCache()
            },
        ]
        // Seed cache once we're on a window.
        DispatchQueue.main.async { [weak self] in self?.refreshVisibilityCache() }
    }

    // MARK: Rasterize (render queue)

    private func rasterize(size: CGSize, feed: SpectrumFeed?) -> CGImage? {
        guard size.width > 2, size.height > 2 else { return nil }

        // Pull spectrum; advance peaks even when bins are unchanged so caps fall.
        let gen = feed?.copyPost(into: &levels) ?? 0
        let spectrumChanged = gen != lastSpectrumGeneration
        if spectrumChanged {
            lastSpectrumGeneration = gen
        }
        updatePeaks(spectrumChanged: spectrumChanged)

        switch mode {
        case .bars:
            return drawBars(size: size)
        case .ledBars:
            return drawLED(size: size)
        case .spectrogram:
            return drawSpectrogram(size: size, spectrumChanged: spectrumChanged)
        }
    }

    private func updatePeaks(spectrumChanged: Bool) {
        guard !levels.isEmpty else {
            peaks = []
            return
        }
        // Scale the original ~2 dB-per-20 Hz-frame fall to our ~30 fps display link.
        let fall = peakFallPerFrame * Float(Self.minFrameInterval * 20)
        if peaks.count != levels.count {
            peaks = levels
            return
        }
        for i in levels.indices {
            let fallen = peaks[i] - fall
            peaks[i] = spectrumChanged ? max(levels[i], fallen) : fallen
        }
    }

    // MARK: Bars

    private func drawBars(size: CGSize) -> CGImage? {
        guard levels.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let n = levels.count
            let gapFinal: CGFloat = n > 48 ? max(1, w * 0.002) : max(2, w * 0.004)
            let barWidth = max(1, (w - gapFinal * CGFloat(n - 1)) / CGFloat(n))

            // Accent gradient via clip + linear gradient.
            let accent = NSColor.controlAccentColor
            let bars = CGMutablePath()
            for i in 0..<n {
                let x = CGFloat(i) * (barWidth + gapFinal)
                let height = CGFloat(VizScale.normFloat(levels[i])) * h
                if height > 0.5 {
                    bars.addRect(CGRect(x: x, y: 0, width: barWidth, height: height))
                }
            }
            ctx.addPath(bars)
            ctx.clip()
            let colors = [
                accent.withAlphaComponent(0.35).cgColor,
                accent.cgColor,
            ] as CFArray
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: h),
                                       options: [])
            }
            ctx.resetClip()

            // Peak caps.
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.85).cgColor)
            for i in 0..<min(n, peaks.count) {
                let x = CGFloat(i) * (barWidth + gapFinal)
                let capY = CGFloat(VizScale.normFloat(peaks[i])) * h
                ctx.fill(CGRect(x: x, y: max(0, capY - 2), width: barWidth, height: 2))
            }
        }
    }

    // MARK: LED

    private func drawLED(size: CGSize) -> CGImage? {
        guard levels.count > 1 else { return nil }
        let segments = 22
        let greenTop = 0.6
        let amberTop = 0.82
        return withContext(size: size) { ctx, w, h in
            let n = levels.count
            let gapFinal: CGFloat = n > 48 ? max(1, w * 0.002) : max(2, w * 0.004)
            let colWidth = max(1, (w - gapFinal * CGFloat(n - 1)) / CGFloat(n))
            let segGap: CGFloat = max(1, h * 0.004)
            let segHeight = max(1, (h - segGap * CGFloat(segments - 1)) / CGFloat(segments))

            let green = NSColor.systemGreen.cgColor
            let amber = NSColor.systemYellow.cgColor
            let red = NSColor.systemRed.cgColor
            let greenDim = NSColor.systemGreen.withAlphaComponent(0.10).cgColor
            let amberDim = NSColor.systemYellow.withAlphaComponent(0.10).cgColor
            let redDim = NSColor.systemRed.withAlphaComponent(0.10).cgColor

            for i in 0..<n {
                let x = CGFloat(i) * (colWidth + gapFinal)
                let lit = Int((VizScale.normFloat(levels[i]) * Float(segments)).rounded())
                let peakSeg = i < peaks.count
                    ? Int((VizScale.normFloat(peaks[i]) * Float(segments)).rounded())
                    : 0
                for j in 0..<segments {
                    let y = CGFloat(j) * (segHeight + segGap)
                    let rect = CGRect(x: x, y: y, width: colWidth, height: segHeight)
                    let isPeak = j == peakSeg - 1 && peakSeg > 0
                    let isLit = j < lit
                    let frac = Double(j) / Double(segments - 1)
                    let color: CGColor
                    if frac < greenTop {
                        color = (isPeak || isLit) ? green : greenDim
                    } else if frac < amberTop {
                        color = (isPeak || isLit) ? amber : amberDim
                    } else {
                        color = (isPeak || isLit) ? red : redDim
                    }
                    ctx.setFillColor(color)
                    ctx.fill(rect)
                }
            }
        }
    }

    // MARK: Spectrogram

    private func drawSpectrogram(size: CGSize, spectrumChanged: Bool) -> CGImage? {
        guard levels.count > 1 else { return nil }
        let maxColumns = Self.spectroMaxColumns
        let bins = levels.count

        if spectroBins != bins || spectroPixels.count != maxColumns * bins {
            spectroBins = bins
            spectroColumns = 0
            spectroPixels = [UInt32](repeating: Self.heatBGRA(0), count: maxColumns * bins)
        }

        if spectrumChanged {
            if spectroColumns > 0 {
                for row in 0..<bins {
                    let rowStart = row * maxColumns
                    spectroPixels.withUnsafeMutableBufferPointer { buf in
                        let base = buf.baseAddress! + rowStart
                        memmove(base, base + 1, (maxColumns - 1) * MemoryLayout<UInt32>.stride)
                    }
                }
            }
            let col = maxColumns - 1
            for b in 0..<bins {
                let row = bins - 1 - b
                spectroPixels[row * maxColumns + col] = Self.heatBGRA(VizScale.normFloat(levels[b]))
            }
            spectroColumns = min(spectroColumns + 1, maxColumns)
        }

        guard let small = makeBGRAImage(pixels: spectroPixels, width: maxColumns, height: bins) else {
            return nil
        }
        // Scale to view pixel size without interpolation for the chunky look.
        return withContext(size: size) { ctx, w, h in
            ctx.interpolationQuality = .none
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    // MARK: CG helpers

    /// Bottom-left origin context matching Core Graphics defaults.
    private func withContext(size: CGSize, draw: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage? {
        let w = Int(size.width.rounded(.down))
        let h = Int(size.height.rounded(.down))
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress else { return nil }
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return nil }
            draw(ctx, CGFloat(w), CGFloat(h))
            return ctx.makeImage()
        }
    }

    private func makeBGRAImage(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * MemoryLayout<UInt32>.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private struct HeatStop {
        let t: Float
        let r: Float
        let g: Float
        let b: Float
    }

    private static let heatStops: [HeatStop] = [
        HeatStop(t: 0.00, r: 0.02, g: 0.02, b: 0.08),
        HeatStop(t: 0.30, r: 0.25, g: 0.05, b: 0.45),
        HeatStop(t: 0.55, r: 0.75, g: 0.10, b: 0.55),
        HeatStop(t: 0.78, r: 0.98, g: 0.55, b: 0.20),
        HeatStop(t: 1.00, r: 1.00, g: 0.98, b: 0.85),
    ]

    private static func heatBGRA(_ t: Float) -> UInt32 {
        let tt = min(max(t, 0), 1)
        var lo = heatStops[0], hi = heatStops[heatStops.count - 1]
        for k in 1..<heatStops.count where heatStops[k].t >= tt {
            hi = heatStops[k]
            lo = heatStops[k - 1]
            break
        }
        let span = hi.t - lo.t
        let f = span > 0 ? (tt - lo.t) / span : 0
        let r = lo.r + (hi.r - lo.r) * f
        let g = lo.g + (hi.g - lo.g) * f
        let b = lo.b + (hi.b - lo.b) * f
        let ri = UInt32(min(max(r * 255, 0), 255))
        let gi = UInt32(min(max(g * 255, 0), 255))
        let bi = UInt32(min(max(b * 255, 0), 255))
        let ai: UInt32 = 255
        return bi | (gi << 8) | (ri << 16) | (ai << 24)
    }
}
