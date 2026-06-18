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

## Disclaimer

Provided "AS IS" without warranty (Apache 2.0 §7–8). EQ boosts can make audio
much louder — start at low volume with new profiles and protect your hearing
and equipment. SonarForge collects no data (see PRIVACY.md).

## Install

Open `SonarForge-X.Y.Z.dmg` and drag SonarForge to Applications. Signed and
notarized — opens with a single confirmation, no Gatekeeper workaround. A
`.zip` is also attached as an alternative.

## Checksums

- `SonarForge-X.Y.Z.dmg` — `shasum -a 256`: `…`
- `SonarForge-X.Y.Z.zip` — `shasum -a 256`: `…`

## Attribution

Headphone corrections via the [AutoEQ project](https://autoeq.app) and the
measurement community (oratory1990 et al.). Licensed under the
Apache License 2.0.
