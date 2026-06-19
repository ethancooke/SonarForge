# SonarForge Architecture

> **For AI agents / new sessions**: See [AGENTS.md](AGENTS.md) for the recommended reading order and current project state. This document is the technical core.

This document describes the high-level architecture, key technical decisions, module boundaries, and data flows for SonarForge.

## Guiding Principles

1. **Modularity & Separation**: The real-time audio/DSP layer must be cleanly isolated from the SwiftUI layer. The audio engine must be testable and runnable with minimal UI dependencies.
2. **Performance First**: The audio render thread must stay stable at low latency (< ~10 ms round-trip ideal target for processing) with near-zero CPU when idle and very low CPU under load. No allocations, locks, or ObjC messaging on the audio thread where avoidable.
3. **Driverless by Default**: Target macOS 14.2 and later on Apple Silicon only. Use Apple's Core Audio Taps (`CATapDescription` + `AudioHardwareCreateProcessTap`) as the primary capture mechanism. This avoids the complexity, signing, and UX friction of user-space audio server plug-ins while providing a more direct path.
4. **Local Only**: All audio processing and profile storage is strictly on-device. No cloud services for core functionality.
5. **Graceful Degradation & Recovery**: Handle sample rate changes, device changes, tap failures, and permission state changes without crashing or producing audible artifacts.
6. **Native & Accessible**: SwiftUI-first UI that feels at home on macOS. Full keyboard navigation, VoiceOver support, dynamic type where sensible, and proper dark mode.

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SwiftUI App Layer                       │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
│  │ Main Window │  │ Status Item  │  │ Profile Manager / Importer│ │
│  │ (EQ Editor) │  │  + Menu      │  │  (AutoEQ, JSON, etc.)   │ │
│  └──────┬──────┘  └──────┬───────┘  └────────────┬────────────┘ │
└─────────┼────────────────┼───────────────────────┼──────────────┘
          │                │                       │
          │                │         Commands / Bindings
          ▼                ▼                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Application Core (Models + State)            │
