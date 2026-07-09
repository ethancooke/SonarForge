# SonarForge v0.2.0

> Crossfeed, a full visualization suite, and a pop-out visualizer — still a focused system-wide parametric EQ for Apple Silicon.

## Requirements

- macOS 14.2 or later, Apple Silicon (M1 or newer). No Intel support.
- "System Audio Recording" permission (requested on first engine start).

## New

- **Per-profile headphone crossfeed** — complementary-filter design after the EQ; strength saved with each profile.
- **Visualization modes** driven by spectrum bins and post-EQ PCM:
  - Spectrum Bars, Mirrored Bars, Ghost Bars, LED Meters, Spectrogram
  - Oscilloscope, CRT Scope
  - Vectorscope (stereo width / mono image — useful with crossfeed)
  - Correlation meter, VU / PPM meters
  - Particles, Reactor (Metal audio-reactive feedback)
- **Pop-out Visualizer** window with fullscreen support (Window menu / ⌘⇧V / Pop Out).
- **Menu-bar mini spectrum** strip while the menu-bar panel is open.
- Spectrum **FFT window sized per sample rate** so low bass no longer flat-lines at 96 kHz (and other rates).

## Fixed / improved

- Visualizers stay smooth while dragging sliders and toggles (off-main draw paths, spectrum/waveform feeds).
- Switching between bar-family modes and **Particles → Reactor** remounts correctly.
- Polar Spectrum tucked from the menu (code retained); hidden-style preferences migrate to Spectrum Bars.

## Known Limitations

- Apps using exclusive audio access or certain DRM paths may bypass the system
  tap (Netflix in a browser is confirmed working; some protected players may not).
- A brief gap is expected while switching output devices (the capture path is
  rebuilt with a fade).
- AirPlay / Bluetooth / external USB DAC behavior is not fully hardware-QA’d.
- No optional output limiter yet — watch gain staging with boosted AutoEQ profiles.

## Disclaimer

Provided "AS IS" without warranty (Apache 2.0 §7–8). EQ boosts can make audio
much louder — start at low volume with new profiles and protect your hearing
and equipment. SonarForge collects no data (see PRIVACY.md).

## Install

Open `SonarForge-0.2.0.dmg` and drag SonarForge to Applications. Signed and
notarized — opens with a single confirmation, no Gatekeeper workaround. A
`.zip` is also attached as an alternative.

## Checksums

- `SonarForge-0.2.0.dmg` — `shasum -a 256`: `25a916439033e84a847c5583f4ad6dda216e82e3d59c6dab7a2216b683f34d11`
- `SonarForge-0.2.0.zip` — `shasum -a 256`: `6fc4b4bb7f8e41591788d324681d211c58b817b4fcaf3542ba17f3d86f42c062`

## Attribution

Headphone corrections via the [AutoEQ project](https://autoeq.app) and the
measurement community (oratory1990 et al.). Licensed under the
Apache License 2.0.
