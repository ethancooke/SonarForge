# SonarForge Development Plan

> **For AI agents**: See [AGENTS.md](../AGENTS.md) first. It contains the recommended reading order (including `VISION.md`, `DECISIONS.md`, and `STATE.md`), key locked decisions, and current status.

This document breaks the project into logical, sequential phases and chunks. The ordering prioritizes early validation of the **critical audio path** (capture → process → output with bypass) so that the hardest and most consequential work is de-risked before heavy UI investment.

All estimates are rough and assume a single experienced developer with occasional focused review. "Complexity" refers to the combination of technical risk, unknowns, and implementation effort.

## Phase 0: Foundations & Scaffolding

### Chunk 0.1 — Project Scaffolding & Repository Hygiene (Low)
**Deliverables / Acceptance Criteria**
- Clean directory layout matching the recommended structure (see README and ARCHITECTURE).
- `README.md`, `LICENSE` (Apache 2.0), `.gitignore`, `CONTRIBUTING.md`, `ARCHITECTURE.md`, `DEVELOPMENT_PLAN.md`.
- Basic Xcode project created (`SonarForge.xcodeproj`) as a macOS App (SwiftUI, **macOS 14.2** deployment target, **Apple Silicon arm64 only** — no Intel, no "Standard Architectures" that include x86_64).
- Exact recommended target settings (set during project creation or Build Settings):
  - Deployment Target: 14.2
  - Supported Platforms: macOS
  - Architectures (ARCHS): `arm64`
  - Valid Architectures: `arm64`
  - Build Active Architecture Only (Debug): Yes
  - Excluded Architectures: (empty or explicitly exclude x86_64)
- `SonarForge.entitlements` with initial audio-related keys.
- Info.plist with appropriate usage descriptions and version/build settings.
- GitHub Actions skeleton for build (or at least a `build.yml` that compiles on push).
- `.github` issue/PR templates.
- First commit on `main`; a `develop` or feature branch workflow documented.

**Dependencies**: None.
**Key Risks/Decisions**: Decide on exact project organization (single target vs. internal SPM module for `SonarForgeAudio`). Start simple (single target with clear folders). Add a framework target later only if cross-target testing or distribution benefits justify it. **Hard requirement**: macOS 14.2 deployment + arm64 only (no Intel). This must be set correctly at project creation time.
**Rationale for Early Placement**: Unblocks all other work and signals professionalism to contributors.

**See also**: `Documentation/Xcode-Setup.md` for the precise target settings that **must** be applied in this chunk (macOS 14.2 + arm64 only). Do not proceed to Chunk 1.1 until the project builds cleanly for Apple Silicon 14.2+.

**Current Status (as of 2026-06-09)**: **Complete.** `SonarForge.xcodeproj` is generated via XcodeGen from `project.yml` with the correct 14.2 + arm64 settings. Build and unit tests pass, the binary is verified arm64-only with minos 14.2, and the app shell launches cleanly. Next: Chunk 1.1. See `STATE.md`.

**Estimated Size**: Very small. 1–2 days.

---

## Phase 1: Audio Path Validation (Highest Priority)

### Chunk 1.1 — Core Audio Tap Capture + Reliable Passthrough + Bypass (High)

**Deliverables / Acceptance Criteria**
- Functional audio subsystem that can:
  1. Request and handle "Screen & System Audio Recording" permission.
  2. Create a global `CATapDescription` (exclude own process).
  3. Instantiate an `AVAudioEngine` (or equivalent) that receives audio from the tap as input.
  4. Render the (unprocessed or bypassed) audio to a user-selectable output device.
  5. Provide a rock-solid **bypass** that is bit-identical or extremely close to direct passthrough when engaged (measure with tones if possible).
- Graceful handling of:
  - Initial permission denial (clear UI guidance + button to open System Settings).
  - No tap available (show error state).
  - Output device disconnected or sample rate change (log + attempt recovery or clear message to user).
