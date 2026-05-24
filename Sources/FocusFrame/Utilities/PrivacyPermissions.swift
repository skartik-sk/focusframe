import Foundation

enum PrivacyPermission {
    case camera
    case microphone
    case speechRecognition
    case screenCapture
    case inputMonitoring
    case accessibility

    var usageDescriptionKey: String {
        switch self {
        case .camera:
            return "NSCameraUsageDescription"
        case .microphone:
            return "NSMicrophoneUsageDescription"
        case .speechRecognition:
            return "NSSpeechRecognitionUsageDescription"
        case .screenCapture:
            return "NSScreenCaptureUsageDescription"
        case .inputMonitoring:
            return "NSInputMonitoringUsageDescription"
        case .accessibility:
            return "NSAccessibilityUsageDescription"
        }
    }
}

enum PrivacyPermissions {
    static func hasUsageDescription(_ permission: PrivacyPermission) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: permission.usageDescriptionKey) as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func missingUsageMessage(for permission: PrivacyPermission) -> String {
        "Missing \(permission.usageDescriptionKey). Run the app bundle instead of swift run, or add that key to the bundle Info.plist."
    }
}

struct MissingPrivacyUsageDescriptionError: LocalizedError {
    let permission: PrivacyPermission

    var errorDescription: String? {
        PrivacyPermissions.missingUsageMessage(for: permission)
    }
}
