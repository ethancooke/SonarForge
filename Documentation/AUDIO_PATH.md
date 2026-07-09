# Audio Path Implementation Notes (Chunk 1.1)

This document describes the exact technique used for system audio capture →
passthrough → output, the threading model, and measured characteristics, as
first written for the Chunk 1.1 exit criteria and kept current as the audio path evolved.

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

## Gain Staging & Bypass Semantics (Chunk 1.2)

After the copy pass, the render block applies one smoothed gain:

- **Targets**: preamp and output gain are published from the UI as linear-gain
  Float bit patterns in `ManagedAtomic<UInt32>` (relaxed loads/stores). The
  engine clamps to ±24 dB; the UI exposes ±12 dB.
- **Smoothing**: a per-sample one-pole smoother (`g += k·(target − g)`,
  τ = 15 ms) eliminates zipper noise on fader moves. Initializing the smoother
  at 0 on engine start doubles as the start fade-in (~45 ms to 95%), replacing
  the previous linear ramp.
- **Bypass** (`ManagedAtomic<Bool>`): bypassed ⇒ target = unity (all gains
  excluded); active ⇒ target = preamp × output gain. Toggling is therefore a
  click-free ~15 ms crossfade between processed and untouched levels.
- **Unity fast path**: when the smoother has settled at 1.0 and the target is
  1.0 (bypassed, or all gains at 0 dB), the gain pass is skipped entirely —
  bypass provably does not touch samples.
- **Headroom**: no always-on limiter (see DECISIONS.md D-009); negative preamp
  is the headroom mechanism, per AutoEQ convention.
- The EQ will sit between the preamp and output gain stages from Chunk 2.2;
  the two targets are kept separate for exactly that reason even though they
  currently collapse into one multiply.

Profile loads and A/B swaps apply the profile's `preamp` value, so A/B state
includes gain as required by the Chunk 1.2 deliverables.

## Parametric EQ (Chunks 2.1 / 2.2)

- **Processor**: `RealtimeParametricEQ` — up to 16 cascaded DF2T biquads over
  the first stereo output buffer, Double state, Float32 samples, per-buffer
  denormal flush. Coefficients come from `BiquadCoefficients` (RBJ formulas,
  inputs clamped: freq [10 Hz, 0.49 fs], Q [0.025, 40], gain ±24 dB, shelf
  radicand floored strictly positive so poles stay inside the unit circle).
- **Parameter path** (D-010): lock-free SPSC command ring. The control queue
  computes coefficients and pushes set-coefficients / set-band-count /
  reset-state commands; the render thread drains them at the top of every IO
  cycle (even while bypassed, so coefficients are current when bypass lifts).
- **Render order**: copy pass → EQ (skipped when bypassed; state reset on the
  bypass→active transition, masked by the gain crossfade) → smoothed combined
  gain. The EQ is linear, so combined preamp×output gain after it is exactly
  equivalent to preamp-before/output-after until a nonlinear stage exists.
- **Restart behavior**: the engine re-applies the current bands at the actual
  output rate on every start, so device/sample-rate changes recompute
  coefficients correctly.
- **Limitations (MVP)**: EQ applies to the first 2-channel output buffer;
  other stream layouts pass through with gain only.
- **Measured**: 12 bands at 48 kHz stereo cost **0.29 % of one core**
  (optimized build, Apple Silicon; ~4.6 % in Debug from bounds checks —
  the unit-test bound guards regressions, the Release number is the target).
- **Live integration**: the EQ runs in the live render path, driven by the saved
  profile / AutoEQ system (Phase 4).

## Spectrum Analysis (Chunk 3.1)

- **Realtime taps**: pre-EQ (raw system mix, post-copy) and post (post-EQ,
  post-gain — what reaches the hardware). One relaxed atomic read gates all
  cost; when enabled, the block mixes the stereo buffer to mono into two
  lock-free SPSC `SampleRing`s (drops when full — analysis is best-effort and
  never touches playback correctness).
- **Analysis**: a 20 Hz `DispatchSourceTimer` on a utility queue drains the
  rings into rolling 4096-sample windows and runs `SpectrumProcessor`
  (Hann window → vDSP real DFT → power → dBFS calibrated so a full-scale sine
  reads 0 dB → max-power reduction into 64 log-spaced bins, 20 Hz–20 kHz).
- **Delivery**: snapshot callback → AppModel hops to the main actor →
  `SpectrumSection`/`SpectrumView` (Canvas polylines). The spectrum view is
  observation-isolated: level updates re-evaluate only that view. (Lesson
  learned: routing the arrays through the full ContentView body cost ~34 %
  CPU in Debug; isolation + 20 Hz brought the whole app back to ~0.3 %.)
