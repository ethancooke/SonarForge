# SonarForge

**A free, open-source, native macOS system-wide parametric equalizer.**

SonarForge delivers reliable, low-CPU, artifact-free audio processing with a clean modern SwiftUI experience. It focuses on essential high-quality EQ functionality and excellent headphone profile support (especially seamless AutoEQ integration).

- **Target**: macOS 14.2 and later on Apple Silicon only (M1 and newer).
- **License**: Apache License 2.0.
- **Philosophy**: Focused essentials, native feel, zero paywalls, maximum audio fidelity.

## Features (MVP Scope)

- System-wide audio capture and processing via Core Audio Taps (driverless on supported macOS).
- High-quality parametric EQ (multiple bands, peaking, shelves, high/low pass, etc.).
- Real-time spectrum analyzer (FFT via Accelerate/vDSP).
- Headphone profile system with easy AutoEQ import.
- Profile management: save, load, export, import, favorites, quick switch.
- Preamp / output gain.
- Global bypass and A/B comparison.
- Minimal, useful menu bar / status item.
- Resizable main window, full native dark mode, excellent keyboard + VoiceOver accessibility.
- Thoughtful keyboard shortcuts.

## Non-Goals

- AU hosting or plugin chaining.
- Spatial / 3D audio or advanced effects.
- Per-app routing or mixing.
- Convolution / FIR (unless it becomes trivial later).
- Any monetization.

## Installation

1. Download the latest release from GitHub Releases (or build from source).
2. Open SonarForge. Grant "Screen & System Audio Recording" permission when prompted (required for Core Audio Taps).
3. Select your output device if needed.
4. Create or import EQ profiles (AutoEQ recommended for headphones).

## Building from Source

Requirements:
- Xcode 16+ (or latest)
- macOS 14.2 SDK (deployment target 14.2)
- Apple Silicon Mac (M1 or newer) — required for both development and runtime (no Intel support)

```bash
git clone https://github.com/<your-org>/SonarForge.git
cd SonarForge
open SonarForge.xcodeproj
```

Build the `SonarForge` scheme (Release for distribution builds).

Code signing / notarization is required for distribution outside the App Store or direct developer ID.

## Usage

- **Menu Bar**: Toggle bypass, switch profiles, open main window, access settings.
- **Main Window**: Graphical frequency response editor + band list. Drag nodes on the curve or edit numerically.
- **Profiles**: Import AutoEQ settings via the dedicated importer (paste text or load file). Attribution is preserved and displayed.
- **Shortcuts**: See the Keyboard Shortcuts section in-app (or ⌘?).

## AutoEQ Integration

SonarForge makes it easy to apply community headphone corrections from [AutoEQ](https://github.com/jaakkopasanen/AutoEQ).

1. Visit the AutoEQ project or oratory1990 measurements.
2. Copy the Parametric EQ settings (or the full text block).
3. In SonarForge → Profiles → Import from AutoEQ.
4. The profile is created with proper source attribution.

**Attribution**: All imported profiles must retain clear credit to the original measurement author and AutoEQ. SonarForge displays this prominently.

## Technical Highlights

- Audio path built on Apple's Core Audio Taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) for modern, low-overhead system capture.
- DSP implemented with carefully designed biquad IIR filters (Direct Form II Transposed) for stability and low CPU.
- Spectrum analysis uses Accelerate `vDSP` (FFT, windowing, log-frequency mapping).
- All processing is strictly local. No network calls for audio.
- Designed for sample rates 44.1 kHz – 96 kHz+ with graceful device change handling.

## Contributing

We welcome contributions that improve audio quality, stability, or the native experience. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and open issues/discussions before large changes.

Key areas:
- DSP filter quality and coefficient calculation.
- Real-time performance / CPU profiling.
- SwiftUI polish and accessibility.
- AutoEQ import robustness and profile UX.

## Attribution & Thanks

- Inspired in part by the open-source work in [eqMac](https://github.com/bitgapp/eqMac), particularly their user-space driver explorations (Apache 2.0). We have chosen a driverless Core Audio Tap path for this project.
- Apple's Core Audio team and public sample code for Audio Server Plug-ins and the Core Audio Taps documentation.
- The AutoEQ community and headphone measurement experts (oratory1990 et al.).
- Accelerate and AVFoundation teams for the excellent low-level tools.

## Disclaimer

SonarForge is provided **"AS IS"**, without warranty of any kind, and the
authors accept no liability for damages arising from its use (Apache License
2.0, §7–8). An equalizer can make audio **much louder** — large boosts or a
high preamp can overdrive headphones and speakers. Start at low volume when
trying new profiles, and protect your hearing and your equipment.

SonarForge is an independent project. It is **not affiliated with or endorsed
by** Apple, Bitgap (eqMac), the AutoEQ project, or any headphone measurement
author; their names are used only to refer to them. SonarForge does not bundle
or redistribute AutoEQ results or measurement data — it parses files you
supply, and displays their source attribution.

See [PRIVACY.md](PRIVACY.md) (short version: the app collects nothing) and
[NOTICE](NOTICE) for third-party attributions.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.

---

**SonarForge** — Precise. Native. Free.

---

**For AI agents / new contributors**: Start by reading [AGENTS.md](AGENTS.md). It points to the full recommended reading order (`VISION.md`, `DECISIONS.md`, `STATE.md`, etc.) so the project can be picked up cleanly in a new session or different tool.
