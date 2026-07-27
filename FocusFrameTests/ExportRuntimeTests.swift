import XCTest
import AVFoundation
import CoreGraphics
@testable import FocusFrame

final class ExportRuntimeTests: XCTestCase {
    func testVideoExportPresetsDefaultToSixtyFPS() {
        let videoPresets = ExportProfile.allPresets.filter { $0.format != .gif }

        XCTAssertFalse(videoPresets.isEmpty)
        XCTAssertTrue(
            videoPresets.allSatisfy { $0.fps >= 60 },
            "Video exports should default to high-framerate output. GIF stays separate because high-FPS GIF files are impractical."
        )
    }

    func testHighClarityExportPresetsUseExplicitBitrateTargets() {
        XCTAssertEqual(ExportProfile.youtube4K.codec, .h264)
        XCTAssertGreaterThanOrEqual(ExportProfile.youtube4K.quality, 0.98)
        XCTAssertGreaterThanOrEqual(ExportProfile.youtube4K.averageBitrateMbps ?? 0, 100)

        XCTAssertEqual(ExportProfile.maxClarity4K.width, 3840)
        XCTAssertEqual(ExportProfile.maxClarity4K.height, 2160)
        XCTAssertEqual(ExportProfile.maxClarity4K.fps, 60)
        XCTAssertGreaterThanOrEqual(ExportProfile.maxClarity4K.averageBitrateMbps ?? 0, 120)
    }

    @MainActor
    func testSilentExportCompletesProgress() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("silent.mov")
        try await writePlayableVideo(to: videoURL, size: CGSize(width: 160, height: 90), frameCount: 5, fps: 5)

