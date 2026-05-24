import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

class CaptureEngine: NSObject, @unchecked Sendable {
    private static let minimumCaptureDimension = 2
    private static let maximumCaptureDimension = 8192
    private static let defaultFrameRate = 60
    private static let maximumFrameRate = 120

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private let outputURL: URL
    private let queue = DispatchQueue(label: "com.screenrecorder.capture")
    private var firstSampleTime: CMTime?
    private var lastSampleTime: CMTime?
    private var pauseStartTime: CMTime?
    private var accumulatedPauseDuration = CMTime.zero
    private var writerStarted = false
    private var isPaused = false
    
    struct Config {
        var display: SCDisplay
        var captureRect: CGRect?       // nil = full display
        var minimumFrameRate: Int = 30
        var maximumFrameRate: Int = 60
        var pixelFormat: OSType = kCVPixelFormatType_32BGRA
        var capturesAudio: Bool = false
        var excludesCurrentProcess: Bool = true
    }
    
    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }
    
    func start(config: Config) async throws {
        // SCShareableContent list etc are assumed called outside, passing config in
        let excludedApplications: [SCRunningApplication]
        if config.excludesCurrentProcess,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
            let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
            excludedApplications = content.applications.filter { $0.processID == currentPID }
        } else {
            excludedApplications = []
        }

        let filter = SCContentFilter(
            display: config.display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        
        let streamConfig = SCStreamConfiguration()
        let frameRate = Self.sanitizedFrameRate(config.maximumFrameRate)
        if let rect = Self.sanitizedSourceRect(
            config.captureRect,
            displayWidth: config.display.width,
            displayHeight: config.display.height
        ) {
            streamConfig.sourceRect = rect
            streamConfig.width = Self.sanitizedCaptureDimension(rect.width)
            streamConfig.height = Self.sanitizedCaptureDimension(rect.height)
        } else {
            streamConfig.width = Self.sanitizedCaptureDimension(config.display.width)
            streamConfig.height = Self.sanitizedCaptureDimension(config.display.height)
        }
        
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        streamConfig.pixelFormat = config.pixelFormat
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = false
        streamConfig.capturesAudio = config.capturesAudio
        streamConfig.excludesCurrentProcessAudio = config.excludesCurrentProcess
        
        // Asset Writer setup
        assetWriter = try AVAssetWriter(url: outputURL, fileType: .mov)
        guard let writer = assetWriter else { return }

        firstSampleTime = nil
        lastSampleTime = nil
        pauseStartTime = nil
        accumulatedPauseDuration = .zero
        writerStarted = false
        isPaused = false
        
        let videoSettings = Self.screenVideoSettings(
            width: streamConfig.width,
            height: streamConfig.height,
            fps: frameRate
        )
        
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        if let vi = videoWriterInput, writer.canAdd(vi) {
            writer.add(vi)
        }
        
        if config.capturesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = true
            if let ai = audioWriterInput, writer.canAdd(ai) {
                writer.add(ai)
            }
        }
        
        guard writer.startWriting() else {
            throw writer.error ?? CaptureEngineError.writerFailedToStart
        }
        
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.capturesAudio {
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        
        try await stream?.startCapture()
    }
    
    func stop() async throws -> URL {
        try await stream?.stopCapture()
        stream = nil

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                guard let writer = self.assetWriter else {
                    continuation.resume(returning: self.outputURL)
                    return
                }

                guard self.writerStarted else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.outputURL)
                    continuation.resume(throwing: CaptureEngineError.noFramesCaptured)
                    return
                }

                self.videoWriterInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()

                writer.finishWriting { [self] in
                    if self.assetWriter?.status == .completed {
                        continuation.resume(returning: self.outputURL)
                    } else {
                        continuation.resume(throwing: self.assetWriter?.error ?? CaptureEngineError.writerFailedToFinish)
                    }
                }
            }
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartTime = self.lastSampleTime
        }
    }

    func resume() {
        queue.async { [weak self] in
            self?.isPaused = false
        }
    }

    nonisolated static func sanitizedCaptureDimension(_ value: Int) -> Int {
        min(max(value, minimumCaptureDimension), maximumCaptureDimension)
    }

    nonisolated static func sanitizedCaptureDimension(_ value: CGFloat) -> Int {
        guard value.isFinite else {
            return minimumCaptureDimension
        }
        return sanitizedCaptureDimension(Int(value.rounded(.toNearestOrAwayFromZero)))
    }

    nonisolated static func sanitizedFrameRate(_ value: Int) -> Int {
        guard value > 0 else {
            return defaultFrameRate
        }
        return min(value, maximumFrameRate)
    }

    nonisolated static func sanitizedSourceRect(_ rect: CGRect?, displayWidth: Int, displayHeight: Int) -> CGRect? {
        guard let rect,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }

        let displayWidth = CGFloat(sanitizedCaptureDimension(displayWidth))
        let displayHeight = CGFloat(sanitizedCaptureDimension(displayHeight))
        let x = min(max(rect.origin.x, 0), displayWidth - 1)
        let y = min(max(rect.origin.y, 0), displayHeight - 1)
        let maxWidth = max(1, displayWidth - x)
        let maxHeight = max(1, displayHeight - y)
        let width = min(max(rect.width, CGFloat(minimumCaptureDimension)), maxWidth)
        let height = min(max(rect.height, CGFloat(minimumCaptureDimension)), maxHeight)

        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width.rounded(.down), height: height.rounded(.down))
    }

    nonisolated static func screenVideoSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        let safeWidth = sanitizedCaptureDimension(width)
        let safeHeight = sanitizedCaptureDimension(height)
        let safeFPS = sanitizedFrameRate(fps)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: safeWidth,
            AVVideoHeightKey: safeHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: screenVideoBitrate(width: safeWidth, height: safeHeight, fps: safeFPS),
                AVVideoExpectedSourceFrameRateKey: safeFPS,
                AVVideoMaxKeyFrameIntervalKey: safeFPS,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }

    nonisolated static func screenVideoBitrate(width: Int, height: Int, fps: Int) -> Int {
        let safeWidth = sanitizedCaptureDimension(width)
        let safeHeight = sanitizedCaptureDimension(height)
        let safeFPS = sanitizedFrameRate(fps)
        let pixelsPerSecond = Double(safeWidth) * Double(safeHeight) * Double(safeFPS)
        let calculated = pixelsPerSecond * 0.18
        return Int(min(140_000_000, max(25_000_000, calculated)))
    }
}

