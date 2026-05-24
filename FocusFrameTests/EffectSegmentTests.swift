import XCTest
import AVFoundation
@testable import FocusFrame

final class EffectSegmentTests: XCTestCase {
    func testQuietSegmentMutesOnlyInsideSelectedRange() {
        var project = makeProject()
        project.style.backgroundMusicVolume = 0.4
        project.style.clickSoundEnabled = true
        project.style.keyboardSoundEnabled = true
        var quiet = EffectSegment(startTime: 2, endTime: 5, name: "Quiet")
        quiet.music = .off
        quiet.clickSound = .off
        quiet.keyboardSound = .off
        project.effectSegments = [quiet]

        let before = EffectSegmentResolver.resolve(project: project, at: 1.5)
        XCTAssertEqual(before.style.backgroundMusicVolume, 0.4, accuracy: 0.001)
        XCTAssertTrue(before.style.clickSoundEnabled)
        XCTAssertTrue(before.style.keyboardSoundEnabled)

        let inside = EffectSegmentResolver.resolve(project: project, at: 3)
        XCTAssertEqual(inside.style.backgroundMusicVolume, 0, accuracy: 0.001)
        XCTAssertFalse(inside.style.clickSoundEnabled)
        XCTAssertFalse(inside.style.keyboardSoundEnabled)

        let after = EffectSegmentResolver.resolve(project: project, at: 6)
        XCTAssertEqual(after.style.backgroundMusicVolume, 0.4, accuracy: 0.001)
        XCTAssertTrue(after.style.clickSoundEnabled)
        XCTAssertTrue(after.style.keyboardSoundEnabled)
    }

    func testLaterOverlappingSegmentWinsForSpecificOverrides() {
        var project = makeProject()
        var quiet = EffectSegment(startTime: 2, endTime: 8, name: "Quiet", createdAt: Date(timeIntervalSince1970: 1))
        quiet.keyboardSound = .off
        quiet.keyboardBadges = .off

        var keysBack = EffectSegment(startTime: 4, endTime: 6, name: "Keys", createdAt: Date(timeIntervalSince1970: 2))
        keysBack.keyboardSound = .on

        project.effectSegments = [quiet, keysBack]

        let insideOverlap = EffectSegmentResolver.resolve(project: project, at: 5)
        XCTAssertTrue(insideOverlap.style.keyboardSoundEnabled)
        XCTAssertFalse(insideOverlap.showKeyboardShortcuts)
    }

    @MainActor
    func testEditorAddsSelectedEffectSegmentFromRange() throws {
        let editorVM = EditorVM(project: makeProject())
        editorVM.selectedRangeStart = 3
        editorVM.selectedRangeEnd = 7

        let segment = try XCTUnwrap(editorVM.addEffectSegment(startTime: 3, endTime: 7, preset: .quiet))

        XCTAssertEqual(editorVM.effectSegments.count, 1)
        XCTAssertEqual(segment.startTime, 3, accuracy: 0.001)
        XCTAssertEqual(segment.endTime, 7, accuracy: 0.001)
        XCTAssertEqual(segment.music, .off)
        XCTAssertEqual(editorVM.selectedTimelineItem, .effectSegment(segment.id))
    }

    private func makeProject() -> RecordingProject {
        RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Test",
            videoFileURL: URL(fileURLWithPath: "/tmp/test.mov"),
            cursorDataFileURL: URL(fileURLWithPath: "/tmp/cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: nil,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            sourceRect: CGRect(x: 0, y: 0, width: 1280, height: 720),
            displayID: 1,
            zoomSegments: [],
            editActions: [],
            style: .default,
            hideDesktopIcons: false,
            showKeyboardShortcuts: true,
            webcamEnabled: false,
            subtitlesEnabled: false
        )
    }
}
