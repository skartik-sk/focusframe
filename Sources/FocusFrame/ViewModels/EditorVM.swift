import Foundation
import Combine
import AVFoundation
import CoreGraphics
import CoreImage
import AppKit

enum EditorTool: String, CaseIterable {
    case timeline
    case cut
    case effects
    case speed
    case zoom
}

enum PreviewRenderMode: String, CaseIterable, Identifiable {
    case quality
    case performance
    case powerSaving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quality:
            return "Quality"
        case .performance:
            return "Performance"
        case .powerSaving:
            return "Power"
        }
    }
}

enum TimelineSelection: Equatable {
    case zoom(UUID)
    case editAction(UUID)
    case overlay(UUID)
    case titleCard(UUID)
    case cameraLayout(UUID)
    case effectSegment(UUID)
    case keyEvent(UUID)
}

private struct EditorMediaLoadInput: @unchecked Sendable {
    let project: RecordingProject
    let previewOutputSize: CGSize
    let previewFPS: Double
}

private struct EditorMediaLoadResult: @unchecked Sendable {
    let projectModifiedAt: Date
    let inputZoomSegments: [ZoomSegment]
    let detectedSourceRect: CGRect?
    let captionSegments: [CaptionSegment]
    let keyEvents: [KeyPressEvent]
    let rawCursorRecording: CursorRecording?
    let renderCursorRecording: CursorRecording?
    let smoothedCursor: [CursorFrame]
    let smoothedCursorStyle: CursorMovementStyle?
    let zoomSegments: [ZoomSegment]
    let frameTransforms: [FrameTransform]
    let cursorLoadErrorDescription: String?
}

@MainActor
class EditorVM: ObservableObject {
    @Published var project: RecordingProject
    @Published var playheadTime: Double = 0
    @Published var isPlaying = false
    @Published var zoomSegments: [ZoomSegment]
    @Published var editActions: [EditAction] = []
    @Published var selectedTool: EditorTool = .timeline
    @Published var selectedRangeStart: Double?
    @Published var selectedRangeEnd: Double?
    @Published var undoStack: [RecordingProject] = []
    @Published var redoStack: [RecordingProject] = []
    @Published var renderRevision = 0
    @Published var selectedZoomSegmentID: UUID?
    @Published var isGeneratingCaptions = false
    @Published var captionStatusMessage: String?
    @Published var backgroundMusicDuration: Double = 0
    @Published var captionSegments: [CaptionSegment] = []
    @Published var selectedTimelineItem: TimelineSelection?
    @Published var isTimelineItemInteractionActive = false
    @Published var isApplyingTimelineChanges = false
    @Published var isLoadingProjectMedia = false
    @Published var editorLoadStatusMessage: String?
    @Published var previewRenderMode: PreviewRenderMode = .performance {
        didSet {
            guard oldValue != previewRenderMode else { return }
            generateFrameTransforms(deferred: true)
            cachedSourceFrameTime = nil
            cachedSourceFrame = nil
            cachedWebcamFrameTime = nil
            cachedWebcamFrame = nil
        }
    }
    
    private let renderer = VideoRenderer()
    private let cursorSmoother = CursorSmoother()
    private let zoomTransformer = ZoomTransformer()
    private let autoZoomCalculator = AutoZoomCalculator()
    private let transcriptionEngine = TranscriptionEngine()
    private let clickPreviewPlayer = ClickPreviewPlayer()
    private let sourceAudioPreviewPlayer = TimelineAudioPreviewPlayer()
    private let micAudioPreviewPlayer = TimelineAudioPreviewPlayer()
    private let backgroundMusicPreviewPlayer = BackgroundMusicPreviewPlayer()
    private let stillFrameContext = CIContext()
    private let previewOutputSize = CGSize(width: 1280, height: 720)
    nonisolated static let maxCaptionImportBytes: UInt64 = 10 * 1024 * 1024
    nonisolated static let maxKeyEventsFileBytes: UInt64 = 20 * 1024 * 1024
    nonisolated static let maxCursorDataFileBytes: UInt64 = 128 * 1024 * 1024
    
    private var smoothedCursor: [CursorFrame] = []
    private var frameTransforms: [FrameTransform] = []
    private var rawCursorRecording: CursorRecording?
    private var renderCursorRecording: CursorRecording?
    private var playbackTimer: Timer?
    private var lastPlaybackTick: Date?
    private var webcamImageGenerator: AVAssetImageGenerator?
    private var keyEvents: [KeyPressEvent] = []
    private var cachedSourceFrameTime: Double?
    private var cachedSourceFrame: CIImage?
    private var cachedWebcamFrameTime: Double?
    private var cachedWebcamFrame: CIImage?
    private var interactiveUndoCaptured = false
    private var lastPreviewClickTimestamp: Double?
    private var lastPreviewKeyboardTimestamp: Double?
    private var smoothedCursorStyle: CursorMovementStyle?
    private var frameTransformTask: Task<Void, Never>?
    private var editorMediaLoadTask: Task<Void, Never>?
    private var captionGenerationToken: UUID?
    
    var duration: Double {
        Self.safeDurationSeconds(for: project.duration)
    }

    var canGenerateCaptions: Bool {
        let audioURL = project.micAudioFileURL ?? project.videoFileURL
        return FileManager.default.fileExists(atPath: audioURL.path)
    }

    var hasKeyboardEvents: Bool {
        !keyEvents.isEmpty
    }

    var recordedKeyEvents: [KeyPressEvent] {
        keyEvents
    }

    var cameraLayouts: [CameraLayoutSegment] {
        project.cameraLayoutSegments ?? []
    }

    var titleCards: [TitleCardSegment] {
        project.titleCardSegments ?? []
    }

    var effectSegments: [EffectSegment] {
        project.effectSegments ?? []
    }

    var overlays: [OverlayElement] {
        project.overlayElements ?? []
    }

    var selectedTimelineItemLabel: String? {
        guard let selectedTimelineItem else { return nil }
        switch selectedTimelineItem {
        case .zoom:
            return "zoom"
        case .editAction(let id):
            guard let action = project.editActions.first(where: { $0.id == id }) else { return nil }
            switch action.type {
            case .cut:
                return "cut"
            case .speedChange:
                return "speed segment"
            case .hideCursor:
                return "cursor hide segment"
            }
        case .overlay(let id):
            guard let overlay = project.overlayElements?.first(where: { $0.id == id }) else { return nil }
            return overlay.type.label.lowercased() + " overlay"
        case .titleCard(let id):
            guard let card = project.titleCardSegments?.first(where: { $0.id == id }) else { return nil }
            return card.kind.label.lowercased() + " card"
        case .cameraLayout:
            return "camera layout"
        case .effectSegment(let id):
            guard let segment = project.effectSegments?.first(where: { $0.id == id }) else { return nil }
            return segment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "effect segment" : segment.name
        case .keyEvent(let id):
            guard let event = keyEvents.first(where: { $0.id == id }) else { return nil }
            return event.displayString + " key"
        }
    }

    var productionReadiness: ProductionReadiness {
        ProductionReadiness(
            hasLook: project.style.backgroundType != .solid || project.style.padding > 0 || project.style.shadowEnabled,
            hasFocus: !zoomSegments.isEmpty,
            hasCaptions: project.subtitlesEnabled == true && project.captionsFileURL != nil,
            hasKeyboard: (project.showKeyboardShortcuts || project.style.showKeyboardShortcuts) && hasKeyboardEvents,
            hasCamera: project.webcamEnabled && project.webcamFileURL != nil,
            hasStoryCards: !(project.titleCardSegments ?? []).isEmpty,
            hasBranding: project.style.watermarkEnabled && !project.style.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasShareMetadata: project.sharePageSettings?.resolvedTitleFallback != nil || !(project.sharePageSettings?.creatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
    }
    
    let totalWidth: CGFloat = 800
    
    private var assetImageGenerator: AVAssetImageGenerator?
    private var asset: AVAsset?

    init(project: RecordingProject) {
        let project = project.sanitizedForUse()
        self.project = project
        self.zoomSegments = project.zoomSegments
        self.editActions = project.editActions

        let url = project.videoFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            let a = AVAsset(url: url)
            asset = a
            let gen = AVAssetImageGenerator(asset: a)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
            assetImageGenerator = gen
        }

        if project.webcamEnabled,
           let webcamURL = project.webcamFileURL,
           FileManager.default.fileExists(atPath: webcamURL.path) {
            let webcamAsset = AVAsset(url: webcamURL)
            let gen = AVAssetImageGenerator(asset: webcamAsset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            webcamImageGenerator = gen
        }

        backgroundMusicPreviewPlayer.durationDidChange = { [weak self] duration in
            self?.backgroundMusicDuration = duration
        }
        backgroundMusicPreviewPlayer.configure(url: project.style.backgroundMusicURL)
        refreshTimelineAudioPreviewSources()

        let loadInput = EditorMediaLoadInput(
            project: self.project,
            previewOutputSize: previewOutputSize,
            previewFPS: currentPreviewFPS
        )
        if Self.shouldLoadEditorMediaSynchronously {
            applyEditorMediaLoadResult(Self.prepareEditorMedia(input: loadInput))
        } else {
            startEditorMediaLoad(input: loadInput)
        }
    }

    // MARK: - Editor Media Loading

    private func startEditorMediaLoad(input: EditorMediaLoadInput) {
        editorMediaLoadTask?.cancel()
        isLoadingProjectMedia = true
        editorLoadStatusMessage = "Preparing editor media..."
        editorMediaLoadTask = Task { [input] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.prepareEditorMedia(input: input)
            }.value
            guard !Task.isCancelled else { return }
            applyEditorMediaLoadResult(result)
        }
    }

    private func applyEditorMediaLoadResult(_ result: EditorMediaLoadResult) {
        if project.sourceRect.width <= 0 || project.sourceRect.height <= 0,
           let detectedSourceRect = result.detectedSourceRect {
            project.sourceRect = detectedSourceRect
        }

        captionSegments = result.captionSegments
        if !captionSegments.isEmpty {
            project.subtitlesEnabled = true
        }
        keyEvents = result.keyEvents
        rawCursorRecording = result.rawCursorRecording
        renderCursorRecording = result.renderCursorRecording
        smoothedCursor = result.smoothedCursor
        smoothedCursorStyle = result.smoothedCursorStyle

        let canApplyPreparedZooms = project.modifiedAt == result.projectModifiedAt || zoomSegments == result.inputZoomSegments
        if canApplyPreparedZooms {
            zoomSegments = result.zoomSegments
            project.zoomSegments = result.zoomSegments
            frameTransforms = result.frameTransforms
        } else {
            generateFrameTransforms(deferred: true)
        }

        if let cursorLoadErrorDescription = result.cursorLoadErrorDescription {
            print("Failed to load cursor data: \(cursorLoadErrorDescription)")
        }

        isLoadingProjectMedia = false
        editorLoadStatusMessage = nil
        editorMediaLoadTask = nil
        renderRevision += 1
    }

    func cancelBackgroundWork() {
        editorMediaLoadTask?.cancel()
        editorMediaLoadTask = nil
        frameTransformTask?.cancel()
        frameTransformTask = nil
        captionGenerationToken = nil
        isLoadingProjectMedia = false
        isApplyingTimelineChanges = false
        isGeneratingCaptions = false
    }

    private static var shouldLoadEditorMediaSynchronously: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.processName.contains("xctest")
    }

