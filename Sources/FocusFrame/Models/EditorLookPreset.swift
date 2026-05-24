import Foundation
import CoreGraphics

enum EditorLookPreset: String, CaseIterable, Identifiable {
    case studio
    case productDemo
    case creator
    case course
    case minimal
    case social
    case crispLight
    case graphite
    case oceanGlass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .studio:
            return "Studio"
        case .productDemo:
            return "Product"
        case .creator:
            return "Creator"
        case .course:
            return "Course"
        case .minimal:
            return "Minimal"
        case .social:
            return "Social"
        case .crispLight:
            return "Crisp"
        case .graphite:
            return "Graphite"
        case .oceanGlass:
            return "Ocean"
        }
    }

    var systemImage: String {
        switch self {
        case .studio:
            return "wand.and.stars"
        case .productDemo:
            return "sparkles"
        case .creator:
            return "person.crop.rectangle"
        case .course:
            return "graduationcap"
        case .minimal:
            return "rectangle"
        case .social:
            return "rectangle.portrait"
        case .crispLight:
            return "sun.max"
        case .graphite:
            return "square.stack.3d.up"
        case .oceanGlass:
            return "drop"
        }
    }

    var summary: String {
        switch self {
        case .studio:
            return "Signature FocusFrame focus, cursor, depth, and badges."
        case .productDemo:
            return "Balanced zoom, polished background, subtle cursor."
        case .creator:
            return "Camera-first styling with warmer facecam polish."
        case .course:
            return "Readable captions, keyboard badges, steady camera."
        case .minimal:
            return "Clean source frame with very light effects."
        case .social:
            return "Punchier cursor, tighter padding, strong subtitles."
        case .crispLight:
            return "Light studio background with sharp product contrast."
        case .graphite:
            return "Neutral pro backdrop with strong depth and focus."
        case .oceanGlass:
            return "Fresh blue-green gradient with clean camera polish."
        }
    }

    func apply(to project: inout RecordingProject) {
        var style = project.style

        style.motionBlurEnabled = true
        style.motionBlurStrength = 2.8
        style.shadowEnabled = true
        style.shadowRadius = 36
        style.shadowOffsetY = 18
        style.shadowOpacity = 0.28
        style.useHighResCursors = true
        style.hideStaticCursor = true
        style.clickSoundEnabled = true
        style.clickSoundStyle = .provided
        style.clickSoundVolume = 0.34
        style.keyboardSoundEnabled = true
        style.keyboardSoundStyle = .provided
        style.keyboardSoundVolume = 0.24
        style.webcamEnhanceEnabled = true
        style.webcamBrightness = 0.035
        style.webcamContrast = 1.06
        style.webcamSaturation = 1.08
        style.webcamShadowEnabled = true
        style.webcamShadowRadius = 26
        style.webcamShadowOpacity = 0.32
        style.webcamBorderEnabled = true
        style.webcamBorderWidth = 2
        style.webcamBorderColor = CodableColor(r: 1, g: 1, b: 1)

        switch self {
        case .studio:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.07, g: 0.08, b: 0.095),
                CodableColor(r: 0.23, g: 0.25, b: 0.31)
            ]
            style.backgroundGradientAngle = 138
            style.padding = 76
            style.cornerRadius = 20
            style.shadowEnabled = true
            style.shadowRadius = 42
            style.shadowOffsetY = 22
            style.shadowOpacity = 0.32
            style.motionBlurEnabled = true
            style.motionBlurStrength = 4.0
            style.cursorScale = 1.52
            style.cursorStyle = .slow
            style.hideStaticCursor = true
            style.loopCursorPosition = false
            style.useHighResCursors = true
            style.autoZoomScale = 1.52
            style.clickSoundEnabled = true
            style.clickSoundStyle = .provided
            style.clickSoundVolume = 0.36
            style.showKeyboardShortcuts = true
            style.shortcutBadgePosition = .bottomCenter
            style.shortcutBadgeStyle = .pillDark
            style.shortcutBadgeDuration = 1.35
            style.shortcutBadgeFontSize = 20
            style.shortcutBadgeBackgroundOpacity = 0.92
            style.shortcutBadgeShowSingleKeys = true
            style.keyboardSoundEnabled = true
            style.keyboardSoundStyle = .provided
            style.keyboardSoundVolume = 0.24
            style.webcamPosition = .bottomLeft
            style.webcamShape = .roundedRect
            style.webcamSize = 190
            style.webcamWidth = 220
            style.webcamHeight = 164
            style.webcamCornerRadius = 38
            style.webcamZoomScale = 0.62
            style.webcamEnhanceEnabled = true
            style.webcamBrightness = 0.04
            style.webcamContrast = 1.08
            style.webcamSaturation = 1.10
            style.webcamBorderEnabled = true
            style.webcamBorderWidth = 2
            style.webcamShadowEnabled = true
            style.webcamShadowRadius = 28
            style.webcamShadowOpacity = 0.34
            style.subtitlePosition = .bottomCenter
            style.subtitleFontSize = 26
            style.subtitleBackgroundOpacity = 0.76
            project.showKeyboardShortcuts = true
            if project.captionsFileURL != nil {
                project.subtitlesEnabled = true
            }
        case .productDemo:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.05, g: 0.07, b: 0.09),
                CodableColor(r: 0.23, g: 0.26, b: 0.32)
            ]
            style.backgroundGradientAngle = 132
            style.padding = 74
            style.cornerRadius = 18
            style.cursorScale = 1.3
            style.autoZoomScale = 1.34
            style.webcamPosition = .bottomLeft
            style.webcamShape = .roundedRect
            style.webcamSize = 170
            style.webcamWidth = 190
            style.webcamHeight = 142
            style.webcamCornerRadius = 34
            style.webcamZoomScale = 0.68
            style.subtitlePosition = .bottomCenter
            style.subtitleFontSize = 24
        case .creator:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.10, g: 0.10, b: 0.12),
                CodableColor(r: 0.28, g: 0.18, b: 0.28)
            ]
            style.backgroundGradientAngle = 45
            style.padding = 82
            style.cornerRadius = 24
            style.cursorScale = 1.22
            style.autoZoomScale = 1.28
            style.webcamPosition = .bottomLeft
            style.webcamShape = .roundedRect
            style.webcamSize = 210
            style.webcamWidth = 230
            style.webcamHeight = 172
            style.webcamCornerRadius = 42
            style.webcamZoomScale = 0.62
            style.webcamBrightness = 0.05
            style.webcamContrast = 1.08
            style.webcamSaturation = 1.12
            style.subtitleFontSize = 26
        case .course:
            style.backgroundType = .solid
            style.backgroundColor = CodableColor(r: 0.08, g: 0.085, b: 0.095)
            style.padding = 62
            style.cornerRadius = 14
            style.cursorScale = 1.45
            style.autoZoomScale = 1.32
            style.showKeyboardShortcuts = true
            style.shortcutBadgeStyle = .pillDark
            style.shortcutBadgeDuration = 1.35
            style.webcamPosition = .topRight
            style.webcamShape = .circle
            style.webcamSize = 168
            style.webcamWidth = 0
            style.webcamHeight = 0
            style.webcamZoomScale = 0.58
            style.subtitlePosition = .bottomCenter
            style.subtitleFontSize = 28
            style.subtitleBackgroundOpacity = 0.78
            project.showKeyboardShortcuts = true
            if project.captionsFileURL != nil {
                project.subtitlesEnabled = true
            }
        case .minimal:
            style.backgroundType = .solid
            style.backgroundColor = CodableColor(r: 0.02, g: 0.02, b: 0.025)
            style.padding = 0
            style.cornerRadius = 0
            style.shadowEnabled = false
            style.motionBlurStrength = 1.2
            style.cursorScale = 1.12
            style.autoZoomScale = 1.2
            style.clickSoundVolume = 0.22
            style.keyboardSoundVolume = 0.16
            style.webcamBorderEnabled = false
            style.webcamShadowOpacity = 0.18
            style.subtitleBackgroundOpacity = 0.6
        case .social:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.06, g: 0.08, b: 0.16),
                CodableColor(r: 0.16, g: 0.28, b: 0.24)
            ]
            style.backgroundGradientAngle = 158
            style.padding = 48
            style.cornerRadius = 26
            style.cursorScale = 1.5
            style.autoZoomScale = 1.48
            style.clickSoundStyle = .provided
            style.clickSoundVolume = 0.40
            style.keyboardSoundVolume = 0.30
            style.webcamPosition = .bottomLeft
            style.webcamShape = .circle
            style.webcamSize = 190
            style.webcamWidth = 0
            style.webcamHeight = 0
            style.webcamZoomScale = 0.55
            style.subtitleFontSize = 30
            style.subtitleBackgroundOpacity = 0.82
        case .crispLight:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.93, g: 0.96, b: 0.98),
                CodableColor(r: 0.66, g: 0.74, b: 0.83)
            ]
            style.backgroundGradientAngle = 128
            style.padding = 68
            style.cornerRadius = 18
            style.shadowRadius = 34
            style.shadowOffsetY = 16
            style.shadowOpacity = 0.24
            style.cursorScale = 1.34
            style.autoZoomScale = 1.36
            style.shortcutBadgeStyle = .pillLight
            style.webcamPosition = .bottomRight
            style.webcamShape = .roundedRect
            style.webcamWidth = 204
            style.webcamHeight = 154
            style.webcamCornerRadius = 34
            style.webcamZoomScale = 0.64
        case .graphite:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.10, g: 0.105, b: 0.11),
                CodableColor(r: 0.30, g: 0.31, b: 0.33)
            ]
            style.backgroundGradientAngle = 140
            style.padding = 78
            style.cornerRadius = 20
            style.shadowRadius = 44
            style.shadowOffsetY = 22
            style.shadowOpacity = 0.34
            style.cursorScale = 1.32
            style.autoZoomScale = 1.38
            style.webcamPosition = .bottomLeft
            style.webcamShape = .roundedRect
            style.webcamWidth = 214
            style.webcamHeight = 160
            style.webcamCornerRadius = 36
            style.webcamZoomScale = 0.62
        case .oceanGlass:
            style.backgroundType = .gradient
            style.backgroundGradientColors = [
                CodableColor(r: 0.04, g: 0.18, b: 0.22),
                CodableColor(r: 0.18, g: 0.44, b: 0.42)
            ]
            style.backgroundGradientAngle = 152
            style.padding = 64
            style.cornerRadius = 22
            style.shadowRadius = 38
            style.shadowOffsetY = 18
            style.shadowOpacity = 0.30
            style.cursorScale = 1.4
            style.autoZoomScale = 1.42
            style.subtitleBackgroundOpacity = 0.76
            style.webcamPosition = .bottomLeft
            style.webcamShape = .circle
            style.webcamSize = 178
            style.webcamWidth = 0
            style.webcamHeight = 0
            style.webcamZoomScale = 0.58
        }

        if project.webcamFileURL != nil {
            project.webcamEnabled = true
        }
        project.style = style
    }
}
