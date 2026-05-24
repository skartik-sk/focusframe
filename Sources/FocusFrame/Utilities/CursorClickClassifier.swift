import Foundation

enum CursorClickClassifier {
    static func clickDownFrames(from frames: [CursorFrame]) -> [CursorFrame] {
        var result: [CursorFrame] = []
        var wasClicking = false

        let safeFrames = frames
            .filter { frame in
                frame.timestamp.isFinite &&
                frame.position.x.isFinite &&
                frame.position.y.isFinite
            }
            .sorted(by: { $0.timestamp < $1.timestamp })

        for frame in safeFrames {
            if isClickDown(frame, wasClickingBefore: wasClicking) {
                result.append(frame)
            }
            wasClicking = pressedState(after: frame, previous: wasClicking)
        }

        return result
    }

    static func isClickDown(_ frame: CursorFrame) -> Bool {
        switch frame.clickType {
        case .leftDown, .rightDown:
            return true
        case .other:
            return frame.isClicking
        case nil:
            return frame.isClicking
        case .leftUp, .rightUp:
            return false
        }
    }

    static func isClickDown(_ frame: CursorFrame, wasClickingBefore: Bool) -> Bool {
        switch frame.clickType {
        case .leftDown, .rightDown:
            return true
        case .other:
            return frame.isClicking && !wasClickingBefore
        case nil:
            return frame.isClicking && !wasClickingBefore
        case .leftUp, .rightUp:
            return false
        }
    }

    static func pressedState(after frame: CursorFrame, previous: Bool) -> Bool {
        switch frame.clickType {
        case .leftDown, .rightDown:
            return true
        case .leftUp, .rightUp:
            return false
        case .other:
            return frame.isClicking
        case nil:
            return frame.isClicking
        }
    }

    static func debouncedClickTimes(
        from frames: [CursorFrame],
        minimumInterval: Double
    ) -> [Double] {
        var times: [Double] = []
        var lastTime = -Double.infinity

        for frame in clickDownFrames(from: frames) where frame.timestamp - lastTime >= minimumInterval {
            times.append(frame.timestamp)
            lastTime = frame.timestamp
        }

        return times
    }
}
