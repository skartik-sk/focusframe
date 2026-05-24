import XCTest
@testable import FocusFrame

final class TimelineEventSamplerTests: XCTestCase {
    func testDenseKeyEventsAreSampledForLongTimelineRendering() {
        let events = (0..<2_000).map { index in
            KeyPressEvent(
                id: UUID(),
                timestamp: Double(index) * 0.05,
                keyCode: UInt16(index % 40),
                modifiers: [],
                characters: "A",
                displayString: "A"
            )
        }

        let sampled = TimelineEventSampler.sampleKeyEvents(
            events,
            duration: 100,
            width: 560,
            minimumPixelSpacing: 28
        )

        XCTAssertLessThanOrEqual(sampled.count, 20)
        XCTAssertEqual(sampled.map(\.timestamp), sampled.map(\.timestamp).sorted())
    }

    func testSparseKeyEventsAreNotDropped() {
        let events = (0..<4).map { index in
            KeyPressEvent(
                id: UUID(),
                timestamp: Double(index),
                keyCode: UInt16(index),
                modifiers: [],
                characters: "A",
                displayString: "A"
            )
        }

        let sampled = TimelineEventSampler.sampleKeyEvents(
            events,
            duration: 4,
            width: 560,
            minimumPixelSpacing: 28
        )

        XCTAssertEqual(sampled.map(\.id), events.map(\.id))
    }
}
