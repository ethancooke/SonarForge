# Contributing to SonarForge

Thank you for your interest in contributing. SonarForge aims to be a focused, high-quality, maintainable open-source macOS audio tool. We value clean architecture, rigorous attention to real-time audio correctness, and a native SwiftUI experience.

## Code of Conduct

Be respectful, constructive, and patient. Audio is subtle; disagreements about DSP choices or UX should be evidence-based and kind.

## Development Philosophy

- **Audio quality and stability are non-negotiable**. Performance regressions or audible artifacts must be treated as release blockers.
- Keep the scope narrow (see README Non-Goals). Large feature requests will be closed or moved to a future "SonarForge Pro" discussion only after the core is excellent.
- Prefer simple, well-tested solutions over clever ones.
- All changes to the audio path require clear justification and, ideally, before/after measurements or listening notes.

## Getting Started

1. Fork and clone.
2. Ensure you are on macOS 14.2 or later with Xcode 16+ on Apple Silicon (M1 or newer). Intel Macs are not supported.
3. Read [ARCHITECTURE.md](ARCHITECTURE.md) and [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md).
4. Build the project and run it. Grant the necessary permissions when prompted.
5. Play some audio from another app and verify passthrough works before making changes.

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

If your contribution is based on a specific technique or open-source code (including portions of eqMac's driver work or Apple's samples), add clear attribution in code comments and update the README "Attribution & Thanks" section if appropriate.

## Questions & Discussions

- Use GitHub Discussions for usage questions and broad ideas.
- Use Issues for bugs and specific, scoped feature work.
- For anything touching the audio path or architecture, tag maintainers early.

## Release Process (Maintainers)

- Versioning: SemVer. Breaking audio behavior changes require a major or at least clear migration notes.
- All releases must pass manual listening tests on multiple content types and at least two different output devices (internal + external DAC or headphones).
- Update `CHANGELOG.md` (create one if it doesn't exist for the first release).

---

**Thank you for helping make precise, native, free system EQ a reality on macOS.**