- **Layout lesson (2026-06-11 toggle-lag fix)**: `HSplitView` panes are
  independent AppKit layout worlds — keep the band sidebar in its own pane so
  left-pane toggles never re-measure the AppKit-backed band-row fields (that
  cross-measurement was ~150 ms of `sizeThatFits` per click). Also: observe
  AppModel only in leaf views (`SpectrumToggles`, `LegendOverlay`), keep the
  band list a `ScrollView`+`LazyVStack` (a `List` re-measures expensively), and
  compute the EQ response curve in `body`, *captured* by the Canvas closure —
  never inside it, or resize animations redo the biquad math every frame.
  Measured (Debug, audio playing): Pre/Legend toggles ~72 ms, panel collapse
  ~35 ms.
- **Visualizer perf (2026-07-08)**: Canvas modes and Reactor must stay cheap
  enough that band edits / panel toggles / gain sliders remain snappy while a
  visualizer is live. Lessons:
  - **Main-thread freeze**: `MTKView.draw(in:)` and SwiftUI `Canvas` both
    depend on the main run loop. Any button/slider tracking stalls them even
    when the control does not touch audio — felt as "the visual pauses when I
    click anything." Fix: a thread-safe `SpectrumFeed` published from the
    analyzer callback (before the MainActor hop), plus **CVDisplayLink**
    renderers that poll the feed on a dedicated queue.
  - **Inactive-but-visible**: do **not** pause on `willResignActive`. Keep
    animating while the window is on-screen (another app may be frontmost);
    pause only when hidden / miniaturized / fully occluded. Bars/LED also run
    a 30 Hz fallback timer because `CVDisplayLink` is often throttled for
    non-frontmost apps (Metal/Reactor is less affected).
  - **Slider-drag isolation**: continuous controls (crossfeed amount, gain)
    must not rewrite `currentProfile` / re-render ContentView every tick —
    that main-thread body work starved bars/LED presents. Crossfeed amount
    uses local `@State` + engine-only updates during drag; profile commit on
    gesture end. Gain/crossfeed live in leaf panels (`GainStagingPanel` /
    `CrossfeedPanel`).
  - **Reactor**: `CAMetalLayer` + off-main CVDisplayLink (not `MTKView`);
    feedback targets capped at a 720 px long edge; ~30 fps pacing. Present
    still fills the full layer.
  - **Bars / LED / Spectrogram**: `NSView` + CVDisplayLink (+ fallback timer)
    rasterize to a capped-resolution `CGImage` on a background queue and set
    `layer.contents` **off the main thread** (actions disabled). Spectrogram
    keeps a scrolling BGRA buffer (not thousands of Canvas rects).
- **Enablement**: both pre and post traces are always shown — there are no
  user-facing toggles. A single relaxed atomic still gates the whole cost,
  driven by view visibility (below): when the spectrum view is off screen the
  IO block's atomic reads false and the timer idles.
- **Visibility gating (Chunk 6.2)**: analysis also stops when the spectrum view
  is not on screen (window closed → menu-bar use). With *continuous* audio the
  full pipeline (2× FFT + 20 Hz redraw) measured 6–17 % CPU in Debug — earlier
  near-zero readings were intermittent test tones leaving most ticks idle.
  Display-only work should never run without a display.
- Analyzer starts/stops with the engine and is recreated at the device rate.

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
  in the UI with "Open Privacy Settings" + "Retry" on failure.

## Permission

The system shows the **System Audio Recording** TCC prompt automatically on
first tap IO (the `NSAudioCaptureUsageDescription` string is in Info.plist).
There is no public preflight API for this TCC class; if the user denies, the
tap may deliver silence rather than fail, so the app tells users to check
Privacy & Security if they hear nothing.

**Dev gotcha (observed 2026-06-10)**: after a rebuild, the ad-hoc signature can
stop matching the stored TCC entry. The symptom is the engine hanging forever
in `.starting` — `AudioDeviceCreateIOProcIDWithBlock` blocks inside coreaudiod
waiting on consent that never displays. Fix:
`tccutil reset All com.sonarforge.SonarForge`, relaunch, re-grant.