- Public API surface in the audio layer is small, pure, and injectable (protocol or actor boundary).
- Basic logging (os_log / Logger) with categories for audio lifecycle.
- A simple command-line or debug UI toggle (or SwiftUI button in a temporary window) that exercises bypass on/off while playing system audio.
- No audible artifacts (pops, clicks, dropouts) during normal operation and bypass transitions on common content (music, voice, system sounds) at 44.1/48 kHz.
- CPU usage documented (Activity Monitor + Instruments) for idle + light load.

**Dependencies**: Chunk 0.1 (scaffolding).
**Key Technical Risks / Decisions**:
- **CATap vs. driver**: Primary decision is already made in ARCHITECTURE (CATap first). Validate early whether global tap + mute + re-render works reliably for the user's full system (including browsers, music apps, video). If major gaps appear, document them and decide whether to add a virtual device fallback (high cost, deferred).
- Tap format handling and device selection: The tap inherits the format of the tapped stream(s). Output device may be at a different rate. Decide on resampling strategy (AVAudioConverter quality vs. requiring matched rates).
- Threading model for parameter updates and engine reconfiguration.
- Feedback prevention: Must exclude SonarForge process from the tap.
- Stability on Apple Silicon (M-series): Test buffer sizes (256–1024 range typical). Target is macOS 14.2+ only.
- Permission model: The prompt appears on first tap creation in an aggregate context. Must be robust.

**Why This Chunk Must Be Early**: Every other feature (EQ, spectrum, profiles) is worthless without a stable, low-artifact audio path. UI investment before this is validated is wasted.

**Estimated Size**: High. 1–3 weeks depending on iteration cycles with real hardware/content.

---

### Chunk 1.2 — Basic Preamp + Output Gain Staging + Safety (Medium)

**Deliverables**
- Preamp (pre-EQ) and master output gain controls (dB, smooth).
- Headroom management / simple soft limiting or clipping prevention strategy (document decision: none vs. simple tanh vs. proper limiter).
- UI faders (temporary or final) wired live to the engine.
- A/B state at minimum includes the gain values.

**Dependencies**: 1.1 (working passthrough).
**Risks**: Zipper noise on gain changes (must implement smoothing). Clipping on high positive preamp + many boosting bands.

---

## Phase 2: Parametric EQ DSP Core

### Chunk 2.1 — Biquad Filter Bank + Standard Filter Types (High)

**Deliverables**
- Production-quality `BiquadFilter` implementation (Direct Form II Transposed preferred).
- `ParametricEQ` processor owning N bands + preamp/master.
- Supported types (minimum): Peaking, Low Shelf, High Shelf, Low-pass (12 dB/oct), High-pass (12 dB/oct). Nice-to-have: Notch, Band-pass.
- Correct RBJ / Audio EQ Cookbook coefficient formulas with edge-case handling (Nyquist, Q < 0.1, extreme gains ±20 dB or more).
- Lock-free or double-buffered parameter update path from UI to audio thread.
- Unit tests with known-good coefficient values and impulse/step response checks.
- CPU profiling: target < 1–2% on M1/M2 for 8–12 bands at 48 kHz.

**Dependencies**: 1.1 (stable engine to host the processor).
**Risks**:
- Numerical stability and denormals.
- Parameter smoothing strategy (per-sample vs. per-block).
- Verifying correctness without measurement hardware (use synthetic tests + listening with known tracks).
- Performance on many bands or high sample rates.

**Chunk 2.2 — Integration into Live Engine + Bypass Semantics** (follows 2.1 closely)

- Wire the EQ into the processing graph from 1.1.
- Define exact bypass semantics (zero-cost passthrough vs. unity-gain filters).
- A/B swap of complete profiles with optional short crossfade (linear or equal-power).

---

## Phase 3: Real-time Spectrum Analyzer

### Chunk 3.1 — vDSP FFT Analysis + Thread-Safe Delivery (Medium)

