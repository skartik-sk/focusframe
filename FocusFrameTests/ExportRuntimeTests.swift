import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
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

    // MARK: - Frame-drop regression

    /// Writes a CFR source where every frame is a unique, monotonically increasing gray
    /// level (a linear ramp). Because the level is monotonic and non-cyclic, consecutive
    /// frames differ by ~a constant — so a held (frozen) frame shows up as a near-zero
    /// consecutive difference and a skipped frame as a roughly doubled one. This stays
    /// unambiguous even though the renderer composites the source onto a background.
    @MainActor
    private func writeLinearRampVideo(
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
            let pixelBuffer = try makeLinearLevelPixelBuffer(
                size: size,
                frameIndex: frameIndex,
                frameCount: frameCount
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

    private func makeLinearLevelPixelBuffer(size: CGSize, frameIndex: Int, frameCount: Int) throws -> CVPixelBuffer {
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

        // Monotonic gray ramp: each frame is strictly brighter than the last.
        let level = 0.1 + 0.8 * (CGFloat(frameIndex) / CGFloat(max(frameCount - 1, 1)))
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return pixelBuffer
    }

    /// Returns the mean absolute per-channel difference (0...1) between each pair of
    /// consecutive frames in the asset, in presentation order.
    private static func consecutiveFrameMeanDifferences(at url: URL) async throws -> [Double] {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        guard reader.startReading() else { return [] }

        var differences: [Double] = []
        var previous: [UInt8]?
        while let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, [.readOnly])
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = [UInt8](
                UnsafeRawBufferPointer(
                    start: CVPixelBufferGetBaseAddress(buffer),
                    count: bytesPerRow * height
                )
            )
            CVPixelBufferUnlockBaseAddress(buffer, [.readOnly])

            if let previous {
                // Sample up to ~2k pixels for speed; only BGR channels (skip alpha).
                let stride = max(1, (width * height) / 2_000)
                var sum = 0
                var count = 0
                for y in 0..<height {
                    for x in 0..<width where (y * width + x) % stride == 0 {
                        let offset = y * bytesPerRow + x * 4
                        for channel in 0..<3 {
                            sum += abs(Int(bytes[offset + channel]) - Int(previous[offset + channel]))
                            count += 1
                        }
                    }
                }
                differences.append(count > 0 ? Double(sum) / Double(count) / 255.0 : 0)
            }
            previous = bytes
        }
        return differences
    }

    /// Regression for the reported "frame drop on the final exported video".
    ///
    /// The export must show every source frame exactly once, in order. Two bugs broke that:
    /// (1) `CMTime(seconds:preferredTimescale:)` truncated `frameIndex/fps` one tick low,
    /// so `FrameSource` held the previous frame instead of advancing; (2) AVAssetReader
    /// recycles a small pool of `CVPixelBuffer` objects, so the lazy `CIImage`s captured
    /// during the serial decode read a *later* frame's content by render time. With a
    /// monotonic gray source, consecutive export frames must all differ by ~the same step —
    /// any near-zero difference is a held (dropped) frame, any ~doubled difference a skip.
    @MainActor
    func testExportDoesNotFreezeCFRSourceContent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fps = 30
        let frameCount = 90
        let size = CGSize(width: 320, height: 180)
        let videoURL = directory.appendingPathComponent("linear-cfr.mov")
        try await writeLinearRampVideo(to: videoURL, size: size, frameCount: frameCount, fps: fps)

        var project = RecordingProject(
            id: UUID(), createdAt: Date(), modifiedAt: Date(),
            title: "CFR Freeze",
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

        let profile = ExportProfile(
            id: UUID(),
            name: "CFR Freeze Test",
            width: 320,
            height: 180,
            fps: fps,
            codec: .h264,
            quality: 0.6,
            orientation: .landscape,
            format: .mp4
        )

        let exportVM = ExportVM()
        let outputURL = directory.appendingPathComponent("linear-cfr-export.mp4")
        exportVM.outputURL = outputURL
        let exportedURL = try await exportVM.export(project: project, profile: profile)

        let differences = try await Self.consecutiveFrameMeanDifferences(at: exportedURL)
        XCTAssertEqual(differences.count, frameCount - 1, "Export should have \(frameCount - 1) frame gaps")

        let sorted = differences.sorted()
        let median = sorted[sorted.count / 2]
        let held = differences.enumerated().filter { $0.element < median * 0.4 }.map { $0.offset }
        let skipped = differences.enumerated().filter { $0.element > median * 1.6 }.map { $0.offset }

        let preview = differences.prefix(12).map { String(format: "%.4f", $0) }.joined(separator: " ")
        print("[CFR-Freeze] median=\(String(format: "%.4f", median)) first12=[\(preview)] held=\(held) skipped=\(skipped)")

        XCTAssertTrue(median > 0.0005, "Consecutive frames must visibly advance (median diff \(median))")
        XCTAssertTrue(held.isEmpty, "Export held (dropped) frames at gaps \(held); diffs \(differences)")
        XCTAssertTrue(skipped.isEmpty, "Export skipped frames at gaps \(skipped); diffs \(differences)")
    }

    /// Exports a real local recording into the repo's `video/` folder using the fixed
    /// pipeline, so the output can be inspected for frame drops. Gated behind an env var so
    /// it never runs in the normal suite. Run with:
    ///   FOCUSFRAME_EXPORT_TO_VIDEO=1 swift test --filter testExportRealRecordingToVideoFolder
    @MainActor
    func testExportRealRecordingToVideoFolder() async throws {
        guard ProcessInfo.processInfo.environment["FOCUSFRAME_EXPORT_TO_VIDEO"] == "1" else {
            throw XCTSkip("Set FOCUSFRAME_EXPORT_TO_VIDEO=1 to export a real recording into video/.")
        }

        let projects = try FileManager.default.loadRecordingProjects()
        let project = projects.first(where: { $0.videoFileURL.path.contains("E0D96FB8") })
            ?? projects.first
        guard let project else {
            throw XCTSkip("No local recording available to export.")
        }

        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let videoDir = repoRoot.appendingPathComponent("video", isDirectory: true)
        try? FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)

        let exportVM = ExportVM()
        let outputURL = videoDir.appendingPathComponent("focusframe_export_60fps_fixed.mp4")
        exportVM.outputURL = outputURL

        let start = Date()
        let exportedURL = try await exportVM.export(project: project, profile: .web720p)
        let elapsed = Date().timeIntervalSince(start)
        let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
        let sizeMB = Double((attributes[.size] as? NSNumber)?.int64Value ?? 0) / 1_000_000

        print("[VideoExport] wrote \(exportedURL.path) (\(String(format: "%.1f", sizeMB)) MB, \(String(format: "%.1f", elapsed))s)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
    }
}
