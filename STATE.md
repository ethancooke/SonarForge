# SonarForge — Current Project State

This is the living "where are we right now" document. Update it whenever significant progress is made.

**Last Updated**: 2026-06-10 — **Chunk 4.2 implemented** (AutoEQ importer: parametric + GraphicEQ parser with 12 tests, import sheet with paste/file/drag-drop and live preview, mandatory attribution stored and displayed). Chunk 4.1 complete. Pending: user click-through of 4.1.3 UI + a real AutoEQ import listening test.

---

## High-Level Status

- **Phase**: Phase 1 (Audio Path Validation). **Chunk 1.1 complete (2026-06-10)** — full validation record in `Documentation/AUDIO_PATH.md`:
  - Passthrough, permission flow, bypass toggling, 44.1 + 48 kHz, device switches (in-app picker + system default, ~60–100 ms rebuilds), clean quit: all confirmed by listening.
  - 35-min soak: no memory growth, ~0% CPU, no audio-code leaks.
  - **Netflix (browser DRM) is captured and processed cleanly** — major de-risking of the CATap approach. Apple Music/FairPlay untested.
  - One real bug found by validation and fixed: device switch silently killed the engine (stale `.running` state blocked the rebuild guard); `stopOnQueue()` now resets state to `.idle`.
  - Deferred: USB DAC / Bluetooth device validation (no hardware at hand; folded into Chunk 6.1).
- A debug `--autostart-engine` launch argument exists for autonomous testing (`open SonarForge.app --args --autostart-engine`).
- **Chunk 1.1 implementation** (see `Documentation/AUDIO_PATH.md` for full details):
  - Real audio engine: global stereo-mixdown process tap (own PID excluded, `muteBehavior = .muted`, private) → private aggregate device (output device as clock master, tap drift-compensated) → single HAL IOProc copying tap input to output buffers (D-007).
  - Atomic bypass flag (swift-atomics, D-008); in 1.1 both paths are bit-identical passthrough — EQ slots into the active branch in Chunk 2.2.
  - ~30 ms fade-in on engine start; 512-frame buffer requested.
  - Output device selection by UID (or follow system default); listeners for default-device change, device removal, and sample-rate change trigger a debounced engine rebuild.
  - Engine state machine (`idle/starting/running/failed`) surfaced in a debug panel in the main window (start/stop ⌘⇧E, device picker, privacy-settings + retry buttons) and in the menu bar.
  - New files: `Audio/AudioEngineProtocol.swift`, `Audio/AudioDeviceUtils.swift`; `Audio/AudioEngine.swift` rewritten; `AppModel`/`ContentView`/`MenuBarContent` wired.
- **Chunk 0.1**: complete (XcodeGen project, 14.2/arm64-only verified, CI, templates).
- **Next Immediate Work**: Run the manual validation checklist (below), record results + CPU measurements in `Documentation/AUDIO_PATH.md`, fix anything it surfaces. Then Chunk 1.2 (gain staging).
- **Critical Path**: The audio engine (Chunk 1.1) is the highest priority and riskiest piece. No significant UI investment should happen until a stable, artifact-free passthrough + bypass is demonstrated.

---

## What Exists in the Repository

### Documentation (Strong)
- `README.md` — Public vision and overview (updated with current target).
- `VISION.md` — Original detailed requirements preserved.
- `ARCHITECTURE.md` — Technical design and data flow.
- `DEVELOPMENT_PLAN.md` — Complete phased breakdown with chunk details.
- `CHUNK1_IMPLEMENTATION_GUIDE.md` — Detailed implementation + validation guide for Chunk 1.1.
- `DECISIONS.md` — Architectural decision records.
- `AGENTS.md` — Handoff instructions for AI agents.
- `CONTRIBUTING.md`
- `Documentation/`
  - `GETTING_STARTED.md`
  - `Xcode-Setup.md` (exact build settings)
- `STATE.md` (this file)

### Code Skeletons (Good starting points)
- `Sources/SonarForge/App/`
  - `SonarForgeApp.swift` (basic SwiftUI App with MenuBarExtra)
  - `AppModel.swift` (observable state + protocol stub for engine)
- `Sources/SonarForge/Models/`
  - `EQProfile.swift` (Codable profile model, `flat` reference, `FilterType` enum)
- `Sources/SonarForge/DSP/`
  - `BiquadFilter.swift` (DF2T implementation + RBJ coefficient calculators for all planned filter types)
  - `ParametricEQ.swift` (band bank + preamp/output gain + buffer processing skeleton)
- `Sources/SonarForge/Audio/`
  - `AudioEngine.swift` (detailed stub with comments on CATap approach, platform requirements, and threading notes)
- `Sources/SonarForge/UI/`
  - `ContentView.swift` (placeholder layout with frequency response area and basic controls)
  - `MenuBarContent.swift` (status item menu skeleton)
- `Sources/SonarForge/Utilities/`
  - `PermissionHelper.swift` (Screen & System Audio Recording helpers using `CGRequestScreenCaptureAccess`)
- `Sources/SonarForge/Resources/`
  - `Entitlements.entitlements`
- `Sources/SonarForgeTests/`
  - `DSPTests.swift` (basic smoke tests for biquad coefficients)
- `.github/workflows/build.yml` (basic CI skeleton)

