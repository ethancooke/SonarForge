# Privacy

SonarForge collects **nothing**.

- All audio processing happens locally on your Mac. Audio is never recorded to
  disk, analyzed off-device, or transmitted anywhere.
- There is no telemetry, analytics, crash reporting, account system, or
  network communication of any kind in the app.
- The "System Audio Recording" permission exists solely so the macOS audio tap
  can feed the equalizer in real time; the audio stream lives only in memory
  for the milliseconds it takes to process and play it.
- Your EQ profiles are plain JSON files stored in
  `~/Library/Application Support/SonarForge/Profiles/` and never leave your
  machine unless you export and share them yourself.

If a future version ever adds an update checker, it will be opt-in and
documented here first.
