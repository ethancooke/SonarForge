# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-07-11 — **[v0.2.1](https://github.com/ethancooke/SonarForge/releases/tag/v0.2.1)** re-cut (build 7). Includes permission start-gate fix, Frequency Response spectrum slider lag fix, refreshed README hero, plus original 0.2.1 stability work (preamp persistence, clip meter, Help menu, viz polish, MainActor isolation). Repo still **private**; remaining: private→public flip, residual 6.5 (AirPlay / FairPlay / non‑M4), optional deferred extras (limiter, hotkeys, Sparkle, …).

---

## High-Level Status

The MVP feature set is **functionally complete**. Visualizers and crossfeed shipped in v0.2.0. Owner hardware QA covers dual M4 Pro MBPs, USB DACs, and Bluetooth (see § Hardware QA below); residual gaps are AirPlay, FairPlay/Apple Music edge cases, and non‑M4 machines.

| Phase | Status |
|---|---|
| 0 — Scaffolding | ✅ Complete (XcodeGen project, 14.2/arm64-only, CI + SwiftLint, templates) |
| 1 — Audio path (tap capture, passthrough, bypass, gain staging) | ✅ Complete + validated (see `Documentation/AUDIO_PATH.md`) |
| 2 — Parametric EQ DSP (biquad bank, lock-free parameter path, live integration) | ✅ Complete + validated |
| 3 — Spectrum analyzer (3.1) | ✅ Complete (pre/post taps → 20 Hz FFT → live traces; adaptive FFT size D-013) |
| 4 — Profiles + AutoEQ (4.1 persistence/CRUD, 4.2 importer + attribution, 4.3 quick switch, A/B compare) | ✅ Complete + validated |
| 5 — UI (shell, graphical editor, band list, spectrum overlay, visualizers, pop-out) | ✅ Complete for MVP + v0.2.0 visualizer suite |
| 6 — Hardening & release | ✅ 6.1–6.4 complete — CI signed-release pipeline. 🔶 6.5 mostly done for owner machines (USB + BT + M4 Pro); residual: AirPlay, FairPlay, community hardware |

**Headline facts**
- Audio: tap → private aggregate → HAL IOProc; optional per-profile **crossfeed** after EQ (D-012); gain staging + bypass.
- DSP: 16-band DF2T cascade; spectrum FFT window sized per sample rate (~2.9 Hz/bin); post-EQ mono + stereo PCM windows for scope/meters; 102 unit tests.
- Profiles: JSON persistence, AutoEQ import + attribution, favorites, A/B by profile id, factory presets including Sonar Wave.
- Editor: response curve over pre/post spectrum; spectral band colors; draggable handles, ⌥-drag Q, numeric band rows.
- Visualizer: mode picker (D-014/D-016) — Frequency Response, spectrum bars / mirrored / ghost / LED, spectrogram, oscilloscope, CRT, vectorscope, correlation, VU/PPM, particles, Reactor (Metal). Pop-out window + fullscreen; menu-bar mini meter. Polar tucked from menu. Selection via `@AppStorage`.

---

## Where Things Live

- `Sources/SonarForge/Audio/` — `AudioEngine`, `SpectrumAnalyzer` (FFT + PCM), `AudioDeviceUtils`, `AudioEngineProtocol`.
- `Sources/SonarForge/DSP/` — EQ, crossfeed, spectrum processor, sample rings, response curve.
- `Sources/SonarForge/Profiles/` — store, manager, AutoEQ importer.
- `Sources/SonarForge/App/` — `AppModel` (A/B, spectrum/waveform feeds, visibility gates).
- `Sources/SonarForge/UI/` — `ContentView`, editor, visualizers (`Visualizations.swift`, `SpectrumVisualizerNSView`, `ReactorView`, `VisualizerPopoutView`), menu bar.
- `Sources/SonarForge/Utilities/` — `SpectrumFeed`, `WaveformFeed`.
- `Documentation/AUDIO_PATH.md` — live audio path + visualizer perf notes.
- `project.yml` — build settings / entitlements; regenerate with `xcodegen generate`.

---

## Hardware QA (owner-validated)

Validated by project owner on real hardware (not synthetic-only):

| Surface | Status | Notes |
|---|---|---|
| MacBook Pro **M4 Pro 14"** | ✅ | Primary daily driver |
| MacBook Pro **M4 Pro 16"** | ✅ | Second machine |
| **USB DACs** | ✅ | External DAC path functions correctly |
| **Bluetooth** output | ✅ | Wireless headphones/speakers path OK |
| Built-in speakers / wired headphones | ✅ | Baseline from earlier audio-path validation |
| **AirPlay** | ⏳ untested | Known CATap risk area historically |
| Apple Music / **FairPlay** DRM edge cases | ⏳ partial / open | Netflix browser DRM was fine earlier; full Apple Music matrix not signed off |
| M1 / M2 / M3 / base M4 | ⏳ untested by owner | Low risk (arm64 + same stack); community beta after public flip |

---

## Not Done Yet

- **Phase 6.5 residual**: AirPlay, FairPlay/Apple Music edge cases, non‑M4 community hardware after public launch.
- **Public launch**: repo still private; flip private→public, then branch protection on `main`.
- Deferred extras: global hotkeys (other app frontmost), curve snapping/zoom, A/B crossfade, optional limiter (D-009), Sparkle auto-update, **Reduce Motion** for Reactor/particles/heavy viz (a11y; owner deferred).
- Digital **output clip indicator** (post-gain sample-peak meter + CLIP badge) shipped; no limiter yet.
- Audit follow-ups shipped: clearer start/timeout UI; **L6** debug spectrum file write is Debug-only; **L8** spectrum FFT scratch reuse (no per-tick alloc thrash); **I10** `@MainActor` on `AppModel` + `ProfileManager`.
- **Permission preflight regression (v0.2.1) fixed**: do not gate on `CGPreflightScreenCaptureAccess` — System Audio Recording has no public preflight API; false negatives blocked start with permission already granted.

---

## Immediate Next Steps (Prioritized)

1. **Private→public** repo flip when ready.
2. Residual 6.5 as opportunity allows (AirPlay, FairPlay); broader machines via community.
3. Deferred extras by demand: limiter, global hotkeys, A/B crossfade, Sparkle (not Reduce Motion unless requested).

---

## For New Agents / Contributors

Read `AGENTS.md` first. Technical truth: `ARCHITECTURE.md` + `Documentation/AUDIO_PATH.md`. Decisions in `DECISIONS.md`. This file for current status.
