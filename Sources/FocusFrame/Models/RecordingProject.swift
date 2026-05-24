import Foundation
import ScreenCaptureKit
import AVFoundation

extension CMTime: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let seconds = try container.decode(Double.self)
        self = CMTime(seconds: seconds, preferredTimescale: 600)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.seconds)
    }
}

struct RecordingProject: Codable, Identifiable, Equatable {
    let id: UUID
    var createdAt: Date
    var modifiedAt: Date
    var title: String

    // File references
    var videoFileURL: URL          // raw captured MOV
    var cursorDataFileURL: URL     // JSON with [CursorFrame]
    var keyEventsFileURL: URL?     // JSON with [KeyPressEvent]
    var micAudioFileURL: URL?      // mic audio track
    var systemAudioFileURL: URL?   // system audio track
    var webcamFileURL: URL?        // webcam MOV
    var captionsFileURL: URL?      // JSON with [CaptionSegment]

    // Metadata
    var duration: CMTime
    var sourceRect: CGRect         // original capture area
    var displayID: UInt32          // which display was captured

    // Edit state
    var zoomSegments: [ZoomSegment]
    var editActions: [EditAction]  // cuts, speed changes
    var overlayElements: [OverlayElement]? = nil
    var chapterMarkers: [ChapterMarker]? = nil
    var titleCardSegments: [TitleCardSegment]? = nil
    var effectSegments: [EffectSegment]? = nil
    var speakerNotes: String? = nil
    var cameraLayoutSegments: [CameraLayoutSegment]? = nil
    var sharePageSettings: SharePageSettings? = nil
    var cropRect: CGRect?          // nil = no crop
    var style: StylePreset

    // Flags
    var hideDesktopIcons: Bool
    var showKeyboardShortcuts: Bool
    var webcamEnabled: Bool
    var subtitlesEnabled: Bool?
    var systemAudioEnabled: Bool? = nil
    
    static func == (lhs: RecordingProject, rhs: RecordingProject) -> Bool {
        lhs.id == rhs.id
    }

    func sanitizedForUse() -> RecordingProject {
        var copy = self
        copy.sanitizeForUse()
        return copy
    }

    mutating func sanitizeForUse() {
        style = style.sanitizedForUse()
        duration = Self.sanitizedDuration(duration)
        sourceRect = Self.sanitizedSourceRect(sourceRect)
        cropRect = Self.sanitizedOptionalRect(cropRect)

        let maximumTime = max(0, duration.seconds)
        zoomSegments = zoomSegments
            .compactMap { Self.sanitizedZoomSegment($0, maximumTime: maximumTime, sourceRect: sourceRect) }
            .sorted { $0.startTime < $1.startTime }
        editActions = editActions
            .compactMap { Self.sanitizedEditAction($0, maximumTime: maximumTime) }
            .sorted { $0.startTime < $1.startTime }
        overlayElements = Self.nilIfEmpty((overlayElements ?? [])
            .compactMap { Self.sanitizedOverlay($0, maximumTime: maximumTime) }
            .sorted { $0.startTime < $1.startTime })
        sharePageSettings = sharePageSettings?.sanitizedForUse()
        chapterMarkers = Self.nilIfEmpty((chapterMarkers ?? [])
            .compactMap { Self.sanitizedChapter($0, maximumTime: maximumTime) }
            .sorted { $0.time < $1.time })
        titleCardSegments = Self.nilIfEmpty((titleCardSegments ?? [])
            .compactMap { Self.sanitizedTitleCard($0, maximumTime: maximumTime) }
            .sorted { $0.startTime < $1.startTime })
        cameraLayoutSegments = Self.nilIfEmpty((cameraLayoutSegments ?? [])
            .compactMap { Self.sanitizedCameraLayout($0, maximumTime: maximumTime) }
            .sorted { $0.startTime < $1.startTime })
        effectSegments = Self.nilIfEmpty((effectSegments ?? [])
            .compactMap { Self.sanitizedEffectSegment($0, maximumTime: maximumTime) }
            .sorted { $0.startTime < $1.startTime })
    }

