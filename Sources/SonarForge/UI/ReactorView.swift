import SwiftUI
import Metal
import QuartzCore
import AppKit
import os.log

/// "Reactor" — a Geiss/MilkDrop-inspired audio-reactive visual (D-016).
///
/// Rendered with `CAMetalLayer` + `CVDisplayLink` on a dedicated serial queue —
/// **not** `MTKView` (whose `draw(in:)` runs on the main thread and freezes for
/// the duration of button/slider tracking). Spectrum bins are polled from
/// `SpectrumFeed`, so SwiftUI body re-evals are not on the animation path.
///
/// Performance: feedback targets capped at a 720 px long edge; present fills
/// the full layer. Display link is paused when the app is inactive.
struct ReactorContainer: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Only the feed reference is needed — ObservationIgnored, so this leaf
        // does not re-render at 20 Hz with the spectrum arrays.
        ReactorView(feed: appModel.spectrumFeed)
            .background(Color.black)
    }
}

struct ReactorView: NSViewRepresentable {
    let feed: SpectrumFeed

    func makeNSView(context: Context) -> ReactorMetalView {
        let view = ReactorMetalView(frame: .zero)
        view.feed = feed
        view.start()
        return view
    }

    func updateNSView(_ nsView: ReactorMetalView, context: Context) {
        nsView.feed = feed
        // Re-arm if we were attached after start() ran window-less.
        nsView.ensureRunning()
    }

    static func dismantleNSView(_ nsView: ReactorMetalView, coordinator: ()) {
        nsView.stop()
    }
}

// MARK: - Metal view (off-main display link)

/// Layer-hosted Metal view. All GPU encoding runs on `renderQueue`; the
/// display-link callback never touches the main run loop, so UI tracking
/// cannot stall the animation.
final class ReactorMetalView: NSView {
    private struct Uniforms {
        var time: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treb: Float = 0
        var aspect: Float = 1
        var decay: Float = 0.95
    }

    private static let binCount = 64
    private static let maxFeedbackLongEdge = 720
    private static let textureQuantum = 8
    /// Target frame pacing (~30 fps). Display link fires at refresh rate; we
    /// skip frames to leave GPU/CPU headroom.
    private static let minFrameInterval: CFTimeInterval = 1.0 / 30.0

    private let logger = Logger(subsystem: "com.sonarforge.ui", category: "Reactor")
    private let renderQueue = DispatchQueue(label: "com.sonarforge.reactor.render", qos: .userInteractive)

    private var metalLayer: CAMetalLayer?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var feedbackPipeline: MTLRenderPipelineState?
    private var presentPipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var readingA = true
    private var feedbackWidth = 0
    private var feedbackHeight = 0

    // Mutable only on renderQueue.
    private var spectrum = [Float](repeating: 0, count: binCount)
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedTreb: Float = 0
    private var startTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0
    /// True while a render block is scheduled or running (coalesces display-link backlog).
    private var renderScheduled = false

    // Cross-thread: resized on main, consumed on renderQueue.
    private let stateLock = NSLock()
    private var pendingDrawableSize: CGSize = .zero
    /// Explicit stop() / dismantle.
    private var forcePaused = false
    /// Window not on-screen (hidden / miniaturized / fully occluded).
    private var visibilityPaused = false
    private var _feed: SpectrumFeed?