    nonisolated private static func safeDurationSeconds(for duration: CMTime) -> Double {
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    nonisolated private static func prepareEditorMedia(input: EditorMediaLoadInput) -> EditorMediaLoadResult {
        var project = input.project
        let detectedSourceRect = detectSourceRectIfNeeded(for: project)
        if project.sourceRect.width <= 0 || project.sourceRect.height <= 0,
           let detectedSourceRect {
            project.sourceRect = detectedSourceRect
        }

        let captionSegments = decodeCaptionSegments(from: project.captionsFileURL)
        let keyEvents = decodeKeyEvents(from: project.keyEventsFileURL)
        let sourceSize = CGSize(
            width: project.sourceRect.width > 0 ? project.sourceRect.width : 1920,
            height: project.sourceRect.height > 0 ? project.sourceRect.height : 1080
        )

        var rawCursorRecording: CursorRecording?
        var renderCursorRecording: CursorRecording?
        var smoothedCursor: [CursorFrame] = []
        var smoothedCursorStyle: CursorMovementStyle?
        var cursorLoadErrorDescription: String?

        if FileManager.default.fileExists(atPath: project.cursorDataFileURL.path) {
            do {
                if !fileIsLoadable(project.cursorDataFileURL, maxBytes: maxCursorDataFileBytes) {
                    cursorLoadErrorDescription = "Cursor data file is too large to preview safely."
                } else {
                    let data = try Data(contentsOf: project.cursorDataFileURL)
                    let cursorRecording = try JSONDecoder().decode(CursorRecording.self, from: data).sanitizedForUse()
                    rawCursorRecording = cursorRecording
                    let mappedRecording = CursorCoordinateMapper.toRenderSpace(
                        cursorRecording,
                        sourceSize: sourceSize,
                        displayID: project.displayID == 0 ? nil : project.displayID
                    )
                    renderCursorRecording = mappedRecording
                    smoothedCursor = CursorSmoother().smooth(
                        frames: mappedRecording.frames,
                        style: project.style.cursorStyle,
                        targetFPS: input.previewFPS
                    )
                    smoothedCursorStyle = project.style.cursorStyle
                }
            } catch {
                cursorLoadErrorDescription = error.localizedDescription
            }
        }

        var zoomSegments = project.zoomSegments
        if (zoomSegments.isEmpty || zoomSegments.allSatisfy({ $0.source == .automatic })),
           let cursorRecording = renderCursorRecording,
           !cursorRecording.frames.isEmpty {
            zoomSegments = AutoZoomCalculator().calculateZoomSegments(
                from: cursorRecording,
                sourceRect: CGRect(origin: .zero, size: sourceSize),
                config: AutoZoomCalculator.Config(maxZoomScale: project.style.autoZoomScale)
            )
        }

        let frameTransforms = ZoomTransformer().generateTransforms(
            zoomSegments: zoomSegments,
            sourceSize: sourceSize,
            outputSize: input.previewOutputSize,
            duration: safeDurationSeconds(for: project.duration),
            fps: input.previewFPS
        )

        return EditorMediaLoadResult(
            projectModifiedAt: input.project.modifiedAt,
            inputZoomSegments: input.project.zoomSegments,
            detectedSourceRect: detectedSourceRect,
            captionSegments: captionSegments,
            keyEvents: keyEvents,
            rawCursorRecording: rawCursorRecording,
            renderCursorRecording: renderCursorRecording,
            smoothedCursor: smoothedCursor,
            smoothedCursorStyle: smoothedCursorStyle,
            zoomSegments: zoomSegments,
            frameTransforms: frameTransforms,
            cursorLoadErrorDescription: cursorLoadErrorDescription
        )
    }

    nonisolated private static func detectSourceRectIfNeeded(for project: RecordingProject) -> CGRect? {
        guard project.sourceRect.width <= 0 || project.sourceRect.height <= 0 else { return nil }
        guard FileManager.default.fileExists(atPath: project.videoFileURL.path) else { return nil }
        let asset = AVAsset(url: project.videoFileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let firstFrame = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return CGRect(x: 0, y: 0, width: firstFrame.width, height: firstFrame.height)
    }

    nonisolated private static func decodeCaptionSegments(from url: URL?) -> [CaptionSegment] {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              fileIsLoadable(url, maxBytes: maxCaptionImportBytes),
              let data = try? Data(contentsOf: url),
              let segments = try? JSONDecoder().decode([CaptionSegment].self, from: data) else {
            return []
        }
        return segments
    }

    nonisolated private static func decodeKeyEvents(from url: URL?) -> [KeyPressEvent] {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              fileIsLoadable(url, maxBytes: maxKeyEventsFileBytes),
              let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([KeyPressEvent].self, from: data) else {
            return []
        }
        return KeyPressEvent.sanitized(events)
    }

    nonisolated private static func fileIsLoadable(_ url: URL, maxBytes: UInt64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.uint64Value <= maxBytes
    }

    // MARK: - Playback Control
    private func generateFrameTransforms(deferred: Bool = false) {
        frameTransformTask?.cancel()

        guard deferred else {
            frameTransformTask = nil
            isApplyingTimelineChanges = false
            rebuildFrameTransforms()
            return
        }

        isApplyingTimelineChanges = true
        let zoomSegments = zoomSegments
        let sourceSize = sourceSize
        let outputSize = previewOutputSize
        let duration = duration
        let fps = currentPreviewFPS

        frameTransformTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let transforms = await Task.detached(priority: .userInitiated) {
                ZoomTransformer().generateTransforms(
                    zoomSegments: zoomSegments,
                    sourceSize: sourceSize,
                    outputSize: outputSize,
                    duration: duration,
                    fps: fps
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.frameTransforms = transforms
            self?.renderRevision += 1
            self?.isApplyingTimelineChanges = false
            self?.frameTransformTask = nil
        }
    }

    private func rebuildFrameTransforms() {
        frameTransforms = zoomTransformer.generateTransforms(
            zoomSegments: zoomSegments,
            sourceSize: sourceSize,
            outputSize: previewOutputSize,
            duration: duration,
            fps: currentPreviewFPS
        )
        renderRevision += 1
    }
    
    // MARK: - Playback Control
    
    func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        lastPlaybackTick = Date()
        refreshTimelineAudioPreviewSources()
        refreshBackgroundMusicPreviewSource()
        playTimelineAudioPreview()
        backgroundMusicPreviewPlayer.play(
            projectTime: playheadTime,
            volume: resolvedEffects(at: playheadTime).style.backgroundMusicVolume,
            loop: project.style.backgroundMusicLoop
        )
        
        playbackTimer?.invalidate()
        let timerFPS = currentPlaybackFPS
        let timer = Timer(timeInterval: 1.0 / timerFPS, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePlayhead()
            }
        }
        timer.tolerance = min(0.05, 0.5 / timerFPS)
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }
    
    func pausePlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        lastPlaybackTick = nil
        clickPreviewPlayer.stop()
        sourceAudioPreviewPlayer.pause()
        micAudioPreviewPlayer.pause()
        backgroundMusicPreviewPlayer.pause()
    }
    
    func seek(to time: Double) {
        playheadTime = max(0, min(duration, time))
        lastPreviewClickTimestamp = nil
        lastPreviewKeyboardTimestamp = nil
        seekTimelineAudioPreview()
        backgroundMusicPreviewPlayer.seek(
            projectTime: playheadTime,
            loop: project.style.backgroundMusicLoop
        )
    }
    
    private func updatePlayhead() {
        guard isPlaying else { return }

        let now = Date()
        let delta = lastPlaybackTick.map { now.timeIntervalSince($0) } ?? (1.0 / currentPlaybackFPS)
        lastPlaybackTick = now
        let boundedDelta = min(max(delta, 0), 0.25)
        let multiplier = speedMultiplier(at: playheadTime)
        let previousTime = playheadTime
        let nextTime = nextPreviewTime(from: previousTime, delta: boundedDelta * multiplier)
        playPreviewClickIfNeeded(from: previousTime, to: nextTime)
        playPreviewKeyboardSoundIfNeeded(from: previousTime, to: nextTime)
        playheadTime = nextTime
        syncTimelineAudioPreview(rate: multiplier)
        backgroundMusicPreviewPlayer.sync(
            projectTime: playheadTime,
            volume: resolvedEffects(at: playheadTime).style.backgroundMusicVolume,
            loop: project.style.backgroundMusicLoop
        )
        if playheadTime >= duration {
            playheadTime = 0
            pausePlayback()
        }
    }

    private func playTimelineAudioPreview() {
        let rate = Float(speedMultiplier(at: playheadTime))
        sourceAudioPreviewPlayer.play(
            projectTime: playheadTime,
            volume: resolvedEffects(at: playheadTime).style.sourceAudioVolume,
            rate: rate
        )
        micAudioPreviewPlayer.play(
            projectTime: playheadTime,
            volume: resolvedEffects(at: playheadTime).style.micAudioVolume,
            rate: rate
        )
    }

    private func seekTimelineAudioPreview() {
        sourceAudioPreviewPlayer.seek(projectTime: playheadTime)
        micAudioPreviewPlayer.seek(projectTime: playheadTime)
        guard isPlaying else { return }
        syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
    }

    private func syncTimelineAudioPreview(rate: Double) {
        let style = resolvedEffects(at: playheadTime).style
        sourceAudioPreviewPlayer.sync(
            projectTime: playheadTime,
            volume: style.sourceAudioVolume,
            rate: Float(rate),
            shouldPlay: isPlaying
        )
        micAudioPreviewPlayer.sync(
            projectTime: playheadTime,
            volume: style.micAudioVolume,
            rate: Float(rate),
            shouldPlay: isPlaying
        )
    }

