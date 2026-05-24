import Foundation
import AVFoundation

final class WebcamCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let outputWidth = 1280
    private static let outputHeight = 720
    private static let outputBitrate = 8_000_000

    private var session: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private let captureQueue = DispatchQueue(label: "com.screenrecorder.webcam")
    private var outputURL: URL?
    private var startedSession = false
    private var isRunning = false
    private var isPaused = false
    private var firstSampleTime: CMTime?
    private var lastSampleTime: CMTime?
    private var pauseStartTime: CMTime?
    private var accumulatedPauseDuration = CMTime.zero

    func start(outputURL: URL, device: AVCaptureDevice? = nil) throws {
        cancelCurrentRecording()
        self.outputURL = outputURL
        self.startedSession = false
        self.isRunning = false
        self.isPaused = false
        self.firstSampleTime = nil
        self.lastSampleTime = nil
        self.pauseStartTime = nil
        self.accumulatedPauseDuration = .zero

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720

        guard let device = device ?? AVCaptureDevice.default(for: .video) else {
            throw WebcamError.deviceUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw WebcamError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw WebcamError.configurationFailed }
        session.addOutput(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let inputWriter = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.outputWidth,
                AVVideoHeightKey: Self.outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.outputBitrate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        inputWriter.expectsMediaDataInRealTime = true
        guard writer.canAdd(inputWriter) else { throw WebcamError.configurationFailed }
        writer.add(inputWriter)

        guard writer.startWriting() else {
            throw writer.error ?? WebcamError.writerFailedToStart
        }

        self.writer = writer
        self.writerInput = inputWriter
        self.session = session
        self.isRunning = true
        session.startRunning()
    }

    func stop() async -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        session?.stopRunning()

        guard startedSession else {
            writer?.cancelWriting()
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            reset()
            return nil
        }

        writerInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer?.finishWriting {
                continuation.resume()
            }
        }

        let finishedURL = writer?.status == .completed ? outputURL : nil
        if finishedURL == nil, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        reset()

        return finishedURL
    }

    func pause() {
        captureQueue.async { [weak self] in
            guard let self, self.isRunning, !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartTime = self.lastSampleTime
        }
    }

    func resume() {
        captureQueue.async { [weak self] in
            self?.isPaused = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer = writer,
              let writerInput = writerInput,
              writer.status == .writing else { return }

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

        if !startedSession {
            firstSampleTime = timestamp
            writer.startSession(atSourceTime: .zero)
            startedSession = true
        }
        lastSampleTime = timestamp

        if writerInput.isReadyForMoreMediaData {
            writerInput.append(adjustedSampleBuffer(sampleBuffer, timestamp: timestamp) ?? sampleBuffer)
        }
    }

    private func adjustedSampleBuffer(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        guard let firstSampleTime else { return sampleBuffer }

        let duration = CMSampleBufferGetDuration(sampleBuffer)
        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CaptureTiming.adjustedPresentationTime(
                timestamp: timestamp,
                firstSampleTime: firstSampleTime,
                accumulatedPauseDuration: accumulatedPauseDuration
            ),
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

        return status == noErr ? sampleBufferRef : nil
    }

    private func reset() {
        session = nil
        writer = nil
        writerInput = nil
        outputURL = nil
        startedSession = false
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        lastSampleTime = nil
        pauseStartTime = nil
        accumulatedPauseDuration = .zero
    }

    private func cancelCurrentRecording() {
        if isRunning {
            session?.stopRunning()
        }
        writer?.cancelWriting()
        if let outputURL, FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        reset()
    }
}

enum WebcamError: Error {
    case deviceUnavailable
    case configurationFailed
    case writerFailedToStart
}
