import Foundation
import AVFoundation

final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var session: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private let captureQueue = DispatchQueue(label: "com.screenrecorder.microphone")
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
        startedSession = false
        isRunning = false
        isPaused = false
        firstSampleTime = nil
        lastSampleTime = nil
        pauseStartTime = nil
        accumulatedPauseDuration = .zero

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = device ?? AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneRecorderError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw MicrophoneRecorderError.configurationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw MicrophoneRecorderError.configurationFailed
        }
        session.addOutput(output)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let inputWriter = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000
            ]
        )
        inputWriter.expectsMediaDataInRealTime = true
        guard writer.canAdd(inputWriter) else {
            throw MicrophoneRecorderError.configurationFailed
        }
        writer.add(inputWriter)

        guard writer.startWriting() else {
            throw writer.error ?? MicrophoneRecorderError.writerFailedToStart
        }

        self.writer = writer
        self.writerInput = inputWriter
        self.session = session
        isRunning = true
        session.startRunning()
    }

    func stop() async -> URL? {
        guard isRunning else {
            reset()
            return nil
        }

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

        if let writer {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        let finalURL = writer?.status == .completed ? outputURL : nil
        if finalURL == nil, let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        reset()
        return finalURL
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
        guard let writer, let writerInput, writer.status == .writing else { return }

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

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
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

enum MicrophoneRecorderError: LocalizedError {
    case deviceUnavailable
    case configurationFailed
    case writerFailedToStart

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No microphone device is available."
        case .configurationFailed:
            return "The selected microphone could not be configured."
        case .writerFailedToStart:
            return "The microphone audio writer could not start."
        }
    }
}