### Other
- `LICENSE` (Apache 2.0)
- `.gitignore` (Xcode/Swift focused)
- Directory structure matching the recommended layout in the original plan.

### Project Files (new in Chunk 0.1)
- `project.yml` — XcodeGen project definition (source of truth for build settings).
- `SonarForge.xcodeproj` — generated; committed so `open SonarForge.xcodeproj` works as documented.
- `Sources/SonarForge/Resources/Info.plist` — generated by XcodeGen from `project.yml`.
- `.github/ISSUE_TEMPLATE/` + `.github/PULL_REQUEST_TEMPLATE.md`.

---

## Key Locked Decisions (Summary)

See `DECISIONS.md` for full records. Highlights:

- macOS 14.2+ deployment target, Apple Silicon (arm64) **only**.
- Core Audio Taps as primary capture mechanism (driver approach deferred).
- Strict MVP scope (see `VISION.md`).
- Clean audio engine / UI separation.
- Biquad IIR + vDSP for analysis.

---

## What Has Not Been Done Yet

- Chunk 1.1 manual validation on real hardware (listening tests, device-switch tests, CPU measurements — requires a human).
- DSP integration into a live render path.
- Any spectrum analysis code.
- Profile persistence or AutoEQ importer.
- Graphical frequency response editor or draggable nodes.
- Polish, accessibility work, device handling robustness, etc.

---

## Immediate Next Steps (Prioritized)

1. **Validate 4.1.3 + 4.2** (one combined click-through):
   - Toolbar → Profiles: create/rename/duplicate/favorite/delete; export a profile; re-import it (expect a deduplicated copy that becomes active).
   - "Import AutoEQ…" (sidebar or Profiles sheet): paste a real AutoEQ ParametricEQ.txt (autoeq.app → pick headphone → Parametric Eq), confirm live preview + warnings, import, hear it apply; confirm the attribution line appears under "Current Profile".

2. **Chunk 4.3 — quick switch, favorites ordering, ⌘1–9 shortcuts**, then Phase 3 (spectrum analyzer).

**4.2 summary (2026-06-10)**: `AutoEQImporter` (pure parser: Filter-line format with PK/LSC/HSC/LS/HS/LP/HP/NO, ON/OFF handling, missing-Q→0.707, missing-preamp→derived headroom, >16-band truncation warnings; GraphicEQ point curves reduced to ≤15 log-spaced peaking bands; parametric text export for round trips — 12 tests, 60 total). `AutoEQImportView` sheet: paste box with file drag-drop, Load File… (name auto-suggested from filename), live parse preview + warnings, name/measured-by fields, constructed non-editable attribution. Imported profiles carry mandatory `sourceAttribution`, are activated immediately, and the attribution is displayed under "Current Profile" in the main window and in the library rows.

**4.1.3 summary (2026-06-10)**: `ProfileLibraryView` sheet from the toolbar Profiles button — list with favorite stars, active checkmark, Activate buttons, context menu (rename inline, duplicate, export via save panel, delete with confirmation), New + Import… (NSOpenPanel, multi-select; imports mint a new UUID + deduplicated name, then activate). Manager gained `importProfile`/`exportData`/`decodeProfile` with 4 new round-trip tests (48 total).

**4.1.2 summary (2026-06-10)**: `ProfileManager` (@Observable; seeding, never-empty library, active restore, CRUD with name dedup, in-memory fallback if storage unavailable — 12 unit tests) created by AppModel, which restores and applies the active profile at launch and routes UI selection through `selectProfile(id:)`. Debug preset menu and menu bar now list the real persisted library. Verified live: externally created profile JSON files load, and the persisted active profile (Bass Boost) was applied to the engine on launch.

**Phase 2 validated 2026-06-10**: test-preset switching (Flat / Bass Boost / Treble Boost / Mid Cut / Telephone) audibly correct with clean transitions.

**Chunk 2.1/2.2 summary**: `BiquadCoefficients` (clamped RBJ + analytic magnitude response), `RealtimeParametricEQ` (16-band DF2T cascade, SPSC command ring — D-010), EQ wired between copy and gain passes with state reset on bypass re-engage and coefficient re-application on every engine start. 22 unit tests; 0.29% of realtime for 12 bands (optimized).
**Chunk 1.2 completed 2026-06-10** — listening-validated.

**Dev note**: if the engine ever hangs in "Starting…" after a rebuild, it is the stale-TCC gotcha — run `tccutil reset All com.sonarforge.SonarForge` and re-grant (details in AUDIO_PATH.md).

---

## How to Update This Document

When making progress:
- Update the "High-Level Status" and "Immediate Next Steps" sections.
- Note any new files or major refactors.
- If a chunk is completed, mark it and update the "What Has Not Been Done" list.
- Keep `AGENTS.md` in sync if the handoff story changes.

---

## For New Agents / Contributors

Read in this order (as instructed in `AGENTS.md`):
1. `AGENTS.md`
2. `README.md`
3. `VISION.md`
4. `ARCHITECTURE.md`
5. `DEVELOPMENT_PLAN.md`
6. `CHUNK1_IMPLEMENTATION_GUIDE.md`
7. `Documentation/Xcode-Setup.md`
8. `STATE.md` (this file) — to know exactly where we are today.

Then look at the code skeletons.

Current focus: Get the Xcode project created correctly, then validate the audio path.
