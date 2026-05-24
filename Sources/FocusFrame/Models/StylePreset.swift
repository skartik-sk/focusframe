import Foundation
import CoreGraphics

struct StylePreset: Codable {
    // Background
    var backgroundType: BackgroundType
    var backgroundColor: CodableColor
    var backgroundGradientColors: [CodableColor]
    var backgroundGradientAngle: Double      // degrees
    var backgroundImageURL: URL?

    // Layout
    var padding: CGFloat                     // px around recording frame
    var cornerRadius: CGFloat                // rounded corners
    var margin: CGFloat                      // space from edge of canvas

    // Shadow
    var shadowEnabled: Bool
    var shadowRadius: CGFloat
    var shadowOffsetX: CGFloat
    var shadowOffsetY: CGFloat
    var shadowOpacity: Float
    var shadowColor: CodableColor

    // Motion
    var motionBlurEnabled: Bool
    var motionBlurStrength: Float

    // Cursor
    var cursorScale: CGFloat                 // 1.0 = normal, 2.0 = double
    var cursorStyle: CursorMovementStyle
    var hideStaticCursor: Bool
    var loopCursorPosition: Bool
    var useHighResCursors: Bool
    var autoZoomScale: CGFloat
    var clickSoundEnabled: Bool
    var clickSoundVolume: Float
    var clickSoundStyle: ClickSoundStyle
    var clickSoundFileURL: URL?

    // Audio
    var backgroundMusicURL: URL?
    var backgroundMusicVolume: Float
    var backgroundMusicLoop: Bool
    var backgroundMusicFadeIn: Double
    var backgroundMusicFadeOut: Double
    var backgroundMusicDuckingEnabled: Bool
    var backgroundMusicDuckingVolume: Float
    var sourceAudioVolume: Float
    var micAudioVolume: Float
    var micNoiseReductionEnabled: Bool
    var micNoiseGateThreshold: Float

    // Webcam
    var webcamPosition: WebcamPosition
    var webcamSize: CGFloat                  // diameter in px
    var webcamWidth: CGFloat
    var webcamHeight: CGFloat
    var webcamShape: WebcamShape
    var webcamCornerRadius: CGFloat
    var webcamMirror: Bool
    var webcamOffsetX: CGFloat
    var webcamOffsetY: CGFloat
    var webcamZoomScale: CGFloat
    var webcamEnhanceEnabled: Bool
    var webcamBrightness: Float
    var webcamContrast: Float
    var webcamSaturation: Float
    var webcamBorderEnabled: Bool
    var webcamBorderWidth: CGFloat
    var webcamBorderColor: CodableColor
    var webcamShadowEnabled: Bool
    var webcamShadowRadius: CGFloat
    var webcamShadowOpacity: Float

    // Keyboard shortcuts
    var showKeyboardShortcuts: Bool
    var shortcutBadgePosition: ShortcutPosition
    var shortcutBadgeStyle: ShortcutBadgeStyle
    var shortcutBadgeDuration: Double
    var shortcutBadgeFontSize: CGFloat
    var shortcutBadgeBackgroundOpacity: Float
    var shortcutBadgeUseCustomColors: Bool
    var shortcutBadgeBackgroundColor: CodableColor
    var shortcutBadgeTextColor: CodableColor
    var shortcutBadgeShowSingleKeys: Bool
    var keyboardSoundEnabled: Bool
    var keyboardSoundVolume: Float
    var keyboardSoundStyle: KeyboardSoundStyle
    var keyboardSoundFileURL: URL?

    // Subtitles
    var subtitlePosition: SubtitlePosition
    var subtitleFontSize: CGFloat
    var subtitleBackgroundOpacity: Float

    // Branding
    var watermarkEnabled: Bool
    var watermarkText: String
    var watermarkPosition: WatermarkPosition
    var watermarkOpacity: Float
    var watermarkScale: CGFloat