**Deliverables**
- FFT engine using `vDSP` (Hann window, power spectrum, dB conversion).
- Configurable FFT size (e.g. 2048/4096) and hop size.
- Pre-EQ and Post-EQ analysis points (tappable inside the processing chain).
- Efficient log-frequency binning or direct bin mapping suitable for drawing.
- Delivery mechanism to SwiftUI (actor + `AsyncStream` or `@Published` on main with rate limiting ~30–60 Hz).
- Toggle to disable analysis entirely for CPU-sensitive users.
- Visual component stub (bars or line) that renders the data (final pretty version can come in UI phase).

**Dependencies**: 1.1 + 2.1 (need audio flowing through the processor).
**Risks**: Accuracy of spectrum (windowing, scaling, calibration to 0 dBFS). CPU cost of analysis. Synchronization (analysis must not block render).

---

## Phase 4: Profile System & AutoEQ

### Chunk 4.1 — Profile Model, Persistence, CRUD (Low–Medium)

**Deliverables**
- `EQProfile` + `EQBand` value types (Codable, Identifiable, etc.).
- JSON file-based storage in Application Support with atomic writes.
- In-memory manager with `@Observable` / observable object surface.
- Create, rename, delete, duplicate, favorite, set-active.
- Last-used profile remembered across launches.
- Export single profile as `.sonarforgeprofile.json` (or simple extension).

**Dependencies**: Can start after models exist; benefits from having real EQ parameters.

---

### Chunk 4.2 — AutoEQ Importer + Attribution UX (Medium)

**Deliverables**
- Robust parser for common AutoEQ text formats:
  - "Parametric EQ" sections with "Filter X: ON PK Fc ... Hz Gain ... dB Q ..."
  - GraphicEQ line format (frequency: gain pairs).
- Importer UI: Paste text area + "Load file..." + drag-and-drop.
- Auto-generated profile name with source (e.g. "Sennheiser HD 600 (oratory1990)").
- Prominent, non-dismissible attribution line in profile editor and list.
- "Open in browser" link to the original AutoEQ entry when possible (store URL or note).
- Round-trip tests for importer (parse → profile → export text approximates).
- Error handling for malformed input with helpful messages.

**Dependencies**: 4.1.
**Risks**: Format drift in AutoEQ over time. Many different output styles from the project. Need good heuristics + manual fallback.

---

### Chunk 4.3 — Quick Switch, Favorites, and Status Item Integration (Low)

- Menu bar lists favorite + recent profiles.
- Global hotkey or status item submenu for instant switching (with audio-thread-safe swap).
- Keyboard shortcut discovery (⌘1–9 for first N profiles, etc.).

---

## Phase 5: User Interface (SwiftUI)

### Chunk 5.1 — Main Window Shell + Basic Controls (Medium)

- Resizable window with proper toolbar / titlebar appearance.
- Layout: Frequency response area (large, top), band controls (list or grid below or side), global controls (preamp, bypass, A/B, profile name).
- Live wiring of basic parameters (even if the full graphical editor is stubbed).

### Chunk 5.2 — Frequency Response Curve + Draggable Band Handles (High)

- Custom drawing view (SwiftUI `Canvas` + `Path` is a good starting point; consider `Metal` or `CALayer` later for 120 Hz smoothness if needed).
- Accurate log-frequency x-axis (20 Hz – 20 kHz or 10 Hz – 22 kHz).
- dB y-axis (e.g. ±15 or ±20 dB).
- Draggable nodes for each band (frequency + gain). Q may be adjusted via scroll wheel / modifier + drag or a secondary control.
- Visual curve that is the sum of all band responses (computed efficiently, possibly on background queue or with incremental updates).
- Visual indication of which band is selected.
- Snap / zoom behaviors, keyboard nudging of selected band.

**Risk**: Making a pleasant, precise, fast graphical editor is deceptively hard. Budget time for iteration.

