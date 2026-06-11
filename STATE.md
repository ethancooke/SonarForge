# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-06-11 — **Chunk 5.2 complete** (editor core user-validated; polish added: frequency/dB axis labels, ⌥-drag Q, arrow-key nudging). Remaining: 5.4 accessibility, 5.5 drag-and-drop import, Phase 6 hardening/release.

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
| 5 — UI (5.1 shell, 5.2 graphical editor, 5.3 band list + spectrum overlay) | ✅ Essentials complete; **5.4 accessibility + 5.5 drag-and-drop remain** |
| 6 — Hardening & release | ⏳ Not started |

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
- `Sources/SonarForge/UI/` — `ContentView` (layout + `BandListEditor` + debug panel), `FrequencyResponseEditor`, `SpectrumView`/`SpectrumSection` (observation-isolated — see perf lesson in AUDIO_PATH.md), `ProfileLibraryView`, `AutoEQImportView`, `MenuBarContent`.
- `Documentation/AUDIO_PATH.md` — authoritative audio-path technique, threading model, measurements, validation records, dev gotchas (stale-TCC wedge + `tccutil reset` fix).
- `project.yml` — source of truth for build settings; regenerate with `xcodegen generate`.
- Debug launch: `open <DerivedData>/SonarForge.app --args --autostart-engine`.

---

## Not Done Yet

- **5.4**: VoiceOver/accessibility pass over the editor and band list; keyboard-shortcut discoverability (cheat sheet / Help).
- **5.5**: drag-and-drop of profile JSON onto the window/app; (AutoEQ import sheet already supports file drop).
- **Phase 6**: device robustness QA (USB DAC/Bluetooth/AirPlay untested — no hardware at hand), long-run stability test with EQ active, CPU saver options, first-run/permission UX, signing + notarization + release workflow.
- Deferred extras: global hotkeys while other apps are frontmost (Carbon), curve snapping/zoom, A/B crossfade, optional limiter (D-009), Apple Music/FairPlay capture behavior unverified.

---

## Immediate Next Steps (Prioritized)

1. **Quick validation of 5.2 polish**: axis labels readable in both light/dark; ⌥-drag a handle vertically to feel Q; click the editor then arrow-key nudge the selected band.
2. **5.4 + 5.5** (small): accessibility labels/VoiceOver on editor + band rows, shortcuts cheat sheet, window-level profile drag-and-drop.
3. **Phase 6.1/6.2**: device-change robustness QA and long-run stability with EQ active, then 6.3/6.4 docs + signing/notarization for a first tagged release.

---

## For New Agents / Contributors

Read `AGENTS.md` first (reading order + locked decisions). Technical truth: `ARCHITECTURE.md` + `Documentation/AUDIO_PATH.md`. Decisions D-001…D-010 in `DECISIONS.md`. Then this file for current status.