    private func refreshTimelineAudioPreviewSources() {
        let sourceAudioURL = project.systemAudioFileURL ?? project.videoFileURL
        sourceAudioPreviewPlayer.configure(url: sourceAudioURL)

        if let micURL = project.micAudioFileURL, micURL != sourceAudioURL {
            micAudioPreviewPlayer.configure(url: micURL)
        } else {
            micAudioPreviewPlayer.configure(url: nil)
        }
    }

    private func nextPreviewTime(from currentTime: Double, delta: Double) -> Double {
        var nextTime = currentTime + delta
        let cuts = project.editActions
            .filter { $0.type == .cut }
            .sorted { $0.startTime < $1.startTime }

        for cut in cuts {
            if currentTime >= cut.startTime && currentTime < cut.endTime {
                nextTime = max(nextTime, cut.endTime)
            } else if currentTime < cut.startTime && nextTime >= cut.startTime {
                nextTime = cut.endTime + max(0, nextTime - cut.startTime)
            }
        }

        return max(0, min(duration, nextTime))
    }
    
    // MARK: - Zoom Editing
    
    func addZoomSegment(at time: Double) {
        let source = sourceRect
        let focusPadding: CGFloat = 0.16
        let focusPoint = nearestCursorPosition(at: time) ?? CGPoint(x: source.midX, y: source.midY)
        let zoomRect = makeManualZoomRect(
            centeredAt: focusPoint,
            source: source,
            focusPadding: focusPadding
        )
        let newSegment = ZoomSegment(
            id: UUID(),
            startTime: max(0, time - 0.55),
            endTime: min(duration, time + 1.25),
            zoomRect: zoomRect,
            focusPadding: focusPadding,
            zoomInDuration: 0.55,
            zoomOutDuration: 0.45,
            easingFunction: .easeInOut,
            source: .manual
        )
        
        saveState()
        zoomSegments.append(newSegment)
        zoomSegments.sort { $0.startTime < $1.startTime }
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        selectZoomSegment(newSegment.id)
        generateFrameTransforms()
    }

    func addManualZoomSegment(at time: Double, duration: Double, rect: CGRect) {
        let start = max(0, time - duration / 2)
        let end = min(self.duration, time + duration / 2)

        let segment = ZoomSegment(
            id: UUID(),
            startTime: start,
            endTime: end,
            zoomRect: clampedZoomRect(rect),
            focusPadding: 0.2,
            zoomInDuration: min(0.55, max(0.25, duration * 0.28)),
            zoomOutDuration: min(0.45, max(0.2, duration * 0.22)),
            easingFunction: .easeInOut,
            source: .manual
        )

        saveState()
        zoomSegments.append(segment)
        zoomSegments.sort { $0.startTime < $1.startTime }
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        selectZoomSegment(segment.id)
        generateFrameTransforms()
    }
    
    func updateZoomSegment(_ id: UUID, zoomRect: CGRect) {
        guard let index = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        
        saveState()
        markZoomListAsUserEdited()
        zoomSegments[index].zoomRect = clampedZoomRect(zoomRect)
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        generateFrameTransforms()
    }
    
    func removeZoomSegment(_ id: UUID) {
        guard let index = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        
        saveState()
        markZoomListAsUserEdited()
        zoomSegments.remove(at: index)
        if selectedZoomSegmentID == id {
            selectedZoomSegmentID = nil
        }
        clearSelectionIfMatching(.zoom(id))
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        generateFrameTransforms()
    }

    func selectZoomSegment(_ id: UUID?) {
        selectedZoomSegmentID = id
        selectedTimelineItem = id.map { .zoom($0) }
    }

    private func nearestCursorPosition(at time: Double, maximumDistance: Double = 1.25) -> CGPoint? {
        guard let frames = renderCursorRecording?.frames, !frames.isEmpty else { return nil }
        let nearest = frames.min { lhs, rhs in
            abs(lhs.timestamp - time) < abs(rhs.timestamp - time)
        }
        guard let nearest, abs(nearest.timestamp - time) <= maximumDistance else { return nil }
        return nearest.position
    }

    private func makeManualZoomRect(centeredAt point: CGPoint, source: CGRect, focusPadding: CGFloat) -> CGRect {
        let paddedScale = max(project.style.autoZoomScale, 1.1)
        let paddingMultiplier = max(1, 1 + focusPadding * 2)
        var width = max(180, source.width / paddedScale / paddingMultiplier)
        var height = width / AutoZoomCalculator.Config().outputAspectRatio

        if height > source.height {
            height = max(140, source.height / paddedScale / paddingMultiplier)
            width = height * AutoZoomCalculator.Config().outputAspectRatio
        }

        let rect = CGRect(
            x: point.x - width / 2,
            y: point.y - height / 2,
            width: min(width, source.width),
            height: min(height, source.height)
        )
        return clampedZoomRect(rect)
    }

    private func clampedZoomRect(_ rect: CGRect) -> CGRect {
        let source = sourceRect
        let width = max(50, min(rect.width, source.width))
        let height = max(50, min(rect.height, source.height))
        let x = max(source.minX, min(source.maxX - width, rect.origin.x))
        let y = max(source.minY, min(source.maxY - height, rect.origin.y))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func removeSelectedZoomSegment() {
        guard let selectedZoomSegmentID else { return }
        removeZoomSegment(selectedZoomSegmentID)
    }

    func selectEditAction(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .editAction($0) }
    }

