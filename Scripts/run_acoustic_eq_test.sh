#!/usr/bin/env bash
# Live acoustic EQ verification: +3 dBFS 1 kHz tone + +2 dB EQ profile → ~+5 dBFS post.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="/tmp/sonarforge_acoustic_test"
LOG_FILE="$OUT_DIR/spectrum_probe.log"
EXPECTED_POST=5.0
TOLERANCE=1.5

python3 "$ROOT/Scripts/acoustic_eq_verify.py" "$OUT_DIR"

APP=$(find ~/Library/Developer/Xcode/DerivedData/SonarForge-*/Build/Products/Debug/SonarForge.app -maxdepth 0 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
  echo "Building Debug app..."
  (cd "$ROOT" && xcodebuild build -scheme SonarForge -destination 'platform=macOS' -quiet)
  APP=$(find ~/Library/Developer/Xcode/DerivedData/SonarForge-*/Build/Products/Debug/SonarForge.app -maxdepth 0 | head -1)
fi

pkill -f 'SonarForge.app/Contents/MacOS/SonarForge' 2>/dev/null || true
rm -f "$LOG_FILE"

PROBE_FILE="$OUT_DIR/spectrum_probe.log"
rm -f "$PROBE_FILE"

echo "Launching SonarForge with +2 dB @ 1 kHz profile..."
open -a "$APP" --args \
  --import-profile "$OUT_DIR/profile_plus2_1khz.json" \
  --autostart-engine \
  --debug-log-spectrum \
  --debug-log-spectrum-file "$PROBE_FILE"

sleep 3

echo "Playing +3 dBFS 1 kHz tone for 6 seconds..."
afplay "$OUT_DIR/tone_1khz_plus3db.wav"
sleep 2

cp "$PROBE_FILE" "$LOG_FILE" 2>/dev/null || true

pkill -f 'SonarForge.app/Contents/MacOS/SonarForge' 2>/dev/null || true

if [[ ! -s "$LOG_FILE" ]]; then
  echo "FAIL: No spectrum probe logs captured. Is Screen & System Audio Recording granted?"
  exit 1
fi

# Parse the last probe line: "probe bin=N pre=X post=Y"
LAST=$(grep 'probe bin=' "$LOG_FILE" | tail -1)
if [[ -z "$LAST" ]]; then
  echo "FAIL: Log file has no probe lines."
  echo "--- log ---"
  cat "$LOG_FILE"
  exit 1
fi

PRE=$(echo "$LAST" | sed -n 's/.*pre=\([^ ]*\).*/\1/p')
POST=$(echo "$LAST" | sed -n 's/.*post=\([^ ]*\).*/\1/p')
DELTA=$(python3 -c "print(round(float('$POST') - float('$PRE'), 2))")

echo ""
echo "=== Acoustic EQ Verification ==="
echo "Input tone:     +3.0 dBFS @ 1 kHz"
echo "EQ profile:     +2.0 dB peaking @ 1 kHz"
echo "Expected post:  +5.0 dBFS (±${TOLERANCE} dB)"
echo "Measured pre:   ${PRE} dBFS"
echo "Measured post:  ${POST} dBFS"
echo "EQ delta:       ${DELTA} dB (expect ~+2.0)"
echo "Raw log:        $LAST"

python3 - "$POST" "$DELTA" "$EXPECTED_POST" "$TOLERANCE" <<'PY'
import sys
post, delta, expected, tol = map(float, sys.argv[1:])
ok_post = abs(post - expected) <= tol
ok_delta = abs(delta - 2.0) <= 0.5
if ok_post and ok_delta:
    print("RESULT: PASS")
    sys.exit(0)
print("RESULT: FAIL")
if not ok_post:
    print(f"  post {post:.2f} dBFS not within ±{tol} of {expected:.1f}")
if not ok_delta:
    print(f"  EQ delta {delta:.2f} dB not within ±0.5 of +2.0")
sys.exit(1)
PY