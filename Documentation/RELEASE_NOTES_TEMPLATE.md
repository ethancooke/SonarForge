# SonarForge vX.Y.Z

> One-sentence summary of the release.

## Requirements

- macOS 14.2 or later, Apple Silicon (M1 or newer). No Intel support.
- "System Audio Recording" permission (requested on first engine start).

## New

-

## Fixed

-

## Known Limitations

- Apps using exclusive audio access or certain DRM paths may bypass the system
  tap (Netflix in a browser is confirmed working; some protected players may not).
- A brief gap is expected while switching output devices (the capture path is
  rebuilt with a fade).
- AirPlay output behavior is untested.

## Checksums

- `SonarForge.app.zip` — `shasum -a 256`: `…`

## Attribution

Headphone corrections via the [AutoEQ project](https://autoeq.app) and the
measurement community (oratory1990 et al.). Inspired in part by
[eqMac](https://github.com/bitgapp/eqMac) (Apache 2.0). Licensed under the
Apache License 2.0.
