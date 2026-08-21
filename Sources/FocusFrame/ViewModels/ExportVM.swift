import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal

final class ExportVM: ObservableObject, @unchecked Sendable {
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var selectedProfile: ExportProfile = .web1080p
    @Published var estimatedFileSize: String = ""
    @Published var outputURL: URL?
    /// Live export telemetry surfaced to the UI (ETA, throughput, cores in use).
    @Published var renderedFPS: Double = 0
    @Published var estimatedTimeRemaining: Double = 0
    @Published var coresInUse: Int = 0
    /// Test/benchmark override for the parallel worker count. `nil` (default) uses one
    /// worker per logical core — the production setting.
    var workerCountOverride: Int?
    var project: RecordingProject?
    
    private let renderer = VideoRenderer()
    private let cursorSmoother = CursorSmoother()
    private let zoomTransformer = ZoomTransformer()
    private let autoZoomCalculator = AutoZoomCalculator()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let exportStateLock = NSLock()
    private var isCancellationRequested = false
    private var activeExportSession: AVAssetExportSession?
    private static let maxCaptionFileBytes: UInt64 = 10 * 1024 * 1024
    private static let maxKeyEventsFileBytes: UInt64 = 20 * 1024 * 1024
    private static let maxCursorDataFileBytes: UInt64 = 128 * 1024 * 1024

    // MARK: - Parallel render support

    /// Read-only bundle of everything a worker needs to build one frame's inputs.
    /// Shared by the video and GIF export paths. `bufferPool` is set for video
    /// exports (writer-backed pool) and `nil` for GIF. `@unchecked Sendable`: holds
    /// only immutable data (the pool, when present, is thread-safe for allocation).
    private struct RenderContext: @unchecked Sendable {
        let project: RecordingProject
        let transforms: [FrameTransform]
        let smoothedCursor: [CursorFrame]
        let keyEvents: [KeyPressEvent]
        let captionSegments: [CaptionSegment]
        let timeline: [RenderTimelineSegment]
        let sourceSize: CGSize
        let width: Int
        let height: Int
        let fps: Int
        let bufferPool: CVPixelBufferPool?
    }

    /// Per-worker rendering resources. `@unchecked Sendable`: a worker is used by at
    /// most one task at a time (distinct offsets within a chunk; barriers between
    /// chunks), so its renderer's mutable Core Image filter state is never accessed
    /// concurrently.
    private struct RenderWorker: @unchecked Sendable {
        let renderer: VideoRenderer
        let ciContext: CIContext
        let webcamImageGenerator: AVAssetImageGenerator?
    }

    /// Ordered sink for the video writer. `@unchecked Sendable`: the pipeline calls
    /// `append` strictly sequentially, so the writer objects are never touched
    /// concurrently.
    private final class WriterSink: @unchecked Sendable {
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let writer: AVAssetWriter
        let fps: Int
        let checkCancellation: @Sendable () throws -> Void

        init(
            videoInput: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            writer: AVAssetWriter,
            fps: Int,
            checkCancellation: @escaping @Sendable () throws -> Void
        ) {
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.writer = writer
            self.fps = fps
            self.checkCancellation = checkCancellation
        }

        func append(_ buffer: CVPixelBuffer, frameIndex: Int) async throws {
            while !videoInput.isReadyForMoreMediaData {
                try checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError.renderingFailed
            }
        }
    }

    /// Ordered sink for the GIF destination. `@unchecked Sendable`: the pipeline
    /// calls `add` strictly sequentially, so the destination is never touched
    /// concurrently.
    private final class GifSink: @unchecked Sendable {
        let destination: CGImageDestination
        let ciContext: CIContext
        let outputSize: CGSize
        let frameProperties: CFDictionary

        init(
            destination: CGImageDestination,
            ciContext: CIContext,
            outputSize: CGSize,
            frameProperties: CFDictionary
        ) {
            self.destination = destination
            self.ciContext = ciContext
            self.outputSize = outputSize
            self.frameProperties = frameProperties
        }

        func add(_ buffer: CVPixelBuffer) throws {
            let ciImage = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = ciContext.createCGImage(
                ciImage,
                from: CGRect(origin: .zero, size: outputSize)
            ) else {
                throw ExportError.renderingFailed
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }
    }

    /// Live export telemetry (frames completed + elapsed time) → progress, throughput,
    /// and ETA. `@unchecked Sendable`: access is serialized through `lock`.
    private final class ExportTelemetry: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = 0
        private let total: Int
        private let start: Date

        init(total: Int) {
            self.total = total
            self.start = Date()
        }

        func add(_ frames: Int) {
            lock.lock()
            completed += frames
            lock.unlock()
        }

        var snapshot: (progress: Double, fps: Double, eta: Double) {
            lock.lock()
            let done = completed
            let elapsed = Date().timeIntervalSince(start)
            lock.unlock()
            let progress = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
            let fps = elapsed > 0 ? Double(done) / elapsed : 0
            let remaining = max(0, total - done)
            let eta = fps > 0 ? Double(remaining) / fps : 0
            return (progress, fps, eta)
        }
    }

