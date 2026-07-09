import AppKit
import CoreGraphics
import QuartzCore

// Single host for spectrum + PCM visualizer raster paths.
// swiftlint:disable type_body_length file_length

// MARK: - Off-main raster + layer present

/// CPU visualizer host: rasterizes on a background queue from a CVDisplayLink
/// callback, then sets `layer.contents` off the main thread.
///
/// Visibility policy: keep animating whenever the window is on-screen (including
/// when another app is frontmost). Only stop when the window is miniaturized,
/// fully occluded, the app is hidden, or this view leaves the hierarchy.
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
    private var _spectrumFeed: SpectrumFeed?
    private var _waveformFeed: WaveformFeed?

    var spectrumFeed: SpectrumFeed? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _spectrumFeed }
        set { stateLock.lock(); _spectrumFeed = newValue; stateLock.unlock() }
    }

    var waveformFeed: WaveformFeed? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _waveformFeed }
        set { stateLock.lock(); _waveformFeed = newValue; stateLock.unlock() }
    }

    // Time-domain render-queue state.
    private var waveSamples: [Float] = []
    private var waveLeft: [Float] = []
    private var waveRight: [Float] = []
    private var waveSnapshot = WaveformSnapshot.empty

    // VU/PPM ballistics (linear 0…1 display domain after dB mapping).
    private var vuLeft: Float = 0
    private var vuRight: Float = 0
    private var ppmLeft: Float = 0
    private var ppmRight: Float = 0
    private var corrSmoothed: Float = 0

    private var activityObservers: [NSObjectProtocol] = []

    init(mode: SpectrumVisualizerMode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.contentsGravity = .resize
        host.backgroundColor = mode == .spectrogram || mode == .vectorscope
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
        let spectrum = _spectrumFeed
        let waveform = _waveformFeed
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

        guard let image = rasterize(size: rasterSize, spectrum: spectrum, waveform: waveform) else { return }
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

    private func rasterize(size: CGSize, spectrum: SpectrumFeed?, waveform: WaveformFeed?) -> CGImage? {
        guard size.width > 2, size.height > 2 else { return nil }

        switch mode {
        case .oscilloscope:
            _ = waveform?.copySamples(into: &waveSamples)
            return drawOscilloscope(size: size)
        case .vectorscope:
            if let snap = waveform?.copySnapshot() {
                waveSnapshot = snap
                waveLeft = snap.left
                waveRight = snap.right
            }
            return drawVectorscope(size: size)
        case .correlation:
            if let snap = waveform?.copySnapshot() {
                waveSnapshot = snap
                // Smooth correlation for a calm readout (~150 ms-ish at 30 fps).
                corrSmoothed += (snap.correlation - corrSmoothed) * 0.18
            }
            return drawCorrelation(size: size)
        case .vuMeters:
            if let snap = waveform?.copySnapshot() {
                waveSnapshot = snap
                updateMeterBallistics(snap)
            }
            return drawVUMeters(size: size)
        case .bars, .mirroredBars, .ledBars, .spectrogram:
            break
        }

        // Pull spectrum; advance peaks even when bins are unchanged so caps fall.
        let gen = spectrum?.copyPost(into: &levels) ?? 0
        let spectrumChanged = gen != lastSpectrumGeneration
        if spectrumChanged {
            lastSpectrumGeneration = gen
        }
        updatePeaks(spectrumChanged: spectrumChanged)

        switch mode {
        case .bars:
            return drawBars(size: size)
        case .mirroredBars:
            return drawMirroredBars(size: size)
        case .ledBars:
            return drawLED(size: size)
        case .spectrogram:
            return drawSpectrogram(size: size, spectrumChanged: spectrumChanged)
        default:
            return nil
        }
    }

    /// VU: slow RMS rise/fall. PPM: fast peak attack, slow decay.
    private func updateMeterBallistics(_ snap: WaveformSnapshot) {
        let dt = Float(Self.minFrameInterval)
        // Map linear → 0…1 over −60…0 dB.
        func level(_ linear: Float) -> Float {
            Float(VizScale.meterNorm(VizScale.linearToDB(linear)))
        }
        let lRMS = level(snap.leftRMS)
        let rRMS = level(snap.rightRMS)
        let lPeak = level(snap.leftPeak)
        let rPeak = level(snap.rightPeak)

        // VU ~300 ms; attack slightly faster than release.
        let vuAtk: Float = 1 - exp(-dt / 0.15)
        let vuRel: Float = 1 - exp(-dt / 0.30)
        vuLeft += (lRMS - vuLeft) * (lRMS > vuLeft ? vuAtk : vuRel)
        vuRight += (rRMS - vuRight) * (rRMS > vuRight ? vuAtk : vuRel)

        // PPM: near-instant attack, ~1.5 s fall for 20 dB (approximated).
        let ppmAtk: Float = 1 - exp(-dt / 0.01)
        let ppmRel: Float = 1 - exp(-dt / 0.80)
        ppmLeft += (lPeak - ppmLeft) * (lPeak > ppmLeft ? ppmAtk : ppmRel)
        ppmRight += (rPeak - ppmRight) * (rPeak > ppmRight ? ppmAtk : ppmRel)
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
            fillAccentGradient(ctx: ctx, accent: accent, w: w, h: h)
            ctx.resetClip()

            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.85).cgColor)
            for i in 0..<min(n, peaks.count) {
                let x = CGFloat(i) * (barWidth + gapFinal)
                let capY = CGFloat(VizScale.normFloat(peaks[i])) * h
                ctx.fill(CGRect(x: x, y: max(0, capY - 2), width: barWidth, height: 2))
            }
        }
    }

    /// Classic mirrored media-player bars: grow up and down from a center line.
    private func drawMirroredBars(size: CGSize) -> CGImage? {
        guard levels.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let n = levels.count
            let gapFinal: CGFloat = n > 48 ? max(1, w * 0.002) : max(2, w * 0.004)
            let barWidth = max(1, (w - gapFinal * CGFloat(n - 1)) / CGFloat(n))
            let mid = h * 0.5
            let half = h * 0.48

            // Center line.
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: mid))
            ctx.addLine(to: CGPoint(x: w, y: mid))
            ctx.strokePath()

            let accent = NSColor.controlAccentColor
            let bars = CGMutablePath()
            for i in 0..<n {
                let x = CGFloat(i) * (barWidth + gapFinal)
                let amp = CGFloat(VizScale.normFloat(levels[i])) * half
                if amp > 0.5 {
                    bars.addRect(CGRect(x: x, y: mid - amp, width: barWidth, height: amp * 2))
                }
            }
            ctx.addPath(bars)
            ctx.clip()
            fillAccentGradient(ctx: ctx, accent: accent, w: w, h: h)
            ctx.resetClip()
        }
    }

    private func fillAccentGradient(ctx: CGContext, accent: NSColor, w: CGFloat, h: CGFloat) {
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

    // MARK: Oscilloscope (post-EQ mono PCM)

    private func drawOscilloscope(size: CGSize) -> CGImage? {
        guard waveSamples.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: h * 0.5))
            ctx.addLine(to: CGPoint(x: w, y: h * 0.5))
            ctx.strokePath()

            var peak: Float = 0
            for s in waveSamples { peak = max(peak, abs(s)) }
            let scale = max(peak, 0.05)

            let midY = h * 0.5
            let amp = h * 0.42
            let n = waveSamples.count
            let path = CGMutablePath()
            for i in 0..<n {
                let x = w * CGFloat(i) / CGFloat(n - 1)
                let y = midY - CGFloat(waveSamples[i] / scale) * amp
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(max(1.5, w / 600))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
        }
    }

    // MARK: Vectorscope / goniometer (Mid = L+R vertical, Side = L−R horizontal)

    private func drawVectorscope(size: CGSize) -> CGImage? {
        let n = min(waveLeft.count, waveRight.count)
        guard n > 8 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let side = min(w, h)
            let origin = CGPoint(x: (w - side) * 0.5, y: (h - side) * 0.5)
            let cx = origin.x + side * 0.5
            let cy = origin.y + side * 0.5
            let radius = side * 0.42

            // Background disc + axes.
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                       width: radius * 2, height: radius * 2))
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            // Mono (vertical) and side (horizontal) guides.
            ctx.move(to: CGPoint(x: cx, y: cy - radius))
            ctx.addLine(to: CGPoint(x: cx, y: cy + radius))
            ctx.move(to: CGPoint(x: cx - radius, y: cy))
            ctx.addLine(to: CGPoint(x: cx + radius, y: cy))
            // ±45° (hard L / hard R).
            let d = radius * 0.7071
            ctx.move(to: CGPoint(x: cx - d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy + d))
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy - d))
            ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                         width: radius * 2, height: radius * 2))

            // Labels.
            drawLabel(ctx, "M", at: CGPoint(x: cx + 4, y: cy + radius - 14), color: .secondaryLabelColor)
            drawLabel(ctx, "S", at: CGPoint(x: cx + radius - 14, y: cy + 4), color: .secondaryLabelColor)

            // Plot Mid/Side points (downsample for speed).
            let step = max(1, n / 512)
            var peak: Float = 0.05
            for i in stride(from: 0, to: n, by: step) {
                peak = max(peak, max(abs(waveLeft[i]), abs(waveRight[i])))
            }
            let inv = 1 / peak
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor)
            let dot: CGFloat = max(1.2, side / 400)
            for i in stride(from: 0, to: n, by: step) {
                let l = waveLeft[i] * inv
                let r = waveRight[i] * inv
                let mid = (l + r) * 0.5
                let sideS = (l - r) * 0.5
                let x = cx + CGFloat(sideS) * radius
                let y = cy + CGFloat(mid) * radius
                ctx.fillEllipse(in: CGRect(x: x - dot * 0.5, y: y - dot * 0.5,
                                           width: dot, height: dot))
            }

            // Live correlation chip.
            let corr = waveSnapshot.correlation
            let label = String(format: "r %+0.2f", corr)
            drawLabel(ctx, label, at: CGPoint(x: origin.x + 8, y: origin.y + 8),
                      color: .labelColor)
        }
    }

    // MARK: Correlation meter

    private func drawCorrelation(size: CGSize) -> CGImage? {
        return withContext(size: size) { ctx, w, h in
            let r = corrSmoothed
            let midY = h * 0.55
            let barH = min(36, h * 0.12)
            let barW = w * 0.82
            let barX = (w - barW) * 0.5
            let barY = midY - barH * 0.5
            let centerX = barX + barW * 0.5

            // Track.
            ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(CGRect(x: barX, y: barY, width: barW, height: barH))

            // Zones: red left of −0.5, yellow −0.5…0.25, green above.
            let zoneY = barY
            func xFor(_ corr: Float) -> CGFloat {
                barX + barW * CGFloat((corr + 1) * 0.5)
            }
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: barX, y: zoneY, width: xFor(-0.5) - barX, height: barH))
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: xFor(-0.5), y: zoneY, width: xFor(0.25) - xFor(-0.5), height: barH))
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: xFor(0.25), y: zoneY, width: barX + barW - xFor(0.25), height: barH))

            // Zero tick.
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: centerX, y: barY - 6))
            ctx.addLine(to: CGPoint(x: centerX, y: barY + barH + 6))
            ctx.strokePath()

            // Needle.
            let nx = xFor(r)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(CGRect(x: nx - 2, y: barY - 4, width: 4, height: barH + 8))

            // Big number.
            let text = String(format: "%+.2f", r)
            let monoHint: String
            if r > 0.7 {
                monoHint = "Highly mono / in phase"
            } else if r > 0.25 {
                monoHint = "Mostly correlated"
            } else if r > -0.25 {
                monoHint = "Wide / uncorrelated"
            } else if r > -0.7 {
                monoHint = "Out of phase risk"
            } else {
                monoHint = "Severe inversion"
            }

            drawCenteredLabel(ctx, text,
                              rect: CGRect(x: 0, y: midY - h * 0.32, width: w, height: h * 0.18),
                              style: (min(48, h * 0.16), .labelColor, true))
            drawCenteredLabel(ctx, monoHint,
                              rect: CGRect(x: 0, y: midY + h * 0.12, width: w, height: 22),
                              style: (13, .secondaryLabelColor, false))
            drawCenteredLabel(ctx, "−1          0          +1",
                              rect: CGRect(x: barX, y: barY + barH + 10, width: barW, height: 16),
                              style: (11, .tertiaryLabelColor, false))
        }
    }

    // MARK: VU / PPM meters

    private func drawVUMeters(size: CGSize) -> CGImage? {
        return withContext(size: size) { ctx, w, h in
            let margin: CGFloat = 16
            let gap: CGFloat = 20
            let colW = (w - margin * 2 - gap) * 0.5
            let colH = h - margin * 2 - 28
            drawChannelMeter(ctx,
                             title: "L",
                             levels: (CGFloat(vuLeft), CGFloat(ppmLeft)),
                             in: CGRect(x: margin, y: margin + 20, width: colW, height: colH))
            drawChannelMeter(ctx,
                             title: "R",
                             levels: (CGFloat(vuRight), CGFloat(ppmRight)),
                             in: CGRect(x: margin + colW + gap, y: margin + 20, width: colW, height: colH))
            drawCenteredLabel(ctx, "VU (fill)  ·  PPM (cap)",
                              rect: CGRect(x: 0, y: 4, width: w, height: 16),
                              style: (11, .secondaryLabelColor, false))
        }
    }

    private func drawChannelMeter(_ ctx: CGContext, title: String, levels: (vu: CGFloat, ppm: CGFloat),
                                  in rect: CGRect) {
        let vu = levels.vu
        let ppm = levels.ppm
        // Scale markings −60…0.
        let marks: [(Float, String)] = [(-60, "−60"), (-40, "−40"), (-20, "−20"), (-10, "−10"), (0, "0")]
        ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        for (db, _) in marks {
            let y = rect.minY + rect.height * VizScale.meterNorm(db)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.strokePath()

        // VU body (bottom-up).
        let vuH = rect.height * min(max(vu, 0), 1)
        let vuRect = CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY,
                            width: rect.width * 0.6, height: vuH)
        let accent = NSColor.controlAccentColor
        ctx.setFillColor(accent.withAlphaComponent(0.85).cgColor)
        ctx.fill(vuRect)
        // Red tip above −6 dB region of the fill.
        let redStart = rect.minY + rect.height * VizScale.meterNorm(-6)
        if vuRect.maxY > redStart {
            let redH = vuRect.maxY - redStart
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: vuRect.minX, y: redStart, width: vuRect.width, height: redH))
        }

        // PPM cap.
        let ppmY = rect.minY + rect.height * min(max(ppm, 0), 1)
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.fill(CGRect(x: vuRect.minX - 2, y: ppmY - 1.5, width: vuRect.width + 4, height: 3))

        drawCenteredLabel(ctx, title,
                          rect: CGRect(x: rect.minX, y: rect.maxY + 4, width: rect.width, height: 18),
                          style: (14, .labelColor, true))
    }

    // MARK: Text helpers

    private func drawLabel(_ ctx: CGContext, _ string: String, at point: CGPoint, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color,
        ]
        let ns = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(ns)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawCenteredLabel(_ ctx: CGContext, _ string: String, rect: CGRect,
                                   style: (fontSize: CGFloat, color: NSColor, bold: Bool)) {
        let font = style.bold
            ? NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
            : NSFont.systemFont(ofSize: style.fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color,
        ]
        let ns = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(ns)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = rect.midX - bounds.width * 0.5
        let y = rect.midY - bounds.height * 0.5
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
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

// swiftlint:enable type_body_length file_length
