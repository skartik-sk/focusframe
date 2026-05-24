import AVFoundation
import XCTest
@testable import FocusFrame

final class CaptureTimingTests: XCTestCase {
    func testAdjustedPresentationTimeSubtractsFirstSampleAndPause() {
        let adjusted = CaptureTiming.adjustedPresentationTime(
            timestamp: CMTime(seconds: 12, preferredTimescale: 600),
            firstSampleTime: CMTime(seconds: 2, preferredTimescale: 600),
            accumulatedPauseDuration: CMTime(seconds: 3, preferredTimescale: 600)
        )

        XCTAssertEqual(adjusted.seconds, 7, accuracy: 0.001)
    }

    func testAdjustedPresentationTimeClampsInvalidOrNegativeTimeline() {
        let negative = CaptureTiming.adjustedPresentationTime(
            timestamp: CMTime(seconds: 4, preferredTimescale: 600),
            firstSampleTime: CMTime(seconds: 5, preferredTimescale: 600),
            accumulatedPauseDuration: .zero
        )
        let invalid = CaptureTiming.adjustedPresentationTime(
            timestamp: .invalid,
            firstSampleTime: .zero,
            accumulatedPauseDuration: .zero
        )

        XCTAssertEqual(negative, .zero)
        XCTAssertEqual(invalid, .zero)
    }
}