    private static func makeVideoRenderWorker(webcamAsset: AVAsset?) -> RenderWorker {
        let webcamGenerator: AVAssetImageGenerator? = webcamAsset.map { asset in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
            return generator
        }

        let metalDevice = MTLCreateSystemDefaultDevice()
        let ciContext: CIContext
        if let metalDevice {
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        return RenderWorker(
            renderer: VideoRenderer(),
            ciContext: ciContext,
            webcamImageGenerator: webcamGenerator
        )
    }

    /// Streams hardware-decoded source frames from an asset via `AVAssetReader` — about
    /// 34× faster than per-frame `AVAssetImageGenerator.copyCGImage` seeks, which was
    /// the real export bottleneck. Advances in presentation order; `frame(at:)` returns
    /// the source frame whose presentation covers the requested time.
    /// `@unchecked Sendable`: accessed serially (only from the pipeline's serial decode
    /// phase). Falls back to a generator seek if the reader cannot start or is exhausted.
    private final class FrameSource: @unchecked Sendable {
        private let reader: AVAssetReader?
        private let output: AVAssetReaderTrackOutput?
        private let fallback: AVAssetImageGenerator
        private let lock = NSLock()
        private var current: (CVPixelBuffer, CMTime)?
        private var lookahead: (CVPixelBuffer, CMTime)?
        private var started = false

        init(asset: AVAsset, sourceSize: CGSize) async {
            let fallback = AVAssetImageGenerator(asset: asset)
            fallback.appliesPreferredTrackTransform = true
            fallback.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)
            fallback.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
            self.fallback = fallback

            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else {
                // No readable video track or reader could not be created: `frame(at:)`
                // will fall back to the generator (or a gray frame), matching prior behavior.
                self.reader = nil
                self.output = nil
                return
            }
            // CPU-backed BGRA output (no IOSurface/Metal compatibility). Hardware decode is
            // still used, but frames land in independent, per-sample CPU buffers that are
            // NOT pooled by the decoder — so a buffer retained in `current`/`lookahead`
            // (and the lazy `CIImage` that references it, read later at render time) keeps
            // its content. IOSurface-backed outputs are recycled by the decoder and produced
            // frozen/stale frames in the export. CPU buffers also expose a base address.
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: max(1, Int(sourceSize.width)),
                    kCVPixelBufferHeightKey as String: max(1, Int(sourceSize.height))
                ]
            )
            reader.add(output)
            guard reader.startReading() else {
                self.reader = nil
                self.output = nil
                return
            }
            self.reader = reader
            self.output = output
        }

        private func readNext() -> (CVPixelBuffer, CMTime)? {
            guard let output,
                  let sample = output.copyNextSampleBuffer(),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                return nil
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            // AVAssetReader recycles a small pool of CVPixelBuffer *objects* across reads
            // (confirmed: base addresses repeat in a cycle). The lazy `CIImage` returned by
            // `frame(at:)` references that object, and by the time the parallel render reads
            // it, the decoder has overwritten the backing with a later frame — producing
            // frozen/advanced content with correct presentation timestamps (the export
            // "frame drop"). Snapshot each frame into a fresh, private buffer object so the
            // retained content is immutable. CPU-backed output makes the base-address copy
            // viable. Falls back to the live buffer only if allocation/copy fails.
            guard let copied = Self.deepCopyPixelBuffer(buffer) else {
                return (buffer, presentationTime)
            }
            return (copied, presentationTime)
        }

        /// Allocates a fresh CVPixelBuffer and copies `source`'s current pixels into it.
        /// The result is a private object whose backing is never recycled, so it stays
        /// valid for as long as it is retained (unlike the reader's pooled buffers).
        private static func deepCopyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let format = CVPixelBufferGetPixelFormatType(source)

            var copy: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                format,
                nil,
                &copy
            )
            guard status == kCVReturnSuccess, let copy else { return nil }

            CVPixelBufferLockBaseAddress(source, [.readOnly])
            CVPixelBufferLockBaseAddress(copy, [])
            defer {
                CVPixelBufferUnlockBaseAddress(copy, [])
                CVPixelBufferUnlockBaseAddress(source, [.readOnly])
            }

            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let copyBase = CVPixelBufferGetBaseAddress(copy) else {
                return nil
            }

            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let copyBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
            if sourceBytesPerRow == copyBytesPerRow {
                memcpy(copyBase, sourceBase, sourceBytesPerRow * height)
            } else {
                let rowBytes = min(sourceBytesPerRow, copyBytesPerRow)
                for row in 0..<height {
                    memcpy(
                        copyBase.advanced(by: row * copyBytesPerRow),
                        sourceBase.advanced(by: row * sourceBytesPerRow),
                        rowBytes
                    )
                }
            }
            return copy
        }

        /// Returns the source frame whose presentation covers `time`.
        func frame(at time: Double) -> CIImage {
            lock.lock()
            // Round to the nearest 1/600 tick instead of using
            // `CMTime(seconds:preferredTimescale:)`, which TRUNCATES the seconds→tick
            // conversion. `Double(frameIndex)/fps` is rarely exact, so e.g. 11/30·600 =
            // 219.9999… truncates to 219 — one tick below frame 11's presentation time.
            // That made `while next.pts <= target` fail to advance, so the previous frame
            // was held and the target frame dropped (the export "frame drop"). Rounding
            // recovers the exact grid time.
            let target = CMTime(value: CMTimeValue((time * 600).rounded()), timescale: 600)

            if reader?.status == .reading {
                if !started {
                    current = readNext()
                    lookahead = readNext()
                    started = true
                }
                while let next = lookahead, next.1 <= target {
                    current = next
                    lookahead = readNext()
                }
                if let cur = current {
                    lock.unlock()
                    return CIImage(cvPixelBuffer: cur.0)
                }
            }
            lock.unlock()

            if let cg = try? fallback.copyCGImage(at: target, actualTime: nil) {
                return CIImage(cgImage: cg)
            }
            return CIImage(color: .init(cgColor: CGColor(gray: 0.2, alpha: 1.0)))
        }
    }

    private func webcamAsset(for project: RecordingProject) -> AVAsset? {
        guard let url = project.webcamFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return AVAsset(url: url)
    }

    /// Builds the full `FrameInputs` for a frame from a pre-decoded source image and the
    /// worker's webcam generator. Shared by the video and GIF paths so per-frame output
    /// is identical across both.
    private func frameInputs(
        worker: RenderWorker,
        frameIndex: Int,
        sourceFrame: CIImage,
        context: RenderContext
    ) -> (inputs: VideoRenderer.FrameInputs, style: StylePreset) {
        let outputTime = Double(frameIndex) / Double(context.fps)
        let sourceTime = sourceTime(for: outputTime, timeline: context.timeline)
        let frameTransform = frameTransform(at: sourceTime, transforms: context.transforms)
        let motionBlurVelocity = transformVelocity(at: sourceTime, transforms: context.transforms)
        let cursorData = cursorFrame(at: sourceTime, frames: context.smoothedCursor)
        let clickProgress = clickAnimationProgress(at: sourceTime, frames: context.smoothedCursor)
        let resolvedEffects = EffectSegmentResolver.resolve(project: context.project, at: sourceTime)
        let style = resolvedEffects.style
        let activeShortcuts = activeShortcuts(at: sourceTime, events: context.keyEvents, style: style)

        let inputs = VideoRenderer.FrameInputs(
            sourceFrame: sourceFrame,
            timestamp: outputTime,
            zoomTransform: frameTransform.transform,
            cursorPosition: cursorData?.position,
            cursorVisible: shouldShowCursor(
                at: sourceTime,
                cursorData: cursorData,
                frames: context.smoothedCursor,
                style: style,
                project: context.project,
                clickProgress: clickProgress,
                visibilityOverride: resolvedEffects.cursorVisibility
            ),
            cursorAlpha: 1.0,
            cursorScale: style.cursorScale,
            isClicking: cursorData?.isClicking ?? false,
            clickAnimationProgress: clickProgress,
            webcamFrame: resolvedEffects.webcamEnabled ? loadWebcamFrame(at: sourceTime, generator: worker.webcamImageGenerator) : nil,
            activeShortcuts: resolvedEffects.showKeyboardShortcuts ? activeShortcuts : [],
            subtitleText: activeSubtitle(at: sourceTime, segments: context.captionSegments, enabled: resolvedEffects.subtitlesEnabled),
            motionBlurVelocity: motionBlurVelocity,
            activeOverlays: resolvedEffects.overlaysEnabled ? activeOverlays(at: sourceTime, project: context.project) : [],
            activeTitleCards: activeTitleCards(at: sourceTime, project: context.project),
            zoomScale: frameTransform.scale,
            cameraLayoutMode: activeCameraLayoutMode(at: sourceTime, project: context.project, webcamEnabled: resolvedEffects.webcamEnabled)
        )
        return (inputs, style)
    }

    /// Renders a single video frame into a fresh pool-backed pixel buffer.
    private func renderVideoFrame(
        worker: RenderWorker,
        frameIndex: Int,
        sourceFrame: CIImage,
        context: RenderContext
    ) throws -> CVPixelBuffer {
        guard let pool = context.bufferPool else { throw ExportError.renderingFailed }
        let (inputs, style) = frameInputs(
            worker: worker,
            frameIndex: frameIndex,
            sourceFrame: sourceFrame,
            context: context
        )

        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw ExportError.renderingFailed
        }

        worker.renderer.renderFrame(
            inputs: inputs,
            config: style,
            outputSize: CGSize(width: context.width, height: context.height),
            into: pixelBuffer
        )
        return pixelBuffer
    }

    /// Renders a single GIF frame into a freshly allocated pixel buffer (GIF has no
    /// writer-backed pool). The caller converts it to a `CGImage` for the destination.
    private func renderGifFrame(
        worker: RenderWorker,
        frameIndex: Int,
        sourceFrame: CIImage,
        context: RenderContext
    ) throws -> CVPixelBuffer {
        let (inputs, style) = frameInputs(
            worker: worker,
            frameIndex: frameIndex,
            sourceFrame: sourceFrame,
            context: context
        )
        guard let buffer = worker.renderer.renderFrame(
            inputs: inputs,
            config: style,
            outputSize: CGSize(width: context.width, height: context.height)
        ) else {
            throw ExportError.renderingFailed
        }
        return buffer
    }

    func export(project: RecordingProject, profile: ExportProfile) async throws -> URL {
        guard let finalURL = outputURL else {
            throw ExportError.noOutputLocation
        }
        let project = project.sanitizedForUse()
        let profile = Self.sanitizedProfile(profile)
        
        await MainActor.run {
            isExporting = true
            progress = 0
        }
        setCancellationRequested(false)
        
        await estimateFileSize(for: project, profile: profile)

        do {
            let url: URL
            if profile.format == .gif {
                url = try await exportGIF(project: project, profile: profile, outputURL: finalURL)
            } else {
                url = try await exportVideo(project: project, profile: profile, outputURL: finalURL)
            }
            await finishExportState()
            return url
        } catch {
            await finishExportState()
            throw error
        }
    }
    
    private func exportVideo(
        project: RecordingProject,
        profile: ExportProfile,
        outputURL: URL
    ) async throws -> URL {
        let renderedVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rendered-\(UUID().uuidString).\(profile.format.rawValue)")
        defer {
            try? FileManager.default.removeItem(at: renderedVideoURL)
        }

        let sourceAsset = AVAsset(url: project.videoFileURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        guard sourceDuration.isFinite, sourceDuration > 0 else { throw ExportError.renderingFailed }
        let timeline = makeRenderTimeline(project: project, sourceDuration: sourceDuration)
        let renderedDuration = timeline.last.map { $0.outputStart + $0.outputDuration } ?? sourceDuration
        guard renderedDuration.isFinite, renderedDuration > 0 else { throw ExportError.renderingFailed }

        try removeExistingFile(at: renderedVideoURL)
        let writer = try AVAssetWriter(outputURL: renderedVideoURL, fileType: fileType(for: profile))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: profile.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: profile.width,
            AVVideoHeightKey: profile.height,
            AVVideoCompressionPropertiesKey: videoCompressionProperties(for: profile)
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else { throw ExportError.renderingFailed }
        writer.add(videoInput)
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: profile.width,
                kCVPixelBufferHeightKey as String: profile.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? ExportError.renderingFailed
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int(ceil(renderedDuration * Double(profile.fps))))
        let sourceSize = normalizedSourceSize(for: project)
        let zoomSegments = effectiveZoomSegments(for: project, sourceSize: sourceSize)
        let transforms = zoomTransformer.generateTransforms(
            zoomSegments: zoomSegments,
            sourceSize: sourceSize,
            outputSize: CGSize(width: profile.width, height: profile.height),
            duration: sourceDuration,
            fps: Double(profile.fps),
            orientation: profile.orientation
        )
        let smoothedCursor = loadSmoothedCursor(for: project, fps: Double(profile.fps))
        let keyEvents = loadKeyEvents(for: project)
        let captionSegments = loadCaptionSegments(for: project)

        guard let pool = pixelBufferAdaptor.pixelBufferPool else {
            throw ExportError.renderingFailed
        }

        let context = RenderContext(
            project: project,
            transforms: transforms,
            smoothedCursor: smoothedCursor,
            keyEvents: keyEvents,
            captionSegments: captionSegments,
            timeline: timeline,
            sourceSize: sourceSize,
            width: profile.width,
            height: profile.height,
            fps: profile.fps,
            bufferPool: pool
        )

        // One worker per logical core. Source frames are decoded once, serially, by a
        // single AVAssetReader-backed FrameSource (~34× faster than per-frame
        // copyCGImage); compositing runs in parallel across the workers.
        let workerCount = max(1, workerCountOverride ?? ProcessInfo.processInfo.activeProcessorCount)
        let frameSource = await FrameSource(asset: sourceAsset, sourceSize: sourceSize)
        let telemetry = ExportTelemetry(total: totalFrames)
        await MainActor.run { self.coresInUse = workerCount }

        let checkCancel: @Sendable () throws -> Void = {
            try self.checkCancellation()
        }

        let writerSink = WriterSink(
            videoInput: videoInput,
            adaptor: pixelBufferAdaptor,
            writer: writer,
            fps: profile.fps,
            checkCancellation: checkCancel
        )

        let pipeline = ParallelFramePipeline<RenderWorker>(
            workerCount: workerCount,
            makeWorker: { [webcamURL = project.webcamFileURL] in
                let webcamAsset = webcamURL.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? AVAsset(url: $0) : nil
                }
                return Self.makeVideoRenderWorker(webcamAsset: webcamAsset)
            },
            decode: { frameIndex in
                let outputTime = Double(frameIndex) / Double(context.fps)
                let sourceTime = self.sourceTime(for: outputTime, timeline: context.timeline)
                return frameSource.frame(at: sourceTime)
            },
            render: { worker, frameIndex, sourceFrame in
                try autoreleasepool {
                    try self.renderVideoFrame(
                        worker: worker,
                        frameIndex: frameIndex,
                        sourceFrame: sourceFrame,
                        context: context
                    )
                }
            },
            sink: { frameIndex, buffer in
                try await writerSink.append(buffer, frameIndex: frameIndex)
            }
        )

        try await pipeline.run(
            frameCount: totalFrames,
            isCancelled: checkCancel,
            onProgress: { framesCompleted in
                telemetry.add(framesCompleted)
                let snapshot = telemetry.snapshot
                Task { @MainActor in
                    self.progress = snapshot.progress
                    self.renderedFPS = snapshot.fps
                    self.estimatedTimeRemaining = snapshot.eta
                }
            }
        )

        try checkCancellation()
        videoInput.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.renderingFailed
        }

        return try await muxAudioIfNeeded(
            renderedVideoURL: renderedVideoURL,
            project: project,
            outputURL: outputURL,
            profile: profile,
            timeline: timeline,
            renderedDuration: CMTime(seconds: renderedDuration, preferredTimescale: 600)
        )
    }
    
    private func exportGIF(
        project: RecordingProject,
        profile: ExportProfile,
        outputURL: URL
    ) async throws -> URL {
        try removeExistingFile(at: outputURL)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let sourceAsset = AVAsset(url: project.videoFileURL)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        guard sourceDuration.isFinite, sourceDuration > 0 else { throw ExportError.renderingFailed }
        let timeline = makeRenderTimeline(project: project, sourceDuration: sourceDuration)
        let renderedDuration = timeline.last.map { $0.outputStart + $0.outputDuration } ?? sourceDuration
        guard renderedDuration.isFinite, renderedDuration > 0 else { throw ExportError.renderingFailed }

        let frameDuration = 1.0 / Double(profile.fps)
        let totalFrames = max(1, Int(ceil(renderedDuration * Double(profile.fps))))
        let outputSize = CGSize(width: profile.width, height: profile.height)
        let sourceSize = normalizedSourceSize(for: project)
        let zoomSegments = effectiveZoomSegments(for: project, sourceSize: sourceSize)
        let transforms = zoomTransformer.generateTransforms(
            zoomSegments: zoomSegments,
            sourceSize: sourceSize,
            outputSize: outputSize,
            duration: sourceDuration,
            fps: Double(profile.fps),
            orientation: profile.orientation
        )
        let smoothedCursor = loadSmoothedCursor(for: project, fps: Double(profile.fps))
        let keyEvents = loadKeyEvents(for: project)
        let captionSegments = loadCaptionSegments(for: project)

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, totalFrames, nil) else {
            throw ExportError.renderingFailed
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration
            ]
        ]

        let context = RenderContext(
            project: project,
            transforms: transforms,
            smoothedCursor: smoothedCursor,
            keyEvents: keyEvents,
            captionSegments: captionSegments,
            timeline: timeline,
            sourceSize: sourceSize,
            width: profile.width,
            height: profile.height,
            fps: profile.fps,
            bufferPool: nil
        )

        let workerCount = max(1, workerCountOverride ?? ProcessInfo.processInfo.activeProcessorCount)
        let frameSource = await FrameSource(asset: sourceAsset, sourceSize: sourceSize)
        let telemetry = ExportTelemetry(total: totalFrames)
        await MainActor.run { self.coresInUse = workerCount }

        let gifSink = GifSink(
            destination: destination,
            ciContext: ciContext,
            outputSize: outputSize,
            frameProperties: frameProperties as CFDictionary
        )

        let checkCancel: @Sendable () throws -> Void = {
            try self.checkCancellation()
        }

        let pipeline = ParallelFramePipeline<RenderWorker>(
            workerCount: workerCount,
            makeWorker: { [webcamURL = project.webcamFileURL] in
                let webcamAsset = webcamURL.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? AVAsset(url: $0) : nil
                }
                return Self.makeVideoRenderWorker(webcamAsset: webcamAsset)
            },
            decode: { frameIndex in
                let outputTime = Double(frameIndex) / Double(context.fps)
                let sourceTime = self.sourceTime(for: outputTime, timeline: context.timeline)
                return frameSource.frame(at: sourceTime)
            },
            render: { worker, frameIndex, sourceFrame in
                try autoreleasepool {
                    try self.renderGifFrame(
                        worker: worker,
                        frameIndex: frameIndex,
                        sourceFrame: sourceFrame,
                        context: context
                    )
                }
            },
            sink: { _, buffer in
                try gifSink.add(buffer)
            }
        )

        try await pipeline.run(
            frameCount: totalFrames,
            isCancelled: checkCancel,
            onProgress: { framesCompleted in
                telemetry.add(framesCompleted)
                let snapshot = telemetry.snapshot
                Task { @MainActor in
                    self.progress = snapshot.progress * 0.8
                    self.renderedFPS = snapshot.fps
                    self.estimatedTimeRemaining = snapshot.eta
                }
            }
        )

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.renderingFailed
        }

        await setProgress(1.0)
        completed = true
        return outputURL
    }

    private func normalizedSourceSize(for project: RecordingProject) -> CGSize {
        let size = project.sourceRect.size
        guard size.width > 0, size.height > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        return size
    }

    private func loadSmoothedCursor(for project: RecordingProject, fps: Double) -> [CursorFrame] {
        guard let cursorRecording = loadRenderSpaceCursorRecording(for: project) else {
            return []
        }

        return cursorSmoother.smooth(
            frames: cursorRecording.frames,
            style: project.style.cursorStyle,
            targetFPS: fps
        )
    }

    private func loadRenderSpaceCursorRecording(for project: RecordingProject) -> CursorRecording? {
        guard Self.fileIsLoadable(project.cursorDataFileURL, maxBytes: Self.maxCursorDataFileBytes),
              let data = try? Data(contentsOf: project.cursorDataFileURL),
              let cursorRecording = try? JSONDecoder().decode(CursorRecording.self, from: data).sanitizedForUse() else {
            return nil
        }

        return CursorCoordinateMapper.toRenderSpace(
            cursorRecording,
            sourceSize: normalizedSourceSize(for: project),
            displayID: project.displayID == 0 ? nil : project.displayID
        )
    }

    private func effectiveZoomSegments(
        for project: RecordingProject,
        sourceSize: CGSize
    ) -> [ZoomSegment] {
        guard project.zoomSegments.isEmpty || project.zoomSegments.allSatisfy({ $0.source == .automatic }),
              let cursorRecording = loadRenderSpaceCursorRecording(for: project),
              !cursorRecording.frames.isEmpty else {
            return project.zoomSegments
        }

        return autoZoomCalculator.calculateZoomSegments(
            from: cursorRecording,
            sourceRect: CGRect(origin: .zero, size: sourceSize),
            config: AutoZoomCalculator.Config(maxZoomScale: project.style.autoZoomScale)
        )
    }

    private func loadKeyEvents(for project: RecordingProject) -> [KeyPressEvent] {
        guard let url = project.keyEventsFileURL,
              Self.fileIsLoadable(url, maxBytes: Self.maxKeyEventsFileBytes),
              let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([KeyPressEvent].self, from: data) else {
            return []
        }
        return KeyPressEvent.sanitized(events)
    }

    private func loadCaptionSegments(for project: RecordingProject) -> [CaptionSegment] {
        guard let url = project.captionsFileURL,
              FileManager.default.fileExists(atPath: url.path),
              Self.fileIsLoadable(url, maxBytes: Self.maxCaptionFileBytes),
              let data = try? Data(contentsOf: url),
              let segments = try? JSONDecoder().decode([CaptionSegment].self, from: data) else {
            return []
        }
        return segments
    }

    private static func fileIsLoadable(_ url: URL, maxBytes: UInt64) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.uint64Value <= maxBytes
    }

    private func activeSubtitle(
        at time: Double,
        segments: [CaptionSegment],
        enabled: Bool
    ) -> String? {
        guard enabled else { return nil }
        return segments.first { time >= $0.start && time <= $0.end }?.text
    }

    private func transformVelocity(at index: Int, transforms: [FrameTransform]) -> CGPoint {
        guard transforms.indices.contains(index), transforms[index].isTransitioning, index > 0 else {
            return .zero
        }

        let current = transforms[index].transform
        let previous = transforms[index - 1].transform
        return CGPoint(
            x: current.tx - previous.tx,
            y: current.ty - previous.ty
        )
    }

    private func transformVelocity(at time: Double, transforms: [FrameTransform]) -> CGPoint {
        let current = frameTransform(at: time, transforms: transforms)
        guard current.isTransitioning else { return .zero }
        let previous = frameTransform(at: max(0, time - 1.0 / 60.0), transforms: transforms)
        return CGPoint(
            x: current.transform.tx - previous.transform.tx,
            y: current.transform.ty - previous.transform.ty
        )
    }

    private func frameTransform(at time: Double, transforms: [FrameTransform]) -> FrameTransform {
        guard !transforms.isEmpty else {
            return FrameTransform(
                timestamp: 0,
                transform: .identity,
                sourceRect: .zero,
                scale: 1,
                isTransitioning: false,
                transitionProgress: 0
            )
        }

        var low = 0
        var high = transforms.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if transforms[mid].timestamp <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if let match {
            return transforms[match]
        }
        return transforms[0]
    }

    private func loadWebcamFrame(at time: Double, generator: AVAssetImageGenerator?) -> CIImage? {
        guard let generator else { return nil }

        do {
            let image = try generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600),
                actualTime: nil
            )
            return CIImage(cgImage: image)
        } catch {
            return nil
        }
    }

    private func shouldShowCursor(
        at time: Double,
        cursorData: CursorFrame?,
        frames: [CursorFrame],
        style: StylePreset,
        project: RecordingProject,
        clickProgress: Double?,
        visibilityOverride: EffectOverride
    ) -> Bool {
        guard let cursorData else { return false }
        if project.editActions.contains(where: { $0.type == .hideCursor && $0.intersects(time: time) }) {
            return false
        }
        if visibilityOverride == .off { return false }
        if visibilityOverride == .on { return true }
        guard style.hideStaticCursor else { return true }
        if cursorData.isClicking { return true }
        if clickProgress != nil { return true }

        guard let previous = cursorFrame(at: max(0, time - 0.5), frames: frames) else {
            return true
        }

        return BezierMath.distance(from: previous.position, to: cursorData.position) > 2
    }

    private func activeOverlays(at time: Double, project: RecordingProject) -> [OverlayElement] {
        (project.overlayElements ?? []).filter { $0.intersects(time: time) }
    }

    private func activeTitleCards(at time: Double, project: RecordingProject) -> [TitleCardSegment] {
        (project.titleCardSegments ?? []).filter { $0.intersects(time: time) }
    }

    private func activeCameraLayoutMode(at time: Double, project: RecordingProject, webcamEnabled: Bool? = nil) -> CameraLayoutMode {
        guard (webcamEnabled ?? project.webcamEnabled), project.webcamFileURL != nil else {
            return .screenOnly
        }
        return (project.cameraLayoutSegments ?? [])
            .sorted { $0.startTime < $1.startTime }
            .last(where: { $0.intersects(time: time) })?
            .mode ?? .defaultOverlay
    }

    private func clickAnimationProgress(at time: Double, frames: [CursorFrame]) -> Double? {
        let preRoll = 0.22
        let postRoll = 0.66
        let lowerBound = time - postRoll
        let upperBound = time + preRoll
        guard let upperIndex = lastFrameIndex(at: upperBound, frames: frames) else {
            return nil
        }

        var bestClick: CursorFrame?
        var index = upperIndex
        while index >= 0 {
            let frame = frames[index]
            if frame.timestamp < lowerBound { break }
            if isClickDown(frame),
               bestClick.map({ abs(frame.timestamp - time) < abs($0.timestamp - time) }) ?? true {
                bestClick = frame
            }
            index -= 1
        }

        guard let click = bestClick else { return nil }
        let delta = time - click.timestamp
        if delta < 0 {
            return max(-1, delta / preRoll)
        }
        return min(1, delta / postRoll)
    }

    private func isClickDown(_ frame: CursorFrame) -> Bool {
        CursorClickClassifier.isClickDown(frame)
    }

    private func cursorFrame(at time: Double, frames: [CursorFrame]) -> CursorFrame? {
        guard let index = lastFrameIndex(at: time, frames: frames) else { return nil }
        return frames[index]
    }

    private func lastFrameIndex(at time: Double, frames: [CursorFrame]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count - 1
        var match: Int?

        while low <= high {
            let mid = (low + high) / 2
            if frames[mid].timestamp <= time {
                match = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return match
    }

    private func activeShortcuts(
        at time: Double,
        events: [KeyPressEvent],
        style: StylePreset
    ) -> [KeyPressEvent] {
        KeyboardShortcutDisplayFilter.activeShortcuts(
            at: time,
            events: events,
            style: style
        )
    }

    private struct RenderTimelineSegment {
        let sourceStart: Double
        let sourceEnd: Double
        let outputStart: Double
        let speed: Double

        var sourceDuration: Double { sourceEnd - sourceStart }
        var outputDuration: Double { sourceDuration / speed }
    }

    private func makeRenderTimeline(project: RecordingProject, sourceDuration: Double) -> [RenderTimelineSegment] {
        let boundaries = ([0, sourceDuration] + project.editActions.flatMap { action in
            [max(0, min(sourceDuration, action.startTime)), max(0, min(sourceDuration, action.endTime))]
        })
        .filter { $0.isFinite }
        .sorted()

        let uniqueBoundaries = boundaries.reduce(into: [Double]()) { result, value in
            if result.last.map({ abs($0 - value) > 0.001 }) ?? true {
                result.append(value)
            }
        }

        var segments: [RenderTimelineSegment] = []
        var outputCursor = 0.0

        for index in 0..<(uniqueBoundaries.count - 1) {
            let start = uniqueBoundaries[index]
            let end = uniqueBoundaries[index + 1]
            guard end - start > 0.001 else { continue }
            let midpoint = (start + end) / 2

            if project.editActions.contains(where: { $0.type == .cut && $0.intersects(time: midpoint) }) {
                continue
            }

            let speed = speedMultiplier(at: midpoint, actions: project.editActions)
            let segment = RenderTimelineSegment(
                sourceStart: start,
                sourceEnd: end,
                outputStart: outputCursor,
                speed: speed
            )
            segments.append(segment)
            outputCursor += segment.outputDuration
        }

        if segments.isEmpty {
            return [RenderTimelineSegment(sourceStart: 0, sourceEnd: sourceDuration, outputStart: 0, speed: 1)]
        }
        return segments
    }

    private func timelineOutputDuration(_ timeline: [RenderTimelineSegment], fallback: Double) -> Double {
        let candidate = timeline.last.map { $0.outputStart + $0.outputDuration } ?? fallback
        if candidate.isFinite, candidate > 0 {
            return candidate
        }
        return fallback.isFinite && fallback > 0 ? fallback : 0
    }

    private func sourceTime(for outputTime: Double, timeline: [RenderTimelineSegment]) -> Double {
        for segment in timeline {
            let outputEnd = segment.outputStart + segment.outputDuration
            if outputTime >= segment.outputStart && outputTime <= outputEnd {
                return min(segment.sourceEnd, segment.sourceStart + (outputTime - segment.outputStart) * segment.speed)
            }
        }
        return timeline.last?.sourceEnd ?? outputTime
    }

    private func speedMultiplier(at time: Double, actions: [EditAction]) -> Double {
        let speedActions = actions
            .filter { $0.type == .speedChange && $0.intersects(time: time) }
            .sorted { $0.createdAt > $1.createdAt }
        guard let value = speedActions.first?.value, value.isFinite else {
            return 1.0
        }
        return max(0.25, min(4.0, value))
    }

    private func muxAudioIfNeeded(
        renderedVideoURL: URL,
        project: RecordingProject,
        outputURL: URL,
        profile: ExportProfile,
        timeline: [RenderTimelineSegment],
        renderedDuration: CMTime
    ) async throws -> URL {
        try removeExistingFile(at: outputURL)
        var completed = false
        var preparedAudioURL: URL?
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
            if let preparedAudioURL {
                try? FileManager.default.removeItem(at: preparedAudioURL)
            }
            try? FileManager.default.removeItem(at: renderedVideoURL)
        }

        let composition = AVMutableComposition()
        let renderedAsset = AVAsset(url: renderedVideoURL)
        let actualRenderedDuration = try await renderedAsset.load(.duration)
        let safeRenderedDuration = minCMTime(renderedDuration, actualRenderedDuration)

        guard let renderedVideoTrack = try await renderedAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.renderingFailed
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: safeRenderedDuration),
            of: renderedVideoTrack,
            at: .zero
        )

        let preparedAudio = try await prepareFinalAudioFile(
            for: project,
            timeline: timeline
        )

        guard let preparedAudio else {
            try FileManager.default.moveItem(at: renderedVideoURL, to: outputURL)
            await setProgress(1.0)
            completed = true
            return outputURL
        }
        preparedAudioURL = preparedAudio.url

        let preparedAudioAsset = AVAsset(url: preparedAudio.url)
        guard let preparedAudioTrack = try await preparedAudioAsset.loadTracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            try FileManager.default.moveItem(at: renderedVideoURL, to: outputURL)
            await setProgress(1.0)
            completed = true
            return outputURL
        }

        let preparedAudioDuration = try await preparedAudioAsset.load(.duration)
        let audioDuration = minCMTime(safeRenderedDuration, preparedAudioDuration)
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: preparedAudioTrack,
            at: .zero
        )

        try await exportMuxedComposition(composition, outputURL: outputURL, profile: profile)
        await setProgress(1.0)
        completed = true
        return outputURL
    }

    private func exportMuxedComposition(
        _ composition: AVMutableComposition,
        outputURL: URL,
        profile: ExportProfile
    ) async throws {
        let fileType = fileType(for: profile)

        do {
            try await runConfiguredExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough,
                outputURL: outputURL,
                outputFileType: fileType,
                shouldOptimizeForNetworkUse: true
            )
            return
        } catch {
            if error is CancellationError { throw error }
            try? FileManager.default.removeItem(at: outputURL)
        }

        try await runConfiguredExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality,
            outputURL: outputURL,
            outputFileType: fileType,
            shouldOptimizeForNetworkUse: true
        )
    }

    private func minCMTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        guard lhs.isValid, rhs.isValid, lhs.seconds.isFinite, rhs.seconds.isFinite else {
            return lhs.isValid ? lhs : rhs
        }
        return lhs <= rhs ? lhs : rhs
    }

    private struct PreparedAudioFile {
        let url: URL
    }

    private struct PreparedAudioTrack {
        let url: URL
        let volumeAutomation: [AudioVolumeRange]
        let isTemporary: Bool
    }

    private struct AudioVolumeRange {
        let start: Double
        let end: Double
        let volume: Float
    }

    private struct AudioVolumePoint {
        let time: Double
        let volume: Float
    }

    private func prepareFinalAudioFile(
        for project: RecordingProject,
        timeline: [RenderTimelineSegment]
    ) async throws -> PreparedAudioFile? {
        var preparedTracks: [PreparedAudioTrack] = []
        let outputDuration = timelineOutputDuration(timeline, fallback: project.duration.seconds)

        let screenAudioURL = project.systemAudioFileURL ?? project.videoFileURL
        if let editedSourceAudio = try? await renderEditedAudioTrack(from: screenAudioURL, timeline: timeline) {
            // Boost >1× is applied as real PCM gain because AVAudioMix caps at 1.0.
            let requestedVolume = project.style.sourceAudioVolume
            let boostedSource = await boostedTrack(editedSourceAudio, volume: requestedVolume)
            preparedTracks.append(PreparedAudioTrack(
                url: boostedSource,
                volumeAutomation: volumeAutomation(
                    for: project,
                    timeline: timeline,
                    baseVolume: min(requestedVolume, 1),
                    volume: { min($0.sourceAudioVolume, 1) }
                ),
                isTemporary: true
            ))
        }

        if let micURL = project.micAudioFileURL,
           let editedMicAudio = try? await renderEditedAudioTrack(from: micURL, timeline: timeline) {
            var finalMicAudio: URL
            if project.style.micNoiseReductionEnabled,
               let processedMicURL = try? await AudioProcessor().applyNoiseGate(
                    inputURL: editedMicAudio,
                    outputURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("mic-denoised-\(UUID().uuidString).m4a"),
                    threshold: project.style.micNoiseGateThreshold
               ) {
                try? FileManager.default.removeItem(at: editedMicAudio)
                finalMicAudio = processedMicURL
            } else {
                finalMicAudio = editedMicAudio
            }
            // Boost >1× is applied as real PCM gain because AVAudioMix caps at 1.0.
            let requestedMicVolume = project.style.micAudioVolume
            finalMicAudio = await boostedTrack(finalMicAudio, volume: requestedMicVolume)
            preparedTracks.append(PreparedAudioTrack(
                url: finalMicAudio,
                volumeAutomation: volumeAutomation(
                    for: project,
                    timeline: timeline,
                    baseVolume: min(requestedMicVolume, 1),
                    volume: { min($0.micAudioVolume, 1) }
                ),
                isTemporary: true
            ))
        }

        if let musicTrack = try? await renderBackgroundMusicTrack(
            for: project,
            timeline: timeline,
            duration: outputDuration
        ) {
            preparedTracks.append(PreparedAudioTrack(
                url: musicTrack.url,
                volumeAutomation: [AudioVolumeRange(
                    start: 0,
                    end: outputDuration,
                    volume: 1
                )],
                isTemporary: true
            ))
        }

        if project.style.clickSoundEnabled,
           let clickTrack = try renderClickSoundTrack(for: project, timeline: timeline) {
            preparedTracks.append(PreparedAudioTrack(
                url: clickTrack.url,
                volumeAutomation: [AudioVolumeRange(start: 0, end: outputDuration, volume: 1)],
                isTemporary: true
            ))
        }

        if project.style.keyboardSoundEnabled,
           let keyboardTrack = try renderKeyboardSoundTrack(for: project, timeline: timeline) {
            preparedTracks.append(PreparedAudioTrack(
                url: keyboardTrack.url,
                volumeAutomation: [AudioVolumeRange(start: 0, end: outputDuration, volume: 1)],
                isTemporary: true
            ))
        }

        guard !preparedTracks.isEmpty else { return nil }

        if preparedTracks.count == 1,
           let onlyTrack = preparedTracks.first,
           isConstantUnityAutomation(onlyTrack.volumeAutomation) {
            return PreparedAudioFile(url: onlyTrack.url)
        }

        let mixedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed-audio-\(UUID().uuidString).m4a")
        do {
            try await mixAudioTracks(
                trackURLs: preparedTracks.map(\.url),
                outputURL: mixedURL,
                volumeAutomations: preparedTracks.map(\.volumeAutomation)
            )
        } catch {
            for temporaryTrack in preparedTracks where temporaryTrack.isTemporary {
                try? FileManager.default.removeItem(at: temporaryTrack.url)
            }
            throw error
        }

        for temporaryTrack in preparedTracks where temporaryTrack.isTemporary {
            try? FileManager.default.removeItem(at: temporaryTrack.url)
        }
        return PreparedAudioFile(url: mixedURL)
    }

    private func renderBackgroundMusicTrack(
        for project: RecordingProject,
        timeline: [RenderTimelineSegment],
        duration: Double
    ) async throws -> PreparedAudioFile? {
        guard let musicURL = project.style.backgroundMusicURL,
              FileManager.default.fileExists(atPath: musicURL.path),
              duration.isFinite,
              duration > 0 else {
            return nil
        }

        let asset = AVAsset(url: musicURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.seconds.isFinite, sourceDuration.seconds > 0 else {
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        let outputDuration = CMTime(seconds: duration, preferredTimescale: 600)
        var cursor = CMTime.zero
        repeat {
            let remaining = outputDuration - cursor
            let insertDuration = minCMTime(sourceDuration, remaining)
            guard insertDuration.seconds > 0 else { break }

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: track,
                at: cursor
            )

            cursor = cursor + insertDuration
        } while project.style.backgroundMusicLoop && cursor < outputDuration

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-\(UUID().uuidString).m4a")
        try removeExistingFile(at: outputURL)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: compositionTrack)
        configureBackgroundMusicMix(
            params,
            project: project,
            timeline: timeline,
            duration: duration
        )
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [params]

        export.outputURL = outputURL
        export.outputFileType = .m4a
        export.audioMix = audioMix
        try await runExportSession(export)

        return PreparedAudioFile(url: outputURL)
    }

    private func configureBackgroundMusicMix(
        _ params: AVMutableAudioMixInputParameters,
        project: RecordingProject,
        timeline: [RenderTimelineSegment],
        duration: Double
    ) {
        let baseVolume = Self.clampedAudioVolume(project.style.backgroundMusicVolume)
        let automation = volumeAutomation(
            for: project,
            timeline: timeline,
            baseVolume: project.style.backgroundMusicVolume,
            volume: { $0.backgroundMusicVolume }
        )
        let duckVolume = min(Self.clampedAudioVolume(project.style.backgroundMusicDuckingVolume), baseVolume)
        params.setVolume(baseVolume, at: .zero)

        guard isConstantAutomation(automation, volume: baseVolume, duration: duration) else {
            applyVolumeAutomation(automation, to: params, fallbackVolume: baseVolume)
            return
        }

        let fadeIn = min(max(project.style.backgroundMusicFadeIn, 0), max(duration, 0))
        if fadeIn > 0.01 {
            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: baseVolume,
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                )
            )
        }

        let fadeOut = min(max(project.style.backgroundMusicFadeOut, 0), max(duration, 0))
        if fadeOut > 0.01 {
            params.setVolumeRamp(
                fromStartVolume: baseVolume,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: max(0, duration - fadeOut), preferredTimescale: 600),
                    duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                )
            )
        }

        if project.style.backgroundMusicDuckingEnabled, duckVolume < baseVolume {
            let captionSegments = loadCaptionSegments(for: project)
            for segment in captionSegments {
                guard let start = outputTime(forSourceTime: segment.start, timeline: timeline),
                      let end = outputTime(forSourceTime: segment.end, timeline: timeline),
                      end > start else {
                    continue
                }

                let duckStart = max(0, start - 0.12)
                let duckEnd = min(duration, end + 0.18)
                let attack = min(0.12, max(0.02, duckEnd - duckStart))
                let release = min(0.18, max(0.02, duckEnd - duckStart))

                params.setVolumeRamp(
                    fromStartVolume: baseVolume,
                    toEndVolume: duckVolume,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: duckStart, preferredTimescale: 600),
                        duration: CMTime(seconds: attack, preferredTimescale: 600)
                    )
                )
                params.setVolume(
                    duckVolume,
                    at: CMTime(seconds: min(duration, duckStart + attack), preferredTimescale: 600)
                )
                if duckEnd - release > duckStart + attack {
                    params.setVolume(
                        duckVolume,
                        at: CMTime(seconds: duckEnd - release, preferredTimescale: 600)
                    )
                }
                params.setVolumeRamp(
                    fromStartVolume: duckVolume,
                    toEndVolume: baseVolume,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: max(0, duckEnd - release), preferredTimescale: 600),
                        duration: CMTime(seconds: release, preferredTimescale: 600)
                    )
                )
            }
        }
    }

    private func renderClickSoundTrack(
        for project: RecordingProject,
        timeline: [RenderTimelineSegment]
    ) throws -> PreparedAudioFile? {
        guard let recording = loadRenderSpaceCursorRecording(for: project) else { return nil }
        let clickTimes = debouncedClickTimes(from: recording.frames)
            .filter { EffectSegmentResolver.resolve(project: project, at: $0).style.clickSoundEnabled }
            .compactMap { outputTime(forSourceTime: $0, timeline: timeline) }

        guard !clickTimes.isEmpty else { return nil }

        return try renderEffectTrack(
            times: clickTimes,
            duration: timelineOutputDuration(timeline, fallback: project.duration.seconds),
            volume: project.style.clickSoundVolume,
            prefix: "clicks",
            fileURL: SoundEffectLibrary.clickURL(
                style: project.style.clickSoundStyle,
                customURL: project.style.clickSoundFileURL
            ),
            maxEffectDuration: 0.32
        ) { startFrame, channel, totalFrames, sampleRate, volume in
            ClickSoundSynthesizer.addClickSound(
                at: startFrame,
                channel: channel,
                totalFrames: totalFrames,
                sampleRate: sampleRate,
                volume: volume,
                style: project.style.clickSoundStyle
            )
        }
    }

    private func renderKeyboardSoundTrack(
        for project: RecordingProject,
        timeline: [RenderTimelineSegment]
    ) throws -> PreparedAudioFile? {
        let keyTimes = debouncedKeyTimes(from: loadKeyEvents(for: project))
            .filter { EffectSegmentResolver.resolve(project: project, at: $0).style.keyboardSoundEnabled }
            .compactMap { outputTime(forSourceTime: $0, timeline: timeline) }

        guard !keyTimes.isEmpty else { return nil }

        return try renderEffectTrack(
            times: keyTimes,
            duration: timelineOutputDuration(timeline, fallback: project.duration.seconds),
            volume: project.style.keyboardSoundVolume,
            prefix: "keys",
            fileURL: SoundEffectLibrary.keyboardURL(
                style: project.style.keyboardSoundStyle,
                customURL: project.style.keyboardSoundFileURL
            ),
            maxEffectDuration: 0.24
        ) { startFrame, channel, totalFrames, sampleRate, volume in
            ClickSoundSynthesizer.addClickSound(
                at: startFrame,
                channel: channel,
                totalFrames: totalFrames,
                sampleRate: sampleRate,
                volume: volume,
                style: project.style.keyboardSoundStyle.fallbackClickStyle
            )
        }
    }

    private func renderEffectTrack(
        times: [Double],
        duration: Double,
        volume: Float,
        prefix: String,
        fileURL: URL?,
        maxEffectDuration: Double,
        synthesize: (_ startFrame: Int, _ channel: UnsafeMutablePointer<Float>, _ totalFrames: Int, _ sampleRate: Double, _ volume: Float) -> Void
    ) throws -> PreparedAudioFile? {
        guard duration.isFinite, duration > 0 else { return nil }

        let sampleRate = SoundEffectMixer.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let safeTimes = times.filter { $0.isFinite && $0 >= 0 && $0 <= duration }
        guard !safeTimes.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let volume = Self.clampedAudioVolume(volume)
        let fileSamples = fileURL.flatMap {
            try? SoundEffectMixer.loadMonoSamples(
                from: $0,
                targetSampleRate: sampleRate,
                maxDuration: maxEffectDuration
            )
        }

        let totalFrames = max(1, Int(ceil(duration * sampleRate)))
        let synthesizedFrameCount = max(1, Int(ceil(maxEffectDuration * sampleRate)))
        let synthesizedSamples: [Float]? = {
            guard fileSamples == nil || fileSamples?.isEmpty == true else { return nil }
            var samples = Array(repeating: Float(0), count: synthesizedFrameCount)
            samples.withUnsafeMutableBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    synthesize(0, baseAddress, synthesizedFrameCount, sampleRate, volume)
                }
            }
            return samples
        }()
        let eventSamples: [Float]
        if let fileSamples, !fileSamples.isEmpty {
            eventSamples = fileSamples.map { max(-1, min(1, $0 * volume)) }
        } else {
            eventSamples = synthesizedSamples ?? []
        }
        guard !eventSamples.isEmpty else { return nil }

        let events = safeTimes
            .map { max(0, min(totalFrames - 1, Int($0 * sampleRate))) }
            .sorted()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).wav")
        try removeExistingFile(at: outputURL)
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings
        )

        let chunkCapacity = 131_072
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(chunkCapacity)
        ),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        var chunkStart = 0
        while chunkStart < totalFrames {
            try checkCancellation()
            let chunkFrames = min(chunkCapacity, totalFrames - chunkStart)
            let chunkEnd = chunkStart + chunkFrames
            buffer.frameLength = AVAudioFrameCount(chunkFrames)

            for index in 0..<chunkFrames {
                channel[index] = 0
            }

            for eventStart in events {
                if eventStart >= chunkEnd { break }
                let eventEnd = eventStart + eventSamples.count
                if eventEnd <= chunkStart { continue }

                let sampleStart = max(0, chunkStart - eventStart)
                let outputStart = max(0, eventStart - chunkStart)
                let copyCount = min(eventSamples.count - sampleStart, chunkFrames - outputStart)
                guard copyCount > 0 else { continue }

                for offset in 0..<copyCount {
                    let index = outputStart + offset
                    channel[index] = max(-1, min(1, channel[index] + eventSamples[sampleStart + offset]))
                }
            }

            try file.write(from: buffer)
            chunkStart += chunkFrames
        }
        return PreparedAudioFile(url: outputURL)
    }

    private func debouncedClickTimes(from frames: [CursorFrame]) -> [Double] {
        CursorClickClassifier.debouncedClickTimes(from: frames, minimumInterval: 0.12)
    }

    private func debouncedKeyTimes(from events: [KeyPressEvent]) -> [Double] {
        var times: [Double] = []
        var lastTime = -Double.infinity

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard event.timestamp.isFinite else { continue }
            if event.timestamp - lastTime >= 0.035 {
                times.append(event.timestamp)
                lastTime = event.timestamp
            }
        }

        return times
    }

    private func outputTime(
        forSourceTime sourceTime: Double,
        timeline: [RenderTimelineSegment]
    ) -> Double? {
        for segment in timeline where sourceTime >= segment.sourceStart && sourceTime <= segment.sourceEnd {
            return segment.outputStart + (sourceTime - segment.sourceStart) / segment.speed
        }
        return nil
    }

    private func outputRanges(
        sourceStart: Double,
        sourceEnd: Double,
        timeline: [RenderTimelineSegment]
    ) -> [(start: Double, end: Double)] {
        var ranges: [(Double, Double)] = []
        for segment in timeline {
            let start = max(sourceStart, segment.sourceStart)
            let end = min(sourceEnd, segment.sourceEnd)
            guard end - start > 0.001 else { continue }
            let outputStart = segment.outputStart + (start - segment.sourceStart) / segment.speed
            let outputEnd = segment.outputStart + (end - segment.sourceStart) / segment.speed
            if outputEnd > outputStart {
                ranges.append((outputStart, outputEnd))
            }
        }
        return ranges
    }

    private func volumeAutomation(
        for project: RecordingProject,
        timeline: [RenderTimelineSegment],
        baseVolume: Float,
        volume: (StylePreset) -> Float
    ) -> [AudioVolumeRange] {
        let effectSegments = project.effectSegments ?? []
        var ranges: [AudioVolumeRange] = []

        for segment in timeline {
            var boundaries = [segment.sourceStart, segment.sourceEnd]
            for effect in effectSegments where effect.overlaps(startTime: segment.sourceStart, endTime: segment.sourceEnd) {
                boundaries.append(max(segment.sourceStart, min(segment.sourceEnd, effect.startTime)))
                boundaries.append(max(segment.sourceStart, min(segment.sourceEnd, effect.endTime)))
            }
            boundaries.sort()

            var uniqueBoundaries: [Double] = []
            for boundary in boundaries where boundary.isFinite {
                if uniqueBoundaries.last.map({ abs($0 - boundary) > 0.001 }) ?? true {
                    uniqueBoundaries.append(boundary)
                }
            }

            for index in 0..<(uniqueBoundaries.count - 1) {
                let sourceStart = uniqueBoundaries[index]
                let sourceEnd = uniqueBoundaries[index + 1]
                guard sourceEnd - sourceStart > 0.001 else { continue }
                let midpoint = (sourceStart + sourceEnd) / 2
                let resolvedStyle = EffectSegmentResolver.resolve(project: project, at: midpoint).style
                let outputStart = segment.outputStart + (sourceStart - segment.sourceStart) / segment.speed
                let outputEnd = segment.outputStart + (sourceEnd - segment.sourceStart) / segment.speed
                ranges.append(AudioVolumeRange(
                    start: outputStart,
                    end: outputEnd,
                    volume: Self.clampedAudioVolume(volume(resolvedStyle))
                ))
            }
        }

        guard !ranges.isEmpty else {
            return [AudioVolumeRange(
                start: 0,
                end: timelineOutputDuration(timeline, fallback: project.duration.seconds),
                volume: Self.clampedAudioVolume(baseVolume)
            )]
        }
        return mergeVolumeRanges(ranges)
    }

    private func mergeVolumeRanges(_ ranges: [AudioVolumeRange]) -> [AudioVolumeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [AudioVolumeRange] = []

        for range in sorted {
            guard range.end > range.start else { continue }
            if let last = merged.last,
               abs(last.end - range.start) < 0.001,
               abs(last.volume - range.volume) < 0.001 {
                merged[merged.count - 1] = AudioVolumeRange(
                    start: last.start,
                    end: range.end,
                    volume: last.volume
                )
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func applyVolumeAutomation(
        _ automation: [AudioVolumeRange],
        to params: AVMutableAudioMixInputParameters,
        fallbackVolume: Float
    ) {
        let clampedFallback = Self.clampedAudioVolume(fallbackVolume)
        params.setVolume(clampedFallback, at: .zero)
        for point in volumeAutomationPoints(automation, fallbackVolume: clampedFallback) {
            params.setVolume(
                point.volume,
                at: CMTime(seconds: point.time, preferredTimescale: 600)
            )
        }
    }

    private func volumeAutomationPoints(
        _ automation: [AudioVolumeRange],
        fallbackVolume: Float
    ) -> [AudioVolumePoint] {
        var points: [AudioVolumePoint] = []
        let fallback = Self.clampedAudioVolume(fallbackVolume)
        var previousEnd = 0.0

        func appendPoint(time: Double, volume: Float) {
            guard time.isFinite else { return }
            let quantizedTime = max(0, (time * 600).rounded() / 600)
            let clampedVolume = Self.clampedAudioVolume(volume)
            if let last = points.last, abs(last.time - quantizedTime) < 0.000_1 {
                points[points.count - 1] = AudioVolumePoint(time: quantizedTime, volume: clampedVolume)
            } else {
                points.append(AudioVolumePoint(time: quantizedTime, volume: clampedVolume))
            }
        }

        for range in mergeVolumeRanges(automation) {
            let start = max(0, range.start)
            let end = max(start, range.end)
            guard end - start > 0.001 else { continue }
            if start > previousEnd + 0.001 {
                appendPoint(time: previousEnd, volume: fallback)
            }
            appendPoint(time: start, volume: range.volume)
            previousEnd = max(previousEnd, end)
        }

        if previousEnd > 0.001 {
            appendPoint(time: previousEnd, volume: fallback)
        }

        return points
    }

    private func isConstantUnityAutomation(_ automation: [AudioVolumeRange]) -> Bool {
        guard automation.count == 1, let only = automation.first else { return false }
        return only.start <= 0.001 && abs(only.volume - 1) < 0.001
    }

    private func isConstantAutomation(
        _ automation: [AudioVolumeRange],
        volume: Float,
        duration: Double
    ) -> Bool {
        let merged = mergeVolumeRanges(automation)
        guard merged.count == 1, let only = merged.first else { return false }
        let clampedVolume = Self.clampedAudioVolume(volume)
        return only.start <= 0.001
            && only.end >= max(0, duration) - 0.001
            && abs(only.volume - clampedVolume) < 0.001
    }

    private func renderEditedAudioTrack(
        from url: URL,
        timeline: [RenderTimelineSegment]
    ) async throws -> URL? {
        let asset = AVAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let availableDuration = try await asset.load(.duration).seconds
        guard availableDuration.isFinite, availableDuration > 0,
              let track = audioTracks.first else {
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        var addedAudio = false
        for segment in timeline {
            let sourceStart = min(segment.sourceStart, availableDuration)
            let sourceEnd = min(segment.sourceEnd, availableDuration)
            guard sourceEnd > sourceStart else { continue }

            let sourceDuration = sourceEnd - sourceStart
            let outputDuration = sourceDuration / segment.speed
            let insertedRange = CMTimeRange(
                start: CMTime(seconds: segment.outputStart, preferredTimescale: 600),
                duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)
            )

            try compositionTrack.insertTimeRange(
                CMTimeRange(
                    start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: sourceDuration, preferredTimescale: 600)
                ),
                of: track,
                at: insertedRange.start
            )

            if abs(segment.speed - 1.0) > 0.001 {
                compositionTrack.scaleTimeRange(
                    insertedRange,
                    toDuration: CMTime(seconds: outputDuration, preferredTimescale: 600)
                )
            }
            addedAudio = true
        }

        guard addedAudio else { return nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edited-audio-\(UUID().uuidString).mov")
        try removeExistingFile(at: outputURL)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.renderingFailed
        }

        export.outputURL = outputURL
        export.outputFileType = .mov
        try await runExportSession(export)

        return outputURL
    }

    /// Applies real PCM gain when a track's volume exceeds 1× (AVAudioMix caps at 1.0).
    private func boostedTrack(_ url: URL, volume: Float) async -> URL {
        guard volume > 1.001 else { return url }
        let boostedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-boosted-\(UUID().uuidString).m4a")
        do {
            let result = try await AudioProcessor().applyLinearGain(
                inputURL: url,
                outputURL: boostedURL,
                gain: volume
            )
            try? FileManager.default.removeItem(at: url)
            return result
        } catch {
            print("Track boost failed, using unboosted audio: \(error)")
            try? FileManager.default.removeItem(at: boostedURL)
            return url
        }
    }

    private func mixAudioTracks(
        trackURLs: [URL],
        outputURL: URL,
        volumeAutomations: [[AudioVolumeRange]]
    ) async throws {
        try removeExistingFile(at: outputURL)

        let composition = AVMutableComposition()
        var inputParameters: [AVAudioMixInputParameters] = []

        for (index, trackURL) in trackURLs.enumerated() {
            let asset = AVAsset(url: trackURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else { continue }

            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid + Int32(index)
            ) else { continue }

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: .zero
            )

            let params = AVMutableAudioMixInputParameters(track: compositionTrack)
            let automation = index < volumeAutomations.count ? volumeAutomations[index] : [AudioVolumeRange(
                start: 0,
                end: duration.seconds,
                volume: 1
            )]
            applyVolumeAutomation(automation, to: params, fallbackVolume: 1)
            inputParameters.append(params)
        }

        guard !inputParameters.isEmpty else {
            throw ExportError.renderingFailed
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.renderingFailed
        }

        export.outputURL = outputURL
        export.outputFileType = .m4a

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        export.audioMix = audioMix

        try await runExportSession(export)
    }

    private func runExportSession(_ export: AVAssetExportSession) async throws {
        try checkCancellation()
        setActiveExportSession(export)
        defer {
            clearActiveExportSession(if: export)
        }

        await export.export()
        try checkCancellation()

        if export.status != .completed {
            throw export.error ?? ExportError.renderingFailed
        }
    }

    private func runConfiguredExportSession(
        asset: AVAsset,
        presetName: String,
        outputURL: URL,
        outputFileType: AVFileType,
        shouldOptimizeForNetworkUse: Bool = false
    ) async throws {
        guard let export = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExportError.renderingFailed
        }

        export.outputURL = outputURL
        export.outputFileType = outputFileType
        export.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
        try await runExportSession(export)
    }

    private func checkCancellation() throws {
        if cancellationRequested() {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func setCancellationRequested(_ requested: Bool) {
        exportStateLock.lock()
        isCancellationRequested = requested
        exportStateLock.unlock()
    }

    private func cancellationRequested() -> Bool {
        exportStateLock.lock()
        let requested = isCancellationRequested
        exportStateLock.unlock()
        return requested
    }

    private func setActiveExportSession(_ export: AVAssetExportSession?) {
        exportStateLock.lock()
        activeExportSession = export
        exportStateLock.unlock()
    }

    private func clearActiveExportSession(if export: AVAssetExportSession) {
        exportStateLock.lock()
        if activeExportSession === export {
            activeExportSession = nil
        }
        exportStateLock.unlock()
    }

    private func cancelActiveExportSession() {
        exportStateLock.lock()
        isCancellationRequested = true
        let session = activeExportSession
        exportStateLock.unlock()
        session?.cancelExport()
    }

    private func fileType(for profile: ExportProfile) -> AVFileType {
        switch profile.format {
        case .mov:
            return .mov
        case .mp4, .gif:
            return .mp4
        }
    }

    private func videoCompressionProperties(for profile: ExportProfile) -> [String: Any] {
        var properties: [String: Any] = [
            AVVideoQualityKey: profile.quality,
            AVVideoAverageBitRateKey: averageBitrate(for: profile),
            AVVideoExpectedSourceFrameRateKey: profile.fps,
            AVVideoMaxKeyFrameIntervalKey: profile.fps
        ]

        if profile.codec == .h264 {
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        return properties
    }

    private func averageBitrate(for profile: ExportProfile) -> Int {
        if let bitrate = profile.averageBitrateMbps, bitrate.isFinite, bitrate > 0 {
            let clampedMbps = min(max(bitrate, 1), 240)
            return Int(clampedMbps * 1_000_000)
        }

        let safeWidth = max(profile.width, 1)
        let safeHeight = max(profile.height, 1)
        let safeFPS = max(profile.fps, 1)
        let pixelsPerSecond = Double(safeWidth) * Double(safeHeight) * Double(safeFPS)
        let codecMultiplier = profile.codec == .hevc ? 0.14 : 0.22
        let quality = profile.quality.isFinite ? Double(profile.quality) : 0.8
        let qualityMultiplier = max(0.4, min(quality, 1.0))
        return min(240_000_000, max(2_000_000, Int(pixelsPerSecond * codecMultiplier * qualityMultiplier)))
    }

    private func removeExistingFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    @MainActor
    private func setProgress(_ value: Double) {
        progress = value.isFinite ? max(0, min(value, 1)) : 0
    }

    @MainActor
    private func finishExportState() {
        isExporting = false
        setActiveExportSession(nil)
        setCancellationRequested(false)
    }

    @MainActor
    private func estimateFileSize(for project: RecordingProject, profile: ExportProfile) {
        let rawDuration = project.duration.seconds
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        let bitrate = Double(averageBitrate(for: profile))
        let sizeInBytes = (bitrate * duration) / 8
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        estimatedFileSize = formatter.string(fromByteCount: Int64(sizeInBytes))
    }

    nonisolated static func clampedAudioVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        // Up to 8× for very quiet sources (e.g. Bluetooth mics). Values >1 are applied
        // as real PCM gain before mixing; the mix itself only ever sees ≤1.
        return max(0, min(volume, 8))
    }

    nonisolated static func sanitizedProfile(_ profile: ExportProfile) -> ExportProfile {
        var sanitized = profile
        sanitized.width = min(max(profile.width, 16), 8192)
        sanitized.height = min(max(profile.height, 16), 8192)
        sanitized.fps = min(max(profile.fps, 1), 120)
        sanitized.quality = profile.quality.isFinite ? min(max(profile.quality, 0.1), 1.0) : 0.8
        if let bitrate = profile.averageBitrateMbps {
            sanitized.averageBitrateMbps = bitrate.isFinite && bitrate > 0 ? min(max(bitrate, 1), 240) : nil
        }
        return sanitized
    }
    
    @MainActor
    func cancelExport() {
        cancelActiveExportSession()
        isExporting = false
        progress = 0
    }
}

enum ExportError: LocalizedError {
    case noOutputLocation
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .noOutputLocation:
            return "Choose an export location first."
        case .renderingFailed:
            return "The renderer could not complete the export."
        }
    }
}
