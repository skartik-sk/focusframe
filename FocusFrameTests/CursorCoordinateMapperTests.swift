import XCTest
@testable import FocusFrame
import CoreGraphics

final class CursorCoordinateMapperTests: XCTestCase {
    func testMapsRecordedTopLeftCoordinatesIntoRenderSpace() throws {
        let recording = CursorRecording(
            frames: [
                CursorFrame(
                    timestamp: 0,
                    position: CGPoint(x: 100, y: 20),
                    isClicking: true,
                    clickType: .leftDown,
                    scrollDelta: nil
                )
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 200, height: 100),
            cursorType: .arrow
        )

        let mapped = CursorCoordinateMapper.toRenderSpace(
            recording,
            sourceSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(mapped.frames[0].position.x, 200, accuracy: 0.001)
        XCTAssertEqual(mapped.frames[0].position.y, 240, accuracy: 0.001)
        XCTAssertEqual(mapped.screenSize.width, 400, accuracy: 0.001)
        XCTAssertEqual(mapped.screenSize.height, 300, accuracy: 0.001)
    }

    func testRetinaPointSpaceRecordingScalesToVideoPixelsBeforeFlippingY() throws {
        let recording = CursorRecording(
            frames: [
                CursorFrame(
                    timestamp: 0,
                    position: CGPoint(x: 651.7, y: 871.7),
                    isClicking: true,
                    clickType: .leftDown,
                    scrollDelta: nil
                )
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1680, height: 1050),
            cursorType: .arrow
        )

        let mapped = CursorCoordinateMapper.toRenderSpace(
            recording,
            sourceSize: CGSize(width: 2560, height: 1600),
            displayPointSizeForPointCapture: CGSize(width: 1680, height: 1050)
        )

        XCTAssertEqual(mapped.frames[0].position.x, 993.06, accuracy: 0.1)
        XCTAssertEqual(mapped.frames[0].position.y, 271.70, accuracy: 0.1)
    }

    func testPointSpaceRecordingWithPixelScreenSizeIsRepaired() throws {
        let recording = CursorRecording(
            frames: [
                CursorFrame(
                    timestamp: 0,
                    position: CGPoint(x: 651.7, y: 871.7),
                    isClicking: true,
                    clickType: .leftDown,
                    scrollDelta: nil
                )
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 2560, height: 1600),
            cursorType: .arrow
        )

        let mapped = CursorCoordinateMapper.toRenderSpace(
            recording,
            sourceSize: CGSize(width: 2560, height: 1600),
            displayPointSizeForPointCapture: CGSize(width: 1680, height: 1050)
        )

        XCTAssertEqual(mapped.frames[0].position.x, 993.06, accuracy: 0.1)
        XCTAssertEqual(mapped.frames[0].position.y, 271.70, accuracy: 0.1)
    }

    func testMalformedSizesAndPositionsDoNotLeakIntoRenderSpace() throws {
        let recording = CursorRecording(
            frames: [
                CursorFrame(
                    timestamp: .nan,
                    position: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                    isClicking: true,
                    clickType: .leftDown,
                    scrollDelta: CGFloat.infinity
                )
            ],
            sampleRate: .infinity,
            screenSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            cursorType: .arrow
        )

        let mapped = CursorCoordinateMapper.toRenderSpace(
            recording,
            sourceSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            displayPointSizeForPointCapture: CGSize(width: CGFloat.nan, height: CGFloat.infinity)
        )

        XCTAssertTrue(mapped.frames[0].position.x.isFinite)
        XCTAssertTrue(mapped.frames[0].position.y.isFinite)
        XCTAssertEqual(mapped.frames[0].timestamp, 0)
        XCTAssertNil(mapped.frames[0].scrollDelta)
        XCTAssertEqual(mapped.sampleRate, 60)
        XCTAssertEqual(mapped.frames[0].position.x, 0, accuracy: 0.001)
        XCTAssertEqual(mapped.frames[0].position.y, 1, accuracy: 0.001)
        XCTAssertEqual(mapped.screenSize.width, 1, accuracy: 0.001)
        XCTAssertEqual(mapped.screenSize.height, 1, accuracy: 0.001)
    }
}
