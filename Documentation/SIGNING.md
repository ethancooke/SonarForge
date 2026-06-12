# Signing & Notarization Setup (Chunk 6.4)

Everything needed to go from a fresh Apple Developer enrollment to shipped,
notarized releases. The pipeline (`Scripts/release.sh`, `.github/workflows/release.yml`)
is already built — this is the credentials checklist.

## 0. Enroll

[developer.apple.com/programs](https://developer.apple.com/programs) → Enroll
as an **individual** ($99/year). Use your normal Apple ID. Activation is
usually same-day.

## 1. Three things to collect

### A. Team ID (10 characters, e.g. `AB12CD34EF`)
developer.apple.com → Account → **Membership details** → Team ID.

### B. Developer ID Application certificate (.p12)
Easiest path is Xcode:
1. Xcode → Settings → Accounts → select your Apple ID → **Manage Certificates…**
2. **+** → **Developer ID Application**. (Created and installed into your login keychain.)
3. Export for CI: **Keychain Access** → My Certificates → right-click
   "Developer ID Application: Your Name (TEAMID)" → **Export…** → `.p12`,
   choose an export password (this becomes `MACOS_CERT_PASSWORD`).

> Developer ID **Application** (for apps distributed outside the App Store),
> not "Apple Development" and not "Developer ID Installer".

### C. App-specific password (for the notarization service)
[account.apple.com](https://account.apple.com) → Sign-In and Security →
**App-Specific Passwords** → **+**, name it e.g. `sonarforge-notary`. You get
`xxxx-xxxx-xxxx-xxxx` — shown once, store it.

## 2. Where the values go

### GitHub (for tag-triggered releases)
Repo → Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|---|---|---|
| Secret | `MACOS_CERT_P12_BASE64` | `base64 -i SonarForge.p12 \| pbcopy` |
| Secret | `MACOS_CERT_PASSWORD` | the .p12 export password |
| Secret | `NOTARY_APPLE_ID` | your Apple ID email |
| Secret | `NOTARY_TEAM_ID` | Team ID from step A |
| Secret | `NOTARY_PASSWORD` | app-specific password from step C |
| **Variable** | `SIGNING_ENABLED` | `true` |

Then: `git tag v0.1.0 && git push origin v0.1.0` → draft release appears with
the signed, notarized, stapled zip attached.

### Local machine (one-time, nicer than env vars)
```bash
xcrun notarytool store-credentials sonarforge-notary \
  --apple-id YOU@example.com --team-id TEAMID
# (prompts for the app-specific password, stores it in your keychain)
```
Then a full local release is:
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE=sonarforge-notary \
Scripts/release.sh
```
Bonus: exporting `SIGN_IDENTITY` for normal dev builds gives you a stable
signature, which ends the rebuild → TCC re-prompt cycle permanently.

## 3. What notarization actually checks (and our status)

Apple's automated scan requires — all already satisfied by the pipeline:

| Requirement | Status |
|---|---|
| Valid Developer ID Application signature | supplied by your cert |
| **Hardened runtime** | ✅ `--options runtime` |
| **Secure timestamp** | ✅ `--timestamp` (auto-added for real identities) |
| No `get-task-allow` debug entitlement | ✅ verified absent in Release archives |
| All nested code signed | ✅ single binary, no frameworks/helpers |
| Not obviously malicious | ✅ presumably |

**The one load-bearing entitlement**: `com.apple.security.device.audio-input`
must be in the signature. Under the hardened runtime, audio input is blocked
without it — the tap delivers pure silence, with no error and no TCC prompt.
Debug builds mask this (debuggable builds relax hardened-runtime enforcement),
so the failure only appears in Release. This regression actually happened once
(the entitlements file got emptied during unrelated debugging); `release.sh`
now hard-fails if the entitlement is missing from the final signature.

App Sandbox is **not** required for Developer ID distribution and we don't use
it. TCC (the user's System Audio Recording consent) is a runtime, per-user
mechanism — nothing to configure at signing time, but a stable Developer ID
signature means users grant it once and keep it across updates.
