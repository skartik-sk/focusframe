import XCTest
@testable import FocusFrame

final class CursorTrackerTests: XCTestCase {
    func testCursorRecordingMetadataMatchesPollingCadence() {
        XCTAssertEqual(CursorTracker.pollingSampleRate, 60.0)
    }

    func testCursorRecordingSanitizerClampsAndDeduplicatesMovementFrames() {
        let recording = CursorRecording(
            frames: [
                CursorFrame(timestamp: .nan, position: CGPoint(x: 10, y: 10), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 0, position: CGPoint(x: 10, y: 10), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 0.001, position: CGPoint(x: 10.2, y: 10.2), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 0.002, position: CGPoint(x: 10.2, y: 10.2), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 90_001, position: CGPoint(x: 9_999, y: -10), isClicking: false, clickType: nil, scrollDelta: .nan)
            ],
            sampleRate: .nan,
            screenSize: CGSize(width: CGFloat.nan, height: 0),
            cursorType: .arrow
        )

        let sanitized = recording.sanitizedForUse()

        XCTAssertEqual(sanitized.sampleRate, 60)
        XCTAssertEqual(sanitized.screenSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(sanitized.frames.count, 3)
        XCTAssertEqual(sanitized.frames[0].timestamp, 0)
        XCTAssertEqual(sanitized.frames[1].clickType, CursorFrame.ClickType.leftDown)
        XCTAssertEqual(sanitized.frames[2].timestamp, 86_400)
        XCTAssertEqual(sanitized.frames[2].position.x, 1920)
        XCTAssertEqual(sanitized.frames[2].position.y, 0)
        XCTAssertNil(sanitized.frames[2].scrollDelta)
    }
}