    var feed: SpectrumFeed? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _feed }
        set { stateLock.lock(); _feed = newValue; stateLock.unlock() }
    }

    private var displayLink: CVDisplayLink?
    private var activityObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("No Metal device available; Reactor disabled")
            return
        }
        self.device = device
        self.queue = device.makeCommandQueue()

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        self.layer = layer
        self.metalLayer = layer

        // Runtime-compiled shader (no offline Metal toolchain dependency).
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            logger.error("Reactor shader compile failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        feedbackPipeline = makePipeline(
            device: device, library: library,
            vertex: "reactor_vertex", fragment: "reactor_fragment",
            pixelFormat: .rgba16Float)
        presentPipeline = makePipeline(
            device: device, library: library,
            vertex: "reactor_vertex", fragment: "reactor_present",
            pixelFormat: .bgra8Unorm)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        installActivityObservers()
        logger.info("""
            Reactor configured (device=\(device.name, privacy: .public), \
            off-main CVDisplayLink, maxFeedback=\(Self.maxFeedbackLongEdge)px)
            """)
    }

    deinit {
        stopDisplayLink()
        for token in activityObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func layout() {
        super.layout()
        updateDrawableSizeFromBounds()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        updateDrawableSizeFromBounds()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateDrawableSizeFromBounds()
            // Critical: `start()` often runs from makeNSView *before* we have a
            // window, which would mark us visibility-paused forever. Always
            // re-evaluate when attached so switches like particles → Reactor work.
            stateLock.lock()
            let forced = forcePaused
            stateLock.unlock()
            refreshVisibilityPause()
            if !forced {
                startDisplayLink()
            }
        } else {
            stopDisplayLink()
        }
    }

    func start() {
        stateLock.lock()
        forcePaused = false
        stateLock.unlock()
        // Only arm the display link once hosted; otherwise visibility pause
        // latches true (no window) and the visual never draws.
        if window != nil {
            refreshVisibilityPause()
            startDisplayLink()
        }
    }

    func stop() {
        stateLock.lock()
        forcePaused = true
        stateLock.unlock()
        stopDisplayLink()
    }

    /// Idempotent: call from updateNSView after SwiftUI attaches the view.
    func ensureRunning() {
        stateLock.lock()
        let forced = forcePaused
        stateLock.unlock()
        guard !forced, window != nil else { return }
        refreshVisibilityPause()
        updateDrawableSizeFromBounds()
        startDisplayLink()
    }

    private var isPaused: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return forcePaused || visibilityPaused
    }

    private func updateDrawableSizeFromBounds() {
        guard let metalLayer else { return }
        let scale = metalLayer.contentsScale
        let size = CGSize(width: max(bounds.width * scale, 1),
                          height: max(bounds.height * scale, 1))
        metalLayer.drawableSize = size
        stateLock.lock()
        pendingDrawableSize = size
        stateLock.unlock()
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil, metalLayer != nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else {
            logger.error("CVDisplayLink create failed")
            return
        }
        // Callback runs on a high-priority Core Video thread — not the main
        // run loop, so AppKit tracking modes cannot stall it.
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let view = Unmanaged<ReactorMetalView>.fromOpaque(context).takeUnretainedValue()
            view.displayLinkFired()
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

    private func displayLinkFired() {
        guard !isPaused else { return }
        // Coalesce: at most one render block queued (avoids backlog if encode is slow).
        stateLock.lock()
        if renderScheduled {
            stateLock.unlock()
            return
        }
        renderScheduled = true
        stateLock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.renderScheduled = false
            let pausedNow = self.forcePaused || self.visibilityPaused
            self.stateLock.unlock()
            guard !pausedNow else { return }

            let now = CACurrentMediaTime()
            if now - self.lastFrameTime < Self.minFrameInterval { return }
            self.lastFrameTime = now
            self.renderFrame()
        }
    }

    private func installActivityObservers() {
        // Keep rendering while another app is frontmost if our window is still
        // on-screen. Only pause when the user can't see us (hidden / miniaturized
        // / fully occluded) — matching the bars/LED visibility policy.
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            self?.refreshVisibilityPause()
        }
        activityObservers = [
            center.addObserver(forName: NSApplication.didHideNotification,
                               object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSApplication.didUnhideNotification,
                               object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSWindow.didMiniaturizeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityPause()
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityPause()
            },
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.refreshVisibilityPause()
            },
        ]
        DispatchQueue.main.async { [weak self] in self?.refreshVisibilityPause() }
    }

    /// Pauses only when the window is not visible to the user. Does not require
    /// the app to be active (so inactive-but-visible windows keep animating).
    private func refreshVisibilityPause() {
        let onScreen: Bool = {
            if NSApp.isHidden { return false }
            guard let window, !window.isMiniaturized else { return false }
            return window.occlusionState.contains(.visible)
        }()
        stateLock.lock()
        visibilityPaused = !onScreen
        stateLock.unlock()
    }

    // MARK: - Render (renderQueue only)

    private func renderFrame() {
        guard let metalLayer, let queue, let feedbackPipeline, let presentPipeline,
              let sampler, let device else { return }

        stateLock.lock()
        let drawableSize = pendingDrawableSize
        let feed = _feed
        stateLock.unlock()
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        ensureFeedbackTextures(device: device, drawableSize: drawableSize)
        guard let texA, let texB else { return }

        // Pull latest bins from the feed (no SwiftUI involvement).
        var rawLevels: [Float] = []
        feed?.copyPost(into: &rawLevels)
        if rawLevels.count == Self.binCount {
            for i in 0..<Self.binCount {
                spectrum[i] = VizScale.normFloat(rawLevels[i])
            }
        }

        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let command = queue.makeCommandBuffer() else { return }

        let readTex = readingA ? texA : texB
        let writeTex = readingA ? texB : texA

        let targetBass = bandAverage(0..<21)
        let targetMid = bandAverage(21..<43)
        let targetTreb = bandAverage(43..<64)
        smoothedBass += (targetBass - smoothedBass) * (targetBass > smoothedBass ? 0.5 : 0.12)
        smoothedMid += (targetMid - smoothedMid) * (targetMid > smoothedMid ? 0.5 : 0.12)
        smoothedTreb += (targetTreb - smoothedTreb) * (targetTreb > smoothedTreb ? 0.5 : 0.12)

        var uniforms = Uniforms(
            time: Float(CACurrentMediaTime() - startTime),
            bass: smoothedBass, mid: smoothedMid, treb: smoothedTreb,
            aspect: Float(max(feedbackWidth, 1)) / Float(max(feedbackHeight, 1)),
            decay: 0.955)

        let feedbackPass = MTLRenderPassDescriptor()
        feedbackPass.colorAttachments[0].texture = writeTex
        feedbackPass.colorAttachments[0].loadAction = .dontCare
        feedbackPass.colorAttachments[0].storeAction = .store
        if let enc = command.makeRenderCommandEncoder(descriptor: feedbackPass) {
            enc.setRenderPipelineState(feedbackPipeline)
            enc.setFragmentTexture(readTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            spectrum.withUnsafeBytes { raw in
                enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = drawable.texture
        presentPass.colorAttachments[0].loadAction = .dontCare
        presentPass.colorAttachments[0].storeAction = .store
        if let enc = command.makeRenderCommandEncoder(descriptor: presentPass) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(writeTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        command.present(drawable)
        command.commit()
        readingA.toggle()
    }

    private func ensureFeedbackTextures(device: MTLDevice, drawableSize: CGSize) {
        let longEdge = max(drawableSize.width, drawableSize.height)
        let scale = min(1.0, CGFloat(Self.maxFeedbackLongEdge) / longEdge)
        let q = Self.textureQuantum
        let width = max(q, (Int(drawableSize.width * scale) / q) * q)
        let height = max(q, (Int(drawableSize.height * scale) / q) * q)
        if width == feedbackWidth, height == feedbackHeight, texA != nil, texB != nil {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        texA = device.makeTexture(descriptor: desc)
        texB = device.makeTexture(descriptor: desc)
        feedbackWidth = width
        feedbackHeight = height
        readingA = true
    }

    private func bandAverage(_ range: Range<Int>) -> Float {
        var sum: Float = 0
        for i in range { sum += spectrum[i] }
        return sum / Float(range.count)
    }

    private func makePipeline(device: MTLDevice, library: MTLLibrary,
                              vertex: String, fragment: String,
                              pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let vfn = library.makeFunction(name: vertex),
              let ffn = library.makeFunction(name: fragment) else {
            logger.error("Missing Metal functions \(vertex, privacy: .public)/\(fragment, privacy: .public)")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            logger.error("Pipeline build failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VSOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VSOut reactor_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VSOut o;
        o.pos = float4(p[vid], 0.0, 1.0);
        float2 uv = p[vid] * 0.5 + 0.5;
        o.uv = float2(uv.x, 1.0 - uv.y);
        return o;
    }

    struct Uniforms {
        float time;
        float bass;
        float mid;
        float treb;
        float aspect;
        float decay;
    };

    static float3 hsv2rgb(float3 c) {
        float3 rgb = clamp(abs(fmod(c.x * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
        return c.z * mix(float3(1.0), rgb, c.y);
    }

    fragment float4 reactor_fragment(VSOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     constant float *spectrum [[buffer(1)]],
                                     texture2d<float> prevTex [[texture(0)]],
                                     sampler samp [[sampler(0)]]) {
        float2 d = in.uv - 0.5;
        d.x *= u.aspect;

        float ang = 0.010 + u.treb * 0.035;
        float zoom = 1.0 + 0.018 + u.bass * 0.07;
        float s = sin(ang), c = cos(ang);
        float2 rd = float2(d.x * c - d.y * s, d.x * s + d.y * c) / zoom;
        rd.x /= u.aspect;
        float3 prev = prevTex.sample(samp, rd + 0.5).rgb * u.decay;

        float r = length(d);
        float a = atan2(d.y, d.x);
        float an = (a + M_PI_F) / (2.0 * M_PI_F);
        int idx = clamp(int(an * 63.0), 0, 63);
        float amp = spectrum[idx];
        float ringR = 0.12 + amp * 0.42 + u.bass * 0.08;
        float ring = smoothstep(0.035, 0.0, fabs(r - ringR));
        float hue = fract(an + u.time * 0.03 + u.mid * 0.25);
        float3 col = hsv2rgb(float3(hue, 0.85, 1.0)) * ring;

        col += hsv2rgb(float3(fract(u.time * 0.10), 0.5, 1.0)) * smoothstep(0.20, 0.0, r) * u.bass;

        return float4(max(prev, col), 1.0);
    }

    fragment float4 reactor_present(VSOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler samp [[sampler(0)]]) {
        return float4(tex.sample(samp, in.uv).rgb, 1.0);
    }
    """
}