│  EQProfile, Band, FilterType, AppState, Preferences, History    │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        Parameter updates (thread-safe, smoothed or atomic)
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│                     SonarForgeAudio / DSP Engine                │
│  ┌─────────────────────────────┐   ┌──────────────────────────┐ │
│  │   Capture (Core Audio Tap)  │──▶│   Processing Graph       │ │
│  │   (CATapDescription)        │   │   - Preamp Gain          │ │
│  └─────────────────────────────┘   │   - Biquad Bank (N bands)│ │
│                                    │   - Output Gain          │ │
│                                    └────────────┬─────────────┘ │
│                                                 │               │
│                                    ┌────────────▼─────────────┐ │
│                                    │   Analysis (vDSP FFT)    │ │
│                                    │   Pre-EQ + Post-EQ taps  │ │
│                                    └──────────────────────────┘ │
│                                                 │               │
│                                    Render to selected output    │
│                                    device (AVAudioEngine or     │
│                                    custom AURenderCallback)     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    Physical Output Device (Headphones / Speakers)
```

## Audio Path (Critical)

### Capture
- Use `CATapDescription` (global tap excluding the SonarForge process itself to avoid feedback).
- Request appropriate privacy permissions (`CGRequestScreenCaptureAccess` style + system audio recording TCC).
- The tap can be configured with `muteBehavior = .muted` (or `.mutedWhenTapped`) so the original audio does not reach the speakers directly.
- Tap provides a mix (stereo recommended) at the source device's sample rate and format.

### Processing
- Receive audio buffers from the tap (via `AVAudioEngine` input or lower-level callback).
- Apply a chain of biquad IIR filters (one per band).
- Apply preamp (before EQ) and master output gain (after).
- All coefficients updated in a lock-free or double-buffered manner. Coefficient calculation happens off the audio thread; smoothed application or block-synchronous swap is used.
- Filter implementation: Direct Form II Transposed (good numerical properties for audio). Use `Double` for coefficient calculation and state; consider `Float` for the hot audio path if profiling justifies it, with careful attention to denormals and stability.

### Output
- Route the processed stream to the user-selected output device.
- **Implementation (Chunk 1.1, see D-007 and `Documentation/AUDIO_PATH.md`)**: a private aggregate device (output device as clock master + drift-compensated tap) driven by a single HAL IOProc. `AVAudioEngine` turned out unnecessary for the core path — the aggregate gives the HAL-native equivalent of the "manual render callback" option below.
- On device or sample rate change: tear down/recreate the engine or tap gracefully. Provide a short fade-out/fade-in to mask transition (fade-in implemented; rebuilds are debounced).

### Spectrum Analysis
- Separate lightweight FFT path using `vDSP`.
- Hann (or other) window, configurable size (e.g. 2048 or 4096 points).
- Log-frequency binning + dB conversion for display.
- Two views: Pre-EQ (input to processor) and Post-EQ (after processing), both shown continuously. A single atomic gates the whole analysis cost and idles automatically when the spectrum view is off screen (see `Documentation/AUDIO_PATH.md`).
- Analysis runs at a reduced rate (e.g. 30–60 fps) and is delivered to UI via a thread-safe ring or Combine/actor.

### Bypass & A/B
- Bypass: zero-cost passthrough or coefficient bypass (set all gains to 0 dB and bypass shelves).
- A/B: Maintain two complete `EQProfile` states. A hot-key or button swaps the active profile with a short crossfade if possible.

## DSP Module Details

- `BiquadFilter`: Struct with coefficients (b0,b1,b2,a1,a2) + per-channel state (z1, z2). Process methods for mono/stereo/interleaved.
- `ParametricEQ`: Owns an array of `BiquadFilter`s + preamp/master gain. Exposes methods to set band parameters (type, freq, gain, Q) and `process(buffer:)`.
- Coefficient formulas follow standard RBJ / Audio EQ Cookbook with care for edge cases (Nyquist, very low freqs, Q extremes).
- Parameter smoothing: One-pole or dedicated smoother for gain/freq/Q when changed from UI to prevent zipper artifacts. For critical cases (large gain jumps), a short crossfade between old and new filter states.

## Profile & Persistence

- `EQProfile`: Codable value type.
  ```swift
  struct EQProfile: Codable, Identifiable, Hashable {
      var id: UUID
      var name: String
      var preamp: Double          // dB
      var bands: [EQBand]
      var isFavorite: Bool
      var sourceAttribution: String?  // e.g. "AutoEQ / oratory1990 - Sony WH-1000XM5"
      var notes: String?
  }

  struct EQBand: Codable, Hashable {
      var type: FilterType
      var frequency: Double
      var gain: Double
      var q: Double
  }

  enum FilterType: String, Codable { case peaking, lowShelf, highShelf, lowPass, highPass, notch ... }
  ```
- Storage: JSON files in `Application Support/SonarForge/Profiles/` for easy import/export + UserDefaults for last used / favorites index.
- Import formats: AutoEQ parametric text, JSON, and a simple "GraphicEQ" line parser (common on AutoEQ).

## UI Layer

- **Main Window**: `ContentView` with:
  - Large frequency response `Canvas` or custom `FrequencyResponseView` (draws curve + control points).
  - Band list (editable table or cards).
  - Preamp + master fader.
  - Pre + post spectrum overlay (always on).
  - Profile picker + A/B / Bypass controls.
- **Status Item**: `NSStatusBar` item with popover or menu. Minimal icon that reflects bypass state.
- **Profile Importer Sheet**: Paste box + file drop for AutoEQ data. Parser lives in a dedicated `AutoEQImporter` (pure function or actor).
- All state owned by an observable `AppModel` / `AudioManager` actor or `@Observable` class. Audio engine is injected as a dependency.

## Concurrency & Threading

- Audio render: Highest priority, real-time constraints. Minimal work.
- UI: Main actor.
- Background: Profile loading, import parsing, file I/O, device enumeration.
- Communication: 
  - Parameters: Atomic or lock-free ring buffer / `ManagedAtomic` + a "pending params" snapshot swapped at buffer boundaries.
  - Analysis data: Dedicated lock-free queue or `AsyncStream`.
  - Commands (load profile, bypass): Sent via actor messages or Combine subjects observed from audio side at safe points.

## Device & Format Handling

- Listen to `kAudioDeviceProperty...` notifications and `AVAudioEngine` route change notifications.
- Preferred strategy: When output device or sample rate changes, pause processing, reconfigure tap + output engine to the new format, resume with a brief ramp.
- Support common rates: 44100, 48000, 88200, 96000. For exotic rates, either resample (AVAudioConverter with high quality) or warn the user.

## Permissions & Entitlements

- The app must declare appropriate usage strings and request "Screen & System Audio Recording".
- Entitlements file will include audio-related capabilities.
- On first use of the tap, the system presents the standard TCC prompt. The app must handle denied state gracefully (show clear instructions + "Open Privacy Settings" button).

## Testing Strategy

- Unit tests for DSP: Coefficient calculation accuracy, filter stability (impulse response, step response, known RBJ cases), denormal handling.
- Integration tests (where possible without hardware): Mocked buffer processing, profile roundtrips.
- Manual audio validation: Use calibrated test tones, known music tracks, and measurement tools (e.g. REW, Room EQ Wizard) where practical.
- UI tests for critical flows (profile import, bypass toggle).

## Risks & Mitigations (High Level)

- **CATap limitations** (DRM content, certain apps, AirPlay, exclusivity): Document clearly. Provide user guidance. Consider future hybrid with a virtual device for power users (deferred).
- **Render underflow / glitches on device switch**: Careful teardown + ramping. Provide "Safe Mode" (higher buffer sizes).
- **Numerical issues in filters at extreme settings**: Rigorous coefficient validation + test suite + headroom management.
- **CPU on older M1 under heavy band counts**: Limit max bands (e.g. 12–16) or provide CPU usage indicator. Profile early.
- **Permission fatigue / support burden**: Excellent in-app guidance and troubleshooting view.

## Future Directions (Post-MVP, Explicitly Out of Scope for Initial Releases)

- Optional lightweight FIR / linear-phase modes (if user demand + easy implementation).
- AUv3 hosting for users who want additional processing.
- Per-process exclusion list or advanced tap configuration.
- Export of measured response curves.
- AppleScript / Shortcuts support.

## References

- Apple: "Capturing system audio with Core Audio taps" (developer.apple.com)
- Audio EQ Cookbook (Robert Bristow-Johnson)
- Accelerate vDSP documentation
- iqualize (open source CATap-based EQ) as a modern reference implementation for tap usage patterns

---

This architecture prioritizes long-term maintainability and audio quality over breadth. Changes to the audio path require strong justification and performance evidence.
