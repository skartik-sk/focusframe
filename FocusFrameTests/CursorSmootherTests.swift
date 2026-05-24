import XCTest
@testable import FocusFrame
import CoreGraphics

final class CursorSmootherTests: XCTestCase {

    var smoother: CursorSmoother!

    override func setUp() {
        super.setUp()
        smoother = CursorSmoother()
    }

    override func tearDown() {
        smoother = nil
        super.tearDown()
    }

    // MARK: - Test: Straight Line Remains Straight

    func testStraightLineRemainsStraight() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        XCTAssertGreaterThanOrEqual(smoothed.count, frames.count, "Should preserve frame count")

        let firstPoint = smoothed.first!.position
        let lastPoint = smoothed.last!.position

        XCTAssertEqual(firstPoint.x, 0, accuracy: 10, "First point should remain near start")
        XCTAssertEqual(firstPoint.y, 0, accuracy: 10, "First point should remain near start")
        XCTAssertEqual(lastPoint.x, 200, accuracy: 10, "Last point should remain near end")
        XCTAssertEqual(lastPoint.y, 200, accuracy: 10, "Last point should remain near end")

        // Check if path is roughly linear
        for i in 1..<smoothed.count {
            let prev = smoothed[i-1].position
            let curr = smoothed[i].position
            let dx = curr.x - prev.x
            let dy = curr.y - prev.y

            // In a straight line, dx/dy should be roughly constant
            XCTAssertEqual(dx, dy, accuracy: 50, "Should maintain roughly linear path")
        }
    }

    // MARK: - Test: Sharp Corner Is Rounded

    func testSharpCornerIsRounded() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 100, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        // Find the corner region (around index where both x and y change)
        var cornerFound = false
        for i in 1..<smoothed.count-1 {
            let prev = smoothed[i-1].position
            let curr = smoothed[i].position

            // If we're in the corner region, both x and y should change gradually
            if abs(curr.x - 100) < 20 && abs(curr.y - 0) < 20 {
                let dx1 = curr.x - prev.x
                let dy1 = curr.y - prev.y

                // In a rounded corner, both x and y should have non-zero derivatives
                XCTAssertGreaterThan(abs(dx1) + abs(dy1), 0, "Corner should have movement")
                cornerFound = true
                break
            }
        }

        XCTAssertTrue(cornerFound, "Should find corner region")
    }

    // MARK: - Test: Static Cursor Stays In Place

    func testStaticCursorStaysInPlace() throws {
        let staticPosition = CGPoint(x: 500, y: 500)

        let frames = [
            CursorFrame(timestamp: 0.0, position: staticPosition, isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: staticPosition, isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: staticPosition, isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.5, position: staticPosition, isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        for frame in smoothed {
            XCTAssertEqual(frame.position.x, staticPosition.x, accuracy: 1.0, "Static cursor should stay in place")
            XCTAssertEqual(frame.position.y, staticPosition.y, accuracy: 1.0, "Static cursor should stay in place")
        }
    }

    // MARK: - Test: Movement Styles Affect Smoothness

    func testMovementStylesAffectSmoothness() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 50, y: 50), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let rapidSmooth = smoother.smooth(frames: frames, style: .rapid, targetFPS: 60)
        let defaultSmooth = smoother.smooth(frames: frames, style: .default, targetFPS: 60)
        let slowSmooth = smoother.smooth(frames: frames, style: .slow, targetFPS: 60)

        // Rapid should be closer to original (less smoothing)
        let rapidDeviation = calculateDeviation(from: frames, to: rapidSmooth)
        let defaultDeviation = calculateDeviation(from: frames, to: defaultSmooth)
        let slowDeviation = calculateDeviation(from: frames, to: slowSmooth)

        XCTAssertLessThan(rapidDeviation, defaultDeviation, "Rapid should deviate less from original")
        XCTAssertLessThanOrEqual(defaultDeviation, slowDeviation, "Default should not deviate more than slow")
    }

    // MARK: - Test: Resampling To Target FPS

    func testResamplingToTargetFPS() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.008, position: CGPoint(x: 10, y: 10), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.016, position: CGPoint(x: 20, y: 20), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let resampled = smoother.smooth(frames: frames, style: .default, targetFPS: 30)

        // At 30 FPS, frames should be 0.033s apart
        if resampled.count >= 2 {
            let timeInterval = resampled[1].timestamp - resampled[0].timestamp
            XCTAssertEqual(timeInterval, 1.0/30.0, accuracy: 0.01, "Should resample to target FPS")
        }
    }

    // MARK: - Test: Preserves Click State

    func testPreservesClickState() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 100, y: 100), isClicking: true, clickType: .leftDown, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        let clickFrames = smoothed.filter { $0.isClicking }
        XCTAssertGreaterThan(clickFrames.count, 0, "Should preserve click frames")
    }

    func testPreservesOtherMouseDownState() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 100, y: 100), isClicking: true, clickType: .other, scrollDelta: nil),
            CursorFrame(timestamp: 0.6, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: .other, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .rapid, targetFPS: 60)

        XCTAssertTrue(
            smoothed.contains { $0.clickType == .other && $0.isClicking },
            "Other mouse down events should stay clickable after smoothing for preview/export animations"
        )
    }

    func testPreservesClickStateWithoutClickType() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: 100, y: 100), isClicking: true, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .rapid, targetFPS: 60)

        XCTAssertTrue(
            smoothed.contains { $0.clickType == nil && $0.isClicking },
            "Recordings with only isClicking should keep click state after smoothing"
        )
    }

    // MARK: - Test: Handles Empty Input

    func testHandlesEmptyInput() throws {
        let frames: [CursorFrame] = []

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        XCTAssertEqual(smoothed.count, 0, "Should handle empty input gracefully")
    }

    // MARK: - Test: Single Frame

    func testSingleFrame() throws {
        let frames = [
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: 60)

        XCTAssertEqual(smoothed.count, frames.count, "Should preserve single frame")
        XCTAssertEqual(smoothed.first!.position, frames.first!.position, "Should preserve position")
    }

    func testMalformedFramesAndInvalidFPSDoNotCrashSmoothing() throws {
        let frames = [
            CursorFrame(timestamp: .nan, position: .zero, isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.0, position: CGPoint(x: 0, y: 0), isClicking: false, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: CGFloat.infinity, y: 10), isClicking: true, clickType: .leftDown, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let smoothed = smoother.smooth(frames: frames, style: .default, targetFPS: .nan)

        XCTAssertFalse(smoothed.isEmpty)
        XCTAssertTrue(smoothed.allSatisfy { $0.timestamp.isFinite && $0.position.x.isFinite && $0.position.y.isFinite })
    }

    // MARK: - Test: Long Recording Performance

    func testLongRecordingPerformance() throws {
        var frames: [CursorFrame] = []
        let duration: Double = 60 // 1 minute at 120 FPS = 7200 frames

        for i in 0..<Int(duration * 120) {
            let time = Double(i) / 120.0
            let x = CGFloat(i % 1000)
            let y = CGFloat((i / 1000) * 10)
            frames.append(CursorFrame(
                timestamp: time,
                position: CGPoint(x: x, y: y),
                isClicking: i % 60 == 0,
                clickType: i % 60 == 0 ? .leftDown : nil,
                scrollDelta: nil
            ))
        }

        measure {
            _ = smoother.smooth(frames: frames, style: .default, targetFPS: 60)
        }
    }

    // MARK: - Helper Methods

    private func calculateDeviation(from original: [CursorFrame], to smoothed: [CursorFrame]) -> CGFloat {
        var totalDeviation: CGFloat = 0
        let count = min(original.count, smoothed.count)

        for i in 0..<count {
            let dx = smoothed[i].position.x - original[i].position.x
            let dy = smoothed[i].position.y - original[i].position.y
            totalDeviation += sqrt(dx * dx + dy * dy)
        }

        return totalDeviation / CGFloat(count)
    }
}
