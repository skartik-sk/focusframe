import XCTest
@testable import FocusFrame

final class PreviewValueSanitizationTests: XCTestCase {
    func testTimelineAudioPreviewValuesRejectNonFiniteInputs() {
        XCTAssertEqual(TimelineAudioPreviewPlayer.sanitizedProjectTime(.nan), 0)
        XCTAssertEqual(TimelineAudioPreviewPlayer.sanitizedProjectTime(.infinity), 0)
        XCTAssertEqual(TimelineAudioPreviewPlayer.sanitizedProjectTime(-4), 0)
        XCTAssertEqual(TimelineAudioPreviewPlayer.sanitizedProjectTime(4), 4)

        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedVolume(.nan), 0)
        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedVolume(-1), 0)
        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedVolume(2), 1)

        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedRate(.nan), 1)
        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedRate(0.1), 0.25)
        XCTAssertEqual(TimelineAudioPreviewPlayer.clampedRate(9), 4)
    }

    func testBackgroundMusicPreviewValuesRejectNonFiniteInputs() {
        XCTAssertEqual(BackgroundMusicPreviewPlayer.sanitizedProjectTime(.nan), 0)
        XCTAssertEqual(BackgroundMusicPreviewPlayer.sanitizedProjectTime(.infinity), 0)
        XCTAssertEqual(BackgroundMusicPreviewPlayer.sanitizedProjectTime(-3), 0)
        XCTAssertEqual(BackgroundMusicPreviewPlayer.sanitizedProjectTime(3), 3)

        XCTAssertEqual(BackgroundMusicPreviewPlayer.clampedVolume(.nan), 0)
        XCTAssertEqual(BackgroundMusicPreviewPlayer.clampedVolume(-1), 0)
        XCTAssertEqual(BackgroundMusicPreviewPlayer.clampedVolume(2), 1)
    }

    func testMicrophoneMeterRejectsNonFiniteLevels() {
        XCTAssertEqual(MicrophoneLevelMeter.clampedLevel(.nan), 0)
        XCTAssertEqual(MicrophoneLevelMeter.clampedLevel(.infinity), 0)
        XCTAssertEqual(MicrophoneLevelMeter.clampedLevel(-1), 0)
        XCTAssertEqual(MicrophoneLevelMeter.clampedLevel(2), 1)
    }

    func testExportAudioVolumeRejectsNonFiniteValues() {
        XCTAssertEqual(ExportVM.clampedAudioVolume(.nan), 0)
        XCTAssertEqual(ExportVM.clampedAudioVolume(.infinity), 0)
        XCTAssertEqual(ExportVM.clampedAudioVolume(-1), 0)
        XCTAssertEqual(ExportVM.clampedAudioVolume(2), 1)
        XCTAssertEqual(ExportVM.clampedAudioVolume(0.35), 0.35, accuracy: 0.001)
    }

    func testAudioProcessorRejectsNonFiniteMixAndCleanupValues() {
        XCTAssertEqual(AudioProcessor.clampedVolume(.nan), 0)
        XCTAssertEqual(AudioProcessor.clampedVolume(.infinity), 0)
        XCTAssertEqual(AudioProcessor.clampedVolume(-0.2), 0)
        XCTAssertEqual(AudioProcessor.clampedVolume(1.2), 1)

        XCTAssertEqual(AudioProcessor.sanitizedMakeupGain(.nan), 1)
        XCTAssertEqual(AudioProcessor.sanitizedMakeupGain(9), 4)
        XCTAssertEqual(AudioProcessor.sanitizedNoiseGateThreshold(.nan), -45)
        XCTAssertEqual(AudioProcessor.sanitizedNoiseGateThreshold(-100), -90)
        XCTAssertEqual(AudioProcessor.sanitizedCompressionRatio(.infinity), 3)
        XCTAssertEqual(AudioProcessor.sanitizedCompressionRatio(0.5), 1)
    }

    func testTranscriptionTimeFormattingRejectsNonFiniteValues() {
        XCTAssertEqual(TranscriptionEngine.safeMilliseconds(.nan), 0)
        XCTAssertEqual(TranscriptionEngine.safeMilliseconds(.infinity), 0)
        XCTAssertEqual(TranscriptionEngine.safeMilliseconds(-1), 0)
        XCTAssertEqual(TranscriptionEngine.safeMilliseconds(1.234), 1234)
    }

    func testExportProfileSanitizerRejectsUnsafeCustomValues() {
        let unsafe = ExportProfile(
            id: UUID(),
            name: "Unsafe",
            width: -20,
            height: Int.max,
            fps: 0,
            codec: .h264,
            quality: .nan,
            averageBitrateMbps: .infinity,
            orientation: .landscape,
            format: .mp4
        )

        let sanitized = ExportVM.sanitizedProfile(unsafe)

        XCTAssertEqual(sanitized.width, 16)
        XCTAssertEqual(sanitized.height, 8192)
        XCTAssertEqual(sanitized.fps, 1)
        XCTAssertEqual(sanitized.quality, 0.8)
        XCTAssertNil(sanitized.averageBitrateMbps)
    }
}
