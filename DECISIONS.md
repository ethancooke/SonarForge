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

**Attribution note**: Techniques and lessons from eqMac’s open-source driver work should still be studied and attributed where relevant, even if not directly copied.

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

## How to Record New Decisions

1. Add a new entry here with a sequential ID (D-007, etc.).
2. Update `AGENTS.md` if the decision affects handoff instructions.
3. Update `ARCHITECTURE.md` or `DEVELOPMENT_PLAN.md` as appropriate.
4. Add relevant comments in code.

Major decisions should be discussed in an issue or with the project owner before being treated as locked.
