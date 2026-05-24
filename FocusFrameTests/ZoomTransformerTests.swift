import XCTest
@testable import FocusFrame
import CoreGraphics

final class ZoomTransformerTests: XCTestCase {

    var transformer: ZoomTransformer!

    override func setUp() {
        super.setUp()
        transformer = ZoomTransformer()
    }

    override func tearDown() {
        transformer = nil
        super.tearDown()
    }

    // MARK: - Test: Transform at Zoom Segment Center

    func testTransformAtZoomSegmentCenter() throws {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        // Find transform at segment center (t=2.0)
        let centerTransform = transforms.first { $0.timestamp == 2.0 }

        XCTAssertNotNil(centerTransform, "Should have transform at segment center")

        // Calculate expected scale
        let scaleX: CGFloat = 1920 / 400
        let scaleY: CGFloat = 1080 / 300
        let expectedScale = min(scaleX, scaleY)

        let actualScale = centerTransform!.transform.a // Scale X component
        XCTAssertEqual(actualScale, expectedScale, accuracy: 0.1, "Transform should scale to show zoom rect")
    }

    // MARK: - Test: Transition Between Zoom Segments is Smooth

    func testTransitionBetweenZoomSegmentsIsSmooth() throws {
        let segment1 = ZoomSegment(
            id: UUID(),
            startTime: 0.0,
            endTime: 2.0,
            zoomRect: CGRect(x: 100, y: 100, width: 200, height: 200),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let segment2 = ZoomSegment(
            id: UUID(),
            startTime: 2.5,
            endTime: 4.5,
            zoomRect: CGRect(x: 1500, y: 800, width: 200, height: 200),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment1, segment2],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        // Check transition between segments (around t=2.0 to t=2.5)
        let transitionTransforms = transforms.filter { $0.timestamp >= 2.0 && $0.timestamp <= 2.5 }

        XCTAssertGreaterThan(transitionTransforms.count, 0, "Should have transforms during transition")

        // Check for smoothness (no large jumps)
        for i in 1..<transitionTransforms.count {
            let prev = transitionTransforms[i-1].transform
            let curr = transitionTransforms[i].transform

            let scaleChange = abs(curr.a - prev.a)
            let translateChange = sqrt(pow(curr.tx - prev.tx, 2) + pow(curr.ty - prev.ty, 2))

            XCTAssertLessThan(scaleChange, 0.5, "Scale should not jump dramatically")
            XCTAssertLessThan(translateChange, 50.0, "Translation should not jump dramatically")
        }
    }

    // MARK: - Test: No Zoom = Identity Transform

    func testNoZoomReturnsIdentityTransform() throws {
        let transforms = transformer.generateTransforms(
            zoomSegments: [],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        for transform in transforms {
            XCTAssertEqual(transform.transform.a, 1.0, accuracy: 0.01, "Scale should be 1.0")
            XCTAssertEqual(transform.transform.d, 1.0, accuracy: 0.01, "Scale should be 1.0")
            XCTAssertEqual(transform.transform.tx, 0.0, accuracy: 0.01, "Translation should be 0")
            XCTAssertEqual(transform.transform.ty, 0.0, accuracy: 0.01, "Translation should be 0")
        }
    }

    // MARK: - Test: Vertical Export Transforms Correctly

    func testVerticalExportTransformsCorrectly() throws {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1080, height: 1920), // Portrait
            duration: 5.0,
            fps: 60
        )

        let centerTransform = transforms.first { $0.timestamp == 2.0 }
        XCTAssertNotNil(centerTransform, "Should have transform for vertical output")

        // Calculate expected scale for portrait output
        let scaleX: CGFloat = 1080 / 400
        let scaleY: CGFloat = 1920 / 300
        let expectedScale = min(scaleX, scaleY)

        let actualScale = centerTransform!.transform.a
        XCTAssertEqual(actualScale, expectedScale, accuracy: 0.1, "Transform should scale for portrait output")
    }

    func testOverwideZoomStillProducesVisibleZoom() throws {
        let overwideSegment = ZoomSegment(
            id: UUID(),
            startTime: 0.0,
            endTime: 2.0,
            zoomRect: CGRect(x: 30, y: 0, width: 1650, height: 928),
            focusPadding: 0.22,
            zoomInDuration: 0.0,
            zoomOutDuration: 0.0,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [overwideSegment],
            sourceSize: CGSize(width: 1680, height: 1050),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 1.0,
            fps: 30
        )

        XCTAssertGreaterThan(transforms[0].scale, 1.2, "Overwide auto-zoom rects should not collapse back to full-screen")
        XCTAssertLessThan(transforms[0].sourceRect.width, 1680 * 0.9, "Overwide rect should be normalized to a real zoom crop")
    }

    // MARK: - Test: Zoom In Duration

    func testZoomInDuration() throws {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.0,
            zoomInDuration: 0.6,
            zoomOutDuration: 0.4,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        // Check zoom-in period (1.0 to 1.6)
        let zoomInTransforms = transforms.filter { $0.timestamp >= 1.0 && $0.timestamp <= 1.6 }

        XCTAssertGreaterThan(zoomInTransforms.count, 0, "Should have transforms during zoom-in")

        // Scale should increase during zoom-in
        let firstScale = zoomInTransforms.first!.transform.a
        let lastScale = zoomInTransforms.last!.transform.a
        XCTAssertGreaterThan(lastScale, firstScale, "Scale should increase during zoom-in")
    }

    // MARK: - Test: Zoom Out Duration

