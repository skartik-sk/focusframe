import Foundation
import ScreenCaptureKit
import AVFoundation

final class SystemAudioCapture: NSObject {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.screenrecorder.systemaudio")
    private var outputURL: URL?

    struct Config {
        let display: SCDisplay
        var excludesCurrentProcessAudio: Bool = true
    }

    func start(config: Config, outputURL: URL) async throws {
        self.outputURL = outputURL

        let filter = SCContentFilter(display: config.display, excludingApplications: [], exceptingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = config.excludesCurrentProcessAudio
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        streamConfig.width = config.display.width
        streamConfig.height = config.display.height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
        )
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.audioInput = input

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws -> URL? {
        try await stream?.stopCapture()
        audioInput?.markAsFinished()
        await writer?.finishWriting()
        return outputURL
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        if let input = audioInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
