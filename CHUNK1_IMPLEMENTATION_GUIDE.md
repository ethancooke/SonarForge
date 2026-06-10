# Chunk 1.1 Implementation Guide
## Core Audio Tap Capture + Reliable Passthrough + Bypass

**Goal**: Deliver a working, stable audio path using Core Audio Taps on macOS 14.2+ that can capture system audio, optionally bypass processing, and render to the user's chosen output device with no audible artifacts under normal use.

This is the single most important chunk. Do not move on until it is solid.

---

## Step-by-Step Implementation Plan

### 1. Project & Permission Foundations (if not already done in 0.1)

- Ensure the Xcode project has deployment target **macOS 14.2** (this is the minimum where Core Audio Taps are most stable per Apple documentation and samples).
- Add the `Entitlements.entitlements` (already scaffolded) to the target.
- In `Info.plist` (or via Xcode target settings) add a clear usage description if the system shows one:
  - Key: `NSMicrophoneUsageDescription` or better, rely on the system "Screen & System Audio Recording" prompt which is triggered automatically by the tap APIs.
- Add a **Privacy** section in the app (or first-run sheet) that explains why the permission is needed and has an "Open System Settings" button.

Helper (can live in `Utilities/PermissionHelper.swift`):

```swift
import AppKit
import CoreGraphics

enum SystemAudioPermission {
    static func hasPermission() -> Bool {
        // The most reliable check for the tap permission is attempting creation or using:
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() async -> Bool {
        // This will show the system prompt if not already granted
        return CGRequestScreenCaptureAccess()
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

### 2. Create a Minimal Working Tap + Passthrough

The key reference is Apple's official sample and documentation:

- "Capturing system audio with Core Audio taps"
- Community gists that demonstrate `CATapDescription` + `AudioHardwareCreateProcessTap` + feeding the result into `AVAudioEngine`.

**Recommended concrete approach for v1 (Chunk 1.1)**:

1. Create the `CATapDescription` exactly as sketched in `AudioEngine.swift` (global, mixdown, muted, exclude own PID).
2. Call `AudioHardwareCreateProcessTap`.
3. The returned tap `AudioObjectID` can be used to create an aggregate device or can be read via lower-level `AudioDeviceCreateIOProcID` / buffer handling.

Many successful implementations (including iqualize and various gists) do one of the following:

**Option A (Simpler, recommended to start)**: Use `AVAudioEngine` with a custom input.
   - Create an aggregate device that has the tap as its input "source".
   - Or use the tap's UID with `AVAudioDevice`.

**Option B (More control)**: Use a render callback on an output unit and manually pull from the tap using `AudioObjectGetPropertyData` on the tap for the current buffer list when the tap fires, or install an IO proc on the tap device.

For the first working version, **start with Option A** using aggregate devices or the technique in the gist linked from Apple's docs. The scaffolded `AudioEngine.swift` already has comments pointing at the right direction.

**Minimal success criteria for a first passthrough**:
- Play system audio (Music.app or browser).
- When processing is "on", you hear the audio through your headphones/speakers.
- Toggling bypass produces **no change** in sound (timing, volume, timbre).
- No clicks/pops on start, stop, or bypass toggle (use short linear or raised-cosine ramps on any transition if you must crossfade).

### 3. Output Device Selection

- Enumerate available output devices using `AudioObject` property queries (`kAudioHardwarePropertyDevices`, then filter for output channels).
- Expose a simple picker in the temporary UI (or even just hard-code "use default output" initially).
- When the user (or system) changes the output device while running, the engine must:
  1. Pause / stop the current engine.
  2. Reconfigure the output node / aggregate.
  3. Restart with a brief ramp (20–50 ms fade out before teardown, fade in after).

Implement a `DeviceManager` or simple helper that listens to `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate`, and route change notifications.

### 4. Bypass Implementation (Zero or Near-Zero Cost)

Two good strategies (use both where appropriate):

A. **Structural bypass**: When bypassed, do not run the tap → process → output chain at all if possible, or simply forward the tap buffers directly to the output with no intermediate processing nodes.
B. **Render flag**: The render block checks an atomic `isBypassed` flag at the top of each buffer and does a `memcpy` / direct write of the input to the output buffers.

For the absolute cleanest bypass, many implementations temporarily stop inserting their processing and just let the tap's mute behavior + direct output handle it, or they create a direct "monitor" path.

**Important**: The user must be able to trust that "bypass" means "this app is not touching the audio in any audible way."

### 5. Error Handling & User Communication

Create a small state machine or set of published properties:

- `.idle`
- `.requestingPermission`
- `.running`
- `.failed(why: String)`
- `.deviceLost`

Surface this clearly in the UI (even a big red banner in the early chunks is acceptable).

On tap creation failure or permission denial, show:
- Clear explanation
- "Grant Permission" button that calls the request + opens settings
- "Retry" that re-attempts engine start

### 6. Testing & Validation Checklist for Chunk 1.1 Completion

Manual (do these repeatedly on real hardware):

- [ ] Clean passthrough at 44.1 kHz and 48 kHz on internal speakers / headphones.
- [ ] Clean passthrough on at least one USB DAC or external interface.
- [ ] Bypass toggle produces no audible difference or transient (use a well-known track and A/B quickly).
- [ ] Start SonarForge after music is already playing → audio should continue or recover quickly.
- [ ] Change output device in System Settings or Audio MIDI Setup while processing → recovery or graceful message.
- [ ] Play protected/DRM content (Apple Music, some streaming video) — note behavior (may be silent or un-tappable; this is expected and should be documented).
- [ ] CPU impact: < ~3–5% on M1/M2 while idle + playing normal music (use Instruments + Activity Monitor).
- [ ] No memory growth over 30+ minutes.
- [ ] App can be quit cleanly while audio is flowing; sound should return to normal system path immediately.

Automated (add as you go):
- Basic unit tests for any utility functions you extract.
- The DSP tests file already has a couple of smoke tests for the biquad (even if not wired yet).

### 7. Logging & Diagnostics

Use `os.Logger` with clear categories:
- `AudioEngine`
- `TapLifecycle`
- `DeviceManagement`
- `Permission`

Log at `.info` for major state changes, `.debug` for frequent events, `.error` for failures. Include relevant OSStatus codes.

### 8. Files You Will Most Likely Touch / Create in This Chunk

- `Sources/SonarForge/Audio/AudioEngine.swift` (the big one)
- `Sources/SonarForge/Audio/DeviceManager.swift` (or similar)
- `Sources/SonarForge/Utilities/PermissionHelper.swift`
- `Sources/SonarForge/App/AppModel.swift` (wire up the real engine instead of the protocol stub)
- Temporary debug UI in `ContentView.swift` or a new `AudioDebugView` (can be removed or hidden later)
- Possibly a small `AudioFormat+Helpers.swift`

### 9. Common Pitfalls to Avoid

- Forgetting to exclude your own process PID from the tap → immediate feedback loop / loud noise.
- Not muting the tap (`muteBehavior`) → double audio (original + processed).
- Holding the audio thread in ObjC or doing allocations / locks during render.
- Ignoring sample rate mismatches between tap and chosen output device.
- Not handling the case where the tap returns a multi-channel buffer when you only want stereo.
- Releasing the tap ID incorrectly or too late.

### 10. Exit Criteria — When Is Chunk 1.1 "Done"?

- A developer can launch the app, grant permission, play audio from other applications, hear it cleanly, toggle bypass with no audible change, and change output devices with recovery.
- The code is reasonably commented with references to Apple docs.
- There is a short `AUDIO_PATH.md` (or section in ARCHITECTURE) written by the implementer describing the exact technique used, threading model, and measured characteristics.
- All items in the manual validation checklist above have been exercised and results recorded in the PR or a comment.

---

## Stretch Goals (Only After Core Passthrough Is Solid)

- Basic preamp gain (with proper smoothing) — this actually belongs in Chunk 1.2.
- Simple spectrum analysis stub (just to prove we can tap pre/post inside the chain).
- Nice device picker UI.

**Do not start the graphical EQ editor or profile system until the above is reliable.**

---

After this chunk, the rest of the project becomes mostly "adding value on top of a working audio foundation" rather than "hoping the foundation will work."

Good luck — this is the part that separates a toy from a tool people trust for critical listening.
