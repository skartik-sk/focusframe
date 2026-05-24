import XCTest
@testable import FocusFrame

final class WaveformTimelineMapperTests: XCTestCase {
    func testCutRangesAreMutedInDisplayWaveform() {
        let samples = WaveformTimelineMapper.map(
            rawSamples: [1, 1, 1, 1],
            options: WaveformTimelineMapper.Options(
                displayDuration: 4,
                audioDuration: 4,
                displaySampleCount: 5,
                editActions: [.cut(startTime: 1, endTime: 2.5)]
            )
        )

        XCTAssertEqual(samples.count, 5)
        XCTAssertGreaterThan(samples[0], 0.9)
        XCTAssertEqual(samples[1], 0)
        XCTAssertEqual(samples[2], 0)
        XCTAssertGreaterThan(samples[3], 0.9)
        XCTAssertGreaterThan(samples[4], 0.9)
    }

    func testLoopingMusicRepeatsAcrossProjectDuration() {
        let samples = WaveformTimelineMapper.map(
            rawSamples: [0, 1, 0],
            options: WaveformTimelineMapper.Options(
                displayDuration: 2,
                audioDuration: 1,
                displaySampleCount: 5,
                loops: true,
                muteCutRanges: false
            )
        )

        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0, accuracy: 0.001)
        XCTAssertEqual(samples[1], 1, accuracy: 0.001)
        XCTAssertEqual(samples[2], 0, accuracy: 0.001)
        XCTAssertEqual(samples[3], 1, accuracy: 0.001)
        XCTAssertEqual(samples[4], 0, accuracy: 0.001)
    }

    func testNonLoopingAudioIsSilentAfterMediaEnds() {
        let samples = WaveformTimelineMapper.map(
            rawSamples: [1, 1],
            options: WaveformTimelineMapper.Options(
                displayDuration: 3,
                audioDuration: 1,
                displaySampleCount: 4,
                loops: false
            )
        )

        XCTAssertEqual(samples.count, 4)
        XCTAssertGreaterThan(samples[0], 0.9)
        XCTAssertGreaterThan(samples[1], 0.9)
        XCTAssertEqual(samples[2], 0)
        XCTAssertEqual(samples[3], 0)
    }
}
