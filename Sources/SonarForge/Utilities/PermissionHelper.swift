import AppKit
import CoreGraphics
import Foundation

/// Helpers for the "Screen & System Audio Recording" permission required by Core Audio Taps.
enum PermissionHelper {
    static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests the permission. The system will show the standard prompt if needed.
    /// Returns true if permission is (now) granted.
    static func requestScreenCapturePermission() async -> Bool {
        // CGRequestScreenCaptureAccess is synchronous and will present UI if necessary.
        // We wrap it so callers can treat it as async for future evolution.
        return CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingPrivacySettings() {
        // This URL opens the correct pane in System Settings on recent macOS.
        let pref = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pref) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Convenience for the app model / UI layer.
    static func ensurePermission() async -> Bool {
        if hasScreenCapturePermission() {
            return true
        }
        let granted = await requestScreenCapturePermission()
        return granted
    }
}
