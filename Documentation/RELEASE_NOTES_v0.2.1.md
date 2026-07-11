# SonarForge v0.2.1

> Stability and safety follow-up to v0.2.0 — preamp persistence, digital clip metering, permission recovery, Frequency Response spectrum performance, and polish.

## Requirements

- macOS 14.2 or later, Apple Silicon (M1 or newer). No Intel support.
- "System Audio Recording" permission (requested on first engine start).

## New

- **Output level meter + CLIP badge** — post-gain sample-peak (−60…0 dBFS) with peak-hold. CLIP latches when any sample hits digital full scale (0 dBFS). Measures SonarForge’s float output toward Core Audio, not amp/Bluetooth/speaker clipping.
- **Frequency zone strip + band handle teaching tooltips** — quick guidance on what each range does while editing the curve.
- **Master visualizations toggle** — turn off spectrum analysis and all visualizers to save CPU/battery; EQ audio is unchanged.
- **Matrix Rain** visualization mode (spectrum-driven).

## Fixed / improved

- **Preamp is saved with the active profile** — slider changes persist, survive band edits, profile reload, and A/B compare (no longer snapped back to the old value).
- Profile **save failures** surface in the UI instead of failing silently.
- Profile import/load **caps bands at 16** and derives factory status from the catalog UUID (no spoofed built-ins; no dead 17th+ bands).
- **Bypass** help text matches real behavior (no EQ, crossfeed, or gain trim).
- Clearer **Starting… / timeout / denied** recovery (Privacy Settings, Troubleshooting, `tccutil` tip when relevant). System Audio Recording has no public preflight API — the app does **not** gate start on Screen Capture APIs.
- **Permission start gate regression** — removed a false Screen Capture preflight that could block engine start even when System Audio Recording was already granted (especially after install vs debug identity).
- **Frequency Response spectrum no longer freezes** while dragging preamp/output gain — pre/post traces use `SpectrumFeed` + display-link (same approach as bars/LED) instead of a main-thread SwiftUI Canvas.
- **Help → SonarForge Help** opens in-app Welcome (no more “Help isn’t available”).
- Stereo meters: lockstep L/R PCM and pan-aware balance; vectorscope / correlation label cleanup.
- Spectrum analysis reuses FFT scratch buffers (less alloc thrash with visualizers on).
- Debug-only restriction for `--debug-log-spectrum-file` (not in Release).
- `AppModel` / `ProfileManager` isolated to the main actor.
- UI polish: factory count copy, Flat reset by stable id, menu-bar Bypass aligned with main window, compact output meter with correct full-track colors; refreshed README hero screenshot.
- Band numeric fields use subtler dark-mode chrome (less harsh system rounded borders).

## Known Limitations

- Apps using exclusive audio access or certain DRM paths may bypass the system
  tap (Netflix in a browser is confirmed working; some protected players may not).
- A brief gap is expected while switching output devices (the capture path is
  rebuilt with a fade).
- AirPlay output behavior is untested. USB DACs and Bluetooth have been
  owner-validated on M4 Pro hardware.
- No optional output limiter yet — use the clip indicator and negative preamp
  for headroom (especially with boosted AutoEQ profiles).

## Disclaimer

Provided "AS IS" without warranty (Apache 2.0 §7–8). EQ boosts can make audio
much louder — start at low volume with new profiles and protect your hearing
and equipment. SonarForge collects no data (see PRIVACY.md).

## Install

Open `SonarForge-0.2.1.dmg` and drag SonarForge to Applications. Signed and
notarized — opens with a single confirmation, no Gatekeeper workaround. A
`.zip` is also attached as an alternative.

## Checksums

- `SonarForge-0.2.1.dmg` — `shasum -a 256`: `f90c8c736164595d5d1dc525a26e01623a6a2a372bf25408f3331948a9e8e36a`
- `SonarForge-0.2.1.zip` — `shasum -a 256`: `01ab28f85ca884e55df48cc488226d155fa8a979c48e1c5ec02fc3ea13ea7697`

## Attribution

Headphone corrections via the [AutoEQ project](https://autoeq.app) and the
measurement community (oratory1990 et al.). Licensed under the
Apache License 2.0.
