import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class ExportVM: ObservableObject, @unchecked Sendable {
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var selectedProfile: ExportProfile = .web1080p
    @Published var estimatedFileSize: String = ""
    @Published var outputURL: URL?
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

        let imageGenerator = AVAssetImageGenerator(asset: sourceAsset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.01, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.01, preferredTimescale: 600)

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
        let webcamGenerator = makeWebcamImageGenerator(for: project)
        let captionSegments = loadCaptionSegments(for: project)

        for frameIndex in 0..<totalFrames {
            try checkCancellation()
            let outputTime = Double(frameIndex) / Double(profile.fps)
            let sourceTime = sourceTime(for: outputTime, timeline: timeline)
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(profile.fps))
            let pixelBuffer: CVPixelBuffer = try autoreleasepool {
                let frameTransform = frameTransform(at: sourceTime, transforms: transforms)
                let transform = frameTransform.transform
                let motionBlurVelocity = transformVelocity(at: sourceTime, transforms: transforms)
                let cursorData = cursorFrame(at: sourceTime, frames: smoothedCursor)
                let clickProgress = clickAnimationProgress(at: sourceTime, frames: smoothedCursor)
                let resolvedEffects = EffectSegmentResolver.resolve(project: project, at: sourceTime)
                let style = resolvedEffects.style
                let activeShortcuts = activeShortcuts(at: sourceTime, events: keyEvents, style: style)

                let cmTime = CMTime(seconds: sourceTime, preferredTimescale: 600)
                let sourceFrame: CIImage
                do {
                    let cgImage = try imageGenerator.copyCGImage(at: cmTime, actualTime: nil)
                    sourceFrame = CIImage(cgImage: cgImage)
                } catch {
                    sourceFrame = CIImage(color: .init(cgColor: CGColor(gray: 0.2, alpha: 1.0)))
                        .cropped(to: CGRect(origin: .zero, size: sourceSize))
                }

                guard let pool = pixelBufferAdaptor.pixelBufferPool else {
                    throw ExportError.renderingFailed
                }

                var pixelBuffer: CVPixelBuffer?
                let createStatus = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault,
                    pool,
                    &pixelBuffer
                )

                guard createStatus == kCVReturnSuccess, let pixelBuffer else {
                    throw ExportError.renderingFailed
                }

                renderer.renderFrame(
                    inputs: VideoRenderer.FrameInputs(
                        sourceFrame: sourceFrame,
                        timestamp: outputTime,
                        zoomTransform: transform,
                        cursorPosition: cursorData?.position,
                        cursorVisible: shouldShowCursor(
                            at: sourceTime,
                            cursorData: cursorData,
                            frames: smoothedCursor,
                            style: style,
                            project: project,
                            clickProgress: clickProgress,
                            visibilityOverride: resolvedEffects.cursorVisibility
                        ),
                        cursorAlpha: 1.0,
                        cursorScale: style.cursorScale,
                        isClicking: cursorData?.isClicking ?? false,
                        clickAnimationProgress: clickProgress,
                        webcamFrame: resolvedEffects.webcamEnabled ? loadWebcamFrame(at: sourceTime, generator: webcamGenerator) : nil,
                        activeShortcuts: resolvedEffects.showKeyboardShortcuts ? activeShortcuts : [],
                        subtitleText: activeSubtitle(at: sourceTime, segments: captionSegments, enabled: resolvedEffects.subtitlesEnabled),
                        motionBlurVelocity: motionBlurVelocity,
                        activeOverlays: resolvedEffects.overlaysEnabled ? activeOverlays(at: sourceTime, project: project) : [],
                        activeTitleCards: activeTitleCards(at: sourceTime, project: project),
                        zoomScale: frameTransform.scale,
                        cameraLayoutMode: activeCameraLayoutMode(at: sourceTime, project: project, webcamEnabled: resolvedEffects.webcamEnabled)
                    ),
                    config: style,
                    outputSize: CGSize(width: profile.width, height: profile.height),
                    into: pixelBuffer
                )

                return pixelBuffer
            }

            while !videoInput.isReadyForMoreMediaData {
                try checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError.renderingFailed
            }

            if frameIndex % max(1, profile.fps / 10) == 0 {
                await setProgress(Double(frameIndex) / Double(totalFrames))
                await Task.yield()
            }
        }

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

        let imageGenerator = AVAssetImageGenerator(asset: sourceAsset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)

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
        let webcamGenerator = makeWebcamImageGenerator(for: project)
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

        for i in 0..<totalFrames {
            try checkCancellation()
            try autoreleasepool {
                let outputSeconds = Double(i) * frameDuration
                let sourceSeconds = sourceTime(for: outputSeconds, timeline: timeline)
                let time = CMTime(seconds: sourceSeconds, preferredTimescale: 600)
                let sourceFrame: CIImage
                if let cgImage = try? imageGenerator.copyCGImage(at: time, actualTime: nil) {
                    sourceFrame = CIImage(cgImage: cgImage)
                } else {
                    sourceFrame = CIImage(color: .init(cgColor: CGColor(gray: 0.2, alpha: 1.0)))
                        .cropped(to: CGRect(origin: .zero, size: sourceSize))
                }

                let frameTransform = frameTransform(at: sourceSeconds, transforms: transforms)
                let transform = frameTransform.transform
                let motionBlurVelocity = transformVelocity(at: sourceSeconds, transforms: transforms)
                let cursorData = cursorFrame(at: sourceSeconds, frames: smoothedCursor)
                let clickProgress = clickAnimationProgress(at: sourceSeconds, frames: smoothedCursor)
                let resolvedEffects = EffectSegmentResolver.resolve(project: project, at: sourceSeconds)
                let style = resolvedEffects.style
                let activeShortcuts = activeShortcuts(at: sourceSeconds, events: keyEvents, style: style)

                guard let renderedPB = renderer.renderFrame(
                    inputs: VideoRenderer.FrameInputs(
                        sourceFrame: sourceFrame,
                        timestamp: outputSeconds,
                        zoomTransform: transform,
                        cursorPosition: cursorData?.position,
                        cursorVisible: shouldShowCursor(
                            at: sourceSeconds,
                            cursorData: cursorData,
                            frames: smoothedCursor,
                            style: style,
                            project: project,
                            clickProgress: clickProgress,
                            visibilityOverride: resolvedEffects.cursorVisibility
                        ),
                        cursorAlpha: 1.0,
                        cursorScale: style.cursorScale,
                        isClicking: cursorData?.isClicking ?? false,
                        clickAnimationProgress: clickProgress,
                        webcamFrame: resolvedEffects.webcamEnabled ? loadWebcamFrame(at: sourceSeconds, generator: webcamGenerator) : nil,
                        activeShortcuts: resolvedEffects.showKeyboardShortcuts ? activeShortcuts : [],
                        subtitleText: activeSubtitle(at: sourceSeconds, segments: captionSegments, enabled: resolvedEffects.subtitlesEnabled),
                        motionBlurVelocity: motionBlurVelocity,
                        activeOverlays: resolvedEffects.overlaysEnabled ? activeOverlays(at: sourceSeconds, project: project) : [],
                        activeTitleCards: activeTitleCards(at: sourceSeconds, project: project),
                        zoomScale: frameTransform.scale,
                        cameraLayoutMode: activeCameraLayoutMode(at: sourceSeconds, project: project, webcamEnabled: resolvedEffects.webcamEnabled)
                    ),
                    config: style,
                    outputSize: outputSize
                ) else {
                    throw ExportError.renderingFailed
                }

                let ciImage = CIImage(cvPixelBuffer: renderedPB)
                guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(origin: .zero, size: outputSize)) else {
                    throw ExportError.renderingFailed
                }

                CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            }
            if i % max(1, profile.fps / 10) == 0 {
                await setProgress(Double(i) / Double(totalFrames) * 0.8)
                await Task.yield()
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.renderingFailed
        }

        await setProgress(1.0)
        completed = true
        return outputURL
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, at time: Double, fps: Int) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else { return nil }
        
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
            decodeTimeStamp: CMTime.invalid
        )
        
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        
        return status == noErr ? sampleBuffer : nil
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

    private func makeWebcamImageGenerator(for project: RecordingProject) -> AVAssetImageGenerator? {
        guard let webcamURL = project.webcamFileURL,
              FileManager.default.fileExists(atPath: webcamURL.path) else {
            return nil
        }

        let asset = AVAsset(url: webcamURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
        return generator
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
            preparedTracks.append(PreparedAudioTrack(
                url: editedSourceAudio,
                volumeAutomation: volumeAutomation(
                    for: project,
                    timeline: timeline,
                    baseVolume: project.style.sourceAudioVolume,
                    volume: { $0.sourceAudioVolume }
                ),
                isTemporary: true
            ))
        }

        if let micURL = project.micAudioFileURL,
           let editedMicAudio = try? await renderEditedAudioTrack(from: micURL, timeline: timeline) {
            let finalMicAudio: URL
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
            preparedTracks.append(PreparedAudioTrack(
                url: finalMicAudio,
                volumeAutomation: volumeAutomation(
                    for: project,
                    timeline: timeline,
                    baseVolume: project.style.micAudioVolume,
                    volume: { $0.micAudioVolume }
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
        return max(0, min(volume, 1))
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
