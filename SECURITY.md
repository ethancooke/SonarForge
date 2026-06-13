# Security Policy

SonarForge processes system audio locally and requests the macOS
"System Audio Recording" permission — security reports are taken seriously.

## Reporting a vulnerability

Please use **GitHub's private vulnerability reporting** (Security tab →
"Report a vulnerability") rather than a public issue, especially for anything
involving the audio capture path, entitlements, or the release pipeline.

You can expect an acknowledgement within a few days. Once fixed, reporters are
credited in the release notes unless they prefer otherwise.

## Scope notes

- The app makes no network connections; reports about data exfiltration would
  be especially serious.
- The release pipeline signs with hardened runtime and is notarized; reports
  about signature/entitlement weaknesses are in scope.

## Supported versions

Only the latest release is supported with security fixes.
