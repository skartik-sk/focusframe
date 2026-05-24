import AppKit
import ApplicationServices
import CoreGraphics

enum KeyboardCapturePermissions {
    static var inputMonitoringAuthorized: Bool {
        CGPreflightListenEventAccess()
    }

    static var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    static var reliableCaptureAuthorized: Bool {
        inputMonitoringAuthorized
    }

    static var isCaptureAuthorized: Bool {
        reliableCaptureAuthorized
    }

    @discardableResult
    static func requestInputMonitoring(prompt: Bool = true) -> Bool {
        guard PrivacyPermissions.hasUsageDescription(.inputMonitoring) else {
            return false
        }
        if CGPreflightListenEventAccess() {
            return true
        }
        guard prompt else {
            return false
        }
        return CGRequestListenEventAccess() || CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        guard prompt else {
            return false
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) || AXIsProcessTrusted()
    }

    @discardableResult
    static func requestKeyboardCapture() -> Bool {
        requestInputMonitoring()
    }

    static func openInputMonitoringSettings() {
        openPrivacySettings("Privacy_ListenEvent")
    }

    static func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    private static func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
