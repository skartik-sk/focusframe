import XCTest
import AVFoundation
import CoreImage
import CoreGraphics
@testable import FocusFrame

final class EditorProFeatureTests: XCTestCase {
    func testRendererDrawsShortcutBadgesAndSubtitlesWithoutUnsupportedCoreImageKeys() {
        let renderer = VideoRenderer()
        var config = StylePreset.default
        config.motionBlurEnabled = false
        config.shortcutBadgeStyle = .pillDark
        config.shortcutBadgeFontSize = 22
        config.shortcutBadgeBackgroundOpacity = 0.82
        config.shortcutBadgeUseCustomColors = true
        config.shortcutBadgeBackgroundColor = CodableColor(r: 0.04, g: 0.07, b: 0.11)
        config.shortcutBadgeTextColor = CodableColor(r: 0.94, g: 0.98, b: 1)
        config.subtitleBackgroundOpacity = 0.7

        let outputSize = CGSize(width: 640, height: 360)
        let source = CIImage(color: CIColor(red: 0.12, green: 0.14, blue: 0.16))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
        let shortcut = KeyPressEvent(
            id: UUID(),
            timestamp: 0.2,
            keyCode: 1,
            modifiers: [.command],
            characters: "s",
            displayString: "⌘S"
        )

        let image = renderer.renderFrameImage(
            inputs: VideoRenderer.FrameInputs(
                sourceFrame: source,
                timestamp: 0.2,
                zoomTransform: .identity,
                cursorPosition: nil,
                cursorVisible: false,
                cursorAlpha: 1,
                cursorScale: 1,
                isClicking: false,
                clickAnimationProgress: nil,
                webcamFrame: nil,
                activeShortcuts: [shortcut],
                subtitleText: "Saved successfully"
            ),
            config: config,
            outputSize: outputSize
        )

        XCTAssertEqual(image.extent.width, outputSize.width, accuracy: 0.01)
        XCTAssertEqual(image.extent.height, outputSize.height, accuracy: 0.01)
    }

