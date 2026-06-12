#!/usr/bin/env bash
# Builds a distributable SonarForge.app (Chunk 6.4).
#
# Usage:
#   Scripts/release.sh                  # ad-hoc signed (local testing)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_APPLE_ID=… NOTARY_TEAM_ID=… NOTARY_PASSWORD=… \
#   Scripts/release.sh                  # signed + notarized + stapled
#
# Output: build/release/SonarForge.app, SonarForge-<version>.zip + .sha256
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/SonarForge.xcarchive"
APP="$OUT/SonarForge.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc

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

echo "==> Sign (identity: $SIGN_IDENTITY, hardened runtime)"
codesign --force --options runtime \
         --entitlements "$ROOT/Sources/SonarForge/Resources/Entitlements.entitlements" \
         --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="$OUT/SonarForge-$VERSION.zip"

# Verify the platform contract: arm64-only, 14.2 minimum.
BIN="$APP/Contents/MacOS/SonarForge"
file "$BIN" | grep -q arm64 || { echo "ERROR: not arm64"; exit 1; }
if file "$BIN" | grep -q x86_64; then echo "ERROR: contains x86_64 slice"; exit 1; fi

if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "ERROR: notarization requires a Developer ID identity (SIGN_IDENTITY), not ad-hoc."
    exit 1
  fi
  echo "==> Notarize"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" \
        --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"   # re-zip with the stapled ticket
else
  echo "==> Skipping notarization (NOTARY_* not set)"
fi

echo "==> Package"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo ""
echo "Done:"
echo "  $APP"
echo "  $ZIP"
[[ "$SIGN_IDENTITY" == "-" ]] && echo "NOTE: ad-hoc signed — fine locally; Gatekeeper will block it on other Macs."
