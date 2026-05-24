import XCTest
@testable import FocusFrame

final class CursorClickClassifierTests: XCTestCase {
    func testEveryMouseButtonDownCanDriveEffects() {
        let frames = [
            CursorFrame(timestamp: 0.1, position: .zero, isClicking: true, clickType: .leftDown, scrollDelta: nil),
            CursorFrame(timestamp: 0.2, position: .zero, isClicking: false, clickType: .leftUp, scrollDelta: nil),
            CursorFrame(timestamp: 0.4, position: .zero, isClicking: true, clickType: .rightDown, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: .zero, isClicking: false, clickType: .rightUp, scrollDelta: nil),
            CursorFrame(timestamp: 0.7, position: .zero, isClicking: true, clickType: .other, scrollDelta: nil),
            CursorFrame(timestamp: 0.8, position: .zero, isClicking: false, clickType: .other, scrollDelta: nil)
        ]

        let times = CursorClickClassifier.debouncedClickTimes(from: frames, minimumInterval: 0.01)

        XCTAssertEqual(times, [0.1, 0.4, 0.7])
    }

    func testHeldClickWithoutClickTypeOnlyCreatesOneDownEdge() {
        let frames = [
            CursorFrame(timestamp: 1.0, position: .zero, isClicking: true, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.1, position: .zero, isClicking: true, clickType: nil, scrollDelta: nil),
            CursorFrame(timestamp: 1.2, position: .zero, isClicking: false, clickType: nil, scrollDelta: nil)
        ]

        let times = CursorClickClassifier.debouncedClickTimes(from: frames, minimumInterval: 0.01)

        XCTAssertEqual(times, [1.0])
    }

    func testMalformedFramesAreIgnoredBeforeSortingClickEvents() {
        let frames = [
            CursorFrame(timestamp: .nan, position: .zero, isClicking: true, clickType: .leftDown, scrollDelta: nil),
            CursorFrame(timestamp: 0.5, position: CGPoint(x: CGFloat.infinity, y: 0), isClicking: true, clickType: .leftDown, scrollDelta: nil),
            CursorFrame(timestamp: 1.0, position: .zero, isClicking: true, clickType: .leftDown, scrollDelta: nil)
        ]

        let times = CursorClickClassifier.debouncedClickTimes(from: frames, minimumInterval: 0.01)

        XCTAssertEqual(times, [1.0])
    }
}
