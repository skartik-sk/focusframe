import Foundation
import CoreGraphics

enum CursorCoordinateMapper {
    static func toRenderSpace(
        _ recording: CursorRecording,
        sourceSize: CGSize,
        displayID: CGDirectDisplayID? = nil
    ) -> CursorRecording {
        let displayPointSize = displayID
            .map { CGDisplayBounds($0).size }
            .flatMap { finitePositiveSize($0) }

        return toRenderSpace(
            recording,
            sourceSize: sourceSize,
            displayPointSizeForPointCapture: displayPointSize
        )
    }

    static func toRenderSpace(
        _ recording: CursorRecording,
        sourceSize: CGSize,
        displayPointSizeForPointCapture displayPointSize: CGSize?
    ) -> CursorRecording {
        let recording = recording.sanitizedForUse()
        let sourceSize = finitePositiveSize(sourceSize) ?? CGSize(width: 1, height: 1)
        let recordedSize = effectiveRecordedSize(
            for: recording,
            sourceSize: sourceSize,
            displayPointSize: displayPointSize
        )
        let scaleX = sourceSize.width / recordedSize.width
        let scaleY = sourceSize.height / recordedSize.height

        let frames = recording.frames.map { frame in
            let x = clamp(frame.position.x * scaleX, min: 0, max: sourceSize.width)
            let yFromTop = clamp(frame.position.y * scaleY, min: 0, max: sourceSize.height)
            let y = clamp(sourceSize.height - yFromTop, min: 0, max: sourceSize.height)

            return CursorFrame(
                timestamp: sanitizedTimestamp(frame.timestamp),
                position: CGPoint(x: x, y: y),
                isClicking: frame.isClicking,
                clickType: frame.clickType,
                scrollDelta: sanitizedScrollDelta(frame.scrollDelta)
            )
        }

        return CursorRecording(
            frames: frames,
            sampleRate: sanitizedSampleRate(recording.sampleRate),
            screenSize: sourceSize,
            cursorType: recording.cursorType
        )
    }

    private static func sanitizedTimestamp(_ timestamp: Double) -> Double {
        guard timestamp.isFinite else { return 0 }
        return max(0, timestamp)
    }

    private static func sanitizedSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 60 }
        return min(240, max(1, sampleRate))
    }

    private static func sanitizedScrollDelta(_ scrollDelta: CGFloat?) -> CGFloat? {
        guard let scrollDelta, scrollDelta.isFinite else { return nil }
        return scrollDelta
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private static func finitePositiveSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return size
    }

    private static func effectiveRecordedSize(
        for recording: CursorRecording,
        sourceSize: CGSize,
        displayPointSize: CGSize?
    ) -> CGSize {
        let recordedSize = finitePositiveSize(recording.screenSize) ?? CGSize(width: 1, height: 1)

        guard let displayPointSize = displayPointSize.flatMap(finitePositiveSize),
              displayPointSize.width > 1,
              displayPointSize.height > 1 else {
            return recordedSize
        }

        let sourceMatchesRecordedPixels =
            abs(sourceSize.width - recordedSize.width) / max(sourceSize.width, recordedSize.width, 1) < 0.03 &&
            abs(sourceSize.height - recordedSize.height) / max(sourceSize.height, recordedSize.height, 1) < 0.03

        let recordedLooksLikePixels =
            recordedSize.width / displayPointSize.width > 1.05 ||
            recordedSize.height / displayPointSize.height > 1.05

        let framesFitPointSpace = recording.frames.allSatisfy { frame in
            frame.position.x.isFinite &&
            frame.position.y.isFinite &&
            frame.position.x >= -2 &&
            frame.position.y >= -2 &&
            frame.position.x <= displayPointSize.width + 2 &&
            frame.position.y <= displayPointSize.height + 2
        }

        if sourceMatchesRecordedPixels, recordedLooksLikePixels, framesFitPointSpace {
            return CGSize(
                width: max(displayPointSize.width, 1),
                height: max(displayPointSize.height, 1)
            )
        }

        return recordedSize
    }
}