        let project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Silent Export",
            videoFileURL: videoURL,
            cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: nil,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            sourceRect: CGRect(x: 0, y: 0, width: 160, height: 90),
            displayID: 0,
            zoomSegments: [],
            editActions: [],
            style: .default,
            hideDesktopIcons: false,
            showKeyboardShortcuts: false,
            webcamEnabled: false,
            subtitlesEnabled: false
        )

        let exportVM = ExportVM()
        let outputURL = directory.appendingPathComponent("silent-export.mp4")
        exportVM.outputURL = outputURL

        let exportedURL = try await exportVM.export(project: project, profile: Self.fastVideoProfile)

        XCTAssertEqual(exportVM.progress, 1.0, accuracy: 0.001)
        XCTAssertFalse(exportVM.isExporting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        let videoTracks = try await AVAsset(url: exportedURL).loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty)
    }

    @MainActor
    func testAudioExportKeepsAudioTrack() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("screen.mov")
        try await writePlayableVideo(to: videoURL, size: CGSize(width: 160, height: 90), frameCount: 5, fps: 5)
        let micURL = try makeToneAudioFile()
        defer { try? FileManager.default.removeItem(at: micURL) }

        let project = RecordingProject(
            id: UUID(),
            createdAt: Date(),
            modifiedAt: Date(),
            title: "Audio Export",
            videoFileURL: videoURL,
            cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil,
            micAudioFileURL: micURL,
            systemAudioFileURL: nil,
            webcamFileURL: nil,
            captionsFileURL: nil,
            duration: CMTime(seconds: 1, preferredTimescale: 600),
            sourceRect: CGRect(x: 0, y: 0, width: 160, height: 90),
            displayID: 0,
            zoomSegments: [],
            editActions: [],
            style: .default,
            hideDesktopIcons: false,
            showKeyboardShortcuts: false,
            webcamEnabled: false,
            subtitlesEnabled: false
        )

        let exportVM = ExportVM()
        let outputURL = directory.appendingPathComponent("audio-export.mp4")
        exportVM.outputURL = outputURL

        let exportedURL = try await exportVM.export(project: project, profile: Self.fastVideoProfile)
        let asset = AVAsset(url: exportedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    @MainActor
    func testExportLatestRecording() async throws {
        guard ProcessInfo.processInfo.environment["FOCUSFRAME_RUN_LOCAL_EXPORT_TESTS"] == "1" else {
            throw XCTSkip("Set FOCUSFRAME_RUN_LOCAL_EXPORT_TESTS=1 to run local-recording export integration tests.")
        }

        let project = try await latestExportableProject()

        let exportVM = ExportVM()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-export-\(UUID().uuidString).mp4")
        exportVM.outputURL = outputURL

        let exportedURL = try await exportVM.export(project: project, profile: Self.smokeProfile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 1024)
        if try await projectHasAnyAudio(project) {
            let exportedAudioTracks = try await AVAsset(url: exportedURL).loadTracks(withMediaType: .audio)
            XCTAssertFalse(
                exportedAudioTracks.isEmpty,
                "Export should keep recorded source or mic audio."
            )
        }
    }

    @MainActor
    func testExportLatestRecordingWithSpeedChange() async throws {
        guard ProcessInfo.processInfo.environment["FOCUSFRAME_RUN_LOCAL_EXPORT_TESTS"] == "1" else {
            throw XCTSkip("Set FOCUSFRAME_RUN_LOCAL_EXPORT_TESTS=1 to run local-recording export integration tests.")
        }

        var project = try await latestExportableProject()

        let sourceDuration = project.duration.seconds
        guard sourceDuration > 2 else {
            throw XCTSkip("Need a recording longer than 2 seconds for speed export test.")
        }

        project.editActions = [
            .speedChange(
                startTime: 0,
                endTime: sourceDuration,
                multiplier: 2.0,
                description: "Speed 2x"
            )
        ]
        project.style.backgroundMusicURL = try makeToneAudioFile()
        project.style.backgroundMusicVolume = 0.2
        project.style.backgroundMusicLoop = true

        let exportVM = ExportVM()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-speed-export-\(UUID().uuidString).mp4")
        exportVM.outputURL = outputURL

        let exportedURL = try await exportVM.export(project: project, profile: Self.smokeProfile)
        let exportedDuration = try await AVAsset(url: exportedURL).load(.duration).seconds

        XCTAssertLessThan(exportedDuration, sourceDuration * 0.75)
        XCTAssertGreaterThan(exportedDuration, sourceDuration * 0.40)
        let exportedAudioTracks = try await AVAsset(url: exportedURL).loadTracks(withMediaType: .audio)
        XCTAssertFalse(
            exportedAudioTracks.isEmpty,
            "Export should include generated music/audio mix."
        )
    }

    /// Measures a real end-to-end video export at 1 worker vs one-worker-per-core, to
    /// confirm the parallel pipeline actually speeds up a real render (not just
    /// synthetic CPU work) despite the shared GPU. Prints the ratio; asserts the
    /// parallel run is not slower.
    @MainActor
    func testRealExportParallelSpeedup() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        try XCTSkipUnless(cores >= 2, "Speedup benchmark needs ≥2 cores")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A non-trivial fixture: enough resolution + frames + compositing cost that
        // per-frame render dominates over fixed setup/encode overhead.
        let videoURL = directory.appendingPathComponent("bench.mov")
        let fixtureSize = CGSize(width: 960, height: 540)
        let frameCount = 60
        let fps = 30
        try await writePlayableVideo(to: videoURL, size: fixtureSize, frameCount: frameCount, fps: fps)

        func makeProject() -> RecordingProject {
            var project = RecordingProject(
                id: UUID(),
                createdAt: Date(),
                modifiedAt: Date(),
                title: "Parallel Bench",
                videoFileURL: videoURL,
                cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
                keyEventsFileURL: nil,
                micAudioFileURL: nil,
                systemAudioFileURL: nil,
                webcamFileURL: nil,
                captionsFileURL: nil,
                duration: CMTime(seconds: Double(frameCount) / Double(fps), preferredTimescale: 600),
                sourceRect: CGRect(origin: .zero, size: fixtureSize),
                displayID: 0,
                zoomSegments: [],
                editActions: [],
                style: .default,
                hideDesktopIcons: false,
                showKeyboardShortcuts: false,
                webcamEnabled: false,
                subtitlesEnabled: false
            )
            // Heavier compositing so per-frame cost is meaningful.
            project.style.backgroundType = .gradient
            project.style.shadowEnabled = true
            project.style.motionBlurEnabled = true
            project.style.motionBlurStrength = 0.5
            return project
        }

        let profile = ExportProfile(
            id: UUID(),
            name: "Bench",
            width: Int(fixtureSize.width),
            height: Int(fixtureSize.height),
            fps: fps,
            codec: .h264,
            quality: 0.7,
            orientation: .landscape,
            format: .mp4
        )

        func exportOnce(workers: Int) async throws -> TimeInterval {
            let exportVM = ExportVM()
            exportVM.workerCountOverride = workers
            exportVM.outputURL = directory.appendingPathComponent("bench-\(workers)-\(UUID().uuidString).mp4")
            let start = Date()
            _ = try await exportVM.export(project: makeProject(), profile: profile)
            return Date().timeIntervalSince(start)
        }

        let serial = try await exportOnce(workers: 1)
        let parallel = try await exportOnce(workers: cores)
        let speedup = serial / parallel

        print("[RealExport] cores=\(cores) \(Int(fixtureSize.width))x\(Int(fixtureSize.height)) \(frameCount)fps  serial(1)=\(String(format: "%.3f", serial))s  parallel(\(cores))=\(String(format: "%.3f", parallel))s  speedup=\(String(format: "%.2f", speedup))x")

        XCTAssertLessThanOrEqual(parallel, serial * 1.1, "Parallel export should not be slower than single-worker")
    }

    private func makeToneAudioFile() throws -> URL {
        let sampleRate = 44_100.0
        let duration = 0.75
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-test-music-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw ExportError.renderingFailed
        }

        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            let t = Double(index) / sampleRate
            channel[index] = Float(sin(2 * .pi * 440 * t) * 0.2)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @MainActor
    private func projectHasAnyAudio(_ project: RecordingProject) async throws -> Bool {
        let candidates = [
            project.systemAudioFileURL,
            project.micAudioFileURL,
            project.videoFileURL
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if !(try await AVAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty {
                return true
            }
        }
        return false
    }

    private static let smokeProfile = ExportProfile(
        id: UUID(),
        name: "Runtime Smoke",
        width: 640,
        height: 360,
        fps: 10,
        codec: .h264,
        quality: 0.55,
        orientation: .landscape,
        format: .mp4
    )

    private static let fastVideoProfile = ExportProfile(
        id: UUID(),
        name: "Fast Video",
        width: 160,
        height: 90,
        fps: 5,
        codec: .h264,
        quality: 0.45,
        orientation: .landscape,
        format: .mp4
    )

    @MainActor
    private func latestExportableProject() async throws -> RecordingProject {
        let projects = try FileManager.default.loadRecordingProjects()
        for project in projects {
            let asset = AVAsset(url: project.videoFileURL)
            if let duration = try? await asset.load(.duration).seconds,
               duration.isFinite,
               duration > 0.1 {
                return project
            }
        }
        throw XCTSkip("No playable local recordings available for export integration test.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func writePlayableVideo(
        to url: URL,
        size: CGSize,
        frameCount: Int,
        fps: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )

        guard writer.canAdd(input) else { throw ExportError.renderingFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.renderingFailed
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let pixelBuffer = try makeVideoPixelBuffer(
                size: size,
                progress: CGFloat(frameIndex) / CGFloat(max(frameCount - 1, 1))
            )
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? ExportError.renderingFailed
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.renderingFailed
        }
    }

    @MainActor
    private func makeVideoPixelBuffer(size: CGSize, progress: CGFloat) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ExportError.renderingFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                data: baseAddress,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
              ) else {
            throw ExportError.renderingFailed
        }

        context.setFillColor(CGColor(red: 0.12 + progress * 0.5, green: 0.24, blue: 0.62, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.88))
        context.fill(CGRect(x: size.width * 0.18, y: size.height * 0.24, width: size.width * 0.28, height: size.height * 0.22))
        context.setFillColor(CGColor(red: 0.03, green: 0.05, blue: 0.08, alpha: 0.88))
        context.fill(CGRect(x: size.width * 0.52, y: size.height * 0.52, width: size.width * 0.30, height: size.height * 0.20))

        return pixelBuffer
    }
}
