import XCTest
@testable import FocusFrame

final class TimecodeFormatterTests: XCTestCase {
    func testPositionalFormatterNormalizesUnsafeDoubleValues() {
        XCTAssertEqual(TimecodeFormatter.positional(.nan), "0:00")
        XCTAssertEqual(TimecodeFormatter.positional(.infinity), "0:00")
        XCTAssertEqual(TimecodeFormatter.positional(-12), "0:00")
        XCTAssertEqual(TimecodeFormatter.positional(125.9), "2:05")
    }
}
