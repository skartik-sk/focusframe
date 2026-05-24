import Foundation
import CoreGraphics

struct CursorFrame: Codable {
    let timestamp: Double     // seconds from recording start
    let position: CGPoint     // screen coordinates
    let isClicking: Bool      // was mouse button down at this instant
    let clickType: ClickType? // what kind of click
    let scrollDelta: CGFloat? // scroll wheel delta (for zoom-on-scroll detection)

    enum ClickType: String, Codable {
        case leftDown, leftUp
        case rightDown, rightUp
        case other
    }

    func sanitizedForUse(screenSize: CGSize) -> CursorFrame? {
        let bounds = CursorRecording.sanitizedScreenSize(screenSize)
        let safeTimestamp = timestamp.isFinite ? timestamp : 0
        let safeX = position.x.isFinite ? position.x : 0
        let safeY = position.y.isFinite ? position.y : 0
        let scrollDelta = scrollDelta.flatMap { $0.isFinite ? max(-10_000, min($0, 10_000)) : nil }
        return CursorFrame(
            timestamp: min(max(safeTimestamp, 0), CursorRecording.maxTimelineSeconds),
            position: CGPoint(
                x: max(0, min(safeX, bounds.width)),
                y: max(0, min(safeY, bounds.height))
            ),
            isClicking: isClicking,
            clickType: clickType,
            scrollDelta: scrollDelta
        )
    }
}

// The full cursor recording data stored as JSON
struct CursorRecording: Codable {
    let frames: [CursorFrame]
    let sampleRate: Double     // capture Hz
    let screenSize: CGSize     // screen dimensions at recording time
    let cursorType: CursorType // arrow, beam, hand, etc. at start

    enum CursorType: String, Codable {
        case arrow, beam, crosshair, hand, pointingHand
        case resizeLeftRight, resizeUpDown
        case closedHand, openHand, contextualMenu
        case ibeam, notAllowed, disappearingItem
    }

    func sanitizedForUse() -> CursorRecording {
        let safeScreenSize = Self.sanitizedScreenSize(screenSize)
        let safeSampleRate = Self.sanitizedSampleRate(sampleRate)
        var previousFrame: CursorFrame?
        var safeFrames: [CursorFrame] = []
        safeFrames.reserveCapacity(min(frames.count, Self.maxLoadedFrameCount))

        for frame in frames {
            guard let safeFrame = frame.sanitizedForUse(screenSize: safeScreenSize) else {
                continue
            }
            if let previousFrame,
               Self.shouldDropDuplicateMovement(previous: previousFrame, next: safeFrame, minInterval: 1.0 / 120.0) {
                continue
            }
            safeFrames.append(safeFrame)
            previousFrame = safeFrame
            if safeFrames.count >= Self.maxLoadedFrameCount {
                break
            }
        }

        return CursorRecording(
            frames: safeFrames.sorted { $0.timestamp < $1.timestamp },
            sampleRate: safeSampleRate,
            screenSize: safeScreenSize,
            cursorType: cursorType
        )
    }

    static let maxTimelineSeconds: Double = 24 * 60 * 60
    private static let maxLoadedFrameCount = 1_000_000

    static func sanitizedScreenSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(
            width: min(max(size.width, 1), 16_384),
            height: min(max(size.height, 1), 16_384)
        )
    }

    private static func sanitizedSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 60 }
        return min(max(sampleRate, 1), 240)
    }

    static func shouldDropDuplicateMovement(previous: CursorFrame, next: CursorFrame, minInterval: Double) -> Bool {
        guard previous.clickType == nil,
              next.clickType == nil,
              !previous.isClicking,
              !next.isClicking,
              previous.scrollDelta == nil,
              next.scrollDelta == nil else {
            return false
        }

        let timeDelta = next.timestamp - previous.timestamp
        let distance = hypot(previous.position.x - next.position.x, previous.position.y - next.position.y)
        return (timeDelta >= 0 && timeDelta < minInterval && distance < 1.5) || distance < 0.5
    }
}
