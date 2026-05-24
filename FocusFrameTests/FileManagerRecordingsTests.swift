import AVFoundation
import XCTest
@testable import FocusFrame

final class FileManagerRecordingsTests: XCTestCase {
    func testRecordingProjectSanitizerRejectsUnsafePersistedTimelineValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Unsafe Project",
            videoFileURL: directory.appendingPathComponent("raw.mov"),
            cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: nil,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 12, preferredTimescale: 600),
            sourceRect: CGRect(x: CGFloat.nan, y: -20, width: 1280, height: 720),
            displayID: 1,
            zoomSegments: [],
            editActions: [],
            style: .default,
            hideDesktopIcons: false,
            showKeyboardShortcuts: true,
            webcamEnabled: false,
            subtitlesEnabled: false
        )
        project.style.backgroundMusicVolume = Float.nan
        project.zoomSegments = [
            ZoomSegment(
                id: UUID(),
                startTime: -5,
                endTime: 99,
                zoomRect: CGRect(x: -80, y: 700, width: 9000, height: 9000),
                focusPadding: .infinity,
                zoomInDuration: .nan,
                zoomOutDuration: 9,
                easingFunction: .easeInOut,
                source: .manual,
                keyframes: [
                    ZoomKeyframe(time: 6, zoomRect: CGRect(x: 10, y: 10, width: 120, height: 80)),
                    ZoomKeyframe(time: .nan, zoomRect: CGRect(x: 0, y: 0, width: 120, height: 80))
                ]
            ),
            ZoomSegment(
                id: UUID(),
                startTime: .nan,
                endTime: 3,
                zoomRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                focusPadding: 0.12,
                zoomInDuration: 0.3,
                zoomOutDuration: 0.3,
                easingFunction: .linear,
                source: .manual
            )
        ]
        var speed = EditAction.speedChange(startTime: -1, endTime: 20, multiplier: .infinity)
        speed.description = "Unsafe speed"
        project.editActions = [
            speed,
            EditAction.cut(startTime: .nan, endTime: 3)
        ]
        project.overlayElements = [
            OverlayElement(
                type: .text,
                startTime: -1,
                endTime: 99,
                rect: CGRect(x: CGFloat.nan, y: 2, width: -1, height: CGFloat.infinity),
                text: "Note",
                intensity: .infinity
            )
        ]
        project.chapterMarkers = [
            ChapterMarker(time: .nan, title: "Bad"),
            ChapterMarker(time: 99, title: "End")
        ]
        project.titleCardSegments = [
            TitleCardSegment(
                startTime: -1,
                endTime: 99,
                kind: .intro,
                title: "Intro",
                accentColor: CodableColor(r: .nan, g: 2, b: -1),
                backgroundOpacity: .infinity
            )
        ]
        project.cameraLayoutSegments = [
            CameraLayoutSegment(startTime: -1, endTime: 99, mode: .sideBySide)
        ]
        project.effectSegments = [
            EffectSegment(
                startTime: -1,
                endTime: 99,
                sourceAudioVolume: .nan,
                micAudioVolume: 7,
                musicVolume: -2
            )
        ]

        let sanitized = project.sanitizedForUse()

        XCTAssertEqual(sanitized.sourceRect.origin.x, 0)
        XCTAssertEqual(sanitized.sourceRect.origin.y, 0)
        XCTAssertEqual(sanitized.style.backgroundMusicVolume, 0.25, accuracy: 0.001)
        XCTAssertEqual(sanitized.zoomSegments.count, 1)
        XCTAssertEqual(sanitized.zoomSegments[0].startTime, 0)
        XCTAssertEqual(sanitized.zoomSegments[0].endTime, 12)
        XCTAssertEqual(sanitized.zoomSegments[0].zoomRect, CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(sanitized.zoomSegments[0].focusPadding, 0.12)
        XCTAssertEqual(sanitized.zoomSegments[0].zoomInDuration, 0.35)
        XCTAssertEqual(sanitized.zoomSegments[0].zoomOutDuration, 3)
        XCTAssertEqual(sanitized.zoomSegments[0].keyframes?.count, 1)
        XCTAssertEqual(sanitized.editActions.count, 1)
        XCTAssertEqual(sanitized.editActions[0].startTime, 0)
        XCTAssertEqual(sanitized.editActions[0].endTime, 12)
        XCTAssertEqual(sanitized.editActions[0].value, 1)
        XCTAssertEqual(sanitized.overlayElements?.first?.rect, CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2))
        XCTAssertEqual(sanitized.overlayElements?.first?.intensity, 0.75)
        XCTAssertEqual(sanitized.chapterMarkers?.map { $0.time }, [12])
        XCTAssertEqual(sanitized.titleCardSegments?.first?.accentColor, CodableColor(r: 0, g: 1, b: 0))
        XCTAssertEqual(sanitized.titleCardSegments?.first?.backgroundOpacity, 0.82)
        XCTAssertEqual(sanitized.cameraLayoutSegments?.first?.endTime, 12)
        XCTAssertNil(sanitized.effectSegments?.first?.sourceAudioVolume)
        XCTAssertEqual(sanitized.effectSegments?.first?.micAudioVolume, 1)
        XCTAssertEqual(sanitized.effectSegments?.first?.musicVolume, 0)
    }

    func testOversizedProjectMetadataIsSkippedBeforeDecode() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let videoURL = tempDirectory.appendingPathComponent("raw.mov")
        try Data(repeating: 1, count: 2048).write(to: videoURL)

        let project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Oversized Metadata",
            videoFileURL: videoURL,
            cursorDataFileURL: tempDirectory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: nil,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 4, preferredTimescale: 600),
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

        var metadata = try JSONEncoder().encode(project)
        metadata.append(Data(repeating: UInt8(ascii: " "), count: Int(FileManager.maxProjectMetadataBytes) + 1))

        let metadataURL = FileManager.recordingsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadataURL) }
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metadata.write(to: metadataURL)

        let projects = try FileManager.default.loadRecordingProjects(includeInvalid: true)

        XCTAssertFalse(projects.contains { $0.id == project.id })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-recording-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
