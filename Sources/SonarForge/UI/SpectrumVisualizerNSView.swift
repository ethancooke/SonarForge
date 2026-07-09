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
    /// Current draw mode. Mutable so SwiftUI can switch bar/scope styles without
    /// recreating the NSView (updateNSView reuses the same instance).
    private var mode: SpectrumVisualizerMode
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

    // Ghost-bar trail history (newest last).
    private var ghostHistory: [[Float]] = []
    private static let ghostMaxFrames = 12

    // CRT phosphor (BGRA pixels, same size as last raster).
    private var phosphorPixels: [UInt32] = []
    private var phosphorW = 0
    private var phosphorH = 0

    // Particles.
    private struct Particle {
        var x: Float
        var y: Float
        var vx: Float
        var vy: Float
        var life: Float
        var hue: Float
    }
    private var particles: [Particle] = []
    private static let maxParticles = 400

    // Matrix rain — one stream per frequency column; glyphs are note/Hz/dB tokens.
    private struct MatrixStream {
        var headY: Float          // top of bright head, top-origin (0 = top)
        var speed: Float          // cells per second (scaled)
        var trail: [String]       // newest glyph at index 0 (head)
        var tick: Int             // advances glyph choice with audio
        var binIndex: Int
    }
    private var matrixStreams: [MatrixStream] = []
    private var matrixCellH: Float = 14
    private var matrixFrame: Int = 0

    // Cross-thread state (main writes size/feed/mode/paused; render queue reads).
    private let stateLock = NSLock()
    private var pixelSize: CGSize = .zero
    private var forcePaused = false   // explicit stop() / dismantle
    private var _spectrumFeed: SpectrumFeed?
    private var _waveformFeed: WaveformFeed?
    /// Snapshot of `mode` for the render queue (written under stateLock).
    private var renderMode: SpectrumVisualizerMode

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
    private var balanceSmoothed: Float = 0
    /// Short trail of Mid/Side centroids so L↔R pans leave a visible path.
    private var scopeTrail: [(mid: Float, side: Float)] = []
    private static let scopeTrailMax = 48

    private var activityObservers: [NSObjectProtocol] = []

    init(mode: SpectrumVisualizerMode) {
        self.mode = mode
        self.renderMode = mode
        super.init(frame: .zero)
        wantsLayer = true
        let host = CALayer()
        host.contentsGravity = .resize
        // Avoid implicit fade animations when swapping frame images.
        host.actions = [
            "contents": NSNull(),
            "contentsScale": NSNull(),
        ]
        layer = host
        applyModeAppearance(mode)
        installActivityObservers()
    }

    /// Called from `updateNSView` when the SwiftUI style picker changes. Resets
    /// mode-local state so leftover ghost trails / phosphor don't flash.
    func setMode(_ newMode: SpectrumVisualizerMode) {
        stateLock.lock()
        let old = mode
        guard old != newMode else {
            stateLock.unlock()
            return
        }
        mode = newMode
        renderMode = newMode
        stateLock.unlock()

        // Clear mode-specific buffers on the render queue to avoid races.
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.ghostHistory.removeAll(keepingCapacity: true)
            self.phosphorPixels.removeAll(keepingCapacity: true)
            self.phosphorW = 0
            self.phosphorH = 0
            self.particles.removeAll(keepingCapacity: true)
            self.matrixStreams.removeAll(keepingCapacity: true)
            self.matrixFrame = 0
            self.peaks.removeAll(keepingCapacity: true)
            self.levels.removeAll(keepingCapacity: true)
            self.lastSpectrumGeneration = 0
            self.waveSamples.removeAll(keepingCapacity: true)
            self.waveLeft.removeAll(keepingCapacity: true)
            self.waveRight.removeAll(keepingCapacity: true)
            self.vuLeft = 0; self.vuRight = 0
            self.ppmLeft = 0; self.ppmRight = 0
            self.corrSmoothed = 0
            self.balanceSmoothed = 0
            self.scopeTrail.removeAll(keepingCapacity: true)
            self.spectroPixels.removeAll(keepingCapacity: true)
            self.spectroBins = 0
            self.spectroColumns = 0
            self.peakFallPerFrame = newMode == .ledBars ? 1.6 : 2.0
        }
        applyModeAppearance(newMode)
        // Drop the last presented frame so we don't keep showing the old style.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
    }

    private func applyModeAppearance(_ mode: SpectrumVisualizerMode) {
        let darkModes: Set<SpectrumVisualizerMode> = [
            .spectrogram, .vectorscope, .crt, .particles, .polar, .matrix,
        ]
        layer?.backgroundColor = darkModes.contains(mode)
            ? NSColor.black.withAlphaComponent(0.30).cgColor
            : NSColor.clear.cgColor
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
        // Clear presented frame so a remounted sibling (e.g. Reactor) never
        // briefly shows the last particles/bars frame underneath.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
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
            stateLock.lock()
            let forced = forcePaused
            stateLock.unlock()
            if !forced {
                startDrivers()
            }
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
        let activeMode = renderMode
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

        guard let image = rasterize(size: rasterSize, mode: activeMode,
                                    spectrum: spectrum, waveform: waveform) else { return }
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

    private func rasterize(size: CGSize, mode: SpectrumVisualizerMode,
                           spectrum: SpectrumFeed?, waveform: WaveformFeed?) -> CGImage? {
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
                balanceSmoothed += (snap.balance - balanceSmoothed) * 0.25
                corrSmoothed += (snap.correlation - corrSmoothed) * 0.18
                // Centroid of the current window in Mid/Side (tracks pans).
                if let c = Self.midSideCentroid(left: snap.left, right: snap.right) {
                    scopeTrail.append(c)
                    if scopeTrail.count > Self.scopeTrailMax {
                        scopeTrail.removeFirst(scopeTrail.count - Self.scopeTrailMax)
                    }
                }
            }
            return drawVectorscope(size: size)
        case .correlation:
            if let snap = waveform?.copySnapshot() {
                waveSnapshot = snap
                // Smooth for a calm readout (~150 ms-ish at 30 fps).
                corrSmoothed += (snap.correlation - corrSmoothed) * 0.18
                balanceSmoothed += (snap.balance - balanceSmoothed) * 0.25
            }
            return drawCorrelation(size: size)
        case .vuMeters:
            if let snap = waveform?.copySnapshot() {
                waveSnapshot = snap
                updateMeterBallistics(snap)
            }
            return drawVUMeters(size: size)
        case .crt:
            _ = waveform?.copySamples(into: &waveSamples)
            return drawCRT(size: size)
        case .bars, .mirroredBars, .ghostBars, .polar, .ledBars, .spectrogram,
             .particles, .matrix, .miniBars:
            break
        }

        // Pull spectrum; advance peaks even when bins are unchanged so caps fall.
        let gen = spectrum?.copyPost(into: &levels) ?? 0
        let spectrumChanged = gen != lastSpectrumGeneration
        if spectrumChanged {
            lastSpectrumGeneration = gen
            if mode == .ghostBars {
                ghostHistory.append(levels)
                if ghostHistory.count > Self.ghostMaxFrames {
                    ghostHistory.removeFirst(ghostHistory.count - Self.ghostMaxFrames)
                }
            }
        }
        updatePeaks(spectrumChanged: spectrumChanged)

        switch mode {
        case .bars, .miniBars:
            return drawBars(size: size, mini: mode == .miniBars)
        case .mirroredBars:
            return drawMirroredBars(size: size)
        case .ghostBars:
            return drawGhostBars(size: size)
        case .polar:
            return drawPolar(size: size)
        case .ledBars:
            return drawLED(size: size)
        case .spectrogram:
            return drawSpectrogram(size: size, spectrumChanged: spectrumChanged)
        case .particles:
            return drawParticles(size: size, spectrumChanged: spectrumChanged)
        case .matrix:
            return drawMatrixRain(size: size, spectrumChanged: spectrumChanged)
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

    private func drawBars(size: CGSize, mini: Bool = false) -> CGImage? {
        guard levels.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let n = levels.count
            let gapFinal: CGFloat = mini ? max(0.5, w * 0.003) : (n > 48 ? max(1, w * 0.002) : max(2, w * 0.004))
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

            if !mini {
                ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.85).cgColor)
                for i in 0..<min(n, peaks.count) {
                    let x = CGFloat(i) * (barWidth + gapFinal)
                    let capY = CGFloat(VizScale.normFloat(peaks[i])) * h
                    ctx.fill(CGRect(x: x, y: max(0, capY - 2), width: barWidth, height: 2))
                }
            }
        }
    }

    private func drawGhostBars(size: CGSize) -> CGImage? {
        guard levels.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let n = levels.count
            let gapFinal: CGFloat = n > 48 ? max(1, w * 0.002) : max(2, w * 0.004)
            let barWidth = max(1, (w - gapFinal * CGFloat(n - 1)) / CGFloat(n))
            let frames = ghostHistory
            let count = max(frames.count, 1)
            for (fi, frame) in frames.enumerated() {
                let age = CGFloat(fi + 1) / CGFloat(count)
                let alpha = 0.08 + 0.55 * age * age
                let accent = NSColor.controlAccentColor.withAlphaComponent(alpha)
                ctx.setFillColor(accent.cgColor)
                for i in 0..<min(n, frame.count) {
                    let x = CGFloat(i) * (barWidth + gapFinal)
                    let height = CGFloat(VizScale.normFloat(frame[i])) * h
                    if height > 0.5 {
                        ctx.fill(CGRect(x: x, y: 0, width: barWidth, height: height))
                    }
                }
            }
            // Bright live outline caps.
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.9).cgColor)
            for i in 0..<min(n, peaks.count) {
                let x = CGFloat(i) * (barWidth + gapFinal)
                let capY = CGFloat(VizScale.normFloat(peaks[i])) * h
                ctx.fill(CGRect(x: x, y: max(0, capY - 2), width: barWidth, height: 2))
            }
        }
    }

    private func drawPolar(size: CGSize) -> CGImage? {
        guard levels.count > 1 else { return nil }
        return withContext(size: size) { ctx, w, h in
            let cx = w * 0.5
            let cy = h * 0.5
            let maxR = min(w, h) * 0.42
            let n = levels.count
            // Guide rings.
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor)
            ctx.setLineWidth(1)
            for frac in [0.33, 0.66, 1.0] as [CGFloat] {
                let r = maxR * frac
                ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            let path = CGMutablePath()
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n) * .pi * 2 - .pi / 2
                let amp = CGFloat(VizScale.normFloat(levels[i]))
                let r = maxR * (0.12 + 0.88 * amp)
                let p = CGPoint(x: cx + cos(t) * r, y: cy + sin(t) * r)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(max(1.5, min(w, h) / 280))
            ctx.strokePath()
            // Radial ticks for a few bins.
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            for i in stride(from: 0, to: n, by: max(1, n / 16)) {
                let t = CGFloat(i) / CGFloat(n) * .pi * 2 - .pi / 2
                let amp = CGFloat(VizScale.normFloat(levels[i]))
                let r = maxR * (0.12 + 0.88 * amp)
                ctx.move(to: CGPoint(x: cx, y: cy))
                ctx.addLine(to: CGPoint(x: cx + cos(t) * r, y: cy + sin(t) * r))
            }
            ctx.strokePath()
        }
    }

    private func drawParticles(size: CGSize, spectrumChanged: Bool) -> CGImage? {
        let w = Float(size.width)
        let h = Float(size.height)
        guard w > 2, h > 2, levels.count > 1 else { return nil }

        if spectrumChanged {
            let n = levels.count
            for i in 0..<n {
                let energy = VizScale.normFloat(levels[i])
                guard energy > 0.08 else { continue }
                // Spawn count proportional to energy (capped).
                let spawns = Int(energy * 3)
                let x = (Float(i) + 0.5) / Float(n) * w
                for _ in 0..<spawns where particles.count < Self.maxParticles {
                    particles.append(Particle(
                        x: x + Float.random(in: -4...4),
                        y: energy * h * 0.85,
                        vx: Float.random(in: -12...12),
                        vy: Float.random(in: 20...90) * energy,
                        life: Float.random(in: 0.45...1.0),
                        hue: Float(i) / Float(n)
                    ))
                }
            }
        }

        // Integrate.
        let dt = Float(Self.minFrameInterval)
        var next: [Particle] = []
        next.reserveCapacity(particles.count)
        for var p in particles {
            p.x += p.vx * dt
            p.y += p.vy * dt
            p.vy += -40 * dt   // gravity down in bottom-origin coords? y up from bottom
            p.life -= dt * 0.55
            if p.life > 0, p.y > -10, p.x > -20, p.x < w + 20 {
                next.append(p)
            }
        }
        particles = next

        return withContext(size: size) { ctx, width, height in
            for p in particles {
                let alpha = CGFloat(max(0, min(1, p.life)))
                let color = NSColor(calibratedHue: CGFloat(p.hue) * 0.75 + 0.05,
                                    saturation: 0.85,
                                    brightness: 1,
                                    alpha: alpha * 0.9)
                ctx.setFillColor(color.cgColor)
                let r = CGFloat(1.5 + p.life * 2.5)
                ctx.fillEllipse(in: CGRect(x: CGFloat(p.x) - r,
                                           y: CGFloat(p.y) - r,
                                           width: r * 2, height: r * 2))
            }
        }
    }

    private func drawCRT(size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded(.down))
        let h = Int(size.height.rounded(.down))
        guard w > 2, h > 2 else { return nil }

        if phosphorW != w || phosphorH != h || phosphorPixels.count != w * h {
            phosphorW = w
            phosphorH = h
            phosphorPixels = [UInt32](repeating: 0, count: w * h)
        }

        // Decay phosphor.
        for i in phosphorPixels.indices {
            let px = phosphorPixels[i]
            let b = Int((px >> 0) & 0xFF)
            let g = Int((px >> 8) & 0xFF)
            let r = Int((px >> 16) & 0xFF)
            let a = Int((px >> 24) & 0xFF)
            let nb = b * 88 / 100
            let ng = g * 90 / 100
            let nr = r * 85 / 100
            let na = a * 90 / 100
            phosphorPixels[i] = UInt32(nb) | (UInt32(ng) << 8) | (UInt32(nr) << 16) | (UInt32(na) << 24)
        }

        // Draw scope into phosphor.
        if waveSamples.count > 1 {
            var peak: Float = 0.05
            for s in waveSamples { peak = max(peak, abs(s)) }
            let n = waveSamples.count
            var prevX = 0
            var prevY = h / 2
            for i in 0..<n {
                let x = Int(CGFloat(i) / CGFloat(n - 1) * CGFloat(w - 1))
                let y = Int(CGFloat(h) * 0.5 - CGFloat(waveSamples[i] / peak) * CGFloat(h) * 0.4)
                plotLinePhosphor(x0: prevX, y0: prevY, x1: x, y1: max(0, min(h - 1, y)))
                prevX = x
                prevY = max(0, min(h - 1, y))
            }
        }

        // Scanlines + vignette on top via context.
        guard let base = makeBGRAImage(pixels: phosphorPixels, width: w, height: h) else { return nil }
        return withContext(size: size) { ctx, cw, ch in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
            ctx.interpolationQuality = .none
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            // Scanlines.
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            var y: CGFloat = 0
            while y < ch {
                ctx.fill(CGRect(x: 0, y: y, width: cw, height: 1))
                y += 3
            }
        }
    }

    private func plotLinePhosphor(x0: Int, y0: Int, x1: Int, y1: Int) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            stampPhosphor(x: x, y: y)
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    private func stampPhosphor(x: Int, y: Int) {
        guard x >= 0, y >= 0, x < phosphorW, y < phosphorH else { return }
        // Soft green glow: center + neighbors.
        let glow: [(Int, Int, Int)] = [
            (0, 0, 255), (1, 0, 120), (-1, 0, 120), (0, 1, 120), (0, -1, 120),
            (1, 1, 50), (1, -1, 50), (-1, 1, 50), (-1, -1, 50),
        ]
        for (dx, dy, gAdd) in glow {
            let px = x + dx, py = y + dy
            guard px >= 0, py >= 0, px < phosphorW, py < phosphorH else { continue }
            let idx = py * phosphorW + px
            let cur = phosphorPixels[idx]
            let b = min(255, Int(cur & 0xFF) + gAdd / 6)
            let g = min(255, Int((cur >> 8) & 0xFF) + gAdd)
            let r = min(255, Int((cur >> 16) & 0xFF) + gAdd / 8)
            let a = 255
            phosphorPixels[idx] = UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16) | (UInt32(a) << 24)
        }
    }

    // MARK: Matrix rain (audio-token streams)

    /// Digital-rain columns map to spectrum bins. Glyphs are not pure noise:
    /// each stream prefers the **note name** for that bin’s frequency, the
    /// bin’s **dB** digits, and compact **Hz** tokens — so loud bands rain
    /// faster/brighter with meaningful characters.
    private func drawMatrixRain(size: CGSize, spectrumChanged: Bool) -> CGImage? {
        let w = Float(size.width)
        let h = Float(size.height)
        guard w > 8, h > 8, levels.count > 1 else { return nil }

        let binCount = levels.count
        let cellH: Float = max(11, min(16, h / 36))
        matrixCellH = cellH
        let colCount = min(binCount, max(8, Int(w / (cellH * 0.95))))
        let cellW = w / Float(colCount)

        // Rebuild streams if column count changed (resize / first frame).
        if matrixStreams.count != colCount {
            var fresh: [MatrixStream] = []
            fresh.reserveCapacity(colCount)
            for c in 0..<colCount {
                let bin = Self.matrixBin(column: c, columns: colCount, bins: binCount)
                fresh.append(MatrixStream(
                    headY: Float.random(in: -h...0),
                    speed: Float.random(in: 8...18),
                    trail: [],
                    tick: Int.random(in: 0...40),
                    binIndex: bin
                ))
            }
            matrixStreams = fresh
        }

        matrixFrame &+= 1
        let dt = Float(Self.minFrameInterval)

        for c in matrixStreams.indices {
            advanceMatrixStream(
                at: c,
                colCount: colCount,
                binCount: binCount,
                cellH: cellH,
                height: h,
                dt: dt,
                spectrumChanged: spectrumChanged
            )
        }

        return withContext(size: size) { ctx, cw, ch in
            self.paintMatrixRain(ctx: ctx, width: cw, height: ch, cellW: cellW, cellH: cellH)
        }
    }

    private static func matrixBin(column: Int, columns: Int, bins: Int) -> Int {
        let raw = Int((Float(column) + 0.5) / Float(columns) * Float(bins))
        return min(max(raw, 0), bins - 1)
    }

    private func advanceMatrixStream(at c: Int, colCount: Int, binCount: Int,
                                     cellH: Float, height: Float, dt: Float,
                                     spectrumChanged: Bool) {
        var s = matrixStreams[c]
        s.binIndex = Self.matrixBin(column: c, columns: colCount, bins: binCount)
        let energy = VizScale.normFloat(levels[s.binIndex])
        let targetSpeed = 6 + energy * 42
        s.speed += (targetSpeed - s.speed) * 0.2
        s.headY += s.speed * cellH * dt

        let desiredLen = max(4, min(22, Int(4 + energy * 18)))
        while s.trail.count < desiredLen {
            s.trail.append(Self.matrixGlyph(
                bin: s.binIndex, binCount: binCount,
                db: levels[s.binIndex], energy: energy, tick: s.tick))
            s.tick &+= 1
        }
        if spectrumChanged || matrixFrame % 2 == 0 {
            if energy > 0.05 || s.trail.isEmpty {
                let g = Self.matrixGlyph(
                    bin: s.binIndex, binCount: binCount,
                    db: levels[s.binIndex], energy: energy, tick: s.tick)
                if s.trail.isEmpty {
                    s.trail.append(g)
                } else {
                    s.trail[0] = g
                }
                s.tick &+= 1
                if energy > 0.12 && matrixFrame % 3 == c % 3 {
                    s.trail.insert(g, at: 0)
                    if s.trail.count > desiredLen {
                        s.trail.removeLast(s.trail.count - desiredLen)
                    }
                }
            }
        }
        if s.trail.count > desiredLen {
            s.trail.removeLast(s.trail.count - desiredLen)
        }
        if s.headY - Float(s.trail.count) * cellH > height + cellH {
            s.headY = Float.random(in: (-height * 0.5)...0)
            s.trail.removeAll(keepingCapacity: true)
            s.speed = 8 + energy * 20
        }
        if energy < 0.04 && s.trail.count > 6 {
            s.trail = Array(s.trail.prefix(5))
        }
        matrixStreams[c] = s
    }

    private func paintMatrixRain(ctx: CGContext, width: CGFloat, height: CGFloat,
                                 cellW: Float, cellH: Float) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = CGFloat(cellH) * 0.85
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let hF = Float(height)

        for (c, s) in matrixStreams.enumerated() {
            let energyF = s.binIndex < levels.count
                ? VizScale.normFloat(levels[s.binIndex]) : Float(0)
            let energy = CGFloat(energyF)
            let x = CGFloat(c) * CGFloat(cellW) + CGFloat(cellW) * 0.15
            for (ti, glyph) in s.trail.enumerated() {
                let topY = s.headY - Float(ti) * cellH
                guard topY > -cellH, topY < hF + cellH else { continue }
                let cgY = height - CGFloat(topY) - CGFloat(cellH)
                let trailCount = max(s.trail.count, 1)
                let fade = max(CGFloat(0), 1 - CGFloat(ti) / CGFloat(trailCount))
                let isHead = ti == 0
                let alpha: CGFloat
                if isHead {
                    alpha = 0.55 + 0.45 * energy
                } else {
                    alpha = 0.12 + 0.55 * fade * (0.35 + energy)
                }
                let color: NSColor
                if isHead {
                    color = NSColor(calibratedRed: 0.75, green: 1.0, blue: 0.75, alpha: alpha)
                } else {
                    color = NSColor(calibratedRed: 0.05, green: 0.9, blue: 0.25, alpha: alpha)
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color,
                ]
                let ns = NSAttributedString(string: glyph, attributes: attrs)
                let line = CTLineCreateWithAttributedString(ns)
                ctx.saveGState()
                ctx.textPosition = CGPoint(x: x, y: cgY)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        drawCenteredLabel(ctx, "Matrix Rain · note / Hz / dB tokens from the live spectrum",
                          rect: CGRect(x: 4, y: 4, width: width - 8, height: 12),
                          style: (9, NSColor.green.withAlphaComponent(0.45), false))
    }

    /// Pick a display token for a bin: note name, frequency, or dB magnitude.
    private static func matrixGlyph(bin: Int, binCount: Int, db: Float, energy: Float, tick: Int) -> String {
        let hz = logBinFrequency(index: bin, count: binCount)
        let note = noteName(forHz: hz)
        let hzTok: String
        if hz >= 1000 {
            hzTok = String(format: "%.1fk", hz / 1000)
        } else {
            hzTok = String(format: "%.0f", hz)
        }
        let dbClamped = min(max(db, -99), 0)
        let dbTok = String(format: "%.0f", abs(dbClamped))
        var pool: [String] = [note, note, hzTok, dbTok]
        if energy > 0.25 {
            pool.append(contentsOf: [note, "♪", hzTok])
        }
        if energy > 0.55 {
            pool.append(contentsOf: ["dB", "Hz", note])
        }
        if energy < 0.08 {
            pool = [note, "·", "0"]
        }
        return pool[tick % pool.count]
    }

    private static func logBinFrequency(index: Int, count: Int,
                                        fMin: Float = 20, fMax: Float = 20_000) -> Float {
        guard count > 1 else { return fMin }
        let t = Float(index) / Float(count - 1)
        return fMin * pow(fMax / fMin, t)
    }

    private static func noteName(forHz hz: Float) -> String {
        guard hz > 1 else { return "—" }
        let midi = 69 + 12 * log2(Double(hz) / 440)
        let n = Int(midi.rounded())
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let name = names[((n % 12) + 12) % 12]
        let octave = n / 12 - 1
        return "\(name)\(octave)"
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
    //
    // Coordinate meaning (Mid/Side, not raw L on X / R on Y):
    //   Vertical (↑↓)  = Mid  = (L+R)/2   →  shared / mono energy
    //   Horizontal (↔) = Side = (L−R)/2   →  stereo width / difference
    //   Distance from center ≈ loudness (auto-scaled to the window peak)
    //   L diagonal ≈ hard left mono; R diagonal ≈ hard right mono
    //   Vertical line ≈ centered mono; horizontal smear ≈ wide stereo

    private static func midSideCentroid(left: [Float], right: [Float]) -> (mid: Float, side: Float)? {
        let n = min(left.count, right.count)
        guard n > 0 else { return nil }
        var midAcc: Float = 0
        var sideAcc: Float = 0
        var wAcc: Float = 0
        for i in 0..<n {
            let l = left[i], r = right[i]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            let w = mid * mid + side * side
            midAcc += mid * w
            sideAcc += side * w
            wAcc += w
        }
        guard wAcc > 1e-12 else { return (0, 0) }
        return (midAcc / wAcc, sideAcc / wAcc)
    }

    private func drawVectorscope(size: CGSize) -> CGImage? {
        let n = min(waveLeft.count, waveRight.count)
        guard n > 8 else { return nil }
        return withContext(size: size) { ctx, w, h in
            // Layout (CG y grows up): bottom status, middle plot, top balance.
            let pad: CGFloat = 10
            let statusH: CGFloat = min(40, h * 0.14)
            let balH: CGFloat = min(22, h * 0.08)
            let plotTop = h - pad - balH - 6
            let plotBottom = pad + statusH + 6
            let plotH = max(40, plotTop - plotBottom)
            let sideLen = min(w - pad * 2, plotH)
            let cx = w * 0.5
            let cy = plotBottom + plotH * 0.5
            let radius = sideLen * 0.38

            // Balance bar at top of view.
            drawBalanceBar(ctx, balance: balanceSmoothed,
                           in: CGRect(x: w * 0.12, y: h - pad - balH, width: w * 0.76, height: balH))

            // Plot disc.
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                       width: radius * 2, height: radius * 2))
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            // Mid axis (vertical) + Side axis (horizontal).
            ctx.move(to: CGPoint(x: cx, y: cy - radius))
            ctx.addLine(to: CGPoint(x: cx, y: cy + radius))
            ctx.move(to: CGPoint(x: cx - radius, y: cy))
            ctx.addLine(to: CGPoint(x: cx + radius, y: cy))
            let d = radius * 0.7071
            ctx.move(to: CGPoint(x: cx - d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy + d))
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy - d))
            ctx.strokePath()
            ctx.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                         width: radius * 2, height: radius * 2))

            // Axis captions outside the circle (no overlap with cloud).
            drawLabel(ctx, "Mid ↑", at: CGPoint(x: cx + 6, y: cy + radius + 2),
                      color: .secondaryLabelColor)
            drawLabel(ctx, "Side →", at: CGPoint(x: cx + radius + 4, y: cy - 5),
                      color: .secondaryLabelColor)
            drawLabel(ctx, "L", at: CGPoint(x: cx - d - 12, y: cy + d + 2),
                      color: .systemOrange)
            drawLabel(ctx, "R", at: CGPoint(x: cx + d + 4, y: cy + d + 2),
                      color: .systemTeal)

            var peak: Float = 0.05
            let step = max(1, n / 400)
            for i in stride(from: 0, to: n, by: step) {
                peak = max(peak, max(abs(waveLeft[i]), abs(waveRight[i])))
            }
            let inv = 1 / peak
            let dot: CGFloat = max(1.0, sideLen / 450)
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor)
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

            if scopeTrail.count > 1 {
                let path = CGMutablePath()
                for (i, pt) in scopeTrail.enumerated() {
                    let m = max(-1 as Float, min(1 as Float, pt.mid * inv * 2))
                    let s = max(-1 as Float, min(1 as Float, pt.side * inv * 2))
                    let x = cx + CGFloat(s) * radius
                    let y = cy + CGFloat(m) * radius
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(max(2, sideLen / 180))
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
            if let last = scopeTrail.last {
                let m = max(-1 as Float, min(1 as Float, last.mid * inv * 2))
                let s = max(-1 as Float, min(1 as Float, last.side * inv * 2))
                let x = cx + CGFloat(s) * radius
                let y = cy + CGFloat(m) * radius
                let rr: CGFloat = max(4, sideLen / 60)
                ctx.setFillColor(NSColor.systemYellow.cgColor)
                ctx.fillEllipse(in: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
            }

            let bal = balanceSmoothed
            let panWord: String
            if bal < -0.45 { panWord = "LEFT" }
            else if bal < -0.12 { panWord = "left" }
            else if bal <= 0.12 { panWord = "CENTER" }
            else if bal <= 0.45 { panWord = "right" }
            else { panWord = "RIGHT" }

            // Status strip at bottom only (two short lines, fixed slots).
            drawCenteredLabel(ctx,
                              String(format: "Balance %+.2f · %@ · corr %+.2f", bal, panWord, corrSmoothed),
                              rect: CGRect(x: pad, y: pad + 16, width: w - pad * 2, height: 14),
                              style: (11, .labelColor, true))
            drawCenteredLabel(ctx,
                              "↑ Mid (mono) · → Side (width) · yellow = pan path · farther from center = louder",
                              rect: CGRect(x: pad, y: pad, width: w - pad * 2, height: 14),
                              style: (10, .secondaryLabelColor, false))
        }
    }

    /// Horizontal L ← → R meter. Balance −1…+1.
    private func drawBalanceBar(_ ctx: CGContext, balance: Float, in rect: CGRect) {
        ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        let midX = rect.midX
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: midX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: midX, y: rect.maxY))
        ctx.strokePath()
        drawLabel(ctx, "L", at: CGPoint(x: rect.minX + 4, y: rect.midY - 5), color: .systemOrange)
        drawLabel(ctx, "R", at: CGPoint(x: rect.maxX - 12, y: rect.midY - 5), color: .systemTeal)

        let t = CGFloat((balance + 1) * 0.5)
        let nx = rect.minX + rect.width * min(max(t, 0), 1)
        ctx.setFillColor(NSColor.systemYellow.cgColor)
        ctx.fill(CGRect(x: nx - 3, y: rect.minY - 1, width: 6, height: rect.height + 2))
    }

    // MARK: Correlation + balance (stereo image)

    private func drawCorrelation(size: CGSize) -> CGImage? {
        return withContext(size: size) { ctx, w, h in
            let r = corrSmoothed
            let bal = balanceSmoothed
            let pad: CGFloat = 12

            // Fixed vertical bands (top → bottom in view space). Avoids stacked
            // captions colliding when the pane is short.
            // CG y: band bottom = h - topOffset - bandHeight
            func bandRect(top: CGFloat, height: CGFloat) -> CGRect {
                CGRect(x: pad, y: h - top - height, width: w - pad * 2, height: height)
            }

            let titleH: CGFloat = 18
            let valueH: CGFloat = min(36, h * 0.12)
            let barH: CGFloat = min(26, h * 0.08)
            let captionH: CGFloat = 16
            let gap: CGFloat = 8

            var top: CGFloat = pad

            // Section 1 — Correlation
            drawCenteredLabel(ctx, "Correlation (waveform shape L vs R)",
                              rect: bandRect(top: top, height: titleH),
                              style: (12, .secondaryLabelColor, false))
            top += titleH + 2

            let corrValRect = bandRect(top: top, height: valueH)
            drawCenteredLabel(ctx, String(format: "%+.2f", r),
                              rect: corrValRect,
                              style: (min(32, valueH * 0.9), .labelColor, true))
            top += valueH + 2

            let corrHint: String
            if r > 0.7 { corrHint = "Same shape / in phase" }
            else if r > 0.25 { corrHint = "Mostly similar L & R" }
            else if r > -0.25 { corrHint = "Different content or hard-panned" }
            else if r > -0.7 { corrHint = "Out-of-phase risk" }
            else { corrHint = "Severe inversion" }
            drawCenteredLabel(ctx, corrHint,
                              rect: bandRect(top: top, height: captionH),
                              style: (11, .secondaryLabelColor, false))
            top += captionH + 4

            let corrBar = bandRect(top: top, height: barH)
            ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(corrBar)
            func xCorr(_ v: Float) -> CGFloat {
                corrBar.minX + corrBar.width * CGFloat((v + 1) * 0.5)
            }
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: corrBar.minX, y: corrBar.minY,
                            width: xCorr(-0.5) - corrBar.minX, height: corrBar.height))
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: xCorr(-0.5), y: corrBar.minY,
                            width: xCorr(0.25) - xCorr(-0.5), height: corrBar.height))
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: xCorr(0.25), y: corrBar.minY,
                            width: corrBar.maxX - xCorr(0.25), height: corrBar.height))
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: xCorr(0), y: corrBar.minY - 2))
            ctx.addLine(to: CGPoint(x: xCorr(0), y: corrBar.maxY + 2))
            ctx.strokePath()
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(CGRect(x: xCorr(r) - 2, y: corrBar.minY - 2, width: 4, height: corrBar.height + 4))
            top += barH + 2
            drawCenteredLabel(ctx, "−1  out of phase          0          +1  mono",
                              rect: bandRect(top: top, height: captionH),
                              style: (10, .tertiaryLabelColor, false))
            top += captionH + gap + 6

            // Section 2 — Balance
            drawCenteredLabel(ctx, "Balance (left ↔ right pan)",
                              rect: bandRect(top: top, height: titleH),
                              style: (12, .secondaryLabelColor, false))
            top += titleH + 2

            let panWord: String
            if bal < -0.45 { panWord = "Hard LEFT" }
            else if bal < -0.12 { panWord = "Left of center" }
            else if bal <= 0.12 { panWord = "Center" }
            else if bal <= 0.45 { panWord = "Right of center" }
            else { panWord = "Hard RIGHT" }

            drawCenteredLabel(ctx, String(format: "%+.2f  ·  %@", bal, panWord),
                              rect: bandRect(top: top, height: valueH),
                              style: (min(28, valueH * 0.85), .labelColor, true))
            top += valueH + 4

            let balBar = bandRect(top: top, height: barH)
            drawBalanceBar(ctx, balance: bal, in: balBar)
            top += barH + 2
            drawCenteredLabel(ctx, "L                    center                    R",
                              rect: bandRect(top: top, height: captionH),
                              style: (10, .tertiaryLabelColor, false))

            // Footer tip only if room remains.
            let footerTop = top + captionH + gap
            if footerTop + 28 < h - pad {
                drawCenteredLabel(ctx,
                                  "Pans move balance. Correlation is shape similarity, not pan position.",
                                  rect: bandRect(top: footerTop, height: 28),
                                  style: (10, .tertiaryLabelColor, false))
            }
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
