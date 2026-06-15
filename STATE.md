# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-06-14 — **v0.1.0 shipped.** Signed + notarized and published to [GitHub Releases](https://github.com/ethancooke/SonarForge/releases/tag/v0.1.0); the CI signed-release pipeline is live and dry-run verified end-to-end (push `vX.Y.Z` → CI builds → signs → notarizes → drafts a release). Phase 6 is essentially complete. Remaining: ongoing beta + hardware QA (Chunk 6.5: BT/USB DAC/AirPlay/FairPlay), the private→public repo flip, and a few optional deferred extras.

---

## High-Level Status

The MVP feature set is **functionally complete**. All work below is listening-validated by the project owner unless noted.

| Phase | Status |
|---|---|
| 0 — Scaffolding | ✅ Complete (XcodeGen project, 14.2/arm64-only, CI, templates) |
| 1 — Audio path (tap capture, passthrough, bypass, gain staging) | ✅ Complete + validated (see `Documentation/AUDIO_PATH.md`) |
| 2 — Parametric EQ DSP (biquad bank, lock-free parameter path, live integration) | ✅ Complete + validated |
| 3 — Spectrum analyzer (3.1) | ✅ Complete (pre/post taps → 20 Hz FFT → live traces) |
| 4 — Profiles + AutoEQ (4.1 persistence/CRUD, 4.2 importer + attribution, 4.3 quick switch) | ✅ Complete + validated (real Koss KPH40 AutoEQ profile in daily use) |
| 5 — UI (shell, graphical editor, band list, spectrum overlay, accessibility, shortcuts help, drag-and-drop import, library search) | ✅ Complete |
| 6 — Hardening & release | ✅ 6.1–6.4 complete — **v0.1.0 signed, notarized, published**; CI signed-release verified end-to-end. 🔶 6.5 ongoing (broader beta + hardware QA: BT/USB DAC/AirPlay/FairPlay) |

**Headline facts**
- Audio: tap → private aggregate → HAL IOProc; ~0% CPU running with EQ + spectrum + editor live; 35-min soak clean; Netflix browser DRM captured fine.
- DSP: 16-band DF2T cascade, 0.29% of realtime for 12 bands (optimized build); 76 unit tests across DSP/profiles/importer/spectrum, all passing.
- Profiles persist as plain JSON; AutoEQ parametric + GraphicEQ import with mandatory attribution; favorites ordering + ⌘1–9/⌘B quick switch.
- Editor: response curve over live spectrum, draggable handles (live audio, persist-on-release), ⌥-drag Q, arrow-key nudging, numeric band rows, axis labels.

---

## Where Things Live

- `Sources/SonarForge/Audio/` — `AudioEngine` (tap + aggregate + IOProc, gain smoothing, watchdog, device listeners), `SpectrumAnalyzer`, `AudioDeviceUtils`, `AudioEngineProtocol` (UI↔engine boundary, D-004).
- `Sources/SonarForge/DSP/` — `BiquadCoefficients` (clamped RBJ + analytic response), `RealtimeParametricEQ` (SPSC command ring, D-010), `SpectrumProcessor`, `SampleRing`, `EQResponseCurve`, `GainMath`, `BiquadFilter` (offline/test).
- `Sources/SonarForge/Profiles/` — `ProfileStore` (JSON-per-profile, atomic writes), `ProfileManager` (@Observable CRUD + favorites order), `AutoEQImporter` (pure parser).
- `Sources/SonarForge/UI/` — `ContentView` (layout + `BandListEditor` + `AudioEnginePanel`), `FrequencyResponseEditor`, `SpectrumView`/`SpectrumSection` (observation-isolated — see perf lesson in AUDIO_PATH.md), `ProfileLibraryView`, `AutoEQImportView`, `MenuBarContent`.
- `Documentation/AUDIO_PATH.md` — authoritative audio-path technique, threading model, measurements, validation records, dev gotchas (stale-TCC wedge + `tccutil reset` fix).
- `project.yml` — source of truth for build settings; regenerate with `xcodegen generate`.
- Debug launch: `open <DerivedData>/SonarForge.app --args --autostart-engine`.

---

## Not Done Yet

- **Phase 6.5 (ongoing)**: hardware-QA matrix on real devices (USB DAC/Bluetooth/AirPlay untested — no hardware at hand), Apple Music/FairPlay capture behavior, broader beta across M-series chips.
- Deferred extras: global hotkeys while other apps are frontmost (Carbon), curve snapping/zoom, A/B crossfade, optional limiter (D-009), in-app auto-update (Sparkle) — manual GitHub Releases for now.

---

## Immediate Next Steps (Prioritized)

1. **Public-launch prep** (toward flipping the repo private→public): history secret-scan ✅ clean; `SECURITY.md` in place; **rotate the notarization app-specific password** (it was exposed in plaintext during CI-secrets setup) and update the `NOTARY_PASSWORD` secret; enable branch protection on `main` once public (free on public repos).
2. **Hardware QA**: Bluetooth/USB DAC device-switch cycle, Apple Music (FairPlay) capture behavior, CPU spread across M-series chips.
3. **Deferred extras** as demand dictates: global hotkeys, curve snapping/zoom, A/B crossfade, optional limiter, Sparkle auto-update.

---

## For New Agents / Contributors

Read `AGENTS.md` first (reading order + locked decisions). Technical truth: `ARCHITECTURE.md` + `Documentation/AUDIO_PATH.md`. Decisions D-001…D-010 in `DECISIONS.md`. Then this file for current status.