    func selectOverlay(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .overlay($0) }
    }

    func selectTitleCard(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .titleCard($0) }
    }

    func selectCameraLayout(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .cameraLayout($0) }
    }

    func selectEffectSegment(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .effectSegment($0) }
    }

    func selectKeyEvent(_ id: UUID?) {
        selectedZoomSegmentID = nil
        selectedTimelineItem = id.map { .keyEvent($0) }
    }

    func clearTimelineSelection() {
        selectedTimelineItem = nil
        selectedZoomSegmentID = nil
    }

    func clearTimelineInteractionSelection() {
        clearTimelineSelection()
        selectedRangeStart = nil
        selectedRangeEnd = nil
    }

    func removeSelectedTimelineItem() -> Bool {
        guard let selectedTimelineItem else { return false }
        guard timelineSelectionExists(selectedTimelineItem) else {
            clearTimelineSelection()
            return false
        }

        switch selectedTimelineItem {
        case .zoom(let id):
            removeZoomSegment(id)
        case .editAction(let id):
            removeEditAction(id)
        case .overlay(let id):
            removeOverlay(id)
        case .titleCard(let id):
            removeTitleCard(id)
        case .cameraLayout(let id):
            removeCameraLayout(id)
        case .effectSegment(let id):
            removeEffectSegment(id)
        case .keyEvent(let id):
            removeKeyEvent(id)
        }
        return true
    }

    private func timelineSelectionExists(_ selection: TimelineSelection) -> Bool {
        switch selection {
        case .zoom(let id):
            return zoomSegments.contains { $0.id == id }
        case .editAction(let id):
            return project.editActions.contains { $0.id == id }
        case .overlay(let id):
            return project.overlayElements?.contains { $0.id == id } == true
        case .titleCard(let id):
            return project.titleCardSegments?.contains { $0.id == id } == true
        case .cameraLayout(let id):
            return project.cameraLayoutSegments?.contains { $0.id == id } == true
        case .effectSegment(let id):
            return project.effectSegments?.contains { $0.id == id } == true
        case .keyEvent(let id):
            return keyEvents.contains { $0.id == id }
        }
    }

    func nudgeSelectedTimelineItem(by delta: Double) -> Bool {
        guard delta.isFinite, let selectedTimelineItem else { return false }

        switch selectedTimelineItem {
        case .zoom(let id):
            guard let segment = zoomSegments.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: segment.startTime, end: segment.endTime, by: delta)
            updateZoomSegmentTiming(id, startTime: range.start, endTime: range.end)
        case .editAction(let id):
            guard let action = project.editActions.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: action.startTime, end: action.endTime, by: delta)
            updateEditActionTiming(id, startTime: range.start, endTime: range.end)
        case .overlay(let id):
            guard var overlay = project.overlayElements?.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: overlay.startTime, end: overlay.endTime, by: delta)
            overlay.startTime = range.start
            overlay.endTime = range.end
            updateOverlay(overlay)
        case .titleCard(let id):
            guard var card = project.titleCardSegments?.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: card.startTime, end: card.endTime, by: delta)
            card.startTime = range.start
            card.endTime = range.end
            updateTitleCard(card)
        case .cameraLayout(let id):
            guard var layout = project.cameraLayoutSegments?.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: layout.startTime, end: layout.endTime, by: delta)
            layout.startTime = range.start
            layout.endTime = range.end
            updateCameraLayout(layout)
        case .effectSegment(let id):
            guard var segment = project.effectSegments?.first(where: { $0.id == id }) else { return false }
            let range = shiftedTimeRange(start: segment.startTime, end: segment.endTime, by: delta)
            segment.startTime = range.start
            segment.endTime = range.end
            updateEffectSegment(segment)
        case .keyEvent:
            return false
        }
        return true
    }

    func extendSelectedTimelineItemEnd(by delta: Double) -> Bool {
        guard delta.isFinite, let selectedTimelineItem else { return false }

        switch selectedTimelineItem {
        case .zoom(let id):
            guard let segment = zoomSegments.first(where: { $0.id == id }) else { return false }
            updateZoomSegmentTiming(id, startTime: segment.startTime, endTime: segment.endTime + delta)
        case .editAction(let id):
            guard let action = project.editActions.first(where: { $0.id == id }) else { return false }
            updateEditActionTiming(id, startTime: action.startTime, endTime: action.endTime + delta)
        case .overlay(let id):
            guard var overlay = project.overlayElements?.first(where: { $0.id == id }) else { return false }
            overlay.endTime += delta
            updateOverlay(overlay)
        case .titleCard(let id):
            guard var card = project.titleCardSegments?.first(where: { $0.id == id }) else { return false }
            card.endTime += delta
            updateTitleCard(card)
        case .cameraLayout(let id):
            guard var layout = project.cameraLayoutSegments?.first(where: { $0.id == id }) else { return false }
            layout.endTime += delta
            updateCameraLayout(layout)
        case .effectSegment(let id):
            guard var segment = project.effectSegments?.first(where: { $0.id == id }) else { return false }
            segment.endTime += delta
            updateEffectSegment(segment)
        case .keyEvent:
            return false
        }
        return true
    }

    func nudgeSelectedOverlay(dx: CGFloat = 0, dy: CGFloat = 0) -> Bool {
        guard dx.isFinite, dy.isFinite else { return false }
        guard case let .overlay(id)? = selectedTimelineItem,
              var overlay = project.overlayElements?.first(where: { $0.id == id }) else {
            return false
        }
        overlay.rect.origin.x += dx
        overlay.rect.origin.y += dy
        updateOverlay(overlay)
        return true
    }

    private func shiftedTimeRange(start: Double, end: Double, by delta: Double) -> (start: Double, end: Double) {
        guard start.isFinite, end.isFinite, delta.isFinite else {
            return (0, min(duration, 0.2))
        }
        let length = min(duration, max(0.2, end - start))
        let maxStart = max(0, duration - length)
        let shiftedStart = max(0, min(maxStart, start + delta))
        return (shiftedStart, min(duration, shiftedStart + length))
    }

    private func clearSelectionIfMatching(_ selection: TimelineSelection) {
        if selectedTimelineItem == selection {
            selectedTimelineItem = nil
        }
    }

    func regenerateAutomaticZooms(replacingExisting: Bool = false) {
        guard let cursorRecording = renderCursorRecording,
              !cursorRecording.frames.isEmpty else {
            generateFrameTransforms()
            return
        }

        let generatedSegments = autoZoomCalculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: sourceRect,
            config: autoZoomConfig
        )

        guard replacingExisting || zoomSegments.isEmpty || zoomSegments.allSatisfy({ $0.source == .automatic }) else {
            generateFrameTransforms()
            return
        }

        saveState()
        zoomSegments = generatedSegments
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        selectedZoomSegmentID = zoomSegments.first?.id
        selectedTimelineItem = selectedZoomSegmentID.map { .zoom($0) }
        generateFrameTransforms()
    }

    func setBackgroundMusic(url: URL) {
        saveState()
        project.style.backgroundMusicURL = url
        project.modifiedAt = Date()
        markProjectModified()
    }

    func removeBackgroundMusic() {
        guard project.style.backgroundMusicURL != nil else { return }
        saveState()
        project.style.backgroundMusicURL = nil
        project.modifiedAt = Date()
        markProjectModified()
    }

    func previewClickSound() {
        guard project.style.clickSoundEnabled else { return }
        clickPreviewPlayer.playClick(
            volume: project.style.clickSoundVolume,
            style: project.style.clickSoundStyle,
            fileURL: project.style.clickSoundFileURL
        )
    }

    private func playPreviewKeyboardSoundIfNeeded(from startTime: Double, to endTime: Double) {
        let style = resolvedEffects(at: endTime).style
        guard style.keyboardSoundEnabled, endTime >= startTime else { return }

        guard let event = keyEvents.first(where: { event in
            event.timestamp > startTime && event.timestamp <= endTime
        }) else {
            return
        }

        if let lastPreviewKeyboardTimestamp,
           event.timestamp - lastPreviewKeyboardTimestamp < 0.035 {
            return
        }

        lastPreviewKeyboardTimestamp = event.timestamp
        clickPreviewPlayer.playKeyboard(
            volume: style.keyboardSoundVolume,
            style: style.keyboardSoundStyle,
            fileURL: style.keyboardSoundFileURL
        )
    }

    func previewKeyboardSound() {
        guard project.style.keyboardSoundEnabled else { return }
        clickPreviewPlayer.playKeyboard(
            volume: project.style.keyboardSoundVolume,
            style: project.style.keyboardSoundStyle,
            fileURL: project.style.keyboardSoundFileURL
        )
    }

    func applyLookPreset(_ preset: EditorLookPreset) {
        saveState()
        preset.apply(to: &project)
        project.modifiedAt = Date()
        if zoomSegments.isEmpty || zoomSegments.allSatisfy({ $0.source == .automatic }) {
            regenerateAutomaticZooms()
        } else {
            generateFrameTransforms()
        }
        markProjectModified()
    }

    func copyCurrentFrameAsImage() -> Bool {
        guard let frameBuffer = getFrame(at: playheadTime) else { return false }
        let image = CIImage(cvPixelBuffer: frameBuffer)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(frameBuffer),
            height: CVPixelBufferGetHeight(frameBuffer)
        )
        guard let cgImage = stillFrameContext.createCGImage(image, from: rect) else { return false }

        let nsImage = NSImage(cgImage: cgImage, size: rect.size)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([nsImage])
    }

    func saveCurrentFrame(to url: URL) throws {
        guard let frameBuffer = getFrame(at: playheadTime) else {
            throw EditorExportError.frameUnavailable
        }
        let image = CIImage(cvPixelBuffer: frameBuffer)
        let rect = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(frameBuffer),
            height: CVPixelBufferGetHeight(frameBuffer)
        )
        guard let cgImage = stillFrameContext.createCGImage(image, from: rect) else {
            throw EditorExportError.frameUnavailable
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw EditorExportError.frameUnavailable
        }
        try data.write(to: url)
    }

    func exportRawAssets(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [(URL?, String)] = [
            (project.videoFileURL, "raw-video"),
            (project.cursorDataFileURL, "cursor-data"),
            (project.keyEventsFileURL, "key-events"),
            (project.micAudioFileURL, "microphone"),
            (project.systemAudioFileURL, "system-audio"),
            (project.webcamFileURL, "webcam"),
            (project.captionsFileURL, "captions")
        ]

        for (url, prefix) in files {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let destination = uniqueDestination(
                in: directory,
                prefix: prefix,
                fileExtension: url.pathExtension
            )
            try FileManager.default.copyItem(at: url, to: destination)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let projectData = try encoder.encode(project)
        try projectData.write(to: uniqueDestination(in: directory, prefix: "project", fileExtension: "json"))
    }

    func speedUpTypingSegments(multiplier: Double = 3.0) -> Int {
        let typingEvents = keyEvents
            .filter { !$0.isModifierOnly }
            .sorted { $0.timestamp < $1.timestamp }
        guard !typingEvents.isEmpty else { return 0 }

        var clusters: [[KeyPressEvent]] = []
        var current: [KeyPressEvent] = []
        for event in typingEvents {
            if let last = current.last, event.timestamp - last.timestamp > 1.0 {
                clusters.append(current)
                current = []
            }
            current.append(event)
        }
        if !current.isEmpty {
            clusters.append(current)
        }

        let suggestions = clusters.compactMap { cluster -> (Double, Double)? in
            guard cluster.count >= 3,
                  let first = cluster.first,
                  let last = cluster.last else {
                return nil
            }
            let start = max(0, first.timestamp - 0.25)
            let end = min(duration, last.timestamp + 0.55)
            guard end - start >= 0.45 else { return nil }
            return (start, end)
        }

        guard !suggestions.isEmpty else { return 0 }

        saveState()
        let clamped = max(1.1, min(multiplier, 6.0))
        for (start, end) in suggestions {
            let action = EditAction.speedChange(
                startTime: start,
                endTime: end,
                multiplier: clamped,
                description: "Typing \(String(format: "%.1fx", clamped))"
            )
            project.editActions.removeAll {
                $0.type == .speedChange && $0.overlaps(with: action)
            }
            project.editActions.append(action)
        }
        project.editActions.sort { $0.startTime < $1.startTime }
        editActions = project.editActions
        project.modifiedAt = Date()
        return suggestions.count
    }

    func generateChaptersFromTranscript() -> Int {
        var chapters: [ChapterMarker] = []
        let sortedCaptions = captionSegments.sorted { $0.start < $1.start }

        if sortedCaptions.isEmpty {
            let stride = max(20, min(45, duration / 4))
            var time = 0.0
            var index = 1
            while time < duration {
                chapters.append(ChapterMarker(time: time, title: "Chapter \(index)"))
                time += stride
                index += 1
            }
        } else {
            var lastChapterTime = -Double.infinity
            for segment in sortedCaptions where segment.start - lastChapterTime >= 25 || chapters.isEmpty {
                chapters.append(ChapterMarker(
                    time: segment.start,
                    title: chapterTitle(from: segment.text, fallbackIndex: chapters.count + 1)
                ))
                lastChapterTime = segment.start
            }
        }

        project.chapterMarkers = chapters
        project.modifiedAt = Date()
        renderRevision += 1
        return chapters.count
    }

    func addChapter(at time: Double) {
        var chapters = project.chapterMarkers ?? []
        chapters.append(ChapterMarker(
            time: max(0, min(duration, time)),
            title: "Chapter \(chapters.count + 1)"
        ))
        chapters.sort { $0.time < $1.time }
        project.chapterMarkers = chapters
        project.modifiedAt = Date()
    }

    func updateChapter(_ chapter: ChapterMarker) {
        guard var chapters = project.chapterMarkers,
              let index = chapters.firstIndex(where: { $0.id == chapter.id }) else {
            return
        }
        chapters[index] = ChapterMarker(
            id: chapter.id,
            time: max(0, min(duration, chapter.time)),
            title: chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        chapters.sort { $0.time < $1.time }
        project.chapterMarkers = chapters
        project.modifiedAt = Date()
    }

    func removeChapter(_ id: UUID) {
        guard var chapters = project.chapterMarkers else { return }
        chapters.removeAll { $0.id == id }
        project.chapterMarkers = chapters
        project.modifiedAt = Date()
    }

    func exportChapters(to url: URL) throws {
        let chapters = (project.chapterMarkers ?? []).sorted { $0.time < $1.time }
        let lines = chapters.map { "\(formatChapterTime($0.time)) \($0.title)" }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func addCameraLayout(mode: CameraLayoutMode, at time: Double? = nil) {
        guard project.webcamFileURL != nil else { return }
        let start = max(0, min(duration, time ?? playheadTime))
        let end = min(duration, max(start + 2.0, start + 5.0))
        var layouts = project.cameraLayoutSegments ?? []
        let layout = CameraLayoutSegment(
            startTime: start,
            endTime: end,
            mode: mode
        )
        layouts.append(layout)
        layouts.sort { $0.startTime < $1.startTime }
        saveState()
        project.cameraLayoutSegments = layouts
        project.webcamEnabled = true
        selectCameraLayout(layout.id)
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func updateCameraLayout(_ layout: CameraLayoutSegment) {
        guard var layouts = project.cameraLayoutSegments,
              let index = layouts.firstIndex(where: { $0.id == layout.id }) else {
            return
        }
        let minimumDuration = 0.4
        let start = max(0, min(duration - minimumDuration, layout.startTime))
        let end = min(duration, max(start + minimumDuration, layout.endTime))
        layouts[index] = CameraLayoutSegment(
            id: layout.id,
            startTime: start,
            endTime: end,
            mode: layout.mode
        )
        layouts.sort { $0.startTime < $1.startTime }
        project.cameraLayoutSegments = layouts
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func removeCameraLayout(_ id: UUID) {
        guard var layouts = project.cameraLayoutSegments else { return }
        saveState()
        layouts.removeAll { $0.id == id }
        clearSelectionIfMatching(.cameraLayout(id))
        project.cameraLayoutSegments = layouts
        project.modifiedAt = Date()
        renderRevision += 1
    }

    @discardableResult
    func addEffectSegment(
        startTime: Double,
        endTime: Double,
        preset: EffectSegmentPreset = .quiet
    ) -> EffectSegment? {
        let minimumDuration = 0.4
        let start = max(0, min(duration - minimumDuration, startTime))
        let end = min(duration, max(start + minimumDuration, endTime))
        guard end > start else { return nil }

        var segment = EffectSegment(
            startTime: start,
            endTime: end,
            name: preset.title
        )
        preset.apply(to: &segment)

        saveState()
        var segments = project.effectSegments ?? []
        segments.append(segment)
        segments.sort { $0.startTime < $1.startTime }
        project.effectSegments = segments
        project.modifiedAt = Date()
        selectEffectSegment(segment.id)
        refreshBackgroundMusicPreviewSource()
        syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
        renderRevision += 1
        return segment
    }

    func updateEffectSegment(_ segment: EffectSegment) {
        guard var segments = project.effectSegments,
              let index = segments.firstIndex(where: { $0.id == segment.id }) else {
            return
        }

        let minimumDuration = 0.4
        let start = max(0, min(duration - minimumDuration, segment.startTime))
        let end = min(duration, max(start + minimumDuration, segment.endTime))
        segments[index] = EffectSegment(
            id: segment.id,
            startTime: start,
            endTime: end,
            name: segment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Effect Segment" : segment.name,
            music: segment.music,
            clickSound: segment.clickSound,
            keyboardSound: segment.keyboardSound,
            keyboardBadges: segment.keyboardBadges,
            cursor: segment.cursor,
            subtitles: segment.subtitles,
            overlays: segment.overlays,
            webcam: segment.webcam,
            watermark: segment.watermark,
            sourceAudioVolume: clampedOptionalVolume(segment.sourceAudioVolume),
            micAudioVolume: clampedOptionalVolume(segment.micAudioVolume),
            musicVolume: clampedOptionalVolume(segment.musicVolume),
            createdAt: segment.createdAt
        )
        segments.sort { $0.startTime < $1.startTime }
        project.effectSegments = segments
        project.modifiedAt = Date()
        if !isTimelineItemInteractionActive {
            refreshBackgroundMusicPreviewSource()
            syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
        }
        renderRevision += 1
    }

    func removeEffectSegment(_ id: UUID) {
        guard var segments = project.effectSegments else { return }
        saveState()
        segments.removeAll { $0.id == id }
        clearSelectionIfMatching(.effectSegment(id))
        project.effectSegments = segments.isEmpty ? nil : segments
        project.modifiedAt = Date()
        refreshBackgroundMusicPreviewSource()
        syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
        renderRevision += 1
    }

    @discardableResult
    func addSmartTitleCards() -> Int {
        saveState()
        project.titleCardSegments = makeSmartTitleCards()
        project.modifiedAt = Date()
        renderRevision += 1
        return project.titleCardSegments?.count ?? 0
    }

    @discardableResult
    func applySmartFinish() -> ProductionFinishSummary {
        saveState()

        EditorLookPreset.studio.apply(to: &project)

        var captionsEnabled = false
        if project.captionsFileURL != nil || !captionSegments.isEmpty {
            project.subtitlesEnabled = true
            captionsEnabled = true
        }

        var keyboardEnabled = false
        if hasKeyboardEvents {
            project.showKeyboardShortcuts = true
            project.style.showKeyboardShortcuts = true
            keyboardEnabled = true
        }

        let webcamEnabled = project.webcamFileURL != nil
        if webcamEnabled {
            project.webcamEnabled = true
        }

        let titleCards = makeSmartTitleCards()
        project.titleCardSegments = titleCards

        var chapterCount = project.chapterMarkers?.count ?? 0
        if chapterCount == 0 {
            chapterCount = generateChaptersFromTranscript()
        }

        let watermarkText = preferredWatermarkText()
        if !watermarkText.isEmpty {
            project.style.watermarkEnabled = true
            project.style.watermarkText = watermarkText
            project.style.watermarkPosition = .topRight
            project.style.watermarkOpacity = 0.42
            project.style.watermarkScale = 0.95
        }

        project.modifiedAt = Date()
        if zoomSegments.isEmpty || zoomSegments.allSatisfy({ $0.source == .automatic }) {
            regenerateAutomaticZooms()
        } else {
            generateFrameTransforms()
        }
        markProjectModified()

        return ProductionFinishSummary(
            titleCardCount: titleCards.count,
            chapterCount: chapterCount,
            captionsEnabled: captionsEnabled,
            keyboardEnabled: keyboardEnabled,
            webcamEnabled: webcamEnabled,
            watermarkEnabled: !watermarkText.isEmpty
        )
    }

    func addTitleCard(kind: TitleCardKind, at time: Double? = nil) {
        let start: Double
        switch kind {
        case .intro:
            start = 0
        case .section:
            start = max(0, min(duration, time ?? playheadTime))
        case .outro:
            start = max(0, duration - 2.2)
        }
        let length = kind == .section ? 2.0 : 2.4
        let end = min(duration, max(start + 0.6, start + length))
        let defaultTitle: String
        switch kind {
        case .intro:
            defaultTitle = project.sharePageSettings?.resolvedTitleFallback ?? project.title
        case .section:
            defaultTitle = "New section"
        case .outro:
            defaultTitle = "Thanks for watching"
        }

        var cards = project.titleCardSegments ?? []
        let card = TitleCardSegment(
            startTime: start,
            endTime: end,
            kind: kind,
            style: kind == .section ? .lowerThird : .cinematic,
            title: defaultTitle,
            subtitle: kind == .section ? "Key point" : "",
            accentColor: project.sharePageSettings?.accentColor ?? CodableColor(r: 0.23, g: 0.51, b: 0.96),
            backgroundOpacity: kind == .section ? 0.72 : 0.82
        )
        cards.append(card)
        cards.sort { $0.startTime < $1.startTime }
        saveState()
        project.titleCardSegments = cards
        selectTitleCard(card.id)
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func updateTitleCard(_ card: TitleCardSegment) {
        guard var cards = project.titleCardSegments,
              let index = cards.firstIndex(where: { $0.id == card.id }) else {
            return
        }
        let minimumDuration = 0.4
        let start = max(0, min(duration - minimumDuration, card.startTime))
        let end = min(duration, max(start + minimumDuration, card.endTime))
        cards[index] = TitleCardSegment(
            id: card.id,
            startTime: start,
            endTime: end,
            kind: card.kind,
            style: card.style,
            title: card.title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: card.subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            accentColor: card.accentColor,
            backgroundOpacity: max(0.1, min(card.backgroundOpacity, 0.95))
        )
        cards.sort { $0.startTime < $1.startTime }
        project.titleCardSegments = cards
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func removeTitleCard(_ id: UUID) {
        guard var cards = project.titleCardSegments else { return }
        saveState()
        cards.removeAll { $0.id == id }
        clearSelectionIfMatching(.titleCard(id))
        project.titleCardSegments = cards
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func updateZoomSegmentTiming(_ id: UUID, startTime: Double, endTime: Double) {
        guard let index = zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        markZoomListAsUserEdited()
        let minimumDuration = 0.2
        let start = max(0, min(duration - minimumDuration, startTime))
        let end = min(duration, max(start + minimumDuration, endTime))

        zoomSegments[index].startTime = start
        zoomSegments[index].endTime = end
        zoomSegments.sort { $0.startTime < $1.startTime }
        project.zoomSegments = zoomSegments
        project.modifiedAt = Date()
        generateFrameTransforms(deferred: isTimelineItemInteractionActive)
    }

    func beginInteractiveEdit() {
        isTimelineItemInteractionActive = true
        guard !interactiveUndoCaptured else { return }
        saveState()
        interactiveUndoCaptured = true
    }

    func endInteractiveEdit() {
        isTimelineItemInteractionActive = false
        interactiveUndoCaptured = false
        refreshBackgroundMusicPreviewSource()
        if isPlaying {
            syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
        }
    }

    private func markZoomListAsUserEdited() {
        zoomSegments = zoomSegments.map { segment in
            var copy = segment
            if copy.source == .automatic {
                copy.source = .manual
                copy.keyframes = nil
            }
            return copy
        }
    }
    
    // MARK: - Cut/Trim Editing
    
    func cutRegion(startTime: Double, endTime: Double) {
        guard startTime < endTime else { return }
        
        saveState()
        
        let cutAction = EditAction.cut(
            startTime: startTime,
            endTime: endTime,
            description: "Cut \(formatTime(startTime)) to \(formatTime(endTime))"
        )
        
        project.editActions.append(cutAction)
        project.modifiedAt = Date()
        editActions = project.editActions
        selectEditAction(cutAction.id)
    }
    
    func removeCutAction(_ id: UUID) {
        guard let index = project.editActions.firstIndex(where: { $0.id == id }) else { return }
        
        saveState()
        project.editActions.remove(at: index)
        clearSelectionIfMatching(.editAction(id))
        project.modifiedAt = Date()
        editActions = project.editActions
    }

    // MARK: - Speed Editing

    func setSpeed(startTime: Double, endTime: Double, multiplier: Double) {
        guard startTime < endTime else { return }
        let clamped = max(0.5, min(4.0, multiplier))

        saveState()

        let speedAction = EditAction.speedChange(
            startTime: startTime,
            endTime: endTime,
            multiplier: clamped,
            description: "Speed \(String(format: "%.2fx", clamped))"
        )

        project.editActions.removeAll { action in
            action.type == .speedChange && action.overlaps(with: speedAction)
        }
        project.editActions.append(speedAction)
        project.modifiedAt = Date()
        editActions = project.editActions
        selectEditAction(speedAction.id)
    }

    func hideCursorRegion(startTime: Double, endTime: Double) {
        guard startTime < endTime else { return }

        saveState()
        let action = EditAction.hideCursor(
            startTime: startTime,
            endTime: endTime,
            description: "Hide cursor \(formatTime(startTime)) to \(formatTime(endTime))"
        )
        project.editActions.append(action)
        project.modifiedAt = Date()
        editActions = project.editActions
        selectEditAction(action.id)
        renderRevision += 1
    }

    func addOverlay(type: OverlayType, at time: Double) {
        saveState()
        let start = max(0, time)
        let end = min(duration, start + 3)
        let rect: CGRect
        switch type {
        case .text:
            rect = CGRect(x: 0.28, y: 0.74, width: 0.44, height: 0.12)
        case .blur:
            rect = CGRect(x: 0.32, y: 0.34, width: 0.36, height: 0.18)
        case .highlight, .spotlight:
            rect = CGRect(x: 0.30, y: 0.28, width: 0.40, height: 0.28)
        }

        var overlays = project.overlayElements ?? []
        let overlay = OverlayElement(
            type: type,
            startTime: start,
            endTime: max(start + 0.5, end),
            rect: rect,
            text: type == .text ? "Callout" : "",
            intensity: type == .spotlight ? 0.55 : 0.75
        )
        overlays.append(overlay)
        project.overlayElements = overlays
        selectOverlay(overlay.id)
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func updateOverlay(_ overlay: OverlayElement) {
        guard var overlays = project.overlayElements,
              let index = overlays.firstIndex(where: { $0.id == overlay.id }) else {
            return
        }

        let start = max(0, min(duration, overlay.startTime))
        let end = min(duration, max(start + 0.2, overlay.endTime))
        overlays[index] = OverlayElement(
            id: overlay.id,
            type: overlay.type,
            startTime: start,
            endTime: end,
            rect: clampedOverlayRect(overlay.rect),
            text: overlay.text,
            intensity: max(0, min(overlay.intensity, 1))
        )
        project.overlayElements = overlays
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func removeOverlay(_ id: UUID) {
        guard var overlays = project.overlayElements else { return }
        saveState()
        overlays.removeAll { $0.id == id }
        clearSelectionIfMatching(.overlay(id))
        project.overlayElements = overlays
        project.modifiedAt = Date()
        renderRevision += 1
    }

    func generateCaptions() async {
        guard !isGeneratingCaptions, canGenerateCaptions else { return }
        let generationToken = UUID()
        captionGenerationToken = generationToken
        isGeneratingCaptions = true
        captionStatusMessage = nil
        defer {
            if captionGenerationToken == generationToken {
                captionGenerationToken = nil
                isGeneratingCaptions = false
            }
        }

        let audioURL = project.micAudioFileURL ?? project.videoFileURL
        let outputURL = project.videoFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("captions.json")

        do {
            let segments = try await transcriptionEngine.transcribe(audioURL: audioURL)
            try Task.checkCancellation()
            guard captionGenerationToken == generationToken else { return }
            guard !segments.isEmpty else {
                captionStatusMessage = "No speech detected."
                return
            }

            let data = try JSONEncoder().encode(segments)
            try data.write(to: outputURL)

            try? transcriptionEngine.writeSRT(
                segments: segments,
                to: outputURL.deletingPathExtension().appendingPathExtension("srt")
            )
            try? transcriptionEngine.writeVTT(
                segments: segments,
                to: outputURL.deletingPathExtension().appendingPathExtension("vtt")
            )

            captionSegments = segments
            project.captionsFileURL = outputURL
            project.subtitlesEnabled = true
            project.modifiedAt = Date()
            captionStatusMessage = "Captions generated."
            saveProject()
            renderRevision += 1
        } catch is CancellationError {
            if captionGenerationToken == generationToken {
                captionStatusMessage = "Caption generation cancelled."
            }
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("No speech detected") {
                captionStatusMessage = "No speech detected."
            } else {
                captionStatusMessage = "Caption generation failed: \(error.localizedDescription)"
            }
        }
    }

    func addCaptionSegment(at time: Double) {
        saveState()
        let start = max(0, min(duration, time))
        let end = min(duration, start + 2.5)
        captionSegments.append(CaptionSegment(
            id: UUID(),
            start: start,
            end: max(start + 0.5, end),
            text: "New caption"
        ))
        persistCaptionSegments()
    }

    func updateCaptionSegment(_ segment: CaptionSegment) {
        guard let index = captionSegments.firstIndex(where: { $0.id == segment.id }) else { return }
        let start = max(0, min(duration, segment.start))
        let end = min(duration, max(start + 0.2, segment.end))
        captionSegments[index] = CaptionSegment(
            id: segment.id,
            start: start,
            end: end,
            text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        persistCaptionSegments(saveUndo: false)
    }

    func removeCaptionSegment(_ id: UUID) {
        guard let index = captionSegments.firstIndex(where: { $0.id == id }) else { return }
        saveState()
        captionSegments.remove(at: index)
        persistCaptionSegments()
    }

    func importCaptions(from url: URL) throws {
        saveState()
        captionSegments = try Self.importedCaptionSegments(from: url)
        persistCaptionSegments()
        captionStatusMessage = "Captions imported."
    }

    func importCaptionsAsync(from url: URL) async throws {
        let segments = try await Task.detached(priority: .userInitiated) {
            try Self.importedCaptionSegments(from: url)
        }.value

        saveState()
        captionSegments = segments
        persistCaptionSegments()
        captionStatusMessage = "Captions imported."
    }

    func exportCaptions(to url: URL) throws {
        let segments = captionSegments.sorted { $0.start < $1.start }
        switch CaptionFileFormat.infer(from: url) {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(segments).write(to: url)
        case .srt:
            try transcriptionEngine.writeSRT(segments: segments, to: url)
        case .vtt:
            try transcriptionEngine.writeVTT(segments: segments, to: url)
        }
        captionStatusMessage = "Captions exported."
    }

    func removeKeyEvent(_ id: UUID) {
        guard let index = keyEvents.firstIndex(where: { $0.id == id }) else { return }
        keyEvents.remove(at: index)
        clearSelectionIfMatching(.keyEvent(id))
        persistKeyEvents()
    }

    @discardableResult
    func removeKeyEvents(matching displayString: String) -> Int {
        let before = keyEvents.count
        keyEvents.removeAll { $0.displayString == displayString }
        let removed = before - keyEvents.count
        if removed > 0 {
            persistKeyEvents()
        }
        return removed
    }

    @discardableResult
    func cleanFillerWordsFromCaptions(removeEmptySegments: Bool = false) -> Int {
        guard !captionSegments.isEmpty else {
            captionStatusMessage = "No captions to clean."
            return 0
        }

        var cleanedSegments: [CaptionSegment] = []
        var cutActions: [EditAction] = []
        var removedCount = 0

        for segment in captionSegments {
            let cleaned = cleanedCaptionText(segment.text)
            removedCount += cleaned.removedCount

            var updated = segment
            updated.text = cleaned.text

            if updated.text.isEmpty, removeEmptySegments {
                cutActions.append(.cut(
                    startTime: max(0, segment.start),
                    endTime: min(duration, max(segment.start + 0.2, segment.end)),
                    description: "Cut filler pause"
                ))
            } else {
                cleanedSegments.append(updated)
            }
        }

        guard removedCount > 0 else {
            captionStatusMessage = "No filler words found."
            return 0
        }

        saveState()
        captionSegments = cleanedSegments

        if removeEmptySegments {
            for cut in cutActions where cut.endTime > cut.startTime {
                project.editActions.removeAll {
                    $0.type == .cut && abs($0.startTime - cut.startTime) < 0.05 && abs($0.endTime - cut.endTime) < 0.05
                }
                project.editActions.append(cut)
            }
            project.editActions.sort { $0.startTime < $1.startTime }
            editActions = project.editActions
        }

        persistCaptionSegments(saveUndo: false)
        captionStatusMessage = removeEmptySegments
            ? "Removed \(removedCount) filler word\(removedCount == 1 ? "" : "s") and cut \(cutActions.count) pause\(cutActions.count == 1 ? "" : "s")."
            : "Removed \(removedCount) filler word\(removedCount == 1 ? "" : "s")."
        return removedCount
    }

    func removeEditAction(_ id: UUID) {
        guard let index = project.editActions.firstIndex(where: { $0.id == id }) else { return }
        saveState()
        project.editActions.remove(at: index)
        clearSelectionIfMatching(.editAction(id))
        project.modifiedAt = Date()
        editActions = project.editActions
    }

    func updateEditActionTiming(_ id: UUID, startTime: Double, endTime: Double) {
        guard let index = project.editActions.firstIndex(where: { $0.id == id }) else { return }
        let minimumDuration = 0.2
        let start = max(0, min(duration - minimumDuration, startTime))
        let end = min(duration, max(start + minimumDuration, endTime))

        project.editActions[index].startTime = start
        project.editActions[index].endTime = end
        let label = switch project.editActions[index].type {
        case .cut:
            "Cut"
        case .speedChange:
            "Speed"
        case .hideCursor:
            "Hide cursor"
        }
        project.editActions[index].description = "\(label) \(formatTime(start)) to \(formatTime(end))"
        project.modifiedAt = Date()
        editActions = project.editActions
    }

    func updateSpeedActionMultiplier(_ id: UUID, multiplier: Double) {
        guard let index = project.editActions.firstIndex(where: { $0.id == id }),
              project.editActions[index].type == .speedChange else {
            return
        }
        let clamped = max(0.5, min(4.0, multiplier))
        project.editActions[index].value = clamped
        project.editActions[index].description = "Speed \(String(format: "%.2fx", clamped))"
        project.modifiedAt = Date()
        editActions = project.editActions
        syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
    }

    func speedMultiplier(at time: Double) -> Double {
        let speedActions = project.editActions
            .filter { $0.type == .speedChange && $0.intersects(time: time) }
            .sorted { $0.createdAt > $1.createdAt }

        guard let value = speedActions.first?.value, value.isFinite else {
            return 1.0
        }
        return max(0.25, min(4.0, value))
    }
    
    private func formatTime(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }
    
    // MARK: - Frame Rendering
    
    func getFrame(at time: Double) -> CVPixelBuffer? {
        guard let sourceFrame = loadSourceFrame(at: time) else { return nil }
        
        let transform = frameTransform(at: time) ?? FrameTransform(
                timestamp: 0,
                transform: .identity,
                sourceRect: .zero,
                scale: 1.0,
                isTransitioning: false,
                transitionProgress: 0.0
            )
        let motionBlurVelocity = transformVelocity(at: time, current: transform)
        
        // Get cursor position for this time
        let cursorData = cursorFrame(at: time, frames: smoothedCursor)
        let cursorPosition = cursorData?.position
        let clickProgress = clickAnimationProgress(at: time, frames: smoothedCursor)
        let resolvedEffects = resolvedEffects(at: time)
        let cursorVisible = shouldShowCursor(
            at: time,
            cursorData: cursorData,
            clickProgress: clickProgress,
            visibilityOverride: resolvedEffects.cursorVisibility
        )
        let config = previewStyleConfig(base: resolvedEffects.style)
        
        // Render frame
        return renderer.renderFrame(
            inputs: VideoRenderer.FrameInputs(
                sourceFrame: sourceFrame,
                timestamp: time,
                zoomTransform: transform.transform,
                cursorPosition: cursorPosition,
                cursorVisible: cursorVisible,
                cursorAlpha: 1.0,
                cursorScale: config.cursorScale,
                isClicking: cursorData?.isClicking ?? false,
                clickAnimationProgress: clickProgress,
                webcamFrame: resolvedEffects.webcamEnabled ? loadWebcamFrame(at: time) : nil,
                activeShortcuts: resolvedEffects.showKeyboardShortcuts ? activeShortcuts(at: time, style: config) : [],
                subtitleText: resolvedEffects.subtitlesEnabled ? activeSubtitle(at: time) : nil,
                motionBlurVelocity: motionBlurVelocity,
                activeOverlays: resolvedEffects.overlaysEnabled ? activeOverlays(at: time) : [],
                activeTitleCards: activeTitleCards(at: time),
                zoomScale: transform.scale,
                cameraLayoutMode: activeCameraLayoutMode(at: time, webcamEnabled: resolvedEffects.webcamEnabled)
            ),
            config: config,
            outputSize: previewOutputSize
        )
    }

    private func transformVelocity(at time: Double, current: FrameTransform) -> CGPoint {
        guard current.isTransitioning else { return .zero }
        let previousTime = max(0, time - 1.0 / 60.0)
        guard let previous = frameTransform(at: previousTime) else {
            return .zero
        }

        return CGPoint(
            x: current.transform.tx - previous.transform.tx,
            y: current.transform.ty - previous.transform.ty
        )
    }

    private func shouldShowCursor(
        at time: Double,
        cursorData: CursorFrame?,
        clickProgress: Double?,
        visibilityOverride: EffectOverride
    ) -> Bool {
        guard let cursorData else { return false }
        if project.editActions.contains(where: { $0.type == .hideCursor && $0.intersects(time: time) }) {
            return false
        }
        if visibilityOverride == .off { return false }
        if visibilityOverride == .on { return true }
        let style = resolvedEffects(at: time).style
        guard style.hideStaticCursor else { return true }
        if cursorData.isClicking { return true }
        if clickProgress != nil { return true }

        guard let previous = cursorFrame(at: max(0, time - 0.5), frames: smoothedCursor) else {
            return true
        }

        return BezierMath.distance(from: previous.position, to: cursorData.position) > 2
    }

    private func clickAnimationProgress(at time: Double, frames: [CursorFrame]) -> Double? {
        let preRoll = 0.22
        let postRoll = 0.66
        let lowerBound = time - postRoll
        let upperBound = time + preRoll
        guard let upperIndex = lastFrameIndex(at: upperBound, frames: frames) else {
            return nil
        }

        var bestClick: CursorFrame?
        var index = upperIndex
        while index >= 0 {
            let frame = frames[index]
            if frame.timestamp < lowerBound { break }
            if isClickDown(frame),
               bestClick.map({ abs(frame.timestamp - time) < abs($0.timestamp - time) }) ?? true {
                bestClick = frame
            }
            index -= 1
        }

        guard let click = bestClick else { return nil }
        let delta = time - click.timestamp
        if delta < 0 {
            return max(-1, delta / preRoll)
        }
        return min(1, delta / postRoll)
    }

    private func isClickDown(_ frame: CursorFrame) -> Bool {
        CursorClickClassifier.isClickDown(frame)
    }

    private func playPreviewClickIfNeeded(from startTime: Double, to endTime: Double) {
        let style = resolvedEffects(at: endTime).style
        guard style.clickSoundEnabled, endTime >= startTime else { return }

        guard let click = smoothedCursor.first(where: { frame in
            isClickDown(frame) &&
            frame.timestamp > startTime &&
            frame.timestamp <= endTime
        }) else {
            return
        }

        if let lastPreviewClickTimestamp,
           click.timestamp - lastPreviewClickTimestamp < 0.12 {
            return
        }

        lastPreviewClickTimestamp = click.timestamp
        clickPreviewPlayer.playClick(
            volume: style.clickSoundVolume,
            style: style.clickSoundStyle,
            fileURL: style.clickSoundFileURL
        )
    }
    
    private func loadSourceFrame(at time: Double) -> CIImage? {
        let fps = currentPreviewFPS
        let quantizedTime = (time * fps).rounded() / fps
        if cachedSourceFrameTime == quantizedTime, let cachedSourceFrame {
            return cachedSourceFrame
        }

        guard let gen = assetImageGenerator else {
            let fallback = CIImage(color: .init(cgColor: CGColor(gray: 0.2, alpha: 1.0)))
                .cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            cachedSourceFrameTime = quantizedTime
            cachedSourceFrame = fallback
            return fallback
        }

        let cmTime = CMTime(seconds: quantizedTime, preferredTimescale: 600)
        do {
            let cgImage = try gen.copyCGImage(at: cmTime, actualTime: nil)
            let frame = CIImage(cgImage: cgImage)
            cachedSourceFrameTime = quantizedTime
            cachedSourceFrame = frame
            return frame
        } catch {
            let fallback = CIImage(color: .init(cgColor: CGColor(gray: 0.2, alpha: 1.0)))
                .cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            cachedSourceFrameTime = quantizedTime
            cachedSourceFrame = fallback
            return fallback
        }
    }

    private func loadWebcamFrame(at time: Double) -> CIImage? {
        let fps = currentPreviewFPS
        let quantizedTime = (time * fps).rounded() / fps
        if cachedWebcamFrameTime == quantizedTime {
            return cachedWebcamFrame
        }

        guard project.webcamEnabled, let gen = webcamImageGenerator else { return nil }
        let cmTime = CMTime(seconds: quantizedTime, preferredTimescale: 600)
        do {
            let cgImage = try gen.copyCGImage(at: cmTime, actualTime: nil)
            let frame = CIImage(cgImage: cgImage)
            cachedWebcamFrameTime = quantizedTime
            cachedWebcamFrame = frame
            return frame
        } catch {
            cachedWebcamFrameTime = quantizedTime
            cachedWebcamFrame = nil
            return nil
        }
    }

    private func loadCaptionSegments(from url: URL?) -> [CaptionSegment] {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let segments = try? JSONDecoder().decode([CaptionSegment].self, from: data) else {
            return []
        }
        return segments
    }

    private func persistCaptionSegments(saveUndo: Bool = false) {
        if saveUndo {
            saveState()
        }

        captionSegments = captionSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        let outputURL = project.videoFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("captions.json")

        do {
            let data = try JSONEncoder().encode(captionSegments)
            try data.write(to: outputURL)
            try? transcriptionEngine.writeSRT(
                segments: captionSegments,
                to: outputURL.deletingPathExtension().appendingPathExtension("srt")
            )
            try? transcriptionEngine.writeVTT(
                segments: captionSegments,
                to: outputURL.deletingPathExtension().appendingPathExtension("vtt")
            )
            project.captionsFileURL = outputURL
            project.subtitlesEnabled = !captionSegments.isEmpty
            project.modifiedAt = Date()
            captionStatusMessage = captionSegments.isEmpty ? "Captions removed." : "Captions updated."
            saveProject()
            renderRevision += 1
        } catch {
            captionStatusMessage = "Caption save failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func importedCaptionSegments(from url: URL) throws -> [CaptionSegment] {
        let format = CaptionFileFormat.infer(from: url)
        let data = try captionImportData(from: url)

        switch format {
        case .json:
            return try JSONDecoder().decode([CaptionSegment].self, from: data)
        case .srt, .vtt:
            let text = String(decoding: data, as: UTF8.self)
            return try parseCaptionDocument(text)
        }
    }

    nonisolated private static func captionImportData(from url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= maxCaptionImportBytes else {
            throw CaptionImportError.fileTooLarge(maxBytes: maxCaptionImportBytes)
        }
        return try Data(contentsOf: url)
    }

    nonisolated private static func parseCaptionDocument(_ content: String) throws -> [CaptionSegment] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

        var segments: [CaptionSegment] = []
        for block in blocks {
            guard let timeIndex = block.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = block[timeIndex].components(separatedBy: "-->")
            guard timing.count >= 2,
                  let start = parseCaptionTime(timing[0]),
                  let end = parseCaptionTime(timing[1]) else {
                continue
            }

            let text = block.dropFirst(timeIndex + 1)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            segments.append(CaptionSegment(
                id: UUID(),
                start: max(0, start),
                end: max(start + 0.2, end),
                text: text
            ))
        }

        return segments.sorted { $0.start < $1.start }
    }

    nonisolated private static func parseCaptionTime(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".")
        guard let cleaned else { return nil }

        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secondsPart = parts.last ?? "0"
        let secondComponents = secondsPart.split(separator: ".").map(String.init)
        let seconds = Double(secondComponents.first ?? "0") ?? 0
        let milliseconds = Double("0." + (secondComponents.dropFirst().first ?? "0")) ?? 0
        let minutes = Double(parts[parts.count - 2]) ?? 0
        let hours = parts.count == 3 ? (Double(parts[0]) ?? 0) : 0
        return hours * 3600 + minutes * 60 + seconds + milliseconds
    }

    private func activeSubtitle(at time: Double) -> String? {
        return captionSegments.first { time >= $0.start && time <= $0.end }?.text
    }

    private func cleanedCaptionText(_ text: String) -> (text: String, removedCount: Int) {
        let fillerPhrases = [
            "you know",
            "i mean",
            "sort of",
            "kind of",
            "um",
            "uh",
            "er",
            "ah"
        ]

        var working = text
        var removedCount = 0
        for phrase in fillerPhrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = #"(?i)(^|[\s,.;:!?])"# + escaped + #"(?=$|[\s,.;:!?])[,.;:!?\s]*"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = regex.matches(in: working, range: range)
            guard !matches.isEmpty else { continue }
            removedCount += matches.count
            working = regex.stringByReplacingMatches(
                in: working,
                range: range,
                withTemplate: "$1"
            )
        }

        return (normalizeCaptionText(working), removedCount)
    }

    private func normalizeCaptionText(_ text: String) -> String {
        var output = text
        if let whitespace = try? NSRegularExpression(pattern: #"\s+"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = whitespace.stringByReplacingMatches(in: output, range: range, withTemplate: " ")
        }
        if let punctuationSpacing = try? NSRegularExpression(pattern: #"\s+([,.!?;:])"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = punctuationSpacing.stringByReplacingMatches(in: output, range: range, withTemplate: "$1")
        }
        if let duplicatePunctuation = try? NSRegularExpression(pattern: #"([,.!?;:])\s*([,.!?;:])+"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = duplicatePunctuation.stringByReplacingMatches(in: output, range: range, withTemplate: "$1")
        }
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, ",.;:!?".contains(first) {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func activeOverlays(at time: Double) -> [OverlayElement] {
        (project.overlayElements ?? []).filter { $0.intersects(time: time) }
    }

    private func activeTitleCards(at time: Double) -> [TitleCardSegment] {
        (project.titleCardSegments ?? []).filter { $0.intersects(time: time) }
    }

    private func makeSmartTitleCards() -> [TitleCardSegment] {
        let title = (project.sharePageSettings?.resolvedTitleFallback ?? project.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = project.sharePageSettings?.creatorName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = project.sharePageSettings?.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cta = project.sharePageSettings?.callToActionLabel
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let accent = project.sharePageSettings?.accentColor ?? CodableColor(r: 0.23, g: 0.51, b: 0.96)

        var cards = (project.titleCardSegments ?? [])
            .filter { $0.kind != .intro && $0.kind != .outro }
        let introDuration = min(2.4, max(1.2, duration * 0.18))
        let introSubtitle = creator.isEmpty ? description : "By \(creator)"
        cards.append(TitleCardSegment(
            startTime: 0,
            endTime: min(duration, introDuration),
            kind: .intro,
            style: .gradient,
            title: title.isEmpty ? "New Recording" : title,
            subtitle: introSubtitle,
            accentColor: accent,
            backgroundOpacity: 0.86
        ))

        if duration > 4.0 {
            let outroDuration = min(2.4, max(1.4, duration * 0.16))
            let start = max(0, duration - outroDuration)
            cards.append(TitleCardSegment(
                startTime: start,
                endTime: duration,
                kind: .outro,
                style: .cinematic,
                title: cta.isEmpty ? "Thanks for watching" : cta,
                subtitle: project.sharePageSettings?.validCallToActionURL?.absoluteString ?? "",
                accentColor: accent,
                backgroundOpacity: 0.82
            ))
        }

        cards.sort { $0.startTime < $1.startTime }
        return cards
    }

    private func preferredWatermarkText() -> String {
        let creator = project.sharePageSettings?.creatorName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !creator.isEmpty {
            return creator
        }

        let title = project.sharePageSettings?.resolvedTitleFallback
            ?? project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.count > 28 ? AppBrand.name : title
    }

    private func activeCameraLayoutMode(at time: Double, webcamEnabled: Bool? = nil) -> CameraLayoutMode {
        guard (webcamEnabled ?? project.webcamEnabled), project.webcamFileURL != nil else {
            return .screenOnly
        }
        return (project.cameraLayoutSegments ?? [])
            .sorted { $0.startTime < $1.startTime }
            .last(where: { $0.intersects(time: time) })?
            .mode ?? .defaultOverlay
    }

    private func previewStyleConfig(base: StylePreset? = nil) -> StylePreset {
        var config = base ?? project.style
        switch previewRenderMode {
        case .quality:
            break
        case .performance:
            config.motionBlurEnabled = false
        case .powerSaving:
            config.motionBlurEnabled = false
            config.useHighResCursors = false
            config.shadowEnabled = false
        }
        return config
    }

    private func resolvedEffects(at time: Double) -> ResolvedEffectSettings {
        EffectSegmentResolver.resolve(project: project, at: time)
    }

    private func clampedOverlayRect(_ rect: CGRect) -> CGRect {
        let width = max(0.05, min(rect.width, 1))
        let height = max(0.05, min(rect.height, 1))
        let x = max(0, min(rect.origin.x, 1 - width))
        let y = max(0, min(rect.origin.y, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func clampedOptionalVolume(_ volume: Float?) -> Float? {
        volume.map { max(0, min($0, 1)) }
    }

    private func uniqueDestination(in directory: URL, prefix: String, fileExtension pathExtension: String) -> URL {
        let ext = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var candidate = directory.appendingPathComponent("\(prefix)\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(prefix)-\(index)\(ext)")
            index += 1
        }
        return candidate
    }

    private func chapterTitle(from text: String, fallbackIndex: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Chapter \(fallbackIndex)" }
        if cleaned.count <= 54 { return cleaned }
        let prefix = cleaned.prefix(51)
        return "\(prefix)..."
    }

    private func formatChapterTime(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? seconds : 0
        let totalSeconds = max(0, Int(safeSeconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func loadKeyEvents(from url: URL?) -> [KeyPressEvent] {
        Self.decodeKeyEvents(from: url)
    }

    private func persistKeyEvents() {
        guard let url = project.keyEventsFileURL else {
            renderRevision += 1
            return
        }

        keyEvents = KeyPressEvent.sanitized(keyEvents)
        if let persistedURL = KeyboardMonitor.persist(events: keyEvents, to: url) {
            project.keyEventsFileURL = persistedURL
            project.modifiedAt = Date()
            renderRevision += 1
        } else if keyEvents.isEmpty {
            project.keyEventsFileURL = nil
            project.modifiedAt = Date()
            renderRevision += 1
        } else {
            print("Failed to save key events")
        }
    }

    private func activeShortcuts(at time: Double, style: StylePreset? = nil) -> [KeyPressEvent] {
        let style = style ?? project.style
        return KeyboardShortcutDisplayFilter.activeShortcuts(
            at: time,
            events: keyEvents,
            style: style
        )
    }

    private var currentPreviewFPS: Double {
        switch previewRenderMode {
        case .quality:
            return 30
        case .performance:
            return 24
        case .powerSaving:
            return 12
        }
    }

    private var currentPlaybackFPS: Double {
        min(currentPreviewFPS, 24)
    }

    private func frameTransform(at time: Double) -> FrameTransform? {
        guard !frameTransforms.isEmpty else { return nil }
        var low = 0
        var high = frameTransforms.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if frameTransforms[mid].timestamp <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if let match {
            return frameTransforms[match]
        }
        return frameTransforms.first
    }

    private func cursorFrame(at time: Double, frames: [CursorFrame]) -> CursorFrame? {
        guard let index = lastFrameIndex(at: time, frames: frames) else { return nil }
        return frames[index]
    }

    private func lastFrameIndex(at time: Double, frames: [CursorFrame]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].timestamp <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return match
    }

    private var sourceWidth: CGFloat {
        project.sourceRect.width > 0 ? project.sourceRect.width : 1920
    }

    private var sourceHeight: CGFloat {
        project.sourceRect.height > 0 ? project.sourceRect.height : 1080
    }

    private var sourceSize: CGSize {
        CGSize(width: sourceWidth, height: sourceHeight)
    }

    private var sourceRect: CGRect {
        CGRect(origin: .zero, size: sourceSize)
    }

    private var autoZoomConfig: AutoZoomCalculator.Config {
        AutoZoomCalculator.Config(maxZoomScale: project.style.autoZoomScale)
    }
    
    // MARK: - Undo/Redo
    
    private func saveState() {
        undoStack.append(project)
        redoStack.removeAll()
    }
    
    func undo() {
        guard !undoStack.isEmpty else { return }
        redoStack.append(project)
        project = undoStack.removeLast()
        zoomSegments = project.zoomSegments
        editActions = project.editActions
        refreshTimelineAudioPreviewSources()
        refreshBackgroundMusicPreviewSource()
        generateFrameTransforms()
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(project)
        project = redoStack.removeLast()
        zoomSegments = project.zoomSegments
        editActions = project.editActions
        refreshTimelineAudioPreviewSources()
        refreshBackgroundMusicPreviewSource()
        generateFrameTransforms()
    }

    func markProjectModified() {
        objectWillChange.send()
        project.modifiedAt = Date()
        if let cursorRecording = rawCursorRecording {
            let mappedRecording: CursorRecording
            if let renderCursorRecording {
                mappedRecording = renderCursorRecording
            } else {
                mappedRecording = CursorCoordinateMapper.toRenderSpace(
                    cursorRecording,
                    sourceSize: sourceSize,
                    displayID: project.displayID == 0 ? nil : project.displayID
                )
                renderCursorRecording = mappedRecording
            }

            if smoothedCursorStyle != project.style.cursorStyle {
                smoothedCursor = cursorSmoother.smooth(
                    frames: mappedRecording.frames,
                    style: project.style.cursorStyle,
                    targetFPS: currentPreviewFPS
                )
                smoothedCursorStyle = project.style.cursorStyle
            }
        }
        cachedSourceFrameTime = nil
        cachedSourceFrame = nil
        cachedWebcamFrameTime = nil
        cachedWebcamFrame = nil
        refreshTimelineAudioPreviewSources()
        if isPlaying {
            syncTimelineAudioPreview(rate: speedMultiplier(at: playheadTime))
        }
        refreshBackgroundMusicPreviewSource()
        renderRevision += 1
    }

    func saveProject() {
        project.modifiedAt = Date()
        try? FileManager.default.saveRecordingProject(project)
    }

    private func refreshBackgroundMusicPreviewSource() {
        backgroundMusicPreviewPlayer.configure(url: project.style.backgroundMusicURL)
        guard isPlaying else { return }
        backgroundMusicPreviewPlayer.sync(
            projectTime: playheadTime,
            volume: resolvedEffects(at: playheadTime).style.backgroundMusicVolume,
            loop: project.style.backgroundMusicLoop
        )
    }
}

enum EditorExportError: LocalizedError {
    case frameUnavailable

    var errorDescription: String? {
        switch self {
        case .frameUnavailable:
            return "Current frame could not be rendered."
        }
    }
}

struct ProductionReadiness {
    var hasLook: Bool
    var hasFocus: Bool
    var hasCaptions: Bool
    var hasKeyboard: Bool
    var hasCamera: Bool
    var hasStoryCards: Bool
    var hasBranding: Bool
    var hasShareMetadata: Bool

    var completedCount: Int {
        [
            hasLook,
            hasFocus,
            hasCaptions,
            hasKeyboard,
            hasCamera,
            hasStoryCards,
            hasBranding,
            hasShareMetadata
        ].filter { $0 }.count
    }

    var totalCount: Int { 8 }
}

struct ProductionFinishSummary: Equatable {
    var titleCardCount: Int
    var chapterCount: Int
    var captionsEnabled: Bool
    var keyboardEnabled: Bool
    var webcamEnabled: Bool
    var watermarkEnabled: Bool
}