### Chunk 5.3 — Band List / Editor, Spectrum Overlay, Polish (Medium)

- Numeric editing of every band parameter (type picker, freq, gain, Q with sensible units and steppers).
- Add / remove bands (respect reasonable max, e.g. 12–16).
- Pre / Post spectrum overlay on the frequency response view (toggleable, alpha blended or separate traces).
- Bypass and A/B buttons with clear state.
- Keyboard shortcuts for all common actions.

### Chunk 5.4 — Status Item, Menu Bar, Global Shortcuts, Accessibility (Medium)

- `NSStatusBar` item with icon that changes on bypass.
- Popover or menu with: current profile, bypass toggle, quick profile list, "Open SonarForge", Quit.
- Full VoiceOver labels, rotor support where useful, high-contrast considerations.
- Discoverable shortcuts (Help menu or in-app cheat sheet).

### Chunk 5.5 — Profile Manager Window / Sheet + Import Flow (Medium)

- Dedicated view for browsing, searching, importing, exporting, favoriting profiles.
- Import sheet wired to the AutoEQ parser.
- Drag-and-drop of `.json` profile files onto the app or window.

---

## Phase 6: Hardening, UX Refinement, Release

### Chunk 6.1 — Device & Sample Rate Robustness + Error Recovery (High)

- Comprehensive handling of route changes, device removal, sample rate switches, aggregate devices.
- User-visible but non-panicking feedback ("Audio device changed — reconfiguring...").
- "Reset Audio Engine" button in advanced / troubleshooting UI.
- Fade in/out on transitions.

### Chunk 6.2 — Performance, CPU Metering, Quality Assurance (Medium–High)

- Instruments traces on real content.
- Optional "CPU Saver" mode (larger FFT hop, fewer analysis updates, lower max bands, or simplified drawing).
- Headroom and clipping statistics (optional advanced metering view).
- Long-duration stability test (hours of playback).

### Chunk 6.3 — Documentation, Help, First-Run Experience (Low–Medium)

- In-app "Getting Started" / permission explanation flow.
- Troubleshooting page (common issues: no sound after enabling, permission problems, certain apps not affected).
- Keyboard shortcut reference.
- "About" with clear attribution and version info.
- README updates + release notes template.

### Chunk 6.4 — Build, Signing, Distribution, CI Polish (Medium)

- Proper code signing + hardened runtime.
- Notarization script or Fastlane / `xcrun notarytool` automation.
- Sparkle or simple GitHub Releases update mechanism (or just manual for v1).
- GitHub Actions that builds + archives on tag.
- Basic analytics opt-in? (No — keep scope narrow; defer or never.)

### Chunk 6.5 — Beta Testing & Feedback Loop (Variable)

- Small group of trusted listeners with varied headphones and content.
- Focus on artifact reports, CPU on different M-series chips, device compatibility (USB DACs, Bluetooth, AirPods, built-in, HDMI).

---

## Phase 7: Post-MVP (Explicitly Deferred)

- Any form of AU hosting.
- Spatial audio or advanced DSP.
- FIR / linear phase modes (unless trivial).
- Per-app processing.
- Heavy visual chrome or non-essential features.
- Monetization.

---

## Prioritization Rules (for the team)

1. If the audio path (Chunks 1.x) is not rock solid, do not declare any milestone complete.
2. UI beauty and feature breadth are secondary to "it sounds correct and never glitches."
3. When in doubt, cut scope rather than ship unstable audio.
4. Every chunk that touches the audio thread must include a short written note on threading model, synchronization, and measured CPU impact.

## Chunk Sizing Guidance

- High complexity chunks should be broken further if they exceed ~2 weeks of focused work.
- After each high-risk chunk, pause for a short integration + listening test before starting the next.

---

**Current Status**: This plan is the initial public version. Update it as discoveries are made during Chunk 1.1 (the most important learning opportunity).