**Start watchdog (added 2026-06-10)**: if a start attempt has not reached
`.running` (or `.failed`) within 10 s, a watchdog on a separate queue reports
`.failed` to the UI via `onStateChange`, with a message naming the System Audio
Recording permission and the `tccutil reset` workaround. Limitation: the
blocked Core Audio call cannot be cancelled, so the watchdog only *surfaces*
the hang — `controlQueue` stays wedged inside coreaudiod, and any queued
`stop()`/`start()` (e.g. the UI's "Retry") only runs if coreaudiod eventually
returns. The reliable recovery remains the `tccutil` reset plus a relaunch. If
a wedged start does later complete, the engine emits `.running` and the UI
recovers automatically.

## Known Limitations (expected, documented)

- Some DRM-protected content and exclusive-mode apps may not be captured.
  Confirmed working: Netflix in the browser (2026-06-10). Untested: Apple
  Music / FairPlay-protected playback.
- AirPlay output behavior is untested.
- **Voice/video calls on speakers**: the engine mutes each app's direct output
  and re-renders an EQ'd, ~10 ms-delayed copy, which defeats the acoustic echo
  cancellation in conferencing apps (Discord, Zoom, Teams, …) — the far end can
  hear themselves echoed. Bypass does **not** help (it still re-renders); only
  stopping the engine (tap destroyed → original output unmuted) or using
  headphones restores AEC. Possible future mitigation: exclude communication
  apps from the tap via `CATapDescription`'s process-exclusion list, or auto-pause
  the engine when a capture session is active.
- A brief gap (not a glitch) is expected during device switch rebuilds; teardown now ramps to silence (~40 ms, Chunk 6.1) so stops and rebuilds don't click.

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

## Validation Status (Chunk 1.1 acceptance checklist)

| Item | Status |
|---|---|
| Clean passthrough on built-in output (44.1 kHz device) | ✅ confirmed by listening (2026-06-09) |
| Permission prompt flow (grant → audio flows) | ✅ confirmed |
| Start while music already playing | ✅ confirmed |
| Engine on/off toggle | ✅ works; expected millisecond-scale dip at the tap/direct-path handoff |
| Bypass toggle audibly seamless | ✅ toggled live (2026-06-10), no artifacts reported; re-verify when EQ makes the branch meaningful (Chunk 2.2) |
| Clean quit returns audio to system path | ✅ confirmed |
| Clean passthrough at 48 kHz device setting | ✅ External Headphones @ 48 kHz, rate-matched tap, sounded clean (2026-06-10) |
| Output device switch while running | ✅ in-app picker, system-default change, and rapid back-to-back switches: ~60–100 ms rebuild each, brief gap only, no clicks/garbage (2026-06-10) |
| DRM content behavior documented | ✅ Netflix (browser DRM) **is captured** and passes through cleanly — the device-switch session ran on Netflix audio (2026-06-10). Apple Music / FairPlay still untested. |
| No memory growth over 30+ min | ✅ 35-min soak passed (2026-06-10): RSS flat/declining, CPU ~0 %, no audio-code leaks |
| USB DAC / external interface / Bluetooth | ⏳ deferred until hardware is at hand (low risk: speakers↔headphones already exercises device/rate changes); fold into Chunk 6.1 hardening |

**Phase 6.2 soak (2026-06-11, ended early at user request)**: 10 min with the
4-band Rock profile + spectrum + real music playing: RSS 149 → 141 MB (−8.4 MB,
no growth), leaks 288 / 14.4 KB (matches the Phase 1 framework-only baseline,
not growing). CPU 6–17 % Debug under continuous music exposed the spectrum
visibility gap fixed above.

**Acoustic end-to-end EQ verification (2026-06-11)**: −3 dBFS 1 kHz tone played
through the live path (afplay → tap → aggregate → render block → EQ) with a
+2 dB peaking profile @ 1 kHz, measured by the app's calibrated spectrum
analyzer (`Scripts/run_acoustic_eq_test.sh`): pre −3.08 dBFS, post −1.08 dBFS,
**delta exactly +2.00 dB** at display bin 36 (~1 kHz); clean −100 dB floor
before/after the tone. The EQ applies precisely its stated gain end to end.
(Note: digital full scale is 0 dBFS, so the "+3 in, +5 out" form of this test
is run anchored 6 dB lower; the delta is the invariant.)

**Bug found & fixed during validation (2026-06-10)**: switching output devices
while running silently killed the engine — `stopOnQueue()` left `state ==
.running`, so the rebuild's reentrancy guard refused to start. Audio continued
via the direct path (tap destroyed → mute lifted), masking the failure while
the UI claimed "Running". Fix: `stopOnQueue()` now resets state to `.idle`.
All switch paths re-validated after the fix (five consecutive clean rebuilds).
