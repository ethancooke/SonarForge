#!/usr/bin/env bash
# Live acoustic EQ verification through the real audio path:
#   -3 dBFS 1 kHz tone + a +2 dB peaking EQ profile @ 1 kHz
#   → the post-EQ spectrum must read ≈ -1 dBFS at 1 kHz
#   → post − pre (the EQ's measured contribution) must be ≈ +2.0 dB.
#
# (Digital full scale is 0 dBFS, so "+3 dBFS in, +5 dBFS out" can't exist in a
# real WAV — this is the same arithmetic anchored 6 dB lower.)
#
# Uses the app's own calibrated spectrum analyzer as the measuring instrument:
# the probe line with the strongest pre level is the tone (later lines may be
# post-tone room silence).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="/tmp/sonarforge_acoustic_test"
PROBE_FILE="$OUT_DIR/spectrum_probe.log"
EXPECTED_POST=-1.0
POST_TOLERANCE=1.5   # absolute level absorbs FFT scalloping + tap-path details
DELTA_TOLERANCE=0.5  # the EQ contribution itself must be tight

python3 "$ROOT/Scripts/acoustic_eq_verify.py" "$OUT_DIR"

APP=$(find ~/Library/Developer/Xcode/DerivedData/SonarForge-*/Build/Products/Debug/SonarForge.app -maxdepth 0 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  echo "Building Debug app..."
  (cd "$ROOT" && xcodebuild build -scheme SonarForge -destination 'platform=macOS' -quiet)
  APP=$(find ~/Library/Developer/Xcode/DerivedData/SonarForge-*/Build/Products/Debug/SonarForge.app -maxdepth 0 | head -1)
fi

pkill -f 'SonarForge.app/Contents/MacOS/SonarForge' 2>/dev/null || true
sleep 1
rm -f "$PROBE_FILE"

echo "Launching SonarForge with +2 dB @ 1 kHz profile..."
open -a "$APP" --args \
  --import-profile "$OUT_DIR/profile_plus2_1khz.json" \
  --autostart-engine \
  --debug-log-spectrum-file "$PROBE_FILE"

sleep 5   # engine start + permission settle

echo "Playing -3 dBFS 1 kHz tone..."
afplay "$OUT_DIR/tone_1khz_minus3db.wav"
sleep 2

pkill -f 'SonarForge.app/Contents/MacOS/SonarForge' 2>/dev/null || true

if [[ ! -s "$PROBE_FILE" ]]; then
  echo "FAIL: No spectrum probe output. Engine may not have started (check the"
  echo "      System Audio Recording permission / stale-TCC wedge in AUDIO_PATH.md)."
  exit 1
fi

echo "--- probe log ---"
cat "$PROBE_FILE"

# The tone is the probe line with the strongest pre level.
LOUDEST=$(awk '
  /probe bin=/ {
    pre = $0; sub(/.*pre=/, "", pre); sub(/ .*/, "", pre)
    if (pre + 0 > best + 0 || best == "") { best = pre; line = $0 }
  }
  END { print line }
' "$PROBE_FILE")

if [[ -z "$LOUDEST" ]]; then
  echo "FAIL: probe log has no probe lines."
  exit 1
fi

PRE=$(echo "$LOUDEST" | sed -n 's/.*pre=\([^ ]*\).*/\1/p')
POST=$(echo "$LOUDEST" | sed -n 's/.*post=\([^ ]*\).*/\1/p')
BIN=$(echo "$LOUDEST" | sed -n 's/.*bin=\([0-9]*\).*/\1/p')
DELTA=$(python3 -c "print(round(float('$POST') - float('$PRE'), 2))")
# Display-bin center frequency: 20 * 1000^((bin + 0.5) / 64)
FREQ=$(python3 -c "print(round(20 * (1000 ** (($BIN + 0.5) / 64.0))))")

echo ""
echo "=== Acoustic EQ Verification ==="
echo "Input tone:      -3.0 dBFS @ 1 kHz"
echo "EQ profile:      +2.0 dB peaking @ 1 kHz"
echo "Expected post:   ${EXPECTED_POST} dBFS (±${POST_TOLERANCE})"
echo "Expected delta:  +2.0 dB (±${DELTA_TOLERANCE})"
echo "Measured bin:    $BIN (~${FREQ} Hz)"
echo "Measured pre:    ${PRE} dBFS"
echo "Measured post:   ${POST} dBFS"
echo "Measured delta:  ${DELTA} dB"

python3 - "$POST" "$DELTA" "$EXPECTED_POST" "$POST_TOLERANCE" "$DELTA_TOLERANCE" "$FREQ" <<'PY'
import sys
post, delta, expected, post_tol, delta_tol, freq = map(float, sys.argv[1:])
ok_freq = 800 <= freq <= 1250
ok_post = abs(post - expected) <= post_tol
ok_delta = abs(delta - 2.0) <= delta_tol
if ok_freq and ok_post and ok_delta:
    print("RESULT: PASS")
    sys.exit(0)
print("RESULT: FAIL")
if not ok_freq:
    print(f"  loudest bin at {freq:.0f} Hz — expected the 1 kHz tone to dominate")
if not ok_post:
    print(f"  post {post:.2f} dBFS not within ±{post_tol} of {expected:.1f}")
if not ok_delta:
    print(f"  EQ delta {delta:.2f} dB not within ±{delta_tol} of +2.0")
sys.exit(1)
PY