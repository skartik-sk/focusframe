import XCTest
@testable import FocusFrame

final class TimelinePreferencesTests: XCTestCase {
    func testTimelinePreferenceKeysUseFocusFrameNamespace() {
        XCTAssertEqual(TimelinePreferences.zoomScaleKey, "FocusFrame.Timeline.ZoomScale")
        XCTAssertEqual(TimelinePreferences.expandedHeightKey, "FocusFrame.Timeline.Height")
    }

    func testTimelinePreferenceSanitizersRejectNonFiniteAndOutOfRangeValues() {
        XCTAssertEqual(TimelinePreferences.sanitizedZoomScale(.nan), 1.0)
        XCTAssertEqual(TimelinePreferences.sanitizedZoomScale(.infinity), 1.0)
        XCTAssertEqual(TimelinePreferences.sanitizedZoomScale(0.1), 1.0)
        XCTAssertEqual(TimelinePreferences.sanitizedZoomScale(20.0), 8.0)

        XCTAssertEqual(TimelinePreferences.sanitizedExpandedHeight(.nan), 320.0)
        XCTAssertEqual(TimelinePreferences.sanitizedExpandedHeight(.infinity), 320.0)
        XCTAssertEqual(TimelinePreferences.sanitizedExpandedHeight(10.0), 220.0)
        XCTAssertEqual(TimelinePreferences.sanitizedExpandedHeight(900.0), 520.0)
    }
}