    init(
        backgroundType: BackgroundType,
        backgroundColor: CodableColor,
        backgroundGradientColors: [CodableColor],
        backgroundGradientAngle: Double,
        backgroundImageURL: URL?,
        padding: CGFloat,
        cornerRadius: CGFloat,
        margin: CGFloat,
        shadowEnabled: Bool,
        shadowRadius: CGFloat,
        shadowOffsetX: CGFloat,
        shadowOffsetY: CGFloat,
        shadowOpacity: Float,
        shadowColor: CodableColor,
        motionBlurEnabled: Bool = true,
        motionBlurStrength: Float = 3.0,
        cursorScale: CGFloat,
        cursorStyle: CursorMovementStyle,
        hideStaticCursor: Bool,
        loopCursorPosition: Bool,
        useHighResCursors: Bool,
        autoZoomScale: CGFloat = 1.45,
        clickSoundEnabled: Bool = true,
        clickSoundVolume: Float = 0.38,
        clickSoundStyle: ClickSoundStyle = .provided,
        clickSoundFileURL: URL? = nil,
        backgroundMusicURL: URL? = nil,
        backgroundMusicVolume: Float = 0.25,
        backgroundMusicLoop: Bool = true,
        backgroundMusicFadeIn: Double = 0.6,
        backgroundMusicFadeOut: Double = 0.8,
        backgroundMusicDuckingEnabled: Bool = false,
        backgroundMusicDuckingVolume: Float = 0.18,
        sourceAudioVolume: Float = 1.0,
        micAudioVolume: Float = 1.0,
        micNoiseReductionEnabled: Bool = true,
        micNoiseGateThreshold: Float = -45,
        webcamPosition: WebcamPosition,
        webcamSize: CGFloat,
        webcamWidth: CGFloat = 0,
        webcamHeight: CGFloat = 0,
        webcamShape: WebcamShape = .roundedRect,
        webcamCornerRadius: CGFloat = 36,
        webcamMirror: Bool = false,
        webcamOffsetX: CGFloat = 0,
        webcamOffsetY: CGFloat = 0,
        webcamZoomScale: CGFloat = 0.9,
        webcamEnhanceEnabled: Bool = true,
        webcamBrightness: Float = 0.035,
        webcamContrast: Float = 1.06,
        webcamSaturation: Float = 1.08,
        webcamBorderEnabled: Bool = true,
        webcamBorderWidth: CGFloat = 2,
        webcamBorderColor: CodableColor = CodableColor(r: 1, g: 1, b: 1),
        webcamShadowEnabled: Bool = true,
        webcamShadowRadius: CGFloat = 26,
        webcamShadowOpacity: Float = 0.32,
        showKeyboardShortcuts: Bool,
        shortcutBadgePosition: ShortcutPosition,
        shortcutBadgeStyle: ShortcutBadgeStyle,
        shortcutBadgeDuration: Double = 1.2,
        shortcutBadgeFontSize: CGFloat = 18,
        shortcutBadgeBackgroundOpacity: Float = 1.0,
        shortcutBadgeUseCustomColors: Bool = false,
        shortcutBadgeBackgroundColor: CodableColor = CodableColor(r: 0, g: 0, b: 0),
        shortcutBadgeTextColor: CodableColor = CodableColor(r: 1, g: 1, b: 1),
        shortcutBadgeShowSingleKeys: Bool = true,
        keyboardSoundEnabled: Bool = true,
        keyboardSoundVolume: Float = 0.28,
        keyboardSoundStyle: KeyboardSoundStyle = .provided,
        keyboardSoundFileURL: URL? = nil,
        subtitlePosition: SubtitlePosition = .bottomCenter,
        subtitleFontSize: CGFloat = 24,
        subtitleBackgroundOpacity: Float = 0.70,
        watermarkEnabled: Bool = false,
        watermarkText: String = "",
        watermarkPosition: WatermarkPosition = .topRight,
        watermarkOpacity: Float = 0.45,
        watermarkScale: CGFloat = 1.0
    ) {
        self.backgroundType = backgroundType
        self.backgroundColor = backgroundColor
        self.backgroundGradientColors = backgroundGradientColors
        self.backgroundGradientAngle = backgroundGradientAngle
        self.backgroundImageURL = backgroundImageURL
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.margin = margin
        self.shadowEnabled = shadowEnabled
        self.shadowRadius = shadowRadius
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.shadowOpacity = shadowOpacity
        self.shadowColor = shadowColor
        self.motionBlurEnabled = motionBlurEnabled
        self.motionBlurStrength = motionBlurStrength
        self.cursorScale = cursorScale
        self.cursorStyle = cursorStyle
        self.hideStaticCursor = hideStaticCursor
        self.loopCursorPosition = loopCursorPosition
        self.useHighResCursors = useHighResCursors
        self.autoZoomScale = autoZoomScale
        self.clickSoundEnabled = clickSoundEnabled
        self.clickSoundVolume = clickSoundVolume
        self.clickSoundStyle = clickSoundStyle
        self.clickSoundFileURL = clickSoundFileURL
        self.backgroundMusicURL = backgroundMusicURL
        self.backgroundMusicVolume = backgroundMusicVolume
        self.backgroundMusicLoop = backgroundMusicLoop
        self.backgroundMusicFadeIn = backgroundMusicFadeIn
        self.backgroundMusicFadeOut = backgroundMusicFadeOut
        self.backgroundMusicDuckingEnabled = backgroundMusicDuckingEnabled
        self.backgroundMusicDuckingVolume = backgroundMusicDuckingVolume
        self.sourceAudioVolume = sourceAudioVolume
        self.micAudioVolume = micAudioVolume
        self.micNoiseReductionEnabled = micNoiseReductionEnabled
        self.micNoiseGateThreshold = micNoiseGateThreshold
        self.webcamPosition = webcamPosition
        self.webcamSize = webcamSize
        self.webcamWidth = webcamWidth
        self.webcamHeight = webcamHeight
        self.webcamShape = webcamShape
        self.webcamCornerRadius = webcamCornerRadius
        self.webcamMirror = webcamMirror
        self.webcamOffsetX = webcamOffsetX
        self.webcamOffsetY = webcamOffsetY
        self.webcamZoomScale = webcamZoomScale
        self.webcamEnhanceEnabled = webcamEnhanceEnabled
        self.webcamBrightness = webcamBrightness
        self.webcamContrast = webcamContrast
        self.webcamSaturation = webcamSaturation
        self.webcamBorderEnabled = webcamBorderEnabled
        self.webcamBorderWidth = webcamBorderWidth
        self.webcamBorderColor = webcamBorderColor
        self.webcamShadowEnabled = webcamShadowEnabled
        self.webcamShadowRadius = webcamShadowRadius
        self.webcamShadowOpacity = webcamShadowOpacity
        self.showKeyboardShortcuts = showKeyboardShortcuts
        self.shortcutBadgePosition = shortcutBadgePosition
        self.shortcutBadgeStyle = shortcutBadgeStyle
        self.shortcutBadgeDuration = shortcutBadgeDuration
        self.shortcutBadgeFontSize = shortcutBadgeFontSize
        self.shortcutBadgeBackgroundOpacity = shortcutBadgeBackgroundOpacity
        self.shortcutBadgeUseCustomColors = shortcutBadgeUseCustomColors
        self.shortcutBadgeBackgroundColor = shortcutBadgeBackgroundColor
        self.shortcutBadgeTextColor = shortcutBadgeTextColor
        self.shortcutBadgeShowSingleKeys = shortcutBadgeShowSingleKeys
        self.keyboardSoundEnabled = keyboardSoundEnabled
        self.keyboardSoundVolume = keyboardSoundVolume
        self.keyboardSoundStyle = keyboardSoundStyle
        self.keyboardSoundFileURL = keyboardSoundFileURL
        self.subtitlePosition = subtitlePosition
        self.subtitleFontSize = subtitleFontSize
        self.subtitleBackgroundOpacity = subtitleBackgroundOpacity
        self.watermarkEnabled = watermarkEnabled
        self.watermarkText = watermarkText
        self.watermarkPosition = watermarkPosition
        self.watermarkOpacity = watermarkOpacity
        self.watermarkScale = watermarkScale
        sanitizeForUse()
    }

