#!/usr/bin/env bash
# Collect install/launch diagnostics (run on the machine that cannot open SonarForge).
set -euo pipefail

DMG="${1:-$HOME/Downloads/SonarForge-0.1.0.dmg}"
APP="/Applications/SonarForge.app"
BIN="$APP/Contents/MacOS/SonarForge"

echo "========== SonarForge install diagnostics =========="
echo "Date: $(date)"
echo "User: $(whoami)"
echo

echo "--- sw_vers ---"
sw_vers
echo

echo "--- DMG checksum (compare against the release's published .sha256) ---"
if [[ -f "$DMG" ]]; then
  shasum -a 256 "$DMG"
else
  echo "DMG not found at: $DMG"
fi
echo

if [[ -d "$APP" ]]; then
  echo "--- Installed app: codesign ---"
  codesign --verify --deep --strict --verbose=4 "$APP" 2>&1 || true
  echo
  echo "--- Installed app: spctl ---"
  spctl -a -vv "$APP" 2>&1 || true
  echo
  echo "--- Installed app: stapler ---"
  xcrun stapler validate "$APP" 2>&1 || true
  echo
  echo "--- Installed app: xattrs (first 30 lines) ---"
  xattr -lr "$APP" 2>&1 | head -30 || true
  echo
  echo "--- Installed app: binary ---"
  ls -la "$BIN" 2>&1 || true
  file "$BIN" 2>&1 || true
  echo
  echo "--- Direct binary launch (5s timeout) ---"
  timeout 5 "$BIN" 2>&1 || echo "(exit $? — GUI apps often stay running; timeout is normal if no error printed)"
else
  echo "--- No install at $APP ---"
fi
echo

if [[ -f "$DMG" ]]; then
  echo "--- DMG mount test ---"
  MOUNT_OUT="$(hdiutil attach -nobrowse -readonly "$DMG" 2>&1)"
  echo "$MOUNT_OUT"
  VOL="$(echo "$MOUNT_OUT" | awk '/\/Volumes\// {print $NF; exit}')"
  if [[ -n "$VOL" && -d "$VOL/SonarForge.app" ]]; then
    echo "--- DMG app: spctl ---"
    spctl -a -vv "$VOL/SonarForge.app" 2>&1 || true
    echo "--- DMG app: direct binary (5s timeout) ---"
    timeout 5 "$VOL/SonarForge.app/Contents/MacOS/SonarForge" 2>&1 || echo "(exit $?)"
    hdiutil detach "$VOL" -quiet 2>/dev/null || true
  fi
fi

echo
echo "========== done =========="