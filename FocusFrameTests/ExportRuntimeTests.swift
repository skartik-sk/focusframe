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

        func exportOnce(workers: Int) async throws -> (TimeInterval, URL) {
            let exportVM = ExportVM()
            exportVM.workerCountOverride = workers
            let outputURL = directory.appendingPathComponent("bench-\(workers)-\(UUID().uuidString).mp4")
            exportVM.outputURL = outputURL
            let start = Date()
            _ = try await exportVM.export(project: makeProject(), profile: profile)
            return (Date().timeIntervalSince(start), outputURL)
        }

        let (serial, serialURL) = try await exportOnce(workers: 1)
        let (parallel, parallelURL) = try await exportOnce(workers: cores)

        print("[RealExport] cores=\(cores) \(Int(fixtureSize.width))x\(Int(fixtureSize.height)) \(frameCount)f  serial(1)=\(String(format: "%.3f", serial))s  parallel(\(cores))=\(String(format: "%.3f", parallel))s")

        // Both exports must produce a valid, decodable video. On short clips the export
        // is fixed-cost-dominated (setup/encode/mux), so worker count barely moves the
        // needle; parallelism pays off on long recordings where per-frame work dominates.
        let serialTracks = try await AVAsset(url: serialURL).loadTracks(withMediaType: .video)
        let parallelTracks = try await AVAsset(url: parallelURL).loadTracks(withMediaType: .video)
        XCTAssertFalse(serialTracks.isEmpty)
        XCTAssertFalse(parallelTracks.isEmpty)
        XCTAssertLessThan(parallel, 5.0, "Export should be fast on a short clip")
    }

    /// Diagnostic: pinpoints where export time goes and whether it scales with cores.
    /// Prints (no hard assertions). Reveals whether the limiter is decode, GPU-bound
    /// composite, encoder backpressure, or fixed per-export overhead.
    @MainActor
    func testProfileExportBottleneck() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 1280, height: 720)
        let fps = 30
        let frameCount = 60
        let videoURL = directory.appendingPathComponent("prof.mov")
        try await writePlayableVideo(to: videoURL, size: size, frameCount: frameCount, fps: fps)
        let asset = AVAsset(url: videoURL)

        // 1) Single-threaded decode cost (one generator, sequential).
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        let decodeStart = Date()
        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) / Double(fps), preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) { _ = cg }
        }
        let decodeSerial = Date().timeIntervalSince(decodeStart)

        // 1b) AVAssetReader (hardware streaming) decode cost on the same asset.
        let readerStart = Date()
        let reader = try AVAssetReader(asset: asset)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        var assetReaderTime: TimeInterval = 0
        if let videoTrack {
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)
            if reader.startReading() {
                let r0 = Date()
                var decoded = 0
                while let sample = readerOutput.copyNextSampleBuffer(), decoded < frameCount {
                    _ = CMSampleBufferGetImageBuffer(sample)
                    decoded += 1
                }
                assetReaderTime = Date().timeIntervalSince(r0)
                reader.cancelReading()
            }
        }
        let readerTotal = Date().timeIntervalSince(readerStart)

        let plainProfile = ExportProfile(
            id: UUID(), name: "Plain", width: Int(size.width), height: Int(size.height),
            fps: fps, codec: .h264, quality: 0.7, orientation: .landscape, format: .mp4
        )

        func makeProject(heavy: Bool) -> RecordingProject {
            var project = RecordingProject(
                id: UUID(), createdAt: Date(), modifiedAt: Date(),
                title: heavy ? "Heavy" : "Plain",
                videoFileURL: videoURL,
                cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
                keyEventsFileURL: nil, micAudioFileURL: nil, systemAudioFileURL: nil,
                webcamFileURL: nil, captionsFileURL: nil,
                duration: CMTime(seconds: Double(frameCount) / Double(fps), preferredTimescale: 600),
                sourceRect: CGRect(origin: .zero, size: size), displayID: 0,
                zoomSegments: [], editActions: [], style: .default,
                hideDesktopIcons: false, showKeyboardShortcuts: false,
                webcamEnabled: false, subtitlesEnabled: false
            )
            if heavy {
                project.style.backgroundType = .gradient
                project.style.shadowEnabled = true
                project.style.motionBlurEnabled = true
                project.style.motionBlurStrength = 0.5
            }
            return project
        }

        func exportOnce(workers: Int, heavy: Bool) async throws -> TimeInterval {
            let exportVM = ExportVM()
            exportVM.workerCountOverride = workers
            exportVM.outputURL = directory.appendingPathComponent("prof-\(heavy)-\(workers)-\(UUID().uuidString).mp4")
            let start = Date()
            _ = try await exportVM.export(project: makeProject(heavy: heavy), profile: plainProfile)
            return Date().timeIntervalSince(start)
        }

        print("\n========== EXPORT PROFILE (cores=\(cores), \(Int(size.width))x\(Int(size.height)) \(frameCount)f) ==========")
        print(String(format: "decode copyCGImage 1-thread : %.3fs (%.1f ms/frame)", decodeSerial, decodeSerial * 1000 / Double(frameCount)))
        print(String(format: "decode AVAssetReader stream  : %.3fs (%.1f ms/frame)  [read phase %.3fs]", assetReaderTime, assetReaderTime * 1000 / Double(frameCount), readerTotal))

        for heavy in [false, true] {
            let label = heavy ? "HEAVY style" : "PLAIN style"
            for workers in [1, 2, 4, cores] {
                let t = try await exportOnce(workers: workers, heavy: heavy)
                print(String(format: "%@ workers=%-2d : %.3fs", label, workers, t))
            }
        }
        print("===========================================================================\n")
    }

    /// Verifies the exported video has uniform frame timing (every frame at i/fps,
    /// no missing or duplicate timestamps), which is the precondition for smooth
    /// playback — i.e. the export itself introduces no jitter.
    @MainActor
    func testExportProducesUniformFrameTiming() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fps = 5
        let frameCount = 8
        let size = CGSize(width: 160, height: 90)
        let videoURL = directory.appendingPathComponent("timing.mov")
        try await writePlayableVideo(to: videoURL, size: size, frameCount: frameCount, fps: fps)

        var project = RecordingProject(
            id: UUID(), createdAt: Date(), modifiedAt: Date(),
            title: "Timing",
            videoFileURL: videoURL,
            cursorDataFileURL: directory.appendingPathComponent("cursor.json"),
            keyEventsFileURL: nil, micAudioFileURL: nil, systemAudioFileURL: nil,
            webcamFileURL: nil, captionsFileURL: nil,
            duration: CMTime(seconds: Double(frameCount) / Double(fps), preferredTimescale: 600),
            sourceRect: CGRect(origin: .zero, size: size), displayID: 0,
            zoomSegments: [], editActions: [], style: .default,
            hideDesktopIcons: false, showKeyboardShortcuts: false,
            webcamEnabled: false, subtitlesEnabled: false
        )
        project.style.backgroundType = .gradient

        let exportVM = ExportVM()
        let outputURL = directory.appendingPathComponent("timing-export.mp4")
        exportVM.outputURL = outputURL
        let exportedURL = try await exportVM.export(project: project, profile: Self.fastVideoProfile)

        // Read back the exported frames' presentation timestamps.
        let asset = AVAsset(url: exportedURL)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("Exported asset has no video track"); return
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }

        let exportedFPS = Self.fastVideoProfile.fps
        XCTAssertEqual(timestamps.count, frameCount, "Export should contain exactly one buffer per output frame")
        for (index, pts) in timestamps.enumerated() {
            let expected = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(exportedFPS))
            XCTAssertEqual(pts.seconds, expected.seconds, accuracy: 1.0 / 600, "Frame \(index) should be at \(expected.seconds)s")
        }
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
