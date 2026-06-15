# AGENTS.md — SonarForge

This file exists so that any AI coding agent (Grok, Claude, Cursor, etc.) can pick up the project with minimal reliance on chat history.

**Goal**: Make the entire project state, architecture, plan, constraints, and current status fully legible from the files in this repository.

---

## Project Summary

SonarForge is a free, open-source, native macOS system-wide parametric equalizer for Apple Silicon, targeting macOS 14.2 and later.

It is deliberately narrow in scope: high-quality parametric EQ + real-time spectrum analysis + excellent AutoEQ headphone profile support, with a clean SwiftUI experience and menu bar integration. No AU hosting, no spatial audio, no convolution, no per-app routing, no monetization.

**Non-negotiables**:
- Real-time audio must be stable, low-CPU, and artifact-free.
- The audio engine must remain cleanly separated from the UI.
- All processing is strictly local.

---

## Read These Files First (in order)

When starting work, a new agent **must** read the following in this sequence:

1. `AGENTS.md` (this file) — Handoff instructions and current context.
2. `README.md` — High-level vision, scope, and philosophy.
3. `VISION.md` — The original detailed project requirements (preserved).
4. `ARCHITECTURE.md` — The authoritative technical design. Especially:
   - Guiding Principles
   - Audio path (capture via CATap, processing, output, bypass)
   - Threading and concurrency model
   - DSP approach (biquad + vDSP)
5. `DECISIONS.md` — Architectural Decision Records D-001…D-010 (why major choices were made, including platform, capture mechanism, render topology, and the lock-free parameter path).
6. `Documentation/AUDIO_PATH.md` — **The authoritative reference for the live audio path** as actually built: tap → private aggregate → HAL IOProc, gain staging, EQ integration, spectrum analysis, threading model, measured characteristics, and dev gotchas. Read this before touching audio code.
7. `STATE.md` — Current project state (phase status table, what exists, immediate next steps).
8. `Documentation/Xcode-Setup.md` — Exact Xcode project settings (deployment target 14.2, arm64 only; project is generated from `project.yml` via XcodeGen).
9. `Documentation/GETTING_STARTED.md` — How to build and run locally.
10. `CONTRIBUTING.md` — Process expectations and pre-PR quality gates (tests + lint).

Supporting docs as needed: `DEVELOPMENT_PLAN.md` (the original phased roadmap — now a historical record; the MVP is delivered, so treat it as context, not marching orders), `Documentation/SIGNING.md` (release credentials), `PRIVACY.md` / `NOTICE` / `SECURITY.md`.

After the reading list above, skim the source under `Sources/SonarForge/` (the `Audio/` and `DSP/` layers especially) to understand the implementation. `STATE.md` § "Where Things Live" maps the modules.

---

## Key Locked Decisions (Do Not Revisit Without Explicit Discussion)

- **Minimum macOS**: 14.2 (chosen because this is where Core Audio Taps / `CATapDescription` + `AudioHardwareCreateProcessTap` are documented as stable by Apple).
- **Architecture support**: Apple Silicon (arm64) **only**. No Intel / x86_64. This is a hard requirement.
- **Capture mechanism**: Core Audio Process Taps (driverless) is the primary and preferred approach. User-space audio driver (like eqMac's) is explicitly deferred. (Validated: the CATap path captures cleanly, including Netflix browser DRM — see AUDIO_PATH.md.)
- **Scope discipline**: Stick to the MVP feature list in README.md. New features outside the documented non-goals should be rejected or moved to a future discussion.
- **Audio thread sanctity**: No allocations, locks, or heavy work on the real-time render thread. Parameter updates must use lock-free / double-buffered / atomic mechanisms.

These decisions were confirmed by the project owner in conversation and are now reflected across the documentation.

---

## Current Project State

See the dedicated `STATE.md` file for the most up-to-date status. 

`STATE.md` is the single source of truth for status; the summary here is just a pointer.

As of 2026-06-14: **v0.1.0 is shipped** — signed, notarized, and published to GitHub Releases, with a live, dry-run-verified CI signed-release pipeline. Phases 0–6 are essentially complete (capture, EQ, spectrum, profiles + AutoEQ import, full UI, accessibility, signed/notarized release). The repo is still **private** with green CI; remaining before going public: rotate the notarization app-specific password (exposed during CI-secrets setup) and the private→public flip. Ongoing: broader beta + hardware QA (Bluetooth/USB DAC, Apple Music/FairPlay). See `STATE.md` for the live picture and `DECISIONS.md` for the locked choices.

---

## Important Technical Context

- Primary audio capture: `CATapDescription` + `AudioHardwareCreateProcessTap` (global tap, exclude own PID, `muteBehavior = .muted`).
- Processing will use `AVAudioEngine` (with possible lower-level render callbacks for optimization later).
- DSP uses Direct Form II Transposed biquads (RBJ cookbook coefficients).
- Spectrum analysis will use Accelerate `vDSP`.
- Profiles are plain Codable JSON for easy import/export and AutoEQ compatibility.
- Attribution for AutoEQ / oratory1990 profiles must be prominent and non-removable.

See `ARCHITECTURE.md` for the full data flow diagram and threading rules.

---

## How to Continue Work

1. Check `STATE.md` for current status and the prioritized next steps.
2. When implementing audio-related changes, update `Documentation/AUDIO_PATH.md` with:
   - Threading model
   - Measured CPU impact (Instruments / the `--debug-log-spectrum-file` probe)
   - Bypass behavior
   - Device / sample rate change handling
3. Run the pre-PR quality gates in `CONTRIBUTING.md` (tests + SwiftLint) before declaring anything done; CI enforces them on every push.
4. Record any new architectural decision in `DECISIONS.md` (next ID is D-011).

---

## Common Pitfalls for Agents

- Assuming a virtual audio driver is still the way to go (it is not — CATap is the chosen path).
- Starting the pretty frequency response curve editor before a stable passthrough + bypass exists.
- Ignoring the "Apple Silicon only + macOS 14.2" constraints when suggesting build settings or CI changes.
- Adding features outside the documented MVP scope.
- Doing work on the audio thread that violates real-time constraints.

---

## Files That Should Stay in Sync

When making changes, keep these consistent:
- `README.md` (public-facing target platform and scope)
- `VISION.md` (original requirements)
- `ARCHITECTURE.md` (technical truth)
- `DECISIONS.md` (why decisions were made)
- `DEVELOPMENT_PLAN.md` (sequencing and chunk definitions)
- `STATE.md` (living current status)
- `AGENTS.md` (this file — update the reading list and status pointers when the handoff story changes)

---

This file + the documents it points to are intended to allow a new agent (in a fresh context or different tool) to continue development effectively without needing the full previous chat transcript.

If something important is missing from these files that a new agent would need, add it here or to the referenced documents.
