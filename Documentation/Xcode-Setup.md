# Xcode Project Setup (Chunk 0.1)

This document captures the exact settings required when creating or configuring the Xcode project for SonarForge. These are mandatory because of the platform decisions:

- Minimum macOS: **14.2** (Core Audio Taps are most stable starting here)
- Architectures: **Apple Silicon (arm64) only** — no Intel / x86_64 support

## How the Project Is Created (Current Approach: XcodeGen)

The committed `SonarForge.xcodeproj` is **generated** from `project.yml` at the repo root using [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
xcodegen generate
```

`project.yml` is the source of truth for all build settings below. **Do not edit build settings directly in Xcode** — change `project.yml` and regenerate, then commit both. The generated `Sources/SonarForge/Resources/Info.plist` is also produced from `project.yml`.

### Manual Creation (reference only, if ever recreating without XcodeGen)

1. In Xcode: **File > New > Project** → macOS → App
2. Name: `SonarForge`
3. Interface: SwiftUI
4. Language: Swift
5. **Uncheck** "Use Core Data", "Include Tests" can be added later or created manually as we have.
6. Save next to the other repo files (the `.xcodeproj` will sit at the root).

## Critical Build Settings (Target: SonarForge)

Set these in the project or target Build Settings (filter for the key):

| Setting                              | Value                                      | Notes |
|--------------------------------------|--------------------------------------------|-------|
| **Deployment Target** (MACOSX_DEPLOYMENT_TARGET) | 14.2 | Hard minimum for stable CATap behavior |
| **Architectures** (ARCHS)            | `arm64`                                    | Apple Silicon only |
| **Valid Architectures**              | `arm64`                                    | Prevents accidental Intel inclusion |
| **Build Active Architecture Only** (ONLY_ACTIVE_ARCH) | `YES` (Debug), `NO` (Release) | Standard for arm64-only |
| **Excluded Architectures**           | (leave empty or explicitly `x86_64`)       | Ensure no x86_64 slips in |
| **Supported Platforms**              | `macOS`                                    | - |
| **Base SDK**                         | macOS (latest)                             | - |

### How to Set Architectures Strictly

In Build Settings:
- Set **Architectures** → `$(ARCHS_STANDARD)` is usually fine on Apple Silicon hosts, but explicitly set to `arm64` to be safe.
- Or use a custom setting: `arm64`
- For Release builds you can still produce arm64 binaries only.

You can also add a User-Defined Setting or use a config file later if needed.

## Entitlements

Add the entitlements file created in the repo (`Sources/SonarForge/Resources/Entitlements.entitlements`) to the target:
- Target → Signing & Capabilities → + Capability → Hardened Runtime (if distributing)
- Manually add the file under "Code Signing Entitlements"

The file already requests `com.apple.security.device.audio-input`.

## Info.plist / Target Properties

- Add a clear "Screen & System Audio Recording" explanation in the target if Xcode surfaces a usage key (the system prompt for CATap is usually automatic).
- Bundle Identifier: something like `com.yourorg.SonarForge` (update before first archive).

## Signing for Development

- For local development on your own Apple Silicon Mac: "Sign to Run Locally" or your Development Team is usually sufficient.
- The first time you create a `CATapDescription` and start the engine, the system will prompt for **Screen & System Audio Recording** permission.

## Verifying the Configuration

After first successful build and run:

```bash
file /path/to/build/.../SonarForge.app/Contents/MacOS/SonarForge
```

Expected output should mention `Mach-O 64-bit executable arm64` only (no x86_64 fat slice).

## CI Note

The GitHub Actions runner (`macos-15` or newer) is Apple Silicon. The `build.yml` should build for `arm64`.

## Why These Restrictions?

- Core Audio Taps (`AudioHardwareCreateProcessTap` + `CATapDescription`) reached good stability and documentation in macOS 14.2+.
- Limiting to Apple Silicon reduces testing surface, simplifies the audio engine (no cross-architecture issues), and matches the primary user base for high-quality critical listening on modern Macs.
- Keeping the scope narrow is a core project principle.

If these settings are not applied correctly during Chunk 0.1, fix them before starting Chunk 1.1.

---

Update this document if Apple changes the recommended minimum or if we ever revisit Intel support (currently out of scope).
