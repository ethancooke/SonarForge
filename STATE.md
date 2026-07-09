# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-07-09 — **v0.2.0** cut (tag `v0.2.0`). Since v0.1.2: per-profile headphone **crossfeed**, spectrum FFT sized per sample rate (low-frequency fix), full **visualization suite** (spectrum modes, PCM scope/meters, Reactor Metal visual), **pop-out visualizer** with fullscreen, menu-bar mini spectrum, and visualizer performance/mode-switch fixes. Signed + notarized `.dmg` via CI (`push vX.Y.Z` → draft release). Repo still **private**; remaining: private→public flip, ongoing beta + hardware QA (6.5), optional deferred extras.

---

## High-Level Status

The MVP feature set is **functionally complete**. Visualizers and crossfeed shipped in v0.2.0. Listening validation by project owner for core audio; broader hardware QA still open.

| Phase | Status |
|---|---|
| 0 — Scaffolding | ✅ Complete (XcodeGen project, 14.2/arm64-only, CI + SwiftLint, templates) |
| 1 — Audio path (tap capture, passthrough, bypass, gain staging) | ✅ Complete + validated (see `Documentation/AUDIO_PATH.md`) |
| 2 — Parametric EQ DSP (biquad bank, lock-free parameter path, live integration) | ✅ Complete + validated |
| 3 — Spectrum analyzer (3.1) | ✅ Complete (pre/post taps → 20 Hz FFT → live traces; adaptive FFT size D-013) |
| 4 — Profiles + AutoEQ (4.1 persistence/CRUD, 4.2 importer + attribution, 4.3 quick switch, A/B compare) | ✅ Complete + validated |
| 5 — UI (shell, graphical editor, band list, spectrum overlay, visualizers, pop-out) | ✅ Complete for MVP + v0.2.0 visualizer suite |
| 6 — Hardening & release | ✅ 6.1–6.4 complete — CI signed-release pipeline. 🔶 6.5 ongoing (broader beta + hardware QA) |

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

## Not Done Yet

- **Phase 6.5 (ongoing)**: hardware-QA matrix (USB DAC / Bluetooth / AirPlay), Apple Music/FairPlay, broader M-series CPU spread.
- **Public launch**: repo still private; flip private→public, then branch protection on `main`.
- Deferred extras: global hotkeys (other app frontmost), curve snapping/zoom, A/B crossfade, optional limiter (D-009), Sparkle auto-update.

---

## Immediate Next Steps (Prioritized)

1. Publish/verify **v0.2.0** GitHub Release after CI notarizes the draft.
2. **Private→public** repo flip when ready.
3. Hardware QA matrix.
4. Deferred extras by demand: limiter, global hotkeys, A/B crossfade, Sparkle.

---

## For New Agents / Contributors

Read `AGENTS.md` first. Technical truth: `ARCHITECTURE.md` + `Documentation/AUDIO_PATH.md`. Decisions in `DECISIONS.md`. This file for current status.
