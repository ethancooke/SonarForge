#!/usr/bin/env bash
# Build locally (signed + notarized when credentialed) and publish a DRAFT
# GitHub release with the artifacts attached — no CI runner involved.
#
# Usage:
#   Scripts/publish-release.sh v0.1.0
#   (with SIGN_IDENTITY / NOTARY_KEYCHAIN_PROFILE exported for a real release)
#
# This is the recommended solo-dev flow: your Mac builds faster than any
# runner, minutes cost nothing, and the signing certificate never has to
# leave your keychain for GitHub secrets.
set -euo pipefail

TAG="${1:?usage: publish-release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[[ -n "$(git status --porcelain)" ]] && { echo "ERROR: working tree not clean"; exit 1; }

bash Scripts/release.sh

ZIP=$(ls build/release/SonarForge-*.zip)
SHA=$(ls build/release/SonarForge-*.zip.sha256)

git tag -f "$TAG"
git push origin "HEAD:main" "refs/tags/$TAG"

gh release create "$TAG" "$ZIP" "$SHA" \
  --draft --title "SonarForge $TAG" \
  --notes "Draft — fill in from Documentation/RELEASE_NOTES_TEMPLATE.md before publishing.

**Requirements**: macOS 14.2+, Apple Silicon (M1 or newer). Grant \"System Audio Recording\" when prompted on first engine start."

echo ""
echo "Draft release created: review and publish at:"
gh release view "$TAG" --web >/dev/null 2>&1 || gh release view "$TAG" --json url --jq .url
