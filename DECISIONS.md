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

**Status**: Primary path locked for MVP. See `ARCHITECTURE.md` (Audio Path section) and `CHUNK1_IMPLEMENTATION_GUIDE.md`.

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

## How to Record New Decisions

1. Add a new entry here with a sequential ID (D-007, etc.).
2. Update `AGENTS.md` if the decision affects handoff instructions.
3. Update `ARCHITECTURE.md` or `DEVELOPMENT_PLAN.md` as appropriate.
4. Add relevant comments in code.

Major decisions should be discussed in an issue or with the project owner before being treated as locked.