    private enum CodingKeys: String, CodingKey {
        case backgroundType, backgroundColor, backgroundGradientColors, backgroundGradientAngle, backgroundImageURL
        case padding, cornerRadius, margin
        case shadowEnabled, shadowRadius, shadowOffsetX, shadowOffsetY, shadowOpacity, shadowColor
        case motionBlurEnabled, motionBlurStrength
        case cursorScale, cursorStyle, hideStaticCursor, loopCursorPosition, useHighResCursors, autoZoomScale, clickSoundEnabled, clickSoundVolume, clickSoundStyle, clickSoundFileURL
        case backgroundMusicURL, backgroundMusicVolume, backgroundMusicLoop, backgroundMusicFadeIn, backgroundMusicFadeOut, backgroundMusicDuckingEnabled, backgroundMusicDuckingVolume
        case sourceAudioVolume, micAudioVolume, micNoiseReductionEnabled, micNoiseGateThreshold
        case webcamPosition, webcamSize, webcamWidth, webcamHeight, webcamShape, webcamCornerRadius, webcamMirror, webcamOffsetX, webcamOffsetY, webcamZoomScale
        case webcamEnhanceEnabled, webcamBrightness, webcamContrast, webcamSaturation, webcamBorderEnabled, webcamBorderWidth, webcamBorderColor, webcamShadowEnabled, webcamShadowRadius, webcamShadowOpacity
        case showKeyboardShortcuts, shortcutBadgePosition, shortcutBadgeStyle, shortcutBadgeDuration
        case shortcutBadgeFontSize, shortcutBadgeBackgroundOpacity, shortcutBadgeUseCustomColors, shortcutBadgeBackgroundColor, shortcutBadgeTextColor
        case shortcutBadgeShowSingleKeys, keyboardSoundEnabled, keyboardSoundVolume, keyboardSoundStyle, keyboardSoundFileURL
        case subtitlePosition, subtitleFontSize, subtitleBackgroundOpacity
        case watermarkEnabled, watermarkText, watermarkPosition, watermarkOpacity, watermarkScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backgroundType: try c.decodeIfPresent(BackgroundType.self, forKey: .backgroundType) ?? .solid,
            backgroundColor: try c.decodeIfPresent(CodableColor.self, forKey: .backgroundColor) ?? CodableColor(r: 0.11, g: 0.11, b: 0.12),
            backgroundGradientColors: try c.decodeIfPresent([CodableColor].self, forKey: .backgroundGradientColors) ?? [],
            backgroundGradientAngle: try c.decodeIfPresent(Double.self, forKey: .backgroundGradientAngle) ?? 0,
            backgroundImageURL: try c.decodeIfPresent(URL.self, forKey: .backgroundImageURL),
            padding: try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 80,
            cornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16,
            margin: try c.decodeIfPresent(CGFloat.self, forKey: .margin) ?? 0,
            shadowEnabled: try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true,
            shadowRadius: try c.decodeIfPresent(CGFloat.self, forKey: .shadowRadius) ?? 40,
            shadowOffsetX: try c.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetX) ?? 0,
            shadowOffsetY: try c.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetY) ?? 20,
            shadowOpacity: try c.decodeIfPresent(Float.self, forKey: .shadowOpacity) ?? 0.3,
            shadowColor: try c.decodeIfPresent(CodableColor.self, forKey: .shadowColor) ?? CodableColor(r: 0, g: 0, b: 0),
            motionBlurEnabled: try c.decodeIfPresent(Bool.self, forKey: .motionBlurEnabled) ?? true,
            motionBlurStrength: try c.decodeIfPresent(Float.self, forKey: .motionBlurStrength) ?? 3.0,
            cursorScale: try c.decodeIfPresent(CGFloat.self, forKey: .cursorScale) ?? 1.5,
            cursorStyle: try c.decodeIfPresent(CursorMovementStyle.self, forKey: .cursorStyle) ?? .default,
            hideStaticCursor: try c.decodeIfPresent(Bool.self, forKey: .hideStaticCursor) ?? true,
            loopCursorPosition: try c.decodeIfPresent(Bool.self, forKey: .loopCursorPosition) ?? false,
            useHighResCursors: try c.decodeIfPresent(Bool.self, forKey: .useHighResCursors) ?? true,
            autoZoomScale: try c.decodeIfPresent(CGFloat.self, forKey: .autoZoomScale) ?? 1.45,
            clickSoundEnabled: try c.decodeIfPresent(Bool.self, forKey: .clickSoundEnabled) ?? true,
            clickSoundVolume: try c.decodeIfPresent(Float.self, forKey: .clickSoundVolume) ?? 0.38,
            clickSoundStyle: try c.decodeIfPresent(ClickSoundStyle.self, forKey: .clickSoundStyle) ?? .provided,
            clickSoundFileURL: try c.decodeIfPresent(URL.self, forKey: .clickSoundFileURL),
            backgroundMusicURL: try c.decodeIfPresent(URL.self, forKey: .backgroundMusicURL),
            backgroundMusicVolume: try c.decodeIfPresent(Float.self, forKey: .backgroundMusicVolume) ?? 0.25,
            backgroundMusicLoop: try c.decodeIfPresent(Bool.self, forKey: .backgroundMusicLoop) ?? true,
            backgroundMusicFadeIn: try c.decodeIfPresent(Double.self, forKey: .backgroundMusicFadeIn) ?? 0.6,
            backgroundMusicFadeOut: try c.decodeIfPresent(Double.self, forKey: .backgroundMusicFadeOut) ?? 0.8,
            backgroundMusicDuckingEnabled: try c.decodeIfPresent(Bool.self, forKey: .backgroundMusicDuckingEnabled) ?? false,
            backgroundMusicDuckingVolume: try c.decodeIfPresent(Float.self, forKey: .backgroundMusicDuckingVolume) ?? 0.18,
            sourceAudioVolume: try c.decodeIfPresent(Float.self, forKey: .sourceAudioVolume) ?? 1.0,
            micAudioVolume: try c.decodeIfPresent(Float.self, forKey: .micAudioVolume) ?? 1.0,
            micNoiseReductionEnabled: try c.decodeIfPresent(Bool.self, forKey: .micNoiseReductionEnabled) ?? true,
            micNoiseGateThreshold: try c.decodeIfPresent(Float.self, forKey: .micNoiseGateThreshold) ?? -45,
            webcamPosition: try c.decodeIfPresent(WebcamPosition.self, forKey: .webcamPosition) ?? .bottomRight,
            webcamSize: try c.decodeIfPresent(CGFloat.self, forKey: .webcamSize) ?? 220,
            webcamWidth: try c.decodeIfPresent(CGFloat.self, forKey: .webcamWidth) ?? 0,
            webcamHeight: try c.decodeIfPresent(CGFloat.self, forKey: .webcamHeight) ?? 0,
            webcamShape: try c.decodeIfPresent(WebcamShape.self, forKey: .webcamShape) ?? .roundedRect,
            webcamCornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .webcamCornerRadius) ?? 36,
            webcamMirror: try c.decodeIfPresent(Bool.self, forKey: .webcamMirror) ?? false,
            webcamOffsetX: try c.decodeIfPresent(CGFloat.self, forKey: .webcamOffsetX) ?? 0,
            webcamOffsetY: try c.decodeIfPresent(CGFloat.self, forKey: .webcamOffsetY) ?? 0,
            webcamZoomScale: try c.decodeIfPresent(CGFloat.self, forKey: .webcamZoomScale) ?? 0.9,
            webcamEnhanceEnabled: try c.decodeIfPresent(Bool.self, forKey: .webcamEnhanceEnabled) ?? true,
            webcamBrightness: try c.decodeIfPresent(Float.self, forKey: .webcamBrightness) ?? 0.035,
            webcamContrast: try c.decodeIfPresent(Float.self, forKey: .webcamContrast) ?? 1.06,
            webcamSaturation: try c.decodeIfPresent(Float.self, forKey: .webcamSaturation) ?? 1.08,
            webcamBorderEnabled: try c.decodeIfPresent(Bool.self, forKey: .webcamBorderEnabled) ?? true,
            webcamBorderWidth: try c.decodeIfPresent(CGFloat.self, forKey: .webcamBorderWidth) ?? 2,
            webcamBorderColor: try c.decodeIfPresent(CodableColor.self, forKey: .webcamBorderColor) ?? CodableColor(r: 1, g: 1, b: 1),
            webcamShadowEnabled: try c.decodeIfPresent(Bool.self, forKey: .webcamShadowEnabled) ?? true,
            webcamShadowRadius: try c.decodeIfPresent(CGFloat.self, forKey: .webcamShadowRadius) ?? 26,
            webcamShadowOpacity: try c.decodeIfPresent(Float.self, forKey: .webcamShadowOpacity) ?? 0.32,
            showKeyboardShortcuts: try c.decodeIfPresent(Bool.self, forKey: .showKeyboardShortcuts) ?? true,
            shortcutBadgePosition: try c.decodeIfPresent(ShortcutPosition.self, forKey: .shortcutBadgePosition) ?? .bottomCenter,
            shortcutBadgeStyle: try c.decodeIfPresent(ShortcutBadgeStyle.self, forKey: .shortcutBadgeStyle) ?? .pillDark,
            shortcutBadgeDuration: try c.decodeIfPresent(Double.self, forKey: .shortcutBadgeDuration) ?? 1.2,
            shortcutBadgeFontSize: try c.decodeIfPresent(CGFloat.self, forKey: .shortcutBadgeFontSize) ?? 18,
            shortcutBadgeBackgroundOpacity: try c.decodeIfPresent(Float.self, forKey: .shortcutBadgeBackgroundOpacity) ?? 1.0,
            shortcutBadgeUseCustomColors: try c.decodeIfPresent(Bool.self, forKey: .shortcutBadgeUseCustomColors) ?? false,
            shortcutBadgeBackgroundColor: try c.decodeIfPresent(CodableColor.self, forKey: .shortcutBadgeBackgroundColor) ?? CodableColor(r: 0, g: 0, b: 0),
            shortcutBadgeTextColor: try c.decodeIfPresent(CodableColor.self, forKey: .shortcutBadgeTextColor) ?? CodableColor(r: 1, g: 1, b: 1),
            shortcutBadgeShowSingleKeys: try c.decodeIfPresent(Bool.self, forKey: .shortcutBadgeShowSingleKeys) ?? true,
            keyboardSoundEnabled: try c.decodeIfPresent(Bool.self, forKey: .keyboardSoundEnabled) ?? true,
            keyboardSoundVolume: try c.decodeIfPresent(Float.self, forKey: .keyboardSoundVolume) ?? 0.28,
            keyboardSoundStyle: try c.decodeIfPresent(KeyboardSoundStyle.self, forKey: .keyboardSoundStyle) ?? .provided,
            keyboardSoundFileURL: try c.decodeIfPresent(URL.self, forKey: .keyboardSoundFileURL),
            subtitlePosition: try c.decodeIfPresent(SubtitlePosition.self, forKey: .subtitlePosition) ?? .bottomCenter,
            subtitleFontSize: try c.decodeIfPresent(CGFloat.self, forKey: .subtitleFontSize) ?? 24,
            subtitleBackgroundOpacity: try c.decodeIfPresent(Float.self, forKey: .subtitleBackgroundOpacity) ?? 0.70,
            watermarkEnabled: try c.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? false,
            watermarkText: try c.decodeIfPresent(String.self, forKey: .watermarkText) ?? "",
            watermarkPosition: try c.decodeIfPresent(WatermarkPosition.self, forKey: .watermarkPosition) ?? .topRight,
            watermarkOpacity: try c.decodeIfPresent(Float.self, forKey: .watermarkOpacity) ?? 0.45,
            watermarkScale: try c.decodeIfPresent(CGFloat.self, forKey: .watermarkScale) ?? 1.0
        )
    }

    func sanitizedForUse() -> StylePreset {
        var copy = self
        copy.sanitizeForUse()
        return copy
    }

    mutating func sanitizeForUse() {
        backgroundColor = backgroundColor.sanitized()
        backgroundGradientColors = Array(backgroundGradientColors.prefix(4)).map { $0.sanitized() }
        if backgroundType == .gradient && backgroundGradientColors.count < 2 {
            backgroundGradientColors = [
                CodableColor(r: 0.07, g: 0.08, b: 0.095),
                CodableColor(r: 0.23, g: 0.25, b: 0.31)
            ]
        }
        backgroundGradientAngle = Self.clamped(backgroundGradientAngle, fallback: 0, range: 0...360)

        padding = Self.clamped(padding, fallback: 80, range: 0...180)
        cornerRadius = Self.clamped(cornerRadius, fallback: 16, range: 0...100)
        margin = Self.clamped(margin, fallback: 0, range: 0...200)

        shadowRadius = Self.clamped(shadowRadius, fallback: 40, range: 0...100)
        shadowOffsetX = Self.clamped(shadowOffsetX, fallback: 0, range: -50...50)
        shadowOffsetY = Self.clamped(shadowOffsetY, fallback: 20, range: -50...50)
        shadowOpacity = Self.clamped(shadowOpacity, fallback: 0.3, range: 0...1)
        shadowColor = shadowColor.sanitized()

        motionBlurStrength = Self.clamped(motionBlurStrength, fallback: 3, range: 0...12)
        cursorScale = Self.clamped(cursorScale, fallback: 1.5, range: 0.5...3)
        autoZoomScale = Self.clamped(autoZoomScale, fallback: 1.45, range: 1.05...2.4)
        clickSoundVolume = Self.clamped(clickSoundVolume, fallback: 0.38, range: 0...1)

        backgroundMusicVolume = Self.clamped(backgroundMusicVolume, fallback: 0.25, range: 0...1)
        backgroundMusicFadeIn = Self.clamped(backgroundMusicFadeIn, fallback: 0.6, range: 0...5)
        backgroundMusicFadeOut = Self.clamped(backgroundMusicFadeOut, fallback: 0.8, range: 0...5)
        backgroundMusicDuckingVolume = Self.clamped(backgroundMusicDuckingVolume, fallback: 0.18, range: 0...1)
        sourceAudioVolume = Self.clamped(sourceAudioVolume, fallback: 1, range: 0...1)
        micAudioVolume = Self.clamped(micAudioVolume, fallback: 1, range: 0...1)
        micNoiseGateThreshold = Self.clamped(micNoiseGateThreshold, fallback: -45, range: -65 ... -25)

        webcamSize = Self.clamped(webcamSize, fallback: 220, range: 96...420)
        webcamWidth = Self.optionalDimension(webcamWidth, range: 96...420)
        webcamHeight = Self.optionalDimension(webcamHeight, range: 96...320)
        webcamCornerRadius = Self.clamped(webcamCornerRadius, fallback: 36, range: 0...96)
        webcamOffsetX = Self.clamped(webcamOffsetX, fallback: 0, range: -480...480)
        webcamOffsetY = Self.clamped(webcamOffsetY, fallback: 0, range: -360...360)
        webcamZoomScale = Self.clamped(webcamZoomScale, fallback: 0.9, range: 0.35...1.2)
        webcamBrightness = Self.clamped(webcamBrightness, fallback: 0.035, range: -0.08...0.12)
        webcamContrast = Self.clamped(webcamContrast, fallback: 1.06, range: 0.9...1.22)
        webcamSaturation = Self.clamped(webcamSaturation, fallback: 1.08, range: 0.8...1.35)
        webcamBorderWidth = Self.clamped(webcamBorderWidth, fallback: 2, range: 0...8)
        webcamBorderColor = webcamBorderColor.sanitized()
        webcamShadowRadius = Self.clamped(webcamShadowRadius, fallback: 26, range: 0...80)
        webcamShadowOpacity = Self.clamped(webcamShadowOpacity, fallback: 0.32, range: 0...0.8)

        shortcutBadgeDuration = Self.clamped(shortcutBadgeDuration, fallback: 1.2, range: 0.4...3.0)
        shortcutBadgeFontSize = Self.clamped(shortcutBadgeFontSize, fallback: 18, range: 12...34)
        shortcutBadgeBackgroundOpacity = Self.clamped(shortcutBadgeBackgroundOpacity, fallback: 1, range: 0.15...1)
        shortcutBadgeBackgroundColor = shortcutBadgeBackgroundColor.sanitized()
        shortcutBadgeTextColor = shortcutBadgeTextColor.sanitized()
        keyboardSoundVolume = Self.clamped(keyboardSoundVolume, fallback: 0.28, range: 0...1)

        subtitleFontSize = Self.clamped(subtitleFontSize, fallback: 24, range: 16...42)
        subtitleBackgroundOpacity = Self.clamped(subtitleBackgroundOpacity, fallback: 0.70, range: 0...1)
        watermarkOpacity = Self.clamped(watermarkOpacity, fallback: 0.45, range: 0.12...1)
        watermarkScale = Self.clamped(watermarkScale, fallback: 1, range: 0.7...2.2)
    }

    private static func optionalDimension(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamped(_ value: CGFloat, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamped(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clamped(_ value: Float, fallback: Float, range: ClosedRange<Float>) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static var `default`: StylePreset {
        StylePreset(
            backgroundType: .solid,
            backgroundColor: CodableColor(r: 0.11, g: 0.11, b: 0.12), // dark gray
            backgroundGradientColors: [],
            backgroundGradientAngle: 0,
            backgroundImageURL: nil,
            padding: 80,
            cornerRadius: 16,
            margin: 0,
            shadowEnabled: true,
            shadowRadius: 40,
            shadowOffsetX: 0, shadowOffsetY: 20,
            shadowOpacity: 0.3,
            shadowColor: CodableColor(r: 0, g: 0, b: 0),
            motionBlurEnabled: true,
            motionBlurStrength: 3.0,
            cursorScale: 1.5,
            cursorStyle: .default,
            hideStaticCursor: true,
            loopCursorPosition: false,
            useHighResCursors: true,
            autoZoomScale: 1.45,
            clickSoundEnabled: true,
            clickSoundVolume: 0.38,
            clickSoundStyle: .provided,
            clickSoundFileURL: nil,
            backgroundMusicURL: nil,
            backgroundMusicVolume: 0.25,
            backgroundMusicLoop: true,
            backgroundMusicFadeIn: 0.6,
            backgroundMusicFadeOut: 0.8,
            backgroundMusicDuckingEnabled: false,
            backgroundMusicDuckingVolume: 0.18,
            sourceAudioVolume: 1.0,
            micAudioVolume: 1.0,
            micNoiseReductionEnabled: true,
            micNoiseGateThreshold: -45,
            webcamPosition: .bottomRight,
            webcamSize: 220,
            webcamWidth: 0,
            webcamHeight: 0,
            webcamShape: .roundedRect,
            webcamCornerRadius: 36,
            webcamMirror: false,
            webcamOffsetX: 0,
            webcamOffsetY: 0,
            webcamZoomScale: 0.9,
            webcamEnhanceEnabled: true,
            webcamBrightness: 0.035,
            webcamContrast: 1.06,
            webcamSaturation: 1.08,
            webcamBorderEnabled: true,
            webcamBorderWidth: 2,
            webcamBorderColor: CodableColor(r: 1, g: 1, b: 1),
            webcamShadowEnabled: true,
            webcamShadowRadius: 26,
            webcamShadowOpacity: 0.32,
            showKeyboardShortcuts: true,
            shortcutBadgePosition: .bottomCenter,
            shortcutBadgeStyle: .pillDark,
            shortcutBadgeDuration: 1.2,
            shortcutBadgeFontSize: 18,
            shortcutBadgeBackgroundOpacity: 1.0,
            shortcutBadgeUseCustomColors: false,
            shortcutBadgeBackgroundColor: CodableColor(r: 0, g: 0, b: 0),
            shortcutBadgeTextColor: CodableColor(r: 1, g: 1, b: 1),
            shortcutBadgeShowSingleKeys: true,
            keyboardSoundEnabled: true,
            keyboardSoundVolume: 0.28,
            keyboardSoundStyle: .provided,
            keyboardSoundFileURL: nil,
            subtitlePosition: .bottomCenter,
            subtitleFontSize: 24,
            subtitleBackgroundOpacity: 0.70,
            watermarkEnabled: false,
            watermarkText: "",
            watermarkPosition: .topRight,
            watermarkOpacity: 0.45,
            watermarkScale: 1.0
        )
    }
}

enum BackgroundType: String, Codable, CaseIterable {
    case solid, gradient, image
}

enum CursorMovementStyle: String, Codable {
    case rapid   // very fast, almost instant
    case quick   // fast
    case `default` // balanced
    case slow    // gentle, dramatic
}

enum ClickSoundStyle: String, Codable, CaseIterable {
    case provided
    case mouse
    case trackpad
    case soft
    case typewriter
    case custom

    var label: String {
        switch self {
        case .provided:
            return "Provided"
        case .mouse:
            return "Mouse"
        case .trackpad:
            return "Trackpad"
        case .soft:
            return "Soft"
        case .typewriter:
            return "Clack"
        case .custom:
            return "Custom"
        }
    }
}

enum KeyboardSoundStyle: String, Codable, CaseIterable {
    case provided
    case soft
    case mechanical
    case custom

    var label: String {
        switch self {
        case .provided:
            return "Provided"
        case .soft:
            return "Soft"
        case .mechanical:
            return "Mechanical"
        case .custom:
            return "Custom"
        }
    }

    var fallbackClickStyle: ClickSoundStyle {
        switch self {
        case .provided, .mechanical, .custom:
            return .typewriter
        case .soft:
            return .soft
        }
    }
}

enum WebcamPosition: String, Codable {
    case bottomRight, bottomLeft, topRight, topLeft
}

enum WebcamShape: String, Codable, CaseIterable {
    case circle, roundedRect, square
}

enum ShortcutPosition: String, Codable, CaseIterable, Identifiable {
    case bottomCenter, bottomLeft, bottomRight, topCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomCenter:
            return "Bottom Center"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        case .topCenter:
            return "Top Center"
        }
    }
}

enum ShortcutBadgeStyle: String, Codable, CaseIterable, Identifiable {
    case pillDark, pillLight, minimal, roundedRect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pillDark:
            return "Dark Pill"
        case .pillLight:
            return "Light Pill"
        case .minimal:
            return "Minimal"
        case .roundedRect:
            return "Rounded"
        }
    }
}

enum SubtitlePosition: String, Codable {
    case bottomCenter, middleCenter, topCenter
}

enum WatermarkPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        }
    }
}

struct CodableColor: Codable, Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1.0

    var cgColor: CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    func sanitized() -> CodableColor {
        CodableColor(
            r: Self.channel(r, fallback: 0),
            g: Self.channel(g, fallback: 0),
            b: Self.channel(b, fallback: 0),
            a: Self.channel(a, fallback: 1)
        )
    }

    private static func channel(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}
