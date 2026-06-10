# Getting Started with SonarForge Development

This guide helps new contributors (or future you) get a working development environment quickly.

## Prerequisites

- macOS 14.2 or later (14.4+ recommended for Core Audio Tap stability and reliability)
- Apple Silicon Mac (M1 or newer) — **required** (no Intel support)
- Xcode 16 or later (latest recommended)
- Basic familiarity with Core Audio concepts is extremely helpful

## 1. Clone & Open

```bash
git clone https://github.com/<org>/SonarForge.git
cd SonarForge
open SonarForge.xcodeproj
```

**Important**: See [Documentation/Xcode-Setup.md](Xcode-Setup.md) for the exact deployment target (14.2) and architecture settings (arm64 only) that must be applied when creating or configuring the project.

## 2. First Build & Run

1. Select the `SonarForge` scheme.
2. Build and run (⌘R).
3. On first launch the app will request **Screen & System Audio Recording** permission.
   - This is required for Core Audio Taps to capture system output.
   - Go to **System Settings → Privacy & Security → Screen & System Audio Recording** and ensure SonarForge is enabled if the prompt does not appear or is denied.

## 3. Verify the Audio Path (Critical)

Before doing any DSP or UI work:

1. Play audio from Music, Safari (YouTube), or another app.
2. In SonarForge, ensure the output device is set to your headphones/speakers.
3. Toggle the global bypass.
4. You should hear **no difference** (or extremely minimal) when bypassed, and the processed path should be clean with no dropouts, clicks, or change in volume/timing.

If you hear problems at this stage, stop and fix the audio engine before proceeding.

## 4. Useful Debugging Tools

- **Console.app**: Filter by `SonarForge` or subsystem.
- **Instruments**:
  - Audio: System Trace, Core Audio
  - CPU profiling while playing demanding content
- **Audio MIDI Setup**: For inspecting sample rates and creating aggregate devices for testing.
- **Activity Monitor**: Energy and CPU impact.

## 5. Common First-Run Issues

- **No sound after enabling processing**: Check that the output device in SonarForge matches your actual listening device. Device switch handling may still be in development.
- **Permission prompt never appears**: The prompt is usually shown the first time a tap is created that requires an aggregate device internally. Try playing audio and toggling processing.
- **Certain apps are not affected**: Some apps use exclusive mode, private audio paths, or DRM-protected content (e.g. certain streaming video). This is a known limitation of the tap approach. Document it.

## 6. Next Steps for Contributors

1. Read [ARCHITECTURE.md](../ARCHITECTURE.md) thoroughly.
2. Read the current phase in [DEVELOPMENT_PLAN.md](../DEVELOPMENT_PLAN.md).
3. Pick a chunk that matches your interest and the current "in progress" state.
4. For audio/DSP work, start by understanding the current engine implementation in `Sources/SonarForge/Audio` and `DSP`.

## 7. Asking for Help

Open a Discussion or Issue with:
- macOS version + chip
- Exact reproduction steps
- Console logs (redacted if necessary)
- Whether the issue happens with bypass on or off

Welcome aboard — precise audio is hard, and your help is appreciated.
