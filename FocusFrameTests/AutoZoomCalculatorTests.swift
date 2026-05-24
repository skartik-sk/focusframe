import XCTest
@testable import FocusFrame
import CoreGraphics

final class AutoZoomCalculatorTests: XCTestCase {

    var calculator: AutoZoomCalculator!

    override func setUp() {
        super.setUp()
        calculator = AutoZoomCalculator()
    }

    override func tearDown() {
        calculator = nil
        super.tearDown()
    }

    // MARK: - Test: Single Click in Center

    func testSingleClickInCenter() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 960, y: 540), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Should generate one zoom segment for single click")

        let segment = segments.first!
        let centerX = segment.zoomRect.origin.x + segment.zoomRect.width / 2
        let centerY = segment.zoomRect.origin.y + segment.zoomRect.height / 2
        XCTAssertEqual(centerX, 960, accuracy: 100, "Zoom should be centered on click")
        XCTAssertEqual(centerY, 540, accuracy: 100, "Zoom should be centered on click")
        XCTAssertLessThan(segment.zoomRect.width, 1920 * 0.8, "Single click should create a visible zoom, not a near-fullscreen rect")
        XCTAssertLessThan(segment.focusPadding, 0.18, "Auto zoom padding should not cancel the zoom during render")
        XCTAssertTrue(segment.startTime <= 1.0, "Zoom should start at or before click")
        XCTAssertTrue(segment.endTime >= 1.0, "Zoom should end at or after click")
    }

    func testDefaultAutoZoomEasesInAndHoldsAfterClick() throws {
        let clickTime = 1.0
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: clickTime, position: CGPoint(x: 960, y: 540), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segment = try XCTUnwrap(calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        ).first)

        XCTAssertEqual(segment.zoomInDuration, 0.55, accuracy: 0.001, "Default auto zoom should ease in instead of snapping quickly")
        XCTAssertEqual(segment.zoomOutDuration, 0.55, accuracy: 0.001, "Default auto zoom should ease out smoothly")
        XCTAssertLessThanOrEqual(segment.startTime, clickTime - 0.5, "Auto zoom should begin before the click so the target is clear")
        XCTAssertGreaterThanOrEqual(segment.endTime - clickTime, 1.5, "Auto zoom should hold the click target before easing out")
    }

    func testAutoZoomScaleReflectsRenderedZoomAfterPadding() throws {
        let clickTime = 1.0
        let sourceSize = CGSize(width: 1920, height: 1080)
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: clickTime, position: CGPoint(x: 960, y: 540), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: sourceSize,
            cursorType: .arrow
        )

        let config = AutoZoomCalculator.Config(maxZoomScale: 1.45)
        let segment = try XCTUnwrap(calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(origin: .zero, size: sourceSize),
            config: config
        ).first)

        let rendered = ZoomTransformer().generateTransforms(
            zoomSegments: [segment],
            sourceSize: sourceSize,
            outputSize: sourceSize,
            duration: 3.0,
            fps: 100
        )
        let clickTransform = try XCTUnwrap(rendered.first { abs($0.timestamp - clickTime) < 0.0001 })

        XCTAssertEqual(clickTransform.scale, 1.45, accuracy: 0.08, "Auto Zoom should represent visible render scale after focus padding")
    }

    // MARK: - Test: Two Clicks Far Apart

    func testTwoClicksFarApart() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 100, y: 100), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 15.0, position: CGPoint(x: 1800, y: 900), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 2, "Should generate two zoom segments for distant clicks")

        let firstSegment = segments[0]
        let secondSegment = segments[1]

        XCTAssertTrue(firstSegment.zoomRect.contains(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(secondSegment.zoomRect.contains(CGPoint(x: 1800, y: 900)))
        XCTAssertEqual(firstSegment.zoomRect.minX, 0, accuracy: 0.1)
        XCTAssertEqual(secondSegment.zoomRect.maxX, 1920, accuracy: 0.1)
        XCTAssertTrue(secondSegment.startTime - firstSegment.endTime >= 1.0, "Should have context gap between segments")
    }

    // MARK: - Test: Rapid Clicks (Debounce)

    func testRapidClicksDebounce() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 400, y: 300), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.03, position: CGPoint(x: 410, y: 305), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.06, position: CGPoint(x: 405, y: 310), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init(debounceInterval: 0.1)
        )

        XCTAssertEqual(segments.count, 1, "Should group rapid clicks into one segment")
    }

    // MARK: - Test: No Clicks

    func testNoClicks() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 0.0, position: CGPoint(x: 100, y: 100), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 300, y: 300), isClicking: false, clickType: nil, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 0, "Should not generate zoom segments without clicks")
    }

    func testClickDownTypeGeneratesZoomEvenWhenClickingFlagIsFalse() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 480, y: 270), isClicking: false, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 960, height: 540),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Explicit click-down frames should still drive auto zoom")
    }

    func testOtherMouseDownEdgeGeneratesZoom() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 0.9, position: CGPoint(x: 300, y: 180), isClicking: false, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 320, y: 190), isClicking: true, clickType: .other, scrollDelta: nil),
                CursorFrame(timestamp: 1.1, position: CGPoint(x: 320, y: 190), isClicking: false, clickType: .other, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 960, height: 540),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Other mouse down edges should drive auto zoom when the button state becomes pressed")
    }

    func testDefaultAutoZoomHoldsThroughDeliberateNearbyClicks() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 420, y: 320), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.1, position: CGPoint(x: 470, y: 350), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 3.4, position: CGPoint(x: 520, y: 380), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Default click-driven zoom should hold one continuous zoom through nearby repeated clicks")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertTrue(segment.zoomRect.contains(CGPoint(x: 420, y: 320)))
        XCTAssertTrue(segment.zoomRect.contains(CGPoint(x: 520, y: 380)))
        XCTAssertGreaterThanOrEqual(segment.endTime, 4.9, "The combined zoom should hold after the final nearby click")
    }

    func testDefaultAutoZoomGroupsDenseNearbyClicksIntoOneSmoothBlock() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 420, y: 320), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.18, position: CGPoint(x: 450, y: 335), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.36, position: CGPoint(x: 475, y: 350), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Dense nearby real clicks should render as one smooth zoom instead of pulsing in/out")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertLessThanOrEqual(segment.startTime, 0.5, "The zoom should ease in before the first dense click")
        XCTAssertGreaterThanOrEqual(segment.endTime, 2.9, "The zoom should hold after the last dense click")
    }

    func testDefaultAutoZoomMergesOverlappingDistantBlocksInsteadOfPulsing() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 260, y: 240), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.65, position: CGPoint(x: 1460, y: 740), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 4.2, position: CGPoint(x: 1580, y: 780), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Overlapping generated zoom windows should stay in one continuous zoom instead of pulsing out and back in")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertTrue(segment.zoomRect.contains(CGPoint(x: 260, y: 240)))
        XCTAssertTrue(segment.zoomRect.contains(CGPoint(x: 1580, y: 780)))
        XCTAssertGreaterThanOrEqual(segment.endTime, 5.7)
    }

    func testMergedAutoZoomTracksFarClickTargetsWhileStayingZoomed() throws {
        let firstClick = CGPoint(x: 260, y: 240)
        let secondClick = CGPoint(x: 1580, y: 780)
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: firstClick, isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.2, position: secondClick, isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 60,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        XCTAssertEqual(segments.count, 1, "Overlapping quick clicks should stay in one continuous zoom block")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.keyframes?.count, 2, "Continuous auto zooms should keep per-click focus keyframes")

        let transforms = ZoomTransformer().generateTransforms(
            zoomSegments: [segment],
            sourceSize: CGSize(width: 1920, height: 1080),
            outputSize: CGSize(width: 1920, height: 1080),
            duration: 3.5,
            fps: 10
        )
        let firstTransform = try XCTUnwrap(transforms.first { abs($0.timestamp - 1.0) < 0.0001 })
        let secondTransform = try XCTUnwrap(transforms.first { abs($0.timestamp - 2.2) < 0.0001 })

        XCTAssertTrue(firstTransform.sourceRect.contains(firstClick), "The held zoom should frame the first click")
        XCTAssertTrue(secondTransform.sourceRect.contains(secondClick), "The held zoom should pan to frame the later opposite-side click")
        XCTAssertLessThan(firstTransform.sourceRect.midX, secondTransform.sourceRect.midX, "The zoom crop should move across the screen instead of staying locked")
    }

    func testUngroupedAutoZoomCanStillCreateSeparateEditableBlocks() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 420, y: 320), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.18, position: CGPoint(x: 450, y: 335), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.36, position: CGPoint(x: 475, y: 350), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init(groupNearbyClicks: false)
        )

        XCTAssertEqual(segments.count, 3, "Ungrouped click-driven zooms should remain available when separate editable blocks are needed")
    }

    func testHeldClickStateWithoutClickTypeOnlyCreatesOneAnchor() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: true, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.25, position: CGPoint(x: 340, y: 260), isClicking: true, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.5, position: CGPoint(x: 520, y: 300), isClicking: true, clickType: nil, scrollDelta: nil),
                CursorFrame(timestamp: 1.7, position: CGPoint(x: 520, y: 300), isClicking: false, clickType: nil, scrollDelta: nil)
            ],
            sampleRate: 60,
            screenSize: CGSize(width: 960, height: 540),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            config: .init(minClusterDistance: 80, minClusterTimeGap: 0.2, debounceInterval: 0.05)
        )

        XCTAssertEqual(segments.count, 1, "A held click state should not generate repeated automatic zooms")
    }

    func testDebounceDoesNotDuplicatePreviousClickWhenNextClickIsAccepted() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 200, y: 200), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 1.05, position: CGPoint(x: 204, y: 204), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 800, y: 400), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 960, height: 540),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            config: .init(minClusterDistance: 100, minClusterTimeGap: 3.0, groupNearbyClicks: false, debounceInterval: 0.35)
        )

        XCTAssertEqual(segments.count, 2, "Debounced rapid clicks should not add a duplicate anchor before the next accepted click")
    }

    // MARK: - Test: Zoom Rect Respects Aspect Ratio

    func testZoomRectRespectsAspectRatio() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 960, y: 540), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let config = AutoZoomCalculator.Config(outputAspectRatio: 16.0/9.0)
        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: config
        )

        let segment = segments.first!
        let aspectRatio = segment.zoomRect.width / segment.zoomRect.height
        XCTAssertEqual(aspectRatio, 16.0/9.0, accuracy: 0.1, "Zoom rect should respect aspect ratio")
    }

    // MARK: - Test: Zoom Rect Clamped to Screen Bounds

    func testZoomRectClampedToBounds() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 1.0, position: CGPoint(x: 50, y: 50), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: .init()
        )

        let segment = segments.first!
        XCTAssertGreaterThanOrEqual(segment.zoomRect.minX, 0, "Zoom rect should not go off left edge")
        XCTAssertGreaterThanOrEqual(segment.zoomRect.minY, 0, "Zoom rect should not go off top edge")
        XCTAssertLessThanOrEqual(segment.zoomRect.maxX, 1920, "Zoom rect should not go off right edge")
        XCTAssertLessThanOrEqual(segment.zoomRect.maxY, 1080, "Zoom rect should not go off bottom edge")
    }

    // MARK: - Test: Context Gaps

    func testContextGaps() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 400, y: 300), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 10.0, position: CGPoint(x: 1500, y: 700), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let config = AutoZoomCalculator.Config(contextGapThreshold: 1.5)
        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: config
        )

        XCTAssertGreaterThanOrEqual(segments.count, 2, "Should have at least two zoom segments")

        let fullViewSegments = segments.filter { $0.zoomRect == CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        XCTAssertGreaterThan(fullViewSegments.count, 0, "Should insert context gap showing full view")
    }

    // MARK: - Test: Cluster Distance

    func testClusterDistance() throws {
        let cursorRecording = CursorRecording(
            frames: [
                CursorFrame(timestamp: 2.0, position: CGPoint(x: 400, y: 300), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 2.5, position: CGPoint(x: 450, y: 320), isClicking: true, clickType: .leftDown, scrollDelta: nil),
                CursorFrame(timestamp: 6.0, position: CGPoint(x: 1500, y: 700), isClicking: true, clickType: .leftDown, scrollDelta: nil)
            ],
            sampleRate: 120,
            screenSize: CGSize(width: 1920, height: 1080),
            cursorType: .arrow
        )

        let config = AutoZoomCalculator.Config(
            minClusterDistance: 200,
            minClusterTimeGap: 3.0,
            groupNearbyClicks: true
        )
        let segments = calculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            config: config
        )

        XCTAssertEqual(segments.count, 2, "Should cluster first two clicks, keep third separate")
    }

    // MARK: - Test: Easing Functions

    func testEasingFunctions() throws {
        let easeInOut = EasingType.easeInOut
        let easeIn = EasingType.easeIn
        let easeOut = EasingType.easeOut
        let linear = EasingType.linear

        XCTAssertEqual(easeInOut.apply(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(easeInOut.apply(1.0), 1.0, accuracy: 0.01)
        XCTAssertTrue(easeInOut.apply(0.5) > 0.4 && easeInOut.apply(0.5) < 0.6, "Ease-in-out should be near 0.5 at t=0.5")

        XCTAssertEqual(easeIn.apply(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(easeIn.apply(1.0), 1.0, accuracy: 0.01)
        XCTAssertLessThan(easeIn.apply(0.3), 0.3, "Ease-in should be slower at start")

        XCTAssertEqual(easeOut.apply(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(easeOut.apply(1.0), 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(easeOut.apply(0.7), 0.7, "Ease-out should be faster at end")

        XCTAssertEqual(linear.apply(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(linear.apply(0.5), 0.5, accuracy: 0.01)
        XCTAssertEqual(linear.apply(1.0), 1.0, accuracy: 0.01)
    }
}
