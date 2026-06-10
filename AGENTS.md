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
5. `DECISIONS.md` — Architectural Decision Records (why major choices were made, including platform and capture mechanism).
6. `DEVELOPMENT_PLAN.md` — The complete phased plan with chunks.
   - Prioritization rule: The critical audio path must be solid before heavy UI work.
7. `CHUNK1_IMPLEMENTATION_GUIDE.md` — Detailed step-by-step instructions + validation checklist for the most important chunk (Chunk 1.1).
8. `STATE.md` — Current project state (what exists, what is next, immediate actions).
9. `Documentation/Xcode-Setup.md` — Exact Xcode project settings (deployment target 14.2, arm64 only).
10. `Documentation/GETTING_STARTED.md` — How to build and run locally.
11. `CONTRIBUTING.md` — Process expectations.

After the reading list above, skim the source skeletons under `Sources/SonarForge/` (especially `Audio/AudioEngine.swift` — which documents platform requirements — and the DSP files) to understand current implementation state.

Also read the latest `STATE.md` to know exactly where the project stands right now.

---

## Key Locked Decisions (Do Not Revisit Without Explicit Discussion)

- **Minimum macOS**: 14.2 (chosen because this is where Core Audio Taps / `CATapDescription` + `AudioHardwareCreateProcessTap` are documented as stable by Apple).
- **Architecture support**: Apple Silicon (arm64) **only**. No Intel / x86_64. This is a hard requirement.
- **Capture mechanism**: Core Audio Process Taps (driverless) is the primary and preferred approach. User-space audio driver (like eqMac's) is explicitly deferred and should only be considered if CATap proves fundamentally insufficient during Chunk 1.1 validation.
- **Scope discipline**: Stick to the MVP feature list in README.md. New features outside the documented non-goals should be rejected or moved to a future discussion.
- **Audio thread sanctity**: No allocations, locks, or heavy work on the real-time render thread. Parameter updates must use lock-free / double-buffered / atomic mechanisms.

These decisions were confirmed by the project owner in conversation and are now reflected across the documentation.

---

## Current Project State

See the dedicated `STATE.md` file for the most up-to-date status. 

As of the latest update (2026-06-09):
- **Chunk 0.1 is complete.** `SonarForge.xcodeproj` is generated via **XcodeGen** from `project.yml` (the source of truth for build settings — run `xcodegen generate` after editing it). 14.2 + arm64-only settings are applied and verified (arm64-only binary, minos 14.2).
- Build + unit tests pass; the app shell launches and quits cleanly.
- Next: Execute Chunk 1.1 (the critical audio path validation) per `CHUNK1_IMPLEMENTATION_GUIDE.md`.

**Do not start UI-heavy work (graphical EQ editor, spectrum visualization polish, etc.) until Chunk 1.1 acceptance criteria are met.**

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

1. Check `DEVELOPMENT_PLAN.md` for the current phase and which chunk is next.
2. For any chunk, read its description + any linked implementation guide.
3. When implementing audio-related changes, update or add notes about:
   - Threading model
   - Measured CPU impact (Instruments)
   - Bypass behavior
   - Device / sample rate change handling
4. Before declaring a high-risk chunk (especially anything touching the audio render path) complete, run through the explicit acceptance criteria and validation checklist.

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
