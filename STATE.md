# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-06-17 — **v0.1.2 shipped** (latest on [GitHub Releases](https://github.com/ethancooke/SonarForge/releases/tag/v0.1.2)). Signed + notarized `.dmg` installs; CI signed-release pipeline verified end-to-end (push `vX.Y.Z` → CI builds → signs → notarizes → drafts a release). Since v0.1.0: Sonar Wave factory preset, A/B comparison fix (live slot reload by profile id), spectral band coloring + always-on pre/post spectrum, panel and output-device picker polish, SwiftLint + OSS hygiene, public-facing docs pass. Repo still **private**; remaining: private→public flip, ongoing beta + hardware QA (6.5), and optional deferred extras.

---

## High-Level Status

The MVP feature set is **functionally complete**. All work below is listening-validated by the project owner unless noted.

| Phase | Status |
|---|---|
| 0 — Scaffolding | ✅ Complete (XcodeGen project, 14.2/arm64-only, CI + SwiftLint, templates) |
| 1 — Audio path (tap capture, passthrough, bypass, gain staging) | ✅ Complete + validated (see `Documentation/AUDIO_PATH.md`) |
| 2 — Parametric EQ DSP (biquad bank, lock-free parameter path, live integration) | ✅ Complete + validated |
| 3 — Spectrum analyzer (3.1) | ✅ Complete (pre/post taps → 20 Hz FFT → live traces; always-on in UI since v0.1.2) |
| 4 — Profiles + AutoEQ (4.1 persistence/CRUD, 4.2 importer + attribution, 4.3 quick switch, A/B compare) | ✅ Complete + validated (real Koss KPH40 AutoEQ profile in daily use; A/B slots reload live — v0.1.1) |
| 5 — UI (shell, graphical editor, band list, spectrum overlay, spectral band colors, accessibility, shortcuts help, drag-and-drop import, library search) | ✅ Complete |
| 6 — Hardening & release | ✅ 6.1–6.4 complete — **v0.1.2 signed, notarized, published** (`.dmg` primary); CI signed-release verified end-to-end. 🔶 6.5 ongoing (broader beta + hardware QA: BT/USB DAC/AirPlay/FairPlay) |

**Headline facts**
- Audio: tap → private aggregate → HAL IOProc; ~0% CPU running with EQ + spectrum + editor live; 35-min soak clean; Netflix browser DRM captured fine. Output picker filters the app's own aggregate and auto-refreshes via a Core Audio device-list listener (v0.1.2).
- DSP: 16-band DF2T cascade, 0.29% of realtime for 12 bands (optimized build); optional per-profile headphone **crossfeed** stage (complementary-filter, tone-neutral for mono; runs after the EQ — see D-012); 98 unit tests across DSP/profiles/importer/spectrum/A/B/crossfeed, all passing.
- Profiles persist as plain JSON; AutoEQ parametric + GraphicEQ import with mandatory attribution; favorites ordering + ⌘1–9/⌘B quick switch; 11 factory presets including the artistic **Sonar Wave**.
- Editor: response curve over always-on pre/post spectrum; spectral band colors (warm bass → cool treble on footprint, handle, and band row, live while dragging); summed response drawn neutral on top; draggable handles (live audio, persist-on-release), ⌥-drag Q, arrow-key nudging, numeric band rows, axis labels.

---

## Where Things Live

- `Sources/SonarForge/Audio/` — `AudioEngine` (tap + aggregate + IOProc, gain smoothing, watchdog, device listeners), `SpectrumAnalyzer`, `AudioDeviceUtils`, `AudioEngineProtocol` (UI↔engine boundary, D-004).
- `Sources/SonarForge/DSP/` — `BiquadCoefficients` (clamped RBJ + analytic response), `RealtimeParametricEQ` (SPSC command ring, D-010), `Crossfeed` (per-profile headphone crossfeed, D-012), `SpectrumProcessor`, `SampleRing`, `EQResponseCurve`, `GainMath`, `BiquadFilter` (offline/test).
- `Sources/SonarForge/Profiles/` — `ProfileStore` (JSON-per-profile, atomic writes), `ProfileManager` (@Observable CRUD + favorites order), `AutoEQImporter` (pure parser).
- `Sources/SonarForge/App/` — `AppModel` (A/B slot state, profile selection, engine coordination).
- `Sources/SonarForge/UI/` — `ContentView` (layout + `BandListEditor` + `AudioEnginePanel`), `FrequencyResponseEditor`, `BandPalette` (spectral band coloring), `SpectrumView`/`SpectrumSection` (observation-isolated — see perf lesson in AUDIO_PATH.md), `ProfileLibraryView`, `AutoEQImportView`, `MenuBarContent`.
- `Documentation/AUDIO_PATH.md` — authoritative audio-path technique, threading model, measurements, validation records, dev gotchas (stale-TCC wedge + `tccutil reset` fix).
- `project.yml` — source of truth for build settings and entitlements (incl. audio-input, D-011); regenerate with `xcodegen generate`.
- Debug launch: `open <DerivedData>/SonarForge.app --args --autostart-engine`.

---

## Not Done Yet

- **Phase 6.5 (ongoing)**: hardware-QA matrix on real devices (USB DAC/Bluetooth/AirPlay untested — no hardware at hand), Apple Music/FairPlay capture behavior, broader beta across M-series chips.
- **Public launch**: repo still private; docs polished for a public audience (README, CONTRIBUTING, internal/technical docs). Remaining: flip private→public, then enable branch protection on `main`.
- Deferred extras: global hotkeys while other apps are frontmost (Carbon), curve snapping/zoom, A/B crossfade, optional limiter (D-009), in-app auto-update (Sparkle) — manual GitHub Releases for now.

---

## Immediate Next Steps (Prioritized)

1. **Private→public repo flip** — docs and legal hygiene are in place; enable branch protection on `main` once public (free on public repos).
2. **Hardware QA**: Bluetooth/USB DAC device-switch cycle, Apple Music (FairPlay) capture behavior, CPU spread across M-series chips.
3. **Deferred extras** as demand dictates: global hotkeys, curve snapping/zoom, A/B crossfade, optional limiter, Sparkle auto-update.

---

## For New Agents / Contributors

Read `AGENTS.md` first (reading order + locked decisions). Technical truth: `ARCHITECTURE.md` + `Documentation/AUDIO_PATH.md`. Decisions D-001…D-011 in `DECISIONS.md`. Then this file for current status.