    func testStylePresetDecodesKeyboardBadgeAppearanceDefaults() throws {
        let style = try JSONDecoder().decode(StylePreset.self, from: Data("{}".utf8))

        XCTAssertEqual(style.shortcutBadgeFontSize, 18)
        XCTAssertEqual(style.shortcutBadgeBackgroundOpacity, 1.0, accuracy: 0.001)
        XCTAssertFalse(style.shortcutBadgeUseCustomColors)
        XCTAssertEqual(style.shortcutBadgeBackgroundColor, CodableColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(style.shortcutBadgeTextColor, CodableColor(r: 1, g: 1, b: 1))
        XCTAssertTrue(style.shortcutBadgeShowSingleKeys)
        XCTAssertTrue(style.keyboardSoundEnabled)
        XCTAssertEqual(style.keyboardSoundVolume, 0.28, accuracy: 0.001)
        XCTAssertEqual(style.keyboardSoundStyle, .provided)
        XCTAssertEqual(style.clickSoundStyle, .provided)
        XCTAssertEqual(style.autoZoomScale, 1.45, accuracy: 0.001)
        XCTAssertEqual(style.webcamSize, 220, accuracy: 0.001)
        XCTAssertEqual(style.webcamZoomScale, 0.9, accuracy: 0.001)
        XCTAssertTrue(style.micNoiseReductionEnabled)
        XCTAssertEqual(style.micNoiseGateThreshold, -45, accuracy: 0.001)
    }

    func testStylePresetDecodingClampsUnsafePersistedValues() throws {
        let json = """
        {
          "backgroundType": "gradient",
          "backgroundColor": { "r": 2, "g": -1, "b": 0.5, "a": 3 },
          "backgroundGradientColors": [{ "r": 2, "g": 0.2, "b": 0.3, "a": 1 }],
          "backgroundGradientAngle": 720,
          "padding": -20,
          "cornerRadius": 999,
          "shadowRadius": 999,
          "shadowOffsetX": -999,
          "shadowOffsetY": 999,
          "shadowOpacity": 5,
          "motionBlurStrength": 44,
          "cursorScale": 9,
          "autoZoomScale": 12,
          "clickSoundVolume": 5,
          "backgroundMusicVolume": 4,
          "backgroundMusicFadeIn": 9,
          "backgroundMusicFadeOut": -3,
          "backgroundMusicDuckingVolume": -2,
          "sourceAudioVolume": 3,
          "micAudioVolume": -1,
          "micNoiseGateThreshold": -120,
          "webcamSize": 12,
          "webcamWidth": 12,
          "webcamHeight": 9999,
          "webcamCornerRadius": 999,
          "webcamOffsetX": -1000,
          "webcamOffsetY": 1000,
          "webcamZoomScale": 8,
          "webcamBrightness": 1,
          "webcamContrast": 4,
          "webcamSaturation": 7,
          "webcamBorderWidth": 99,
          "webcamShadowRadius": 999,
          "webcamShadowOpacity": 5,
          "shortcutBadgeDuration": 10,
          "shortcutBadgeFontSize": 60,
          "shortcutBadgeBackgroundOpacity": -1,
          "keyboardSoundVolume": 3,
          "subtitleFontSize": 100,
          "subtitleBackgroundOpacity": -1,
          "watermarkOpacity": -1,
          "watermarkScale": 9
        }
        """

        let style = try JSONDecoder().decode(StylePreset.self, from: Data(json.utf8))

        XCTAssertEqual(style.backgroundColor, CodableColor(r: 1, g: 0, b: 0.5, a: 1))
        XCTAssertEqual(style.backgroundGradientColors.count, 2)
        XCTAssertEqual(style.backgroundGradientAngle, 360)
        XCTAssertEqual(style.padding, 0)
        XCTAssertEqual(style.cornerRadius, 100)
        XCTAssertEqual(style.shadowRadius, 100)
        XCTAssertEqual(style.shadowOffsetX, -50)
        XCTAssertEqual(style.shadowOffsetY, 50)
        XCTAssertEqual(style.shadowOpacity, 1)
        XCTAssertEqual(style.motionBlurStrength, 12)
        XCTAssertEqual(style.cursorScale, 3)
        XCTAssertEqual(style.autoZoomScale, 2.4)
        XCTAssertEqual(style.clickSoundVolume, 1)
        XCTAssertEqual(style.backgroundMusicVolume, 1)
        XCTAssertEqual(style.backgroundMusicFadeIn, 5)
        XCTAssertEqual(style.backgroundMusicFadeOut, 0)
        XCTAssertEqual(style.backgroundMusicDuckingVolume, 0)
        XCTAssertEqual(style.sourceAudioVolume, 1)
        XCTAssertEqual(style.micAudioVolume, 0)
        XCTAssertEqual(style.micNoiseGateThreshold, -65)
        XCTAssertEqual(style.webcamSize, 96)
        XCTAssertEqual(style.webcamWidth, 96)
        XCTAssertEqual(style.webcamHeight, 320)
        XCTAssertEqual(style.webcamCornerRadius, 96)
        XCTAssertEqual(style.webcamOffsetX, -480)
        XCTAssertEqual(style.webcamOffsetY, 360)
        XCTAssertEqual(style.webcamZoomScale, 1.2)
        XCTAssertEqual(style.webcamBrightness, 0.12, accuracy: 0.001)
        XCTAssertEqual(style.webcamContrast, 1.22, accuracy: 0.001)
        XCTAssertEqual(style.webcamSaturation, 1.35, accuracy: 0.001)
        XCTAssertEqual(style.webcamBorderWidth, 8)
        XCTAssertEqual(style.webcamShadowRadius, 80)
        XCTAssertEqual(style.webcamShadowOpacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(style.shortcutBadgeDuration, 3.0)
        XCTAssertEqual(style.shortcutBadgeFontSize, 34)
        XCTAssertEqual(style.shortcutBadgeBackgroundOpacity, 0.15, accuracy: 0.001)
        XCTAssertEqual(style.keyboardSoundVolume, 1)
        XCTAssertEqual(style.subtitleFontSize, 42)
        XCTAssertEqual(style.subtitleBackgroundOpacity, 0)
        XCTAssertEqual(style.watermarkOpacity, 0.12, accuracy: 0.001)
        XCTAssertEqual(style.watermarkScale, 2.2)
    }

    func testStylePresetSanitizerRejectsNonFiniteRuntimeValues() {
        var style = StylePreset.default
        style.backgroundColor = CodableColor(r: .nan, g: .infinity, b: -1, a: .nan)
        style.backgroundGradientAngle = .infinity
        style.padding = .nan
        style.shadowOpacity = .infinity
        style.motionBlurStrength = .nan
        style.cursorScale = .infinity
        style.autoZoomScale = .nan
        style.backgroundMusicFadeIn = .nan
        style.webcamWidth = .infinity
        style.webcamHeight = .nan
        style.webcamBrightness = .nan
        style.shortcutBadgeDuration = .nan
        style.watermarkScale = .infinity

        let sanitized = style.sanitizedForUse()

        XCTAssertEqual(sanitized.backgroundColor, CodableColor(r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(sanitized.backgroundGradientAngle, 0)
        XCTAssertEqual(sanitized.padding, 80)
        XCTAssertEqual(sanitized.shadowOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(sanitized.motionBlurStrength, 3, accuracy: 0.001)
        XCTAssertEqual(sanitized.cursorScale, 1.5)
        XCTAssertEqual(sanitized.autoZoomScale, 1.45)
        XCTAssertEqual(sanitized.backgroundMusicFadeIn, 0.6)
        XCTAssertEqual(sanitized.webcamWidth, 0)
        XCTAssertEqual(sanitized.webcamHeight, 0)
        XCTAssertEqual(sanitized.webcamBrightness, 0.035, accuracy: 0.001)
        XCTAssertEqual(sanitized.shortcutBadgeDuration, 1.2)
        XCTAssertEqual(sanitized.watermarkScale, 1)
    }

    func testBuiltInStylePresetsKeepReadableWebcamAndAudioDefaults() {
        for preset in StylePresetManager.defaultPresets {
            XCTAssertGreaterThanOrEqual(preset.webcamSize, 220)
            XCTAssertEqual(preset.webcamZoomScale, 0.9, accuracy: 0.001)
            XCTAssertTrue(preset.micNoiseReductionEnabled)
            XCTAssertEqual(preset.micNoiseGateThreshold, -45, accuracy: 0.001)
        }
    }

    func testShortcutDisplayFilterHidesOnlyPlainSingleKeysWhenDisabled() {
        var style = StylePreset.default
        style.shortcutBadgeShowSingleKeys = false
        style.shortcutBadgeDuration = 1.0

        let plainSingleKey = KeyPressEvent(
            id: UUID(),
            timestamp: 1.0,
            keyCode: 0,
            modifiers: [],
            characters: "a",
            displayString: "A"
        )
        let modifiedShortcut = KeyPressEvent(
            id: UUID(),
            timestamp: 1.0,
            keyCode: 0,
            modifiers: [.command],
            characters: "a",
            displayString: "⌘A"
        )
        let namedKey = KeyPressEvent(
            id: UUID(),
            timestamp: 1.0,
            keyCode: 53,
            modifiers: [],
            characters: nil,
            displayString: "Esc"
        )

        let visible = KeyboardShortcutDisplayFilter.activeShortcuts(
            at: 1.2,
            events: [plainSingleKey, modifiedShortcut, namedKey],
            style: style
        )

        XCTAssertEqual(visible.map(\.displayString), ["⌘A", "Esc"])
    }

    func testShortcutDisplayFilterRespectsBadgeDurationWindow() {
        var style = StylePreset.default
        style.shortcutBadgeDuration = 0.65

        let shortcut = KeyPressEvent(
            id: UUID(),
            timestamp: 2.0,
            keyCode: 1,
            modifiers: [.command],
            characters: "s",
            displayString: "⌘S"
        )

        XCTAssertEqual(
            KeyboardShortcutDisplayFilter.activeShortcuts(at: 2.64, events: [shortcut], style: style).count,
            1
        )
        XCTAssertTrue(
            KeyboardShortcutDisplayFilter.activeShortcuts(at: 2.66, events: [shortcut], style: style).isEmpty
        )
    }

    func testProvidedMouseAndKeySoundsAreBundledAndReadable() throws {
        let mouseURL = try XCTUnwrap(SoundEffectLibrary.clickURL(style: .provided, customURL: nil))
        let keyURL = try XCTUnwrap(SoundEffectLibrary.keyboardURL(style: .provided, customURL: nil))

        XCTAssertTrue(FileManager.default.fileExists(atPath: mouseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertFalse(try SoundEffectMixer.loadMonoSamples(from: mouseURL, maxDuration: 0.32).isEmpty)
        XCTAssertFalse(try SoundEffectMixer.loadMonoSamples(from: keyURL, maxDuration: 0.24).isEmpty)
    }

    @MainActor
    func testCleanFillerWordsCanCreateCutsForEmptyCaptionPauses() throws {
        let directory = try makeTemporaryDirectory()
        let project = try makeProject(in: directory)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }
        let editorVM = EditorVM(project: project)

        editorVM.captionSegments = [
            CaptionSegment(
                id: UUID(),
                start: 0.4,
                end: 1.7,
                text: "Um, I mean this is good."
            ),
            CaptionSegment(
                id: UUID(),
                start: 2.0,
                end: 2.6,
                text: "uh"
            ),
            CaptionSegment(
                id: UUID(),
                start: 4.0,
                end: 5.0,
                text: "No filler here."
            )
        ]

        let removed = editorVM.cleanFillerWordsFromCaptions(removeEmptySegments: true)

        XCTAssertEqual(removed, 3)
        XCTAssertEqual(editorVM.captionSegments.map(\.text), ["this is good.", "No filler here."])
        XCTAssertEqual(editorVM.project.editActions.filter { $0.type == .cut }.count, 1)
        let cut = try XCTUnwrap(editorVM.project.editActions.first)
        XCTAssertEqual(cut.startTime, 2.0, accuracy: 0.01)
        XCTAssertEqual(cut.endTime, 2.6, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("captions.json").path))
    }

    func testLocalSharePackageIncludesVideoCaptionsChaptersAndNotes() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.chapterMarkers = [
            ChapterMarker(time: 0, title: "Intro"),
            ChapterMarker(time: 12.5, title: "Demo")
        ]
        project.titleCardSegments = [
            TitleCardSegment(
                startTime: 0,
                endTime: 2,
                kind: .intro,
                style: .gradient,
                title: "Launch Demo",
                subtitle: "Customer walkthrough"
            )
        ]
        project.speakerNotes = "Use this when sending a local review link."
        project.sharePageSettings = SharePageSettings(
            titleOverride: "Launch Demo",
            description: "A polished customer walkthrough.",
            creatorName: "Kartik",
            callToActionLabel: "Book a demo",
            callToActionURL: "https://example.com/demo",
            accentColor: CodableColor(r: 0.1, g: 0.4, b: 0.9)
        )

        let captions = [
            CaptionSegment(id: UUID(), start: 0, end: 2, text: "Hello"),
            CaptionSegment(id: UUID(), start: 3, end: 5, text: "World")
        ]
        let captionsURL = directory.appendingPathComponent("captions.json")
        try JSONEncoder().encode(captions).write(to: captionsURL)
        project.captionsFileURL = captionsURL

        let exportedVideo = directory.appendingPathComponent("exported.mp4")
        try Data([0, 1, 2, 3, 4, 5]).write(to: exportedVideo)

        let indexURL = try LocalSharePackageService().createPackage(
            videoURL: exportedVideo,
            project: project
        )
        let packageDirectory = indexURL.deletingLastPathComponent()

        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("assets/video.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("assets/captions.vtt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("metadata.json").path))

        let html = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(html.contains("Launch Demo"))
        XCTAssertTrue(html.contains("A polished customer walkthrough."))
        XCTAssertTrue(html.contains("Book a demo"))
        XCTAssertTrue(html.contains("https://example.com/demo"))
        XCTAssertTrue(html.contains("Use this when sending a local review link."))
        XCTAssertTrue(html.contains("Reactions"))
        XCTAssertTrue(html.contains("Comments"))
        XCTAssertTrue(html.contains("chapters"))
        XCTAssertTrue(html.contains("Story Cards"))
        XCTAssertTrue(html.contains("Customer walkthrough"))
        XCTAssertTrue(html.contains("state.reactions.push"))
        XCTAssertTrue(html.contains("jumpTo"))
    }

    func testLocalSharePackageEscapesScriptDataAndSanitizesCaptions() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.titleCardSegments = [
            TitleCardSegment(
                startTime: 0,
                endTime: 2,
                kind: .section,
                style: .gradient,
                title: #"</script><img src=x onerror=alert(1)>"#,
                subtitle: "Safe local card"
            )
        ]

        let captions = [
            CaptionSegment(
                id: UUID(),
                start: 0,
                end: 2,
                text: "line one\nline two --> next"
            )
        ]
        let captionsURL = directory.appendingPathComponent("captions.json")
        try JSONEncoder().encode(captions).write(to: captionsURL)
        project.captionsFileURL = captionsURL

        let exportedVideo = directory.appendingPathComponent("exported.mp4")
        try Data([0, 1, 2, 3, 4, 5]).write(to: exportedVideo)

        let indexURL = try LocalSharePackageService().createPackage(
            videoURL: exportedVideo,
            project: project
        )
        let packageDirectory = indexURL.deletingLastPathComponent()
        let html = try String(contentsOf: indexURL, encoding: .utf8)
        let vtt = try String(
            contentsOf: packageDirectory.appendingPathComponent("assets/captions.vtt"),
            encoding: .utf8
        )

        XCTAssertTrue(html.contains(#"<\/script><img src=x onerror=alert(1)>"#))
        XCTAssertFalse(html.contains(#"</script><img"#))
        XCTAssertTrue(vtt.contains("line one line two - -> next"))
        XCTAssertFalse(vtt.contains("line two --> next"))
    }

    func testLocalSharePackageSanitizesUnsafeShareSettingsAndCaptionTimes() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.sharePageSettings = SharePageSettings(
            titleOverride: String(repeating: "A", count: 180),
            description: "Description",
            creatorName: "Creator",
            callToActionLabel: "Go",
            callToActionURL: "javascript:alert(1)",
            accentColor: CodableColor(r: .nan, g: 2, b: -1)
        )

        let captions = [
            CaptionSegment(id: UUID(), start: -10, end: 120_000, text: "Safe"),
            CaptionSegment(id: UUID(), start: 1, end: 2, text: "   ")
        ]
        let captionsURL = directory.appendingPathComponent("captions.json")
        try JSONEncoder().encode(captions).write(to: captionsURL)
        project.captionsFileURL = captionsURL

        let exportedVideo = directory.appendingPathComponent("exported.mp4")
        try Data([0, 1, 2, 3, 4, 5]).write(to: exportedVideo)

        let indexURL = try LocalSharePackageService().createPackage(
            videoURL: exportedVideo,
            project: project
        )
        let packageDirectory = indexURL.deletingLastPathComponent()
        let html = try String(contentsOf: indexURL, encoding: .utf8)
        let vtt = try String(
            contentsOf: packageDirectory.appendingPathComponent("assets/captions.vtt"),
            encoding: .utf8
        )

        XCTAssertTrue(html.contains("--accent: #00FF00"))
        XCTAssertFalse(html.contains("javascript:alert"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 24:00:00.000"))
        XCTAssertFalse(vtt.contains("00:00:01.000 --> 00:00:02.000"))
    }

    @MainActor
    func testLookPresetAppliesCameraPolishWithoutManualTweaking() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        let webcamURL = directory.appendingPathComponent("webcam.mov")
        try Data([0, 1, 2, 3]).write(to: webcamURL)
        project.webcamFileURL = webcamURL
        project.webcamEnabled = false
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.applyLookPreset(.creator)

        XCTAssertTrue(editorVM.project.webcamEnabled)
        XCTAssertTrue(editorVM.project.style.webcamEnhanceEnabled)
        XCTAssertTrue(editorVM.project.style.webcamBorderEnabled)
        XCTAssertTrue(editorVM.project.style.webcamShadowEnabled)
        XCTAssertGreaterThan(editorVM.project.style.webcamBrightness, 0)
        XCTAssertGreaterThan(editorVM.project.style.webcamSaturation, 1)
        XCTAssertEqual(editorVM.project.style.webcamShape, .roundedRect)
    }

    @MainActor
    func testStudioPresetAppliesFocusFrameDefaults() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        let webcamURL = directory.appendingPathComponent("webcam.mov")
        try Data([0, 1, 2, 3]).write(to: webcamURL)
        project.webcamFileURL = webcamURL
        project.webcamEnabled = false
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.applyLookPreset(.studio)

        XCTAssertEqual(editorVM.project.style.cursorStyle, .slow)
        XCTAssertGreaterThanOrEqual(editorVM.project.style.autoZoomScale, 1.5)
        XCTAssertTrue(editorVM.project.style.motionBlurEnabled)
        XCTAssertTrue(editorVM.project.style.hideStaticCursor)
        XCTAssertTrue(editorVM.project.showKeyboardShortcuts)
        XCTAssertTrue(editorVM.project.style.showKeyboardShortcuts)
        XCTAssertEqual(editorVM.project.style.shortcutBadgePosition, .bottomCenter)
        XCTAssertEqual(editorVM.project.style.shortcutBadgeStyle, .pillDark)
        XCTAssertTrue(editorVM.project.webcamEnabled)
        XCTAssertEqual(editorVM.project.style.webcamShape, .roundedRect)
        XCTAssertTrue(editorVM.project.style.webcamEnhanceEnabled)
    }

    @MainActor
    func testManualZoomAddedFromTimelineFocusesNearestCursorInsteadOfScreenCenter() throws {
        let directory = try makeTemporaryDirectory()
        let project = try makeProject(in: directory)
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.addZoomSegment(at: 1.0)

        let selectedID = try XCTUnwrap(editorVM.selectedZoomSegmentID)
        let segment = try XCTUnwrap(editorVM.zoomSegments.first { $0.id == selectedID })

        XCTAssertEqual(segment.source, .manual)
        XCTAssertTrue(segment.zoomRect.contains(CGPoint(x: 320, y: 780)), "Manual zooms added near a cursor action should focus that cursor position in render space")
        XCTAssertFalse(segment.zoomRect.contains(CGPoint(x: 1500, y: 900)), "Manual zooms should not default to a broad center rect when cursor focus exists")
    }

    @MainActor
    func testCameraLayoutsAreStoredAsTimelineSegments() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        let webcamURL = directory.appendingPathComponent("webcam.mov")
        try Data([0, 1, 2, 3]).write(to: webcamURL)
        project.webcamFileURL = webcamURL
        project.webcamEnabled = true
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.seek(to: 4.0)
        editorVM.addCameraLayout(mode: .cameraOnly)
        editorVM.addCameraLayout(mode: .sideBySide, at: 9.0)

        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.count, 2)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.first?.mode, .cameraOnly)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.last?.mode, .sideBySide)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.first?.startTime ?? -1, 4.0, accuracy: 0.01)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.last?.startTime ?? -1, 9.0, accuracy: 0.01)