    private static func sanitizedDuration(_ duration: CMTime) -> CMTime {
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            return CMTime(seconds: 0, preferredTimescale: 600)
        }
        return CMTime(seconds: min(seconds, 24 * 60 * 60), preferredTimescale: 600)
    }

    private static func sanitizedSourceRect(_ rect: CGRect) -> CGRect {
        let originX = rect.origin.x.isFinite ? max(0, rect.origin.x) : 0
        let originY = rect.origin.y.isFinite ? max(0, rect.origin.y) : 0
        let width = rect.width.isFinite ? max(0, min(rect.width, 8192)) : 0
        let height = rect.height.isFinite ? max(0, min(rect.height, 8192)) : 0
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private static func sanitizedOptionalRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            return nil
        }
        return CGRect(
            x: max(0, rect.origin.x),
            y: max(0, rect.origin.y),
            width: min(max(1, rect.width), 8192),
            height: min(max(1, rect.height), 8192)
        )
    }

    private static func sanitizedZoomSegment(_ segment: ZoomSegment, maximumTime: Double, sourceRect: CGRect) -> ZoomSegment? {
        guard let range = sanitizedRange(start: segment.startTime, end: segment.endTime, maximumTime: maximumTime, minimumDuration: 0.05),
              let zoomRect = sanitizedZoomRect(segment.zoomRect, sourceRect: sourceRect) else {
            return nil
        }
        var sanitized = segment
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        sanitized.zoomRect = zoomRect
        sanitized.focusPadding = clamped(segment.focusPadding, fallback: 0.12, range: 0...0.8)
        sanitized.zoomInDuration = clamped(segment.zoomInDuration, fallback: 0.35, range: 0...3)
        sanitized.zoomOutDuration = clamped(segment.zoomOutDuration, fallback: 0.35, range: 0...3)
        sanitized.keyframes = segment.keyframes?
            .compactMap { keyframe in
                guard keyframe.time.isFinite,
                      keyframe.time >= sanitized.startTime,
                      keyframe.time <= sanitized.endTime,
                      let rect = sanitizedZoomRect(keyframe.zoomRect, sourceRect: sourceRect) else {
                    return nil
                }
                return ZoomKeyframe(time: keyframe.time, zoomRect: rect)
            }
            .sorted { $0.time < $1.time }
        return sanitized
    }

    private static func sanitizedEditAction(_ action: EditAction, maximumTime: Double) -> EditAction? {
        guard let range = sanitizedRange(start: action.startTime, end: action.endTime, maximumTime: maximumTime, minimumDuration: 0.05) else {
            return nil
        }
        var sanitized = action
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        if action.type == .speedChange {
            sanitized.value = clamped(action.value ?? 1, fallback: 1, range: 0.5...4)
        }
        return sanitized
    }

    private static func sanitizedOverlay(_ overlay: OverlayElement, maximumTime: Double) -> OverlayElement? {
        guard let range = sanitizedRange(start: overlay.startTime, end: overlay.endTime, maximumTime: maximumTime, minimumDuration: 0.05) else {
            return nil
        }
        var sanitized = overlay
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        sanitized.rect = normalizedRect(overlay.rect, fallback: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2))
        sanitized.intensity = clamped(overlay.intensity, fallback: 0.75, range: 0...1)
        return sanitized
    }

    private static func sanitizedChapter(_ chapter: ChapterMarker, maximumTime: Double) -> ChapterMarker? {
        guard chapter.time.isFinite else { return nil }
        var sanitized = chapter
        sanitized.time = maximumTime > 0 ? min(max(0, chapter.time), maximumTime) : max(0, chapter.time)
        return sanitized
    }

    private static func sanitizedTitleCard(_ card: TitleCardSegment, maximumTime: Double) -> TitleCardSegment? {
        guard let range = sanitizedRange(start: card.startTime, end: card.endTime, maximumTime: maximumTime, minimumDuration: 0.2) else {
            return nil
        }
        var sanitized = card
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        sanitized.accentColor = card.accentColor.sanitized()
        sanitized.backgroundOpacity = clamped(card.backgroundOpacity, fallback: 0.82, range: 0.1...0.95)
        return sanitized
    }

    private static func sanitizedCameraLayout(_ layout: CameraLayoutSegment, maximumTime: Double) -> CameraLayoutSegment? {
        guard let range = sanitizedRange(start: layout.startTime, end: layout.endTime, maximumTime: maximumTime, minimumDuration: 0.2) else {
            return nil
        }
        var sanitized = layout
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        return sanitized
    }

    private static func sanitizedEffectSegment(_ segment: EffectSegment, maximumTime: Double) -> EffectSegment? {
        guard let range = sanitizedRange(start: segment.startTime, end: segment.endTime, maximumTime: maximumTime, minimumDuration: 0.2) else {
            return nil
        }
        var sanitized = segment
        sanitized.startTime = range.start
        sanitized.endTime = range.end
        sanitized.sourceAudioVolume = sanitizedOptionalVolume(segment.sourceAudioVolume)
        sanitized.micAudioVolume = sanitizedOptionalVolume(segment.micAudioVolume)
        sanitized.musicVolume = sanitizedOptionalVolume(segment.musicVolume)
        return sanitized
    }

    private static func sanitizedZoomRect(_ rect: CGRect, sourceRect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            return nil
        }
        let maxWidth = sourceRect.width > 0 ? sourceRect.width : 8192
        let maxHeight = sourceRect.height > 0 ? sourceRect.height : 8192
        let width = min(max(8, rect.width), maxWidth)
        let height = min(max(8, rect.height), maxHeight)
        let x = min(max(0, rect.origin.x), max(0, maxWidth - width))
        let y = min(max(0, rect.origin.y), max(0, maxHeight - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func normalizedRect(_ rect: CGRect, fallback: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else {
            return fallback
        }
        let width = min(max(0.02, rect.width), 1)
        let height = min(max(0.02, rect.height), 1)
        let x = min(max(0, rect.origin.x), max(0, 1 - width))
        let y = min(max(0, rect.origin.y), max(0, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func sanitizedRange(start: Double, end: Double, maximumTime: Double, minimumDuration: Double) -> (start: Double, end: Double)? {
        guard start.isFinite, end.isFinite else { return nil }
        let upperBound = max(0, maximumTime)
        guard upperBound > 0 else { return nil }
        let duration = min(minimumDuration, upperBound)
        let safeStart = min(max(0, start), max(0, upperBound - duration))
        let safeEnd = min(upperBound, max(safeStart + duration, end))
        guard safeEnd > safeStart else { return nil }
        return (safeStart, safeEnd)
    }

    private static func sanitizedOptionalVolume(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
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

    private static func nilIfEmpty<T>(_ values: [T]) -> [T]? {
        values.isEmpty ? nil : values
    }
}
