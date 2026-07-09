import SwiftUI
import MetalKit
import os.log

/// "Reactor" — a Geiss/MilkDrop-inspired audio-reactive visual (D-016). Unlike
/// the Canvas visualizers this runs on the GPU with its own `MTKView` draw loop
/// (a per-pixel feedback effect can't be done on CPU Canvas at 60 fps). It's
/// designed for front/full-screen viewing, so the display-link throttling that
/// affects backgrounded windows is acceptable here.
///
/// Data flow: the SwiftUI leaf reads the ~20 Hz spectrum bins and pushes them to
/// the renderer via `updateNSView`; the renderer smooths bass/mid/treble
/// internally and animates at its own frame rate, so the motion stays fluid
/// between data updates.
struct ReactorContainer: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Reading postEQLevels keeps this leaf (only) re-evaluating at ~20 Hz,
        // which forwards fresh bins to the Metal renderer.
        ReactorView(levels: appModel.postEQLevels)
            .background(Color.black)
    }
}

struct ReactorView: NSViewRepresentable {
    let levels: [Float]

    func makeCoordinator() -> ReactorRenderer {
        ReactorRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        if let device = MTLCreateSystemDefaultDevice() {
            view.device = device
        }
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        context.coordinator.configure(view)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(levels: levels)
    }
}

/// Owns the Metal pipeline, the ping-pong feedback textures, and the audio-
/// reactive state. All GPU work happens in `draw(in:)` on the main thread (the
/// default for `MTKView`), so reading the pushed levels needs no locking.
final class ReactorRenderer: NSObject, MTKViewDelegate {

    private struct Uniforms {
        var time: Float = 0
        var bass: Float = 0
        var mid: Float = 0
        var treb: Float = 0
        var aspect: Float = 1
        var decay: Float = 0.95
    }

    private static let binCount = 64

    private let logger = Logger(subsystem: "com.sonarforge.ui", category: "Reactor")

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var feedbackPipeline: MTLRenderPipelineState?
    private var presentPipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var readingA = true   // read A / write B, then swap

    // Audio-reactive state (main thread only).
    private var spectrum = [Float](repeating: 0, count: binCount)
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedTreb: Float = 0
    private var startTime = CACurrentMediaTime()

    /// Sets up the device, command queue, pipelines, and sampler. Any failure
    /// leaves the renderer inert (draws nothing) rather than crashing.
    func configure(_ view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
            logger.error("No Metal device available; Reactor disabled")
            return
        }
        self.device = device
        self.queue = device.makeCommandQueue()

        // Compiled at runtime (via the Metal framework) rather than from a
        // precompiled .metal file, so the build needs no offline Metal toolchain
        // — one less build/CI dependency for a single small shader.
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
            pixelFormat: view.colorPixelFormat)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        logger.info("""
            Reactor configured (device=\(device.name, privacy: .public), \
            feedback=\(self.feedbackPipeline != nil), present=\(self.presentPipeline != nil))
            """)
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

    /// Pushes the latest spectrum bins (dBFS) and refreshes band-energy targets.
    /// Log-spaced bins: ~0–20 bass, 21–42 mid, 43–63 treble.
    func update(levels: [Float]) {
        guard levels.count == Self.binCount else { return }
        for i in 0..<Self.binCount {
            spectrum[i] = Float(VizScale.norm(levels[i]))   // 0…1
        }
    }

    private func bandAverage(_ range: Range<Int>) -> Float {
        var sum: Float = 0
        for i in range { sum += spectrum[i] }
        return sum / Float(range.count)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let device, size.width > 0, size.height > 0 else {
            texA = nil; texB = nil; return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        texA = device.makeTexture(descriptor: desc)
        texB = device.makeTexture(descriptor: desc)
    }

    func draw(in view: MTKView) {
        guard let queue, let feedbackPipeline, let presentPipeline, let sampler,
              let texA, let texB,
              let drawable = view.currentDrawable,
              let presentPass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }

        let readTex = readingA ? texA : texB
        let writeTex = readingA ? texB : texA

        // Smooth band energies toward the latest spectrum (fast attack, slow
        // decay) so the motion is lively but not jittery.
        let targetBass = bandAverage(0..<21)
        let targetMid = bandAverage(21..<43)
        let targetTreb = bandAverage(43..<64)
        smoothedBass += (targetBass - smoothedBass) * (targetBass > smoothedBass ? 0.5 : 0.12)
        smoothedMid += (targetMid - smoothedMid) * (targetMid > smoothedMid ? 0.5 : 0.12)
        smoothedTreb += (targetTreb - smoothedTreb) * (targetTreb > smoothedTreb ? 0.5 : 0.12)

        var uniforms = Uniforms(
            time: Float(CACurrentMediaTime() - startTime),
            bass: smoothedBass, mid: smoothedMid, treb: smoothedTreb,
            aspect: Float(max(view.drawableSize.width, 1) / max(view.drawableSize.height, 1)),
            decay: 0.955)

        // Pass 1 — feedback + source into the write texture.
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

        // Pass 2 — present the write texture to the drawable.
        if let enc = command.makeRenderCommandEncoder(descriptor: presentPass) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(writeTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        command.present(drawable)
        command.commit()
        readingA.toggle()   // the frame we just wrote becomes next frame's input
    }

    /// Geiss-style feedback shader (Metal Shading Language). Each frame warps the
    /// previous frame (the flowing motion) and adds a spectrum-driven radial ring
    /// on top; all motion is driven by smoothed bass/mid/treble.
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
