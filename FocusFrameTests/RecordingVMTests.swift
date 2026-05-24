import XCTest
@testable import FocusFrame

@MainActor
final class RecordingVMTests: XCTestCase {
    func testPauseToggleIsIgnoredWhenNotRecording() {
        let recordingVM = RecordingVM()

        recordingVM.togglePause()

        XCTAssertFalse(recordingVM.isPaused)
        XCTAssertEqual(recordingVM.recordingDuration, 0)
    }

    func testStartRecordingRejectsOverlappingSessionBeforePermissionWork() async {
        let recordingVM = RecordingVM()
        recordingVM.isRecording = true

        do {
            try await recordingVM.startRecording()
            XCTFail("Expected startRecording to reject overlapping recording sessions")
        } catch RecordingVMError.alreadyRecording {
            XCTAssertEqual(recordingVM.lastErrorMessage, "A recording is already in progress.")
        } catch {
            XCTFail("Expected alreadyRecording, got \(error)")
        }
    }
}
