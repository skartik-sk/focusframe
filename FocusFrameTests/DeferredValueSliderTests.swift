import XCTest
@testable import FocusFrame

final class DeferredValueSliderTests: XCTestCase {
    func testDeferredSliderClampRejectsNonFiniteDraftValues() {
        XCTAssertEqual(DeferredDoubleSliderRow.clamped(.nan, in: 0...1), 0)
        XCTAssertEqual(DeferredDoubleSliderRow.clamped(.infinity, in: -2...2), -2)
        XCTAssertEqual(DeferredDoubleSliderRow.clamped(-10, in: 0...1), 0)
        XCTAssertEqual(DeferredDoubleSliderRow.clamped(10, in: 0...1), 1)
        XCTAssertEqual(DeferredDoubleSliderRow.clamped(0.4, in: 0...1), 0.4)
    }
}
