#!/usr/bin/env bash
# Builds distributable SonarForge artifacts (Chunk 6.4).
#
# Usage:
#   Scripts/release.sh                  # ad-hoc signed (local testing)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_KEYCHAIN_PROFILE=sonarforge-notary \
#   Scripts/release.sh                  # signed + notarized + stapled
#   (NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD also work in place of
#    the keychain profile.)
#
# Output in build/release/:
#   SonarForge.app          — signed (notarized + stapled when credentialed)
#   SonarForge-<v>.dmg      — PRIMARY artifact for humans (drag to /Applications)
#   SonarForge-<v>.zip      — secondary (scripts, future Homebrew cask)
#   plus .sha256 for each.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/SonarForge.xcarchive"
APP="$OUT/SonarForge.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc

# Notarization credentials: a stored keychain profile takes precedence over the
# app-specific-password triple. Empty => skip notarization (local/ad-hoc).
NOTARIZE=""
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARIZE="profile"
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  NOTARIZE="password"
fi

# Submit a container (.zip or .dmg) to the notary service and wait.
notarize_submit() {
  local artifact="$1"
  if [[ "$NOTARIZE" == "profile" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  else
    xcrun notarytool submit "$artifact" \
          --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
          --password "$NOTARY_PASSWORD" --wait
  fi
}

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Tests (Debug)"
xcodebuild -project SonarForge.xcodeproj -scheme SonarForge \
           -destination 'platform=macOS,arch=arm64' -quiet test

echo "==> Archive (Release, arm64)"
xcodebuild -project SonarForge.xcodeproj -scheme SonarForge \
           -configuration Release -destination 'platform=macOS,arch=arm64' \
           -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO -quiet archive

cp -R "$ARCHIVE/Products/Applications/SonarForge.app" "$APP"

# Strip quarantine/provenance xattrs picked up during local dev (e.g. Preview
# touching AppIcon.icns). Left in the bundle they can break Gatekeeper on
# other Macs (macOS 26: "File created by an AppSandbox, exec/open not allowed").
xattr -cr "$APP"

echo "==> Sign app (identity: $SIGN_IDENTITY, hardened runtime)"
# Secure timestamps are REQUIRED for notarization but unsupported for ad-hoc.
TIMESTAMP_FLAG=""
[[ "$SIGN_IDENTITY" != "-" ]] && TIMESTAMP_FLAG="--timestamp"
codesign --force --options runtime $TIMESTAMP_FLAG \
         --entitlements "$ROOT/Sources/SonarForge/Resources/Entitlements.entitlements" \
         --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Regression guard: the audio-input entitlement is load-bearing under the
# hardened runtime — without it the tap delivers silence in Release builds
# (this exact regression shipped silently once; see AUDIO_PATH.md).
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
  || { echo "ERROR: audio-input entitlement missing from signature — Release builds would capture silence."; exit 1; }

# Regression guard: no AppSandbox provenance xattr may survive into the signed
# bundle. macOS 26 Gatekeeper rejects any bundle containing one ("File created
# by an AppSandbox, exec/open not allowed") — this shipped silently once (a
# sandboxed tool touched AppIcon.icns during icon work) and broke launch on
# other Macs. The `xattr -cr` above strips them pre-sign; this confirms none
# came back. Download quarantine (com.apple.quarantine) is unrelated and fine.
if xattr -rl "$APP" | grep -qi "provenance"; then
  echo "ERROR: AppSandbox provenance xattr present in signed bundle — Gatekeeper would reject this on macOS 26:"
  xattr -rl "$APP" | grep -i "provenance"
  exit 1
fi

# Verify the platform contract: arm64-only, 14.2 minimum.
BIN="$APP/Contents/MacOS/SonarForge"
file "$BIN" | grep -q arm64 || { echo "ERROR: not arm64"; exit 1; }
if file "$BIN" | grep -q x86_64; then echo "ERROR: contains x86_64 slice"; exit 1; fi

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="$OUT/SonarForge-$VERSION.zip"
DMG="$OUT/SonarForge-$VERSION.dmg"

# Notarize the APP first and staple its ticket, so the .app is self-contained
# (opens cleanly even if a user extracts it out of the dmg/zip). The dmg/zip
# built afterwards then carry an already-stapled app.
if [[ -n "$NOTARIZE" ]]; then
  [[ "$SIGN_IDENTITY" == "-" ]] && { echo "ERROR: notarization needs a Developer ID identity, not ad-hoc."; exit 1; }
  echo "==> Notarize app ($NOTARIZE credentials)"
  APPZIP="$OUT/_app_for_notary.zip"
  ditto -c -k --keepParent "$APP" "$APPZIP"
  notarize_submit "$APPZIP"
  xcrun stapler staple "$APP"
  rm -f "$APPZIP"
  echo "==> Gatekeeper assessment (app)"
  spctl --assess --type execute -vv "$APP"
else
  echo "==> Skipping notarization (no NOTARY_KEYCHAIN_PROFILE or NOTARY_* env)"
fi

# --- DMG (primary, drag-to-Applications) -----------------------------------
echo "==> Build DMG"
DMG_STAGE="$OUT/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"   # drag target
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$DMG_STAGE/"
hdiutil create -volname "SonarForge" -srcfolder "$DMG_STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

if [[ -n "$NOTARIZE" ]]; then
  echo "==> Sign + notarize DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize_submit "$DMG"
  xcrun stapler staple "$DMG"          # so the disk image itself opens warning-free
  spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
fi

# --- ZIP (secondary) --------------------------------------------------------
echo "==> Build ZIP (app + LICENSE + NOTICE)"
ZIP_STAGE="$OUT/zip"
rm -rf "$ZIP_STAGE"
mkdir -p "$ZIP_STAGE"
cp -R "$APP" "$ZIP_STAGE/"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ZIP_STAGE/"
ditto -c -k "$ZIP_STAGE" "$ZIP"
rm -rf "$ZIP_STAGE"

echo "==> Checksums"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo ""
echo "Done:"
echo "  $APP"
echo "  $DMG   (primary — drag to /Applications)"
echo "  $ZIP   (secondary)"
# Use a full `if` (not `[[ ]] && echo`): as the script's last command, the
# bare test returns exit 1 for a real identity, which fails CI (`bash release.sh`
# with no pipe to mask it). Locally `| tee` hid it; CI surfaced it.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "NOTE: ad-hoc signed — fine locally; Gatekeeper will block these on other Macs until signed + notarized with a Developer ID."
fi