        guard var layout = editorVM.project.cameraLayoutSegments?.first else {
            return XCTFail("Expected layout")
        }
        layout.mode = .screenOnly
        layout.startTime = 3.0
        layout.endTime = 6.0
        editorVM.updateCameraLayout(layout)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.first?.mode, .screenOnly)

        editorVM.removeCameraLayout(layout.id)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.count, 1)
    }

    @MainActor
    func testSmartTitleCardsAndWatermarkSettingsAreStored() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.sharePageSettings = SharePageSettings(
            titleOverride: "Product Launch",
            description: "The sharp version for customers.",
            creatorName: "Kartik",
            callToActionLabel: "Try it now",
            callToActionURL: "https://example.com",
            accentColor: CodableColor(r: 0.4, g: 0.2, b: 0.9)
        )
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        let count = editorVM.addSmartTitleCards()
        editorVM.project.style.watermarkEnabled = true
        editorVM.project.style.watermarkText = "Kartik"
        editorVM.project.style.watermarkPosition = .bottomRight
        editorVM.markProjectModified()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(editorVM.project.titleCardSegments?.first?.kind, .intro)
        XCTAssertEqual(editorVM.project.titleCardSegments?.first?.title, "Product Launch")
        XCTAssertEqual(editorVM.project.titleCardSegments?.last?.kind, .outro)
        XCTAssertEqual(editorVM.project.titleCardSegments?.last?.title, "Try it now")
        XCTAssertTrue(editorVM.project.style.watermarkEnabled)
        XCTAssertEqual(editorVM.project.style.watermarkText, "Kartik")
        XCTAssertEqual(editorVM.project.style.watermarkPosition, .bottomRight)
    }

    @MainActor
    func testSmartFinishAppliesComposedEditorDefaults() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.sharePageSettings = SharePageSettings(
            titleOverride: "Customer Demo",
            description: "A concise walkthrough.",
            creatorName: "Kartik",
            callToActionLabel: "Get access",
            callToActionURL: "https://example.com",
            accentColor: CodableColor(r: 0.2, g: 0.45, b: 0.9)
        )

        let captionsURL = directory.appendingPathComponent("captions.json")
        try JSONEncoder().encode([
            CaptionSegment(id: UUID(), start: 0, end: 2, text: "Welcome to the demo."),
            CaptionSegment(id: UUID(), start: 3, end: 5, text: "Here is the main flow.")
        ]).write(to: captionsURL)
        project.captionsFileURL = captionsURL

        let keyEventsURL = directory.appendingPathComponent("keys.json")
        try JSONEncoder().encode([
            KeyPressEvent(
                id: UUID(),
                timestamp: 1.0,
                keyCode: 1,
                modifiers: [.command],
                characters: "s",
                displayString: "⌘S"
            )
        ]).write(to: keyEventsURL)
        project.keyEventsFileURL = keyEventsURL

        let webcamURL = directory.appendingPathComponent("webcam.mov")
        try Data([0, 1, 2, 3]).write(to: webcamURL)
        project.webcamFileURL = webcamURL
        project.webcamEnabled = false
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        let summary = editorVM.applySmartFinish()

        XCTAssertTrue(summary.captionsEnabled)
        XCTAssertTrue(summary.keyboardEnabled)
        XCTAssertTrue(summary.webcamEnabled)
        XCTAssertTrue(summary.watermarkEnabled)
        XCTAssertGreaterThanOrEqual(summary.titleCardCount, 2)
        XCTAssertTrue(editorVM.project.subtitlesEnabled == true)
        XCTAssertTrue(editorVM.project.showKeyboardShortcuts)
        XCTAssertTrue(editorVM.project.webcamEnabled)
        XCTAssertEqual(editorVM.project.style.watermarkText, "Kartik")
        XCTAssertEqual(editorVM.project.titleCardSegments?.first?.title, "Customer Demo")
        XCTAssertFalse(editorVM.project.chapterMarkers?.isEmpty ?? true)
    }

    @MainActor
    func testEditorLoadEnablesExistingCaptionsAndKeyboardBadgesForPreview() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.subtitlesEnabled = false
        project.showKeyboardShortcuts = true

        let captionsURL = directory.appendingPathComponent("captions.json")
        try JSONEncoder().encode([
            CaptionSegment(id: UUID(), start: 0.2, end: 1.4, text: "Preview subtitle")
        ]).write(to: captionsURL)
        project.captionsFileURL = captionsURL

        let keyEventsURL = directory.appendingPathComponent("keys.json")
        try JSONEncoder().encode([
            KeyPressEvent(
                id: UUID(),
                timestamp: 0.6,
                keyCode: 1,
                modifiers: [.command],
                characters: "s",
                displayString: "⌘S"
            )
        ]).write(to: keyEventsURL)
        project.keyEventsFileURL = keyEventsURL

        let editorVM = EditorVM(project: project)

        XCTAssertEqual(editorVM.captionSegments.map(\.text), ["Preview subtitle"])
        XCTAssertTrue(editorVM.project.subtitlesEnabled == true)
        XCTAssertTrue(editorVM.productionReadiness.hasCaptions)
        XCTAssertTrue(editorVM.hasKeyboardEvents)
        XCTAssertEqual(editorVM.recordedKeyEvents.map(\.displayString), ["⌘S"])
        XCTAssertTrue(editorVM.productionReadiness.hasKeyboard)
    }

    @MainActor
    func testEditorLoadCombinesCursorDrivenZoomsAndKeyboardBadges() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.showKeyboardShortcuts = true
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 0.0, position: CGPoint(x: 260, y: 260), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 420, y: 320), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.1, position: CGPoint(x: 420, y: 320), isClicking: false, clickType: .leftUp, scrollDelta: nil),
                CursorFrame(timestamp: 2.1, position: CGPoint(x: 470, y: 350), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.2, position: CGPoint(x: 470, y: 350), isClicking: false, clickType: .leftUp, scrollDelta: nil),
                CursorFrame(timestamp: 3.4, position: CGPoint(x: 520, y: 380), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 3.5, position: CGPoint(x: 520, y: 380), isClicking: false, clickType: .leftUp, scrollDelta: nil)
            ],
            sampleRate: 60,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )
        try JSONEncoder().encode(cursorRecording).write(to: project.cursorDataFileURL)

        let keyEventsURL = directory.appendingPathComponent("combined-key-events.json")
        try JSONEncoder().encode([
            KeyPressEvent(
                id: UUID(),
                timestamp: 1.3,
                keyCode: 1,
                modifiers: [.command],
                characters: "s",
                displayString: "⌘S"
            ),
            KeyPressEvent(
                id: UUID(),
                timestamp: 2.5,
                keyCode: 3,
                modifiers: [],
                characters: "f",
                displayString: "F"
            )
        ]).write(to: keyEventsURL)
        project.keyEventsFileURL = keyEventsURL

        let editorVM = EditorVM(project: project)

        XCTAssertEqual(editorVM.zoomSegments.count, 1)
        XCTAssertTrue(editorVM.zoomSegments.allSatisfy { $0.source == .automatic })
        XCTAssertLessThanOrEqual(editorVM.zoomSegments[0].startTime, 0.5)
        XCTAssertGreaterThanOrEqual(editorVM.zoomSegments[0].endTime, 4.9)
        XCTAssertEqual(editorVM.recordedKeyEvents.map(\.displayString), ["⌘S", "F"])
        XCTAssertTrue(editorVM.hasKeyboardEvents)
        XCTAssertTrue(editorVM.productionReadiness.hasFocus)
        XCTAssertTrue(editorVM.productionReadiness.hasKeyboard)
    }

    @MainActor
    func testEditorToolbarActionsMutateRealTimelineState() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        let webcamURL = directory.appendingPathComponent("webcam.mov")
        try Data([0, 1, 2, 3]).write(to: webcamURL)
        project.webcamFileURL = webcamURL
        project.webcamEnabled = true
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        let initialZoomCount = editorVM.zoomSegments.count

        editorVM.addZoomSegment(at: 6.0)
        XCTAssertEqual(editorVM.zoomSegments.count, initialZoomCount + 1)
        let addedZoom = try XCTUnwrap(editorVM.zoomSegments.last)
        XCTAssertEqual(addedZoom.zoomInDuration, 0.55, accuracy: 0.001)
        XCTAssertEqual(addedZoom.zoomOutDuration, 0.45, accuracy: 0.001)
        XCTAssertGreaterThan(addedZoom.duration, 1.5)
        let zoomID = addedZoom.id
        editorVM.selectZoomSegment(zoomID)
        editorVM.removeSelectedZoomSegment()
        XCTAssertFalse(editorVM.zoomSegments.contains { $0.id == zoomID })

        editorVM.cutRegion(startTime: 1.0, endTime: 2.25)
        XCTAssertEqual(editorVM.project.editActions.filter { $0.type == .cut }.count, 1)

        editorVM.setSpeed(startTime: 3.0, endTime: 5.0, multiplier: 2.5)
        XCTAssertEqual(editorVM.speedMultiplier(at: 4.0), 2.5, accuracy: 0.001)

        editorVM.hideCursorRegion(startTime: 5.0, endTime: 6.0)
        XCTAssertEqual(editorVM.project.editActions.filter { $0.type == .hideCursor }.count, 1)

        editorVM.addOverlay(type: .text, at: 7.0)
        var overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        XCTAssertEqual(editorVM.selectedTimelineItem, .overlay(overlay.id))
        overlay.text = "Updated callout"
        overlay.rect = CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        editorVM.updateOverlay(overlay)
        XCTAssertEqual(editorVM.project.overlayElements?.first?.text, "Updated callout")
        XCTAssertLessThanOrEqual(editorVM.project.overlayElements?.first?.rect.maxX ?? 2, 1.0)
        editorVM.selectOverlay(overlay.id)
        XCTAssertTrue(editorVM.removeSelectedTimelineItem())
        XCTAssertTrue(editorVM.project.overlayElements?.isEmpty ?? true)
        editorVM.selectOverlay(overlay.id)
        XCTAssertFalse(editorVM.removeSelectedTimelineItem())
        XCTAssertNil(editorVM.selectedTimelineItem)

        editorVM.addCameraLayout(mode: .sideBySide, at: 8.0)
        XCTAssertEqual(editorVM.project.cameraLayoutSegments?.first?.mode, .sideBySide)
        let layoutID = try XCTUnwrap(editorVM.project.cameraLayoutSegments?.first?.id)
        XCTAssertEqual(editorVM.selectedTimelineItem, .cameraLayout(layoutID))
        editorVM.selectCameraLayout(layoutID)
        XCTAssertTrue(editorVM.removeSelectedTimelineItem())
        XCTAssertTrue(editorVM.project.cameraLayoutSegments?.isEmpty ?? true)
    }

    @MainActor
    func testTranscriptButtonBackendsAddUpdateImportExportAndRemoveCaptions() throws {
        let directory = try makeTemporaryDirectory()
        let project = try makeProject(in: directory)
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)

        editorVM.addCaptionSegment(at: 2.0)
        XCTAssertEqual(editorVM.captionSegments.count, 1)
        XCTAssertTrue(editorVM.project.subtitlesEnabled == true)

        let added = try XCTUnwrap(editorVM.captionSegments.first)
        editorVM.updateCaptionSegment(CaptionSegment(
            id: added.id,
            start: 2.2,
            end: 4.0,
            text: "Updated caption"
        ))
        XCTAssertEqual(editorVM.captionSegments.first?.text, "Updated caption")
        XCTAssertEqual(editorVM.captionSegments.first?.start ?? 0, 2.2, accuracy: 0.01)

        let jsonURL = directory.appendingPathComponent("captions-export.json")
        let srtURL = directory.appendingPathComponent("captions-export.srt")
        let vttURL = directory.appendingPathComponent("captions-export.vtt")
        try editorVM.exportCaptions(to: jsonURL)
        try editorVM.exportCaptions(to: srtURL)
        try editorVM.exportCaptions(to: vttURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srtURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vttURL.path))

        let importURL = directory.appendingPathComponent("captions-import.srt")
        try """
        1
        00:00:05,000 --> 00:00:06,500
        Imported caption

        """.write(to: importURL, atomically: true, encoding: .utf8)
        try editorVM.importCaptions(from: importURL)
        XCTAssertEqual(editorVM.captionSegments.count, 1)
        XCTAssertEqual(editorVM.captionSegments.first?.text, "Imported caption")

        let importedID = try XCTUnwrap(editorVM.captionSegments.first?.id)
        editorVM.removeCaptionSegment(importedID)
        XCTAssertTrue(editorVM.captionSegments.isEmpty)
        XCTAssertFalse(editorVM.project.subtitlesEnabled == true)
    }

    func testCaptionImportRejectsOversizedFilesBeforeDecode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("huge-captions.srt")
        let oversizedBytes = Int(EditorVM.maxCaptionImportBytes) + 1
        try Data(repeating: 0, count: oversizedBytes).write(to: url)

        do {
            _ = try EditorVM.importedCaptionSegments(from: url)
            XCTFail("Expected oversized caption import to fail")
        } catch CaptionImportError.fileTooLarge {
        } catch {
            XCTFail("Expected fileTooLarge, got \(error)")
        }
    }

    @MainActor
    func testTimelineEditButtonBackendsUpdateRemoveUndoAndRedoActions() throws {
        let directory = try makeTemporaryDirectory()
        let project = try makeProject(in: directory)
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)

        editorVM.cutRegion(startTime: 1.0, endTime: 2.0)
        editorVM.setSpeed(startTime: 3.0, endTime: 5.0, multiplier: 2.75)
        editorVM.hideCursorRegion(startTime: 6.0, endTime: 7.0)
        XCTAssertEqual(editorVM.project.editActions.count, 3)

        let speedID = try XCTUnwrap(editorVM.project.editActions.first { $0.type == .speedChange }?.id)
        editorVM.updateEditActionTiming(speedID, startTime: 3.5, endTime: 4.5)
        let speedAction = try XCTUnwrap(editorVM.project.editActions.first { $0.id == speedID })
        XCTAssertEqual(speedAction.startTime, 3.5, accuracy: 0.01)
        XCTAssertEqual(speedAction.endTime, 4.5, accuracy: 0.01)
        XCTAssertEqual(editorVM.speedMultiplier(at: 4.0), 2.75, accuracy: 0.001)

        let cutID = try XCTUnwrap(editorVM.project.editActions.first { $0.type == .cut }?.id)
        editorVM.removeEditAction(cutID)
        XCTAssertFalse(editorVM.project.editActions.contains { $0.id == cutID })

        editorVM.undo()
        XCTAssertTrue(editorVM.project.editActions.contains { $0.id == cutID })
        editorVM.redo()
        XCTAssertFalse(editorVM.project.editActions.contains { $0.id == cutID })
    }

    @MainActor
    func testInspectorUtilityBackendsForChaptersCardsMusicRawAssetsAndSaveFrame() async throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.videoFileURL = directory.appendingPathComponent("playable.mov")
        project.duration = CMTime(seconds: 2.0, preferredTimescale: 600)
        project.sourceRect = CGRect(x: 0, y: 0, width: 640, height: 360)
        try await writePlayableVideo(to: project.videoFileURL, size: CGSize(width: 640, height: 360))
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)

        editorVM.addChapter(at: 0.6)
        var chapter = try XCTUnwrap(editorVM.project.chapterMarkers?.first)
        chapter.title = "Updated Chapter"
        chapter.time = 0.8
        editorVM.updateChapter(chapter)
        XCTAssertEqual(editorVM.project.chapterMarkers?.first?.title, "Updated Chapter")
        let chaptersURL = directory.appendingPathComponent("chapters.txt")
        try editorVM.exportChapters(to: chaptersURL)
        XCTAssertTrue(try String(contentsOf: chaptersURL).contains("Updated Chapter"))
        editorVM.removeChapter(chapter.id)
        XCTAssertTrue(editorVM.project.chapterMarkers?.isEmpty ?? true)

        editorVM.addTitleCard(kind: .intro)
        editorVM.addTitleCard(kind: .section, at: 1.0)
        editorVM.addTitleCard(kind: .outro)
        XCTAssertGreaterThanOrEqual(editorVM.titleCards.count, 3)
        var card = try XCTUnwrap(editorVM.titleCards.first)
        editorVM.selectTitleCard(card.id)
        XCTAssertEqual(editorVM.selectedTimelineItem, .titleCard(card.id))
        card.title = "Edited Card"
        editorVM.updateTitleCard(card)
        XCTAssertEqual(editorVM.titleCards.first?.title, "Edited Card")
        XCTAssertTrue(editorVM.removeSelectedTimelineItem())
        XCTAssertFalse(editorVM.titleCards.contains { $0.id == card.id })

        let musicURL = directory.appendingPathComponent("music.wav")
        try Data([0, 1, 2, 3]).write(to: musicURL)
        editorVM.setBackgroundMusic(url: musicURL)
        XCTAssertEqual(editorVM.project.style.backgroundMusicURL, musicURL)
        editorVM.removeBackgroundMusic()
        XCTAssertNil(editorVM.project.style.backgroundMusicURL)

        editorVM.seek(to: 0.5)
        let frameURL = directory.appendingPathComponent("frame.png")
        try editorVM.saveCurrentFrame(to: frameURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: frameURL.path))

        let assetsDirectory = directory.appendingPathComponent("assets", isDirectory: true)
        try editorVM.exportRawAssets(to: assetsDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetsDirectory.appendingPathComponent("raw-video.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetsDirectory.appendingPathComponent("cursor-data.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetsDirectory.appendingPathComponent("project.json").path))
    }

    func testTimelineTickPlannerDoesNotCreateOneLabelPerSecondForLongClips() {
        let ticks = TimelineTickPlanner.ticks(duration: 3_600, width: 920)

        XCTAssertEqual(ticks.first, 0)
        XCTAssertEqual(ticks.last, 3_600)
        XCTAssertLessThanOrEqual(ticks.count, 18)
        XCTAssertGreaterThan(ticks.dropFirst().first ?? 0, 1)
    }

    @MainActor
    func testEditorLoadsKeyEventsInTimestampOrderForPreviewAndSounds() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let keyEventsURL = directory.appendingPathComponent("key-events.json")
        let events = [
            KeyPressEvent(
                id: UUID(),
                timestamp: 1.2,
                keyCode: 1,
                modifiers: [],
                characters: "b",
                displayString: "B"
            ),
            KeyPressEvent(
                id: UUID(),
                timestamp: 0.4,
                keyCode: 0,
                modifiers: [.command],
                characters: "a",
                displayString: "⌘A"
            )
        ]
        try JSONEncoder().encode(events).write(to: keyEventsURL)
        project.keyEventsFileURL = keyEventsURL

        let editorVM = EditorVM(project: project)

        XCTAssertEqual(editorVM.recordedKeyEvents.map(\.timestamp), [0.4, 1.2])
    }

    @MainActor
    func testExplicitAutoZoomRegenerationReplacesTouchedZooms() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        try writeCursorFixture(to: project.cursorDataFileURL)
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 8,
                endTime: 10,
                zoomRect: CGRect(x: 900, y: 500, width: 400, height: 225),
                focusPadding: 0.2,
                zoomInDuration: 0.4,
                zoomOutDuration: 0.3,
                easingFunction: .easeInOut,
                source: .manual
            )
        ]
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.regenerateAutomaticZooms(replacingExisting: true)

        XCTAssertEqual(editorVM.zoomSegments.count, 1)
        XCTAssertEqual(editorVM.zoomSegments.first?.source, .automatic)
        XCTAssertEqual(editorVM.zoomSegments.first?.startTime ?? 0, 0.45, accuracy: 0.08)
        XCTAssertEqual(editorVM.selectedTimelineItem, editorVM.zoomSegments.first.map { .zoom($0.id) })
    }

    @MainActor
    func testPreviewRendererProducesFramesForPlayableRecording() async throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.videoFileURL = directory.appendingPathComponent("playable.mov")
        project.duration = CMTime(seconds: 2.0, preferredTimescale: 600)
        project.sourceRect = CGRect(x: 0, y: 0, width: 640, height: 360)
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: 0.4,
                endTime: 1.4,
                zoomRect: CGRect(x: 180, y: 90, width: 220, height: 160),
                focusPadding: 0.18,
                zoomInDuration: 0.2,
                zoomOutDuration: 0.2,
                easingFunction: .easeInOut,
                source: .manual
            )
        ]

        try await writePlayableVideo(to: project.videoFileURL, size: CGSize(width: 640, height: 360))
        try writeCursorFixture(to: project.cursorDataFileURL)
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        for time in [0.0, 0.8, 1.6] {
            let frame = try XCTUnwrap(editorVM.getFrame(at: time), "Preview frame at \(time)s should render")
            XCTAssertEqual(CVPixelBufferGetWidth(frame), 1280)
            XCTAssertEqual(CVPixelBufferGetHeight(frame), 720)
        }
    }

    func testAppBundleDeclaresKeyboardCaptureUsageDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runScript = try String(contentsOf: root.appendingPathComponent("run.sh"))
        let plist = try String(contentsOf: root.appendingPathComponent("Info.plist"))
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"))

        XCTAssertTrue(runScript.contains("NSInputMonitoringUsageDescription"))
        XCTAssertTrue(plist.contains("NSInputMonitoringUsageDescription"))
        XCTAssertTrue(runScript.contains("NSAccessibilityUsageDescription"))
        XCTAssertTrue(plist.contains("NSAccessibilityUsageDescription"))
        XCTAssertTrue(readme.contains("Input Monitoring"))
        XCTAssertTrue(readme.contains("Accessibility"))
        XCTAssertFalse(plist.contains("NSMainStoryboardFile"))
        XCTAssertTrue(plist.contains("NSHighResolutionCapable"))
    }

    func testRecordingSetupRefreshesPermissionsAfterReturningFromSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePicker = try String(contentsOf: root.appendingPathComponent("Sources/FocusFrame/Views/Recording/SourcePicker.swift"))

        XCTAssertTrue(sourcePicker.contains("NSApplication.didBecomeActiveNotification"))
        XCTAssertTrue(sourcePicker.contains("refreshAllPermissionState()"))
        XCTAssertTrue(sourcePicker.contains("click-driven auto zoom"))
        XCTAssertTrue(sourcePicker.contains("global clicks for auto zoom"))
    }

    func testHomeRecordingListLoadsOffMainActor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeView = try String(contentsOf: root.appendingPathComponent("Sources/FocusFrame/Views/Home/HomeView.swift"))

        XCTAssertTrue(homeView.contains("RecentRecordingLoader.loadPlayableProjects()"))
        XCTAssertTrue(homeView.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(homeView.contains("try FileManager.default.loadRecordingProjects()"))
    }

    func testMicrophoneStopDoesNotUseBlockingSemaphore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let microphoneRecorder = try String(contentsOf: root.appendingPathComponent("Sources/FocusFrame/Services/MicrophoneRecorder.swift"))
        let webcamCapture = try String(contentsOf: root.appendingPathComponent("Sources/FocusFrame/Services/WebcamCapture.swift"))
        let recordingVM = try String(contentsOf: root.appendingPathComponent("Sources/FocusFrame/ViewModels/RecordingVM.swift"))

        XCTAssertTrue(microphoneRecorder.contains("func stop() async -> URL?"))
        XCTAssertTrue(microphoneRecorder.contains("withCheckedContinuation"))
        XCTAssertFalse(microphoneRecorder.contains("DispatchSemaphore"))
        XCTAssertFalse(microphoneRecorder.contains("semaphore.wait()"))
        XCTAssertTrue(recordingVM.contains("await recorder.stop()"))
        XCTAssertTrue(webcamCapture.contains("func stop() async -> URL?"))
        XCTAssertTrue(recordingVM.contains("let webcamURL = await Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(recordingVM.contains("await webcamCapture.stop()"))
    }

    func testRecordingFinalizationDoesNotKeepMissingWebcamFallbackURL() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("webcam.mov")
        FileManager.default.createFile(atPath: existingURL.path, contents: Data([1, 2, 3]))
        let missingURL = directory.appendingPathComponent("deleted-webcam.mov")

        XCTAssertEqual(RecordingVM.existingRecordedMediaURL(existingURL), existingURL)
        XCTAssertNil(RecordingVM.existingRecordedMediaURL(missingURL))
        XCTAssertNil(RecordingVM.existingRecordedMediaURL(nil))
    }

    @MainActor
    func testEditorNormalizesInvalidProjectDurationAndSpeedMetadata() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.duration = .indefinite
        project.editActions = [
            .speedChange(startTime: 0, endTime: 10, multiplier: .infinity)
        ]
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)

        XCTAssertEqual(editorVM.duration, 0)
        XCTAssertEqual(editorVM.speedMultiplier(at: 1), 1.0, accuracy: 0.001)
    }

    @MainActor
    func testSelectedTimelineItemsCanBeNudgedWithArrowKeyBackends() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        let zoomID = UUID()
        project.zoomSegments = [
            ZoomSegment(
                id: zoomID,
                startTime: 2.0,
                endTime: 4.0,
                zoomRect: CGRect(x: 300, y: 180, width: 520, height: 300),
                focusPadding: 0.18,
                zoomInDuration: 0.35,
                zoomOutDuration: 0.35,
                easingFunction: .easeInOut,
                source: .manual
            )
        ]
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.selectZoomSegment(zoomID)
        XCTAssertFalse(editorVM.nudgeSelectedTimelineItem(by: .nan))
        XCTAssertTrue(editorVM.nudgeSelectedTimelineItem(by: 0.1))
        XCTAssertEqual(editorVM.zoomSegments.first?.startTime ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(editorVM.zoomSegments.first?.endTime ?? 0, 4.1, accuracy: 0.001)
        XCTAssertTrue(editorVM.extendSelectedTimelineItemEnd(by: 0.4))
        XCTAssertEqual(editorVM.zoomSegments.first?.startTime ?? 0, 2.1, accuracy: 0.001)
        XCTAssertEqual(editorVM.zoomSegments.first?.endTime ?? 0, 4.5, accuracy: 0.001)

        editorVM.addOverlay(type: .highlight, at: 7.0)
        var overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        let originalY = overlay.rect.origin.y
        XCTAssertEqual(editorVM.selectedTimelineItem, .overlay(overlay.id))
        XCTAssertTrue(editorVM.nudgeSelectedTimelineItem(by: -0.2))
        overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        XCTAssertEqual(overlay.startTime, 6.8, accuracy: 0.001)
        XCTAssertFalse(editorVM.nudgeSelectedOverlay(dy: .nan))
        XCTAssertTrue(editorVM.nudgeSelectedOverlay(dy: -0.02))
        overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        XCTAssertEqual(overlay.rect.origin.y, originalY - 0.02, accuracy: 0.001)
    }

    @MainActor
    func testTimelineSegmentTimingBackendsCanMoveAndExtendBlocks() throws {
        let directory = try makeTemporaryDirectory()
        var project = try makeProject(in: directory)
        project.webcamFileURL = project.videoFileURL
        project.webcamEnabled = true
        defer { try? FileManager.default.deleteRecordingProject(id: project.id) }

        let editorVM = EditorVM(project: project)
        editorVM.addTitleCard(kind: .section, at: 2.0)
        var card = try XCTUnwrap(editorVM.project.titleCardSegments?.first)
        card.startTime = 1.5
        card.endTime = 6.0
        editorVM.updateTitleCard(card)
        card = try XCTUnwrap(editorVM.project.titleCardSegments?.first)
        XCTAssertEqual(card.startTime, 1.5, accuracy: 0.001)
        XCTAssertEqual(card.endTime, 6.0, accuracy: 0.001)

        editorVM.addOverlay(type: .highlight, at: 4.0)
        var overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        overlay.startTime = 3.2
        overlay.endTime = 9.0
        editorVM.updateOverlay(overlay)
        overlay = try XCTUnwrap(editorVM.project.overlayElements?.first)
        XCTAssertEqual(overlay.startTime, 3.2, accuracy: 0.001)
        XCTAssertEqual(overlay.endTime, 9.0, accuracy: 0.001)

        editorVM.addCameraLayout(mode: .sideBySide, at: 5.0)
        var layout = try XCTUnwrap(editorVM.project.cameraLayoutSegments?.first)
        layout.startTime = 4.4
        layout.endTime = 10.5
        editorVM.updateCameraLayout(layout)
        layout = try XCTUnwrap(editorVM.project.cameraLayoutSegments?.first)
        XCTAssertEqual(layout.startTime, 4.4, accuracy: 0.001)
        XCTAssertEqual(layout.endTime, 10.5, accuracy: 0.001)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeProject(in directory: URL) throws -> RecordingProject {
        let videoURL = directory.appendingPathComponent("raw.mov")
        try Data([0, 1, 2, 3]).write(to: videoURL)
        return RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Test Recording",
            videoFileURL: videoURL,
            cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: nil,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 20, preferredTimescale: 600),
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            displayID: 1,
            zoomSegments: [],
            editActions: [],
            style: .default,
            hideDesktopIcons: false,
            showKeyboardShortcuts: true,
            webcamEnabled: false,
            subtitlesEnabled: false
        )
    }

    private func writeCursorFixture(to url: URL) throws {
        let recording = CursorRecording(
            frames: [
                CursorFrame(
                    timestamp: 0.0,
                    position: CGPoint(x: 240, y: 260),
                    isClicking: false,
                    clickType: nil,
                    scrollDelta: nil
                ),
                CursorFrame(
                    timestamp: 1.0,
                    position: CGPoint(x: 320, y: 300),
                    isClicking: true,
                    clickType: .leftDown,
                    scrollDelta: nil
                ),
                CursorFrame(
                    timestamp: 1.15,
                    position: CGPoint(x: 320, y: 300),
                    isClicking: false,
                    clickType: .leftUp,
                    scrollDelta: nil
                )
            ],
            sampleRate: 60,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )
        try JSONEncoder().encode(recording).write(to: url)
    }

    @MainActor
    private func writePlayableVideo(to url: URL, size: CGSize) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let pixelBuffer = try makeVideoPixelBuffer(
                size: size,
                hue: CGFloat(frameIndex) / 30.0
            )
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: 15)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.renderingFailed
        }
    }

    @MainActor
    private func makeVideoPixelBuffer(size: CGSize, hue: CGFloat) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ExportError.renderingFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
              ) else {
            throw ExportError.renderingFailed
        }

        let background = NSColor(
            hue: hue,
            saturation: 0.48,
            brightness: 0.82,
            alpha: 1
        ).cgColor
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.88))
        context.fill(CGRect(x: size.width * 0.18, y: size.height * 0.24, width: size.width * 0.28, height: size.height * 0.22))
        context.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.88))
        context.fill(CGRect(x: size.width * 0.52, y: size.height * 0.52, width: size.width * 0.30, height: size.height * 0.20))

        return pixelBuffer
    }
}
