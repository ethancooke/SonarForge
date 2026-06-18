# Contributing to SonarForge

Thank you for your interest in contributing. SonarForge aims to be a focused, high-quality, maintainable open-source macOS audio tool. We value clean architecture, rigorous attention to real-time audio correctness, and a native SwiftUI experience.

## Code of Conduct

Be respectful, constructive, and patient. Audio is subtle; disagreements about DSP choices or UX should be evidence-based and kind.

## Development Philosophy

- **Audio quality and stability are non-negotiable**. Performance regressions or audible artifacts must be treated as release blockers.
- Keep the scope narrow (see README Non-Goals). Large or out-of-scope feature requests may be declined or deferred so the core stays excellent.
- Prefer simple, well-tested solutions over clever ones.
- All changes to the audio path require clear justification and, ideally, before/after measurements or listening notes.

## Getting Started

1. Fork and clone.
2. Ensure you are on macOS 14.2 or later with Xcode 16+ on Apple Silicon (M1 or newer). Intel Macs are not supported.
3. Read [ARCHITECTURE.md](ARCHITECTURE.md), [Documentation/AUDIO_PATH.md](Documentation/AUDIO_PATH.md) (the authoritative audio-path reference), and [STATE.md](STATE.md) for current status.
4. Build: `open SonarForge.xcodeproj` and run (⌘R). Grant the System Audio Recording permission when prompted. If you change build settings, edit `project.yml` and run `xcodegen generate` — the project file is generated, never hand-edited.
5. Play some audio from another app and verify passthrough works before making changes.

## Quality gates (run these before opening a PR)

- **Tests**: `xcodebuild -project SonarForge.xcodeproj -scheme SonarForge -destination 'platform=macOS,arch=arm64' test` — all must pass. New DSP/profile/parser logic needs tests.
- **Lint**: `swiftlint lint Sources` (`brew install swiftlint`) — errors fail CI; warnings are advisory. The config (`.swiftlint.yml`) deliberately allows DSP math notation (`b0`, `a1`, `A`, …).
- CI runs both on every push and PR; PRs must be green to merge.

## Branching & PRs

- Use short-lived feature branches from `main`.
- PR titles should be descriptive (e.g. "DSP: Improve peaking filter coefficient stability at low Q").
- Include:
  - Description of the change and motivation.
  - Audio impact notes if the change touches DSP or the render path.
  - Screenshots or recordings for UI changes.
- Keep PRs focused. Large refactors should be discussed in an issue first.

## Commit Messages

Follow conventional style where practical:

```
DSP: Add notch filter type with proper RBJ coefficients

- Add FilterType.notch case
- Include unit test for known 1 kHz notch at 48 kHz
- Verified no regression in existing peaking response
```

## Testing

- Add or update unit tests for any DSP math.
- For audio engine changes, describe manual verification steps in the PR (content used, devices, sample rates, bypass behavior).
- Use Instruments (CPU, System Trace, Audio) on real workloads.

## Style & Organization

- Follow Apple's Swift API Design Guidelines.
- Keep the audio engine (`Sources/.../Audio` and `DSP`) free of SwiftUI and AppKit dependencies.
- Use value types (`struct`) for profiles, bands, and DSP state where possible.
- Prefer `os.Logger` over `print` for production code.
- Document public or tricky interfaces with concise comments.

## DSP Contributions

When contributing filters or processing changes:

1. Reference the algorithm or cookbook used (RBJ, etc.).
2. Provide test cases that can be run deterministically.
3. Consider edge cases: fs/2, very low frequencies (< 20 Hz), extreme Q or gain.
4. Measure and note CPU cost (per band or for a typical 8-band profile).

## UI / Accessibility

- All interactive elements must be keyboard accessible and have good VoiceOver labels.
- New windows or sheets should restore size/position reasonably.
- Respect "Reduce motion" and other accessibility settings where relevant.

## Attribution

If your contribution is based on a specific technique or open-source code (for example, Apple's sample code), add clear attribution in code comments and update the README "Thanks" section if appropriate.

## Questions & feature ideas

- Open an **issue** for bugs and specific, scoped feature requests.
- For usage questions or broad ideas, open an issue too (or a Discussion, if the repo has them enabled).
- For anything touching the audio path or architecture, flag it early so it can be discussed before you build.

## Release Process (Maintainers)

- Versioning: SemVer. Breaking audio behavior changes warrant a major bump or, at minimum, clear migration notes.
- Sanity-check a release by listening across a few content types and output devices before publishing.
- Tag a version (`git tag vX.Y.Z && git push origin vX.Y.Z`); CI builds, signs, and notarizes a draft release. Fill the notes from `Documentation/RELEASE_NOTES_TEMPLATE.md` and publish.

---

**Thank you for helping make precise, native, free system EQ a reality on macOS.**
