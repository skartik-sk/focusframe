import AVFoundation
import XCTest
@testable import FocusFrame

final class CaptureEngineTests: XCTestCase {
    func testCaptureSettingsSanitizeInvalidDimensionsAndFrameRate() {
        let settings = CaptureEngine.screenVideoSettings(width: -40, height: Int.max, fps: 0)

        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 2)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 8192)

        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoExpectedSourceFrameRateKey] as? Int, 60)
        XCTAssertEqual(compression?[AVVideoMaxKeyFrameIntervalKey] as? Int, 60)
        XCTAssertEqual(compression?[AVVideoAverageBitRateKey] as? Int, 25_000_000)
    }

    func testCaptureBitrateAvoidsIntegerOverflowForHugeInputs() {
        let bitrate = CaptureEngine.screenVideoBitrate(width: Int.max, height: Int.max, fps: Int.max)

        XCTAssertEqual(bitrate, 140_000_000)
    }

    func testCaptureSourceRectRejectsNonFiniteAndClampsToDisplay() {
        XCTAssertNil(CaptureEngine.sanitizedSourceRect(
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            displayWidth: 1920,
            displayHeight: 1080
        ))

        let rect = CaptureEngine.sanitizedSourceRect(
            CGRect(x: -10.5, y: 20.7, width: 3000, height: 2000),
            displayWidth: 1920,
            displayHeight: 1080
        )

        XCTAssertEqual(rect?.origin.x, 0)
        XCTAssertEqual(rect?.origin.y, 20)
        XCTAssertEqual(rect?.width, 1920)
        XCTAssertEqual(rect?.height, 1059)
    }
}