extension CaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen, !isCompleteScreenSample(sampleBuffer) {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused {
            if pauseStartTime == nil {
                pauseStartTime = timestamp
            }
            lastSampleTime = timestamp
            return
        }

        if let pauseStartTime {
            accumulatedPauseDuration = CMTimeAdd(
                accumulatedPauseDuration,
                CMTimeSubtract(timestamp, pauseStartTime)
            )
            self.pauseStartTime = nil
        }

        guard writerStarted || type == .screen else {
            return
        }

        if !writerStarted {
            firstSampleTime = timestamp
            assetWriter?.startSession(atSourceTime: .zero)
            writerStarted = true
        }
        lastSampleTime = timestamp

        guard assetWriter?.status == .writing else {
            return
        }

        let adjustedBuffer: CMSampleBuffer
        if let offset = firstSampleTime {
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let adjustedTime = CMTimeSubtract(
                CMTimeSubtract(timestamp, offset),
                accumulatedPauseDuration
            )
            var timingInfo = CMSampleTimingInfo(
                duration: duration,
                presentationTimeStamp: adjustedTime,
                decodeTimeStamp: .invalid
            )

            var sampleBufferRef: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleBufferOut: &sampleBufferRef
            )
            guard status == noErr, let buf = sampleBufferRef else { return }
            adjustedBuffer = buf
        } else {
            adjustedBuffer = sampleBuffer
        }

        switch type {
        case .screen:
            if let vi = videoWriterInput, vi.isReadyForMoreMediaData {
                if !vi.append(adjustedBuffer) {
                    print("Failed to append video sample: \(assetWriter?.error?.localizedDescription ?? "unknown writer error")")
                }
            }
        case .audio, .microphone:
            if let ai = audioWriterInput, ai.isReadyForMoreMediaData {
                if !ai.append(adjustedBuffer) {
                    print("Failed to append audio sample: \(assetWriter?.error?.localizedDescription ?? "unknown writer error")")
                }
            }
        @unknown default:
            break
        }
    }

    private func isCompleteScreenSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }

        return status == .complete
    }
}

enum CaptureEngineError: LocalizedError {
    case writerFailedToStart
    case writerFailedToFinish
    case noFramesCaptured

    var errorDescription: String? {
        switch self {
        case .writerFailedToStart:
            return "The screen recording writer could not start."
        case .writerFailedToFinish:
            return "The screen recording writer could not finish the movie file."
        case .noFramesCaptured:
            return "No complete screen frames were captured. Check Screen Recording permission and try a slightly longer recording."
        }
    }
}
