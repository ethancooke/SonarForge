# Audio Path Implementation Notes (Chunk 1.1)

This document describes the exact technique used for system audio capture →
passthrough → output, the threading model, and measured characteristics, as
required by the Chunk 1.1 exit criteria in `CHUNK1_IMPLEMENTATION_GUIDE.md`.

## Technique

The engine (`Sources/SonarForge/Audio/AudioEngine.swift`) uses a **process tap +
private aggregate device + single HAL IOProc**. This is the pattern from Apple's
"Capturing system audio with Core Audio taps" material, rather than an
`AVAudioEngine` graph (see DECISIONS.md D-007 for why).

1. **Tap** — `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])`
   - Global stereo mixdown of every process *except* SonarForge itself. The
     exclusion list takes Core Audio process objects, not PIDs; our PID is
     translated via `kAudioHardwarePropertyTranslatePIDToProcessObject`.
     Excluding ourselves is what prevents a feedback loop.
   - `muteBehavior = .muted`: the tapped processes' audio no longer reaches the
     hardware directly — SonarForge's re-rendered stream is the only audible path.
   - `isPrivate = true`: the tap is not visible to other tapping clients.
   - Created with `AudioHardwareCreateProcessTap` (macOS 14.2+), destroyed with
     `AudioHardwareDestroyProcessTap`.

2. **Aggregate device** — `AudioHardwareCreateAggregateDevice` with:
   - The user's output device as the only subdevice and clock master
     (`kAudioAggregateDeviceMainSubDeviceKey`, drift compensation off).
   - The tap in `kAudioAggregateDeviceTapListKey` with
     `kAudioSubTapDriftCompensationKey = true`, so the HAL resamples the tap to
     the output device clock.
   - `kAudioAggregateDeviceIsPrivateKey = true` (invisible to the user and other apps),
     `kAudioAggregateDeviceTapAutoStartKey = true`.

3. **IO** — one `AudioDeviceCreateIOProcIDWithBlock` on the aggregate (nil
   dispatch queue → the HAL's realtime IO thread). Each cycle the block receives
   the tap's buffers as input and the output device's buffers as output:
   - Zero all output buffers (never ship stale memory).
   - Copy input → output. Equal channel counts use `memcpy`; mismatched counts
     map the first `min(in, out)` channels frame by frame (Float32 assumed — the
     HAL's canonical IOProc format).
   - A ~30 ms linear fade-in after each engine start masks start transitions.

4. **Buffer size** — 512 frames requested on the aggregate (~10.7 ms at 48 kHz).
   Non-fatal if the HAL refuses.

## Bypass Semantics (Chunk 1.1)

The bypass flag is a `ManagedAtomic<Bool>` (swift-atomics) written from the UI
and read with a relaxed load at the top of each IO cycle. In Chunk 1.1 the
bypassed and active paths are **the same bit-identical copy** — there is no EQ
yet — so toggling bypass is guaranteed artifact-free by construction. The EQ
will occupy the non-bypassed branch in Chunk 2.2; the toggle mechanism
(atomic flag + branch) is already in place and exercised.

## Threading Model

| Concern | Where it runs |
|---|---|
| Engine control (start/stop/reconfigure, all Core Audio object lifecycle) | `controlQueue` — private serial DispatchQueue, QoS userInitiated |
| Render | HAL realtime IO thread. No allocations, locks, or ObjC; only memset/memcpy, pointer math, and one relaxed atomic load |
| Device-change notifications | Listener blocks delivered on `controlQueue`; trigger a debounced (300 ms) stop+start |
| State → UI | `onStateChange` callback fired from `controlQueue`; `AppModel` hops to the main actor |
| Bypass / future parameters | Atomics (swift-atomics); never locks shared with the render thread |

The realtime block is built by a static factory that captures *only* a small
`RenderContext` (atomic flag + ramp counters) — provably no `self`, no Core
Audio IDs, nothing that can allocate or retain on the render thread. Ramp
counters are armed on `controlQueue` strictly before `AudioDeviceStart` and
afterwards touched only by the render thread.

## Device & Error Handling

- Output device selectable by UID; `nil` follows the system default.
- Listeners: default-output changed (when following default), device alive
  (selected device unplugged), nominal sample rate changed. All trigger a
  debounced full engine rebuild — simple and safe; finer-grained recovery can
  come in Chunk 6.1.
- Engine state machine: `idle → starting → running / failed(reason)`, surfaced
  in the debug UI with "Open Privacy Settings" + "Retry" on failure.

## Permission

The system shows the **System Audio Recording** TCC prompt automatically on
first tap IO (the `NSAudioCaptureUsageDescription` string is in Info.plist).
There is no public preflight API for this TCC class; if the user denies, the
tap may deliver silence rather than fail, so the debug UI tells users to check
Privacy & Security if they hear nothing. Dev note: ad-hoc re-signing on rebuild
can cause repeated prompts.

## Known Limitations (expected, documented)

- DRM-protected content and some exclusive-mode apps may not be captured.
- AirPlay output behavior is untested.
- A brief gap (not a glitch) is expected during device switch rebuilds.

## Measured Characteristics

Measured 2026-06-09, Apple Silicon, macOS 26.5, Debug build, built-in output
device at 44.1 kHz (tap reports 48 kHz; the aggregate's drift compensation
rate-matches to the output clock).

| Metric | Value | Conditions |
|---|---|---|
| CPU (idle, engine running, no audio) | ~0.0 % | `ps`/`top` sampling over 10 s |
| CPU (audio playback) | 0.2–0.3 % | `top -l 5 -s 2` while playing system sounds |
| Memory (resident) | ~50 MB footprint / 105–131 MB RSS (Debug) | see soak below |
| Threads | 8 | includes HAL IO thread |

**35-minute soak (2026-06-10, Debug build, engine running with continuous quiet
audio):** process stable for the full duration; RSS *declined* from ~131 MB to
~105 MB (no growth); CPU ~0.0 % at every per-minute sample; `leaks` reported
282 leaks / 14 KB total — all AppKit/XPC framework one-timers (NSArray/NSSet/
NSXPCConnection), none in audio code, and not growing. Raw data:
`/tmp/sonarforge_soak.csv` methodology in repo history.

## Validation Status (checklist from CHUNK1_IMPLEMENTATION_GUIDE.md §6)

| Item | Status |
|---|---|
| Clean passthrough on built-in output (44.1 kHz device) | ✅ confirmed by listening (2026-06-09) |
| Permission prompt flow (grant → audio flows) | ✅ confirmed |
| Start while music already playing | ✅ confirmed |
| Engine on/off toggle | ✅ works; expected millisecond-scale dip at the tap/direct-path handoff |
| Bypass toggle audibly seamless | ⏳ needs explicit A/B confirmation (should be perfectly gapless — identical code path) |
| Clean quit returns audio to system path | ✅ confirmed |
| Clean passthrough at 48 kHz device setting | ⏳ pending |
| USB DAC / external interface | ⏳ pending |
| Output device switch while running | ⏳ pending |
| DRM content behavior documented | ⏳ pending |
| No memory growth over 30+ min | ✅ 35-min soak passed (2026-06-10): RSS flat/declining, CPU ~0 %, no audio-code leaks |