    func testZoomOutDuration() throws {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.0,
            zoomInDuration: 0.6,
            zoomOutDuration: 0.4,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        // Check zoom-out period (2.6 to 3.0)
        let zoomOutTransforms = transforms.filter { $0.timestamp >= 2.6 && $0.timestamp <= 3.0 }

        XCTAssertGreaterThan(zoomOutTransforms.count, 0, "Should have transforms during zoom-out")

        // Scale should decrease during zoom-out
        let firstScale = zoomOutTransforms.first!.transform.a
        let lastScale = zoomOutTransforms.last!.transform.a
        XCTAssertLessThan(lastScale, firstScale, "Scale should decrease during zoom-out")
    }

    func testShortZoomSegmentStillEasesInAndOut() throws {
        let segment = ZoomSegment(
            id: UUID(),
            startTime: 0.0,
            endTime: 0.2,
            zoomRect: CGRect(x: 250, y: 250, width: 500, height: 500),
            focusPadding: 0.0,
            zoomInDuration: 0.6,
            zoomOutDuration: 0.6,
            easingFunction: .easeInOut,
            source: .manual
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1000, height: 1000),
            outputSize: CGSize(width: 1000, height: 1000),
            duration: 0.3,
            fps: 100
        )

        let start = try XCTUnwrap(transforms.first { $0.timestamp == 0.0 })
        let middle = try XCTUnwrap(transforms.first { $0.timestamp == 0.1 })
        let nearEnd = try XCTUnwrap(transforms.first { abs($0.timestamp - 0.19) < 0.0001 })

        XCTAssertGreaterThan(middle.scale, start.scale, "Short zooms should still zoom in")
        XCTAssertLessThan(nearEnd.scale, middle.scale, "Short zooms should still zoom out instead of staying in zoom-in mode")
    }

    // MARK: - Test: Focus Padding

    func testFocusPadding() throws {
        let noPaddingSegment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let paddedSegment = ZoomSegment(
            id: UUID(),
            startTime: 1.0,
            endTime: 3.0,
            zoomRect: CGRect(x: 400, y: 300, width: 400, height: 300),
            focusPadding: 0.2,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let noPaddingTransforms = transformer.generateTransforms(
            zoomSegments: [noPaddingSegment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 3.0,
            fps: 60
        )

        let paddedTransforms = transformer.generateTransforms(
            zoomSegments: [paddedSegment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 3.0,
            fps: 60
        )

        // Padded segment should show more of the scene (lower scale)
        let centerNoPadding = noPaddingTransforms.first { $0.timestamp == 2.0 }!.transform.a
        let centerPadded = paddedTransforms.first { $0.timestamp == 2.0 }!.transform.a

        XCTAssertLessThan(centerPadded, centerNoPadding, "Padded zoom should show more context (lower scale)")
    }

    // MARK: - Test: Multiple Overlapping Segments

    func testMultipleOverlappingSegments() throws {
        let segment1 = ZoomSegment(
            id: UUID(),
            startTime: 0.0,
            endTime: 2.0,
            zoomRect: CGRect(x: 100, y: 100, width: 200, height: 200),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let segment2 = ZoomSegment(
            id: UUID(),
            startTime: 1.5,
            endTime: 3.5,
            zoomRect: CGRect(x: 1500, y: 800, width: 200, height: 200),
            focusPadding: 0.0,
            zoomInDuration: 0.5,
            zoomOutDuration: 0.5,
            easingFunction: .easeInOut,
            source: .automatic
        )

        let transforms = transformer.generateTransforms(
            zoomSegments: [segment1, segment2],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 5.0,
            fps: 60
        )

        // Should generate transforms for entire duration
        XCTAssertEqual(transforms.count, Int(5.0 * 60), "Should generate transforms for entire duration")
    }

    func testLargeAutomaticZoomTimelineDoesNotExplodeFrameGeneration() throws {
        var segments: [ZoomSegment] = []
        for index in 0..<1_000 {
            let x = CGFloat(index % 20) * 40
            let y = CGFloat(index % 12) * 35
            segments.append(ZoomSegment(
                id: UUID(),
                startTime: Double(index) * 0.45,
                endTime: Double(index) * 0.45 + 0.8,
                zoomRect: CGRect(x: x, y: y, width: 480, height: 270),
                focusPadding: 0.12,
                zoomInDuration: 0.2,
                zoomOutDuration: 0.2,
                easingFunction: .easeInOut,
                source: .automatic
            ))
        }

        let transforms = transformer.generateTransforms(
            zoomSegments: Array(segments.reversed()),
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1280, height: 720),
            duration: 120,
            fps: 12
        )

        XCTAssertEqual(transforms.count, 1_440)
        XCTAssertTrue(transforms.allSatisfy { $0.scale.isFinite })
    }

    func testInvalidDurationAndFPSDoNotCrashFrameGeneration() throws {
        let transforms = transformer.generateTransforms(
            zoomSegments: [],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1280, height: 720),
            duration: .nan,
            fps: .infinity
        )

        XCTAssertTrue(transforms.isEmpty)
    }

    // MARK: - Test: Performance

    func testPerformance() throws {
        var segments: [ZoomSegment] = []
        for i in 0..<10 {
            segments.append(ZoomSegment(
                id: UUID(),
                startTime: Double(i) * 5.0,
                endTime: Double(i + 1) * 5.0,
                zoomRect: CGRect(x: CGFloat(i * 100), y: CGFloat(i * 100), width: 400, height: 300),
                focusPadding: 0.2,
                zoomInDuration: 0.6,
                zoomOutDuration: 0.4,
                easingFunction: .easeInOut,
                source: .automatic
            ))
        }

        measure {
            _ = transformer.generateTransforms(
                zoomSegments: segments,
                sourceSize: CGSize(width: 1920, height: 1080),
                outputSize: CGSize(width: 1920, height: 1080),
                duration: 60.0,
                fps: 60
            )
        }
    }
}
