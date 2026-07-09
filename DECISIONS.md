# Architectural & Project Decision Records

This document records major decisions, their rationale, and current status. It helps future contributors and AI agents understand *why* certain paths were chosen.

---

## D-001: Platform Target — macOS 14.2+ on Apple Silicon Only

**Date**: 2026 (clarified during initial planning)

**Decision**:
- Minimum deployment target: **macOS 14.2**
- Architectures: **arm64 (Apple Silicon M1 and newer) only**
- No Intel / x86_64 support

**Rationale**:
- Core Audio Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`) reached reliable stability and have official Apple sample code starting at macOS 14.2.
- Limiting to Apple Silicon reduces testing burden, avoids cross-architecture audio issues, and aligns with the primary target audience for high-quality critical listening.
- Keeps scope narrow (a core project principle).

**Status**: Locked. Do not change without explicit owner approval.
**Impact**: All Xcode project settings, CI, documentation, and code comments must enforce this. See `Documentation/Xcode-Setup.md`.

---

## D-002: Primary Audio Capture Mechanism — Core Audio Taps (Driverless)

**Date**: Initial architecture phase

**Decision**:
- Use Apple's Core Audio Process Taps as the **primary and preferred** method for system-wide audio capture.
- A traditional user-space audio server plug-in / virtual "Null Audio" driver (as used by eqMac and BlackHole) is explicitly a secondary/deferred option.

**Rationale**:
- Better matches the target platform (macOS 14.2+).
- Avoids significant drawbacks of virtual drivers: extra audio hop, volume control issues, exclusivity problems, signing/notarization friction, and user permission fatigue for system extensions.
- Apple is actively promoting the tap APIs as the modern path for system audio access.
- Contemporary open-source precedent (e.g. projects using CATap for EQ + spectrum) shows this path is viable for parametric EQ use cases.
- Reduces maintenance burden for an open-source project.

**Trade-offs acknowledged**:
- CATap has known limitations (some DRM-protected content, certain exclusive-mode apps, and AirPlay behavior may not be fully captured).
- If Chunk 1.1 validation reveals fundamental gaps for the target use cases, a hybrid or driver fallback can be re-evaluated (high cost, low priority).

**Status**: Primary path locked for MVP. See `ARCHITECTURE.md` (Audio Path section) and `Documentation/AUDIO_PATH.md` (as-built reference + validation record).

**Attribution note**: Any third-party technique or open-source code that is used must be attributed clearly in code and in `NOTICE`.

---

## D-003: Scope Discipline — Essentials Only

**Date**: Project inception

**Decision**:
- Strictly limit the initial version to the "Core Feature Scope (MVP)" listed in `VISION.md`.
- Explicit non-goals (AU hosting, spatial audio, per-app routing, convolution/FIR, monetization, heavy visual chrome) are to be respected.

**Rationale**:
- The project positions itself as a focused, high-quality, maintainable open-source alternative rather than a feature-bloated one.
- Audio quality and stability are non-negotiable; feature creep is the fastest way to compromise them.
- Narrow scope makes it realistic for open-source contributors to keep the project healthy.

**Status**: Enforced. New feature requests outside this scope should be documented but not implemented in early phases unless the owner explicitly expands the vision.

---

## D-004: Modularity — Clean Separation of Audio Engine from UI

**Date**: Architecture definition

**Decision**:
- The real-time DSP/audio engine (`Sources/SonarForge/Audio` + `DSP`) must have **no direct dependencies** on SwiftUI or AppKit.
- UI layer talks to the engine through a narrow, injectable protocol or actor boundary (`AudioEngineProtocol` and higher-level models).

**Rationale**:
- Enables unit testing of DSP in isolation.
- Protects the real-time thread from UI-driven complexity.
- Makes future refactoring (e.g. moving the engine to a framework) easier.
- Aligns with professional audio software architecture.

**Status**: Structural requirement. Violating this in new code is considered a defect.

---

## D-005: DSP Implementation Approach

**Date**: Initial design

**Decision**:
- Parametric EQ uses cascaded second-order biquad IIR filters (Direct Form II Transposed preferred for numerical stability).
- Coefficient formulas based on the classic RBJ / Audio EQ Cookbook.
- Preamp before the band filters; master output gain after.
- Spectrum analysis performed with Accelerate `vDSP` (FFT + windowing + log-frequency mapping).
- Parameter updates to the audio thread must be lock-free or double-buffered; smoothing is required to avoid zipper noise.

**Rationale**:
- Proven, low-CPU approach suitable for real-time on Apple Silicon.
- Good numerical properties when implemented carefully (denormal protection, coefficient validation).
- `vDSP` is the idiomatic high-performance path on macOS for FFT-based analysis.

**Status**: Baseline for MVP. Linear-phase / FIR modes are explicitly out of scope unless they become trivial later.

---

## D-006: Profile System & AutoEQ Handling

**Date**: Planning

**Decision**:
- Profiles are simple Codable value types persisted as JSON files (easy to inspect, version, share).
- Strong, visible attribution is mandatory for any AutoEQ-derived profiles.
- Importer must handle common AutoEQ text formats (parametric "Filter X: ON ..." blocks and GraphicEQ lines).

**Rationale**:
- Transparency and shareability are important for a free tool serving the critical listening / headphone community.
- Legal/ethical attribution to measurement authors (oratory1990 et al.) and the AutoEQ project must be respected.

**Status**: Required for Phase 4 work.

---

## D-007: Capture/Render Topology — Private Aggregate Device + HAL IOProc (not AVAudioEngine)

**Date**: 2026-06-09 (Chunk 1.1 implementation)

**Decision**:
- The audio path is: process tap → private aggregate device (output device as clock master + drift-compensated tap) → a single `AudioDeviceCreateIOProcIDWithBlock` that copies/processes tap input buffers into the output device buffers.
- `AVAudioEngine` is **not** used for the core path.

**Rationale**:
- This is the topology Apple's own Core Audio taps sample uses; the HAL handles capture/render synchronization and tap drift compensation natively.
- `AVAudioEngine` on macOS cannot cleanly take a tap-fed aggregate as input while rendering to a *different* output device in one engine; working around that reintroduces format negotiation, an extra buffer hop, and latency.
- A raw IOProc gives the lowest-overhead render path (the ARCHITECTURE.md "Output" section already anticipated falling back to manual render callbacks for exactly this reason).
- The DSP (Chunk 2) operates on raw Float32 buffers either way.

**Trade-offs acknowledged**:
- We own buffer/channel-count handling ourselves (implemented with explicit channel mapping).
- `AVAudioConverter`-style conveniences are unavailable; the aggregate's drift compensation covers the rate-matching need instead.

**Status**: Locked for MVP. See `Documentation/AUDIO_PATH.md` for the full technique and threading model.

---

## D-008: swift-atomics Dependency for Render-Thread Flags

**Date**: 2026-06-09

**Decision**: Add `apple/swift-atomics` (SPM) for lock-free flags/parameters shared with the realtime thread (first use: the bypass flag).

**Rationale**: The project's realtime rules forbid locks on the render thread. Swift's `Synchronization.Atomic` requires macOS 15; we deploy to 14.2. swift-atomics is Apple-maintained, tiny, and the standard pre-15 answer. Raw `UnsafeMutablePointer` reads would be formally undefined behavior under the Swift memory model.

**Status**: Active. The dependency is pinned via the committed `Package.resolved`.

---

## D-009: Headroom Strategy — No Always-On Limiter (MVP)

**Date**: 2026-06-10 (Chunk 1.2)

**Decision**: No soft limiter / tanh saturation in the render path for the MVP. Clipping prevention is handled by gain staging discipline:
- UI gain controls are clamped to ±12 dB (engine accepts ±24 dB).
- The AutoEQ convention applies: profiles with boosting bands ship a negative preamp; the importer (Chunk 4.2) must preserve it.
- Output beyond ±1.0 full scale is clipped by the OS/DAC as usual.

**Rationale**: An always-on nonlinearity colors audio, which contradicts the project's critical-listening positioning. A correct lookahead limiter adds latency and complexity that is not justified before the EQ even exists. Documenting "your preamp is your headroom" matches how the AutoEQ ecosystem already works.

**Revisit**: Phase 6 (optional, default-off safety limiter + clipping indicator were already anticipated in DEVELOPMENT_PLAN 6.2).

**Status**: Locked for MVP.

---

## D-010: Render-Thread Parameter Path — SPSC Command Ring

**Date**: 2026-06-10 (Chunk 2.1)

**Decision**: All EQ parameter updates travel from the control thread to the render thread through a lock-free single-producer/single-consumer ring buffer of small fixed-size commands (set-coefficients / set-band-count / reset-state). Coefficients are computed off the audio thread; the render thread drains pending commands at the top of each IO cycle.

**Rationale**:
- Satisfies the audio-thread sanctity rule (no locks, no allocation, no ObjC) with clean acquire/release semantics — no torn doubles, no formally-UB seqlock reads, no ARC traffic from atomic object-reference swaps.
- The producer is never realtime, so it may sleep briefly if the ring is momentarily full (only plausible when audio is stalled anyway).
- Generalizes: future per-band UI edits, profile swaps, and A/B all reduce to pushing commands.

**Alternatives considered**: double-buffered snapshot with atomic index (unsafe reuse without consumer acknowledgment), seqlock (reader-side data race is formally undefined behavior in the Swift/C++ memory model), atomic object references (refcount traffic on the render thread).

**Status**: Locked. Implemented in `DSP/RealtimeParametricEQ.swift`.

---

## D-011: Audio-input entitlement is declared in `project.yml`, not hand-maintained

**Date**: 2026-06-15

**Decision**: `com.apple.security.device.audio-input` lives in the `entitlements.properties` block of `project.yml`, so `xcodegen generate` regenerates `Sources/SonarForge/Resources/Entitlements.entitlements` *with* the key.

**Rationale**: A `path`-only entitlements block makes XcodeGen overwrite that file with an empty `<dict/>` on every regenerate, silently dropping the entitlement. Under the hardened runtime that makes the Core Audio tap deliver zeros in Release builds (Debug masks it). This regression shipped once and recurred after a later `xcodegen generate`. Declaring the key in `project.yml` makes regeneration idempotent; `Scripts/release.sh` also fails the build if the signed bundle lacks the entitlement (defense in depth).

**Status**: Locked. See `project.yml` (`entitlements.properties`) and the guard in `Scripts/release.sh`.

---

## D-012: Crossfeed — Complementary-Filter Design, Per-Profile, After the EQ

**Date**: 2026-07-08

**Decision**: Ship headphone crossfeed as its own realtime DSP node (`DSP/Crossfeed.swift`) that runs in the same IO block immediately **after** the EQ and before the gain stage. It uses a complementary first-order split — `outL = HP(L) + (1−b)·LP(L) + b·LP(R)` (and mirror) with a fixed 700 Hz low-pass — rather than reproducing bs2b's specific shelf constants. The strength `b` (0…0.5, surfaced as a 0–100% "amount") and enable flag are stored **per profile** (`EQProfile.crossfeedEnabled` / `crossfeedAmount`), default **off** with a "natural" amount of 0.6 retained for when it's toggled on.

**Rationale**:
- **Complementary split is provably tone-neutral for mono**: for `L == R`, the sum collapses to `HP(m) + LP(m) = m` for any `b`, so a centered mix is passed through untouched and crossfeed never colors tonal balance. Reproducing bs2b's magic numbers from memory risked a subtly wrong shelf; this design is fully reasoned and unit-tested (mono neutrality, low bleed, high-frequency separation, finiteness).
- **After the EQ**: crossfeed spatializes the already-corrected signal, and placing it before the gain stage means the post-EQ spectrum tap captures it. It respects bypass (skipped when bypassed) and resets its state on re-engage alongside the EQ.
- **Per profile**: the ideal crossfeed depends on the headphone/recording, so it belongs with the rest of a profile's tuning. New/old profiles default to disabled (backward-compatible `decodeIfPresent`), so nothing changes for existing users until they opt in.
- **Click-free**: the effective bleed is ramped per-sample toward its target (≈10 ms), so toggling and slider drags need no separate gain crossfade; a settled-off state is an exact pass-through (bypass honesty), mirroring the EQ/gain zero-cost path.

**Status**: Shipped. See `DSP/Crossfeed.swift`, the IO block in `Audio/AudioEngine.swift`, and `Sources/SonarForgeTests/CrossfeedTests.swift`.

---

## D-013: Spectrum FFT Window Sized Per Sample Rate (Low-Frequency Fix)

**Date**: 2026-07-08

**Decision**: The spectrum analyzer picks its FFT size from the sample rate — the nearest power of two to `sampleRate / 2.93` (≈ a 0.34 s window), clamped to 4096…65536 — instead of a fixed 4096. Rings and scratch are preallocated for the 65536 maximum so nothing reallocates while audio runs; the DFT setup, window length, and reduction all key off the per-start size.

**Rationale**: With a fixed 4096-point FFT the low end lacked the frequency resolution to fill the 64 log-spaced display bins over 20 Hz–20 kHz. FFT resolution is `sampleRate / fftSize`, so at 48 kHz (~11.7 Hz/bin) roughly the first 14 display bins (20–80 Hz) were fed by only ~6 FFT bins, and at **96 kHz (~23.4 Hz/bin) everything below ~80 Hz collapsed onto ~3 FFT bins** — a flat, content-independent line, exactly the "solid line below 80 Hz no matter the music" a user reported on a 96 kHz machine. Sizing the window to a constant duration keeps ~2.9 Hz/bin at every rate (16384 @ 48 kHz, 32768 @ 96 kHz), so the low bins map to distinct FFT bins. Rounding to the *nearest* power of two (not up) keeps 48 kHz at 16384 rather than overshooting to 32768 and doubling window latency. Cost is trivial: analysis runs off the realtime thread at 20 Hz. Tradeoff: a longer window (~0.34 s) means the low end integrates a bit more slowly — desirable for bass, and the update rate is unchanged.

**Status**: Shipped. See `Audio/SpectrumAnalyzer.swift` (`fftSize(forSampleRate:)`) and `AdaptiveFFTSizeTests` in `Sources/SonarForgeTests/SpectrumTests.swift`.

---

## D-014: Selectable Visualizations Driven by the Existing Spectrum Bins

**Date**: 2026-07-08

**Decision**: The main display pane offers a `VisualizationStyle` picker — `curve` (the existing frequency-response editor, default), `bars`, `ledBars`, `spectrogram` — persisted app-wide via `@AppStorage` (a display preference, not per profile). All modes render from the analyzer's existing ~20 Hz post-EQ display bins; no new audio-capture path was added. Renderers are `Canvas`-based leaf views that read `AppModel.postEQLevels` directly, keeping the 20 Hz updates observation-isolated to the renderer (the enclosing `FrequencyPane` reads only `isProcessing`). `FrequencyPane` owns the `spectrumViewVisible` enable/disable so analysis stays on across mode switches.

**Rationale**: Bars (peak-hold), LED meters (green/amber/red segments + peak cap), and a scrolling spectrogram are all functions of the magnitude spectrum we already compute, so they cost nothing extra on the realtime path and reuse the D-013 low-frequency fix. Oscilloscope was deferred at first (needs time-domain PCM) and later shipped via a short post-EQ mono PCM ring next to the FFT path. Stereo VU / vectorscope remain deferred. Keeping the selection in `@AppStorage` (not the profile) matches how it's used: a viewing preference independent of the loaded EQ.

**Status**: Shipped (in-window mode switcher + pop-out `Visualizer` window with fullscreen, shared style preference). Oscilloscope uses post-EQ PCM (`WaveformFeed`). Stereo VU remains a follow-up. See `UI/Visualizations.swift`, `UI/VisualizerPopoutView.swift`, and `FrequencyPane` in `UI/ContentView.swift`.

---

## D-016: "Reactor" — a Metal GPU Visualizer with a Runtime-Compiled Shader

**Date**: 2026-07-08

**Decision**: The `reactor` visualization is a Geiss/MilkDrop-inspired GPU effect rendered by an `MTKView` (bridged via `NSViewRepresentable`), not the CPU `Canvas` used by the other modes. It's a per-pixel *feedback* shader — each frame warps/zooms/rotates the previous frame's texture (ping-pong `rgba16Float` targets) and adds a spectrum-driven radial ring, all driven by smoothed bass/mid/treble derived from the existing spectrum bins. The shader (MSL) is **compiled at runtime** via `device.makeLibrary(source:)` from an embedded string, rather than shipping a `.metal` file.

**Rationale**: A per-pixel feedback loop at 60 fps is a GPU job — CPU `Canvas` can't do it. The renderer owns its own `MTKView` draw loop, fully decoupled from the SwiftUI/`@Observable` path (so it can't destabilize the other modes), and smooths band energies internally so motion stays fluid between the ~20 Hz data updates. Runtime shader compilation was chosen because this Xcode (26.x) makes the offline Metal toolchain a separately-downloadable component the machine/CI may not have; runtime compilation uses the Metal framework's own compiler, so the build needs no toolchain and there's no `.metal` asset to manage — at the cost of a one-time compile when the view first appears (guarded: any failure logs and leaves the renderer inert, never crashes). Being GPU/display-link driven it throttles when the app isn't frontmost, which is acceptable for a full-screen "watch it" visual (unlike the glanceable spectrum). Only bass/mid/treble + spectrum bins feed it today; a raw PCM waveform tap and real MilkDrop preset support (projectM) are possible later.

**Status**: Shipped. See `UI/ReactorView.swift` (renderer + embedded shader) and the `.reactor` case in `UI/Visualizations.swift` / `FrequencyPane`. Perf follow-up (same decision): `CAMetalLayer` + off-main `CVDisplayLink` (not main-thread `MTKView`), spectrum via thread-safe `SpectrumFeed`, feedback capped at 720 px long edge, ~30 fps — so UI tracking no longer freezes the visual (see `Documentation/AUDIO_PATH.md` visualizer-perf note).

---

## How to Record New Decisions

1. Add a new entry here with a sequential ID (D-007, etc.).
2. Update `AGENTS.md` if the decision affects handoff instructions.
3. Update `ARCHITECTURE.md` or `DEVELOPMENT_PLAN.md` as appropriate.
4. Add relevant comments in code.

Major decisions should be discussed in an issue or with the project owner before being treated as locked.
