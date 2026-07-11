import AppKit
import Foundation

/// Helpers for directing the user to the System Audio Recording privacy pane.
///
/// Core Audio process taps use the **System Audio Recording** TCC service
/// (`NSAudioCaptureUsageDescription` in Info.plist). There is **no** public
/// preflight API for that service — do not gate engine start on
/// `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`. Those
/// cover Screen Recording, a separate TCC class (especially on macOS 15+,
/// where Settings splits "Screen & System Audio Recording" from
/// "System Audio Recording Only"). A false-negative gate shipped in v0.2.1 and
/// blocked starts for users who already had the correct permission.
enum PermissionHelper {
    /// Opens System Settings to the Screen & System Audio Recording privacy pane.
    /// That pane (and the sibling "System Audio Recording Only" section on
    /// recent macOS) is where users enable SonarForge for the CATap path.
    static func openScreenRecordingPrivacySettings() {
        // Deep link into the correct Privacy pane on recent macOS.
        let pref = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pref) {
            NSWorkspace.shared.open(url)
        }
    }
}
