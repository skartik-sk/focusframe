import Foundation
@preconcurrency import AVFoundation

enum SoundEffectLibrary {
    static func clickURL(style: ClickSoundStyle, customURL: URL?) -> URL? {
        switch style {
        case .provided:
            return bundledURL(named: "mouseclick", extension: "mp3")
        case .custom:
            return customURL
        case .mouse, .trackpad, .soft, .typewriter:
            return nil
        }
    }

    static func keyboardURL(style: KeyboardSoundStyle, customURL: URL?) -> URL? {
        switch style {
        case .provided:
            return bundledURL(named: "key", extension: "mp3")
        case .custom:
            return customURL
        case .soft, .mechanical:
            return nil
        }
    }

    private static func bundledURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: name, withExtension: fileExtension)
    }
}

enum SoundEffectMixer {
    static let sampleRate = 44_100.0

    static func loadMonoSamples(
        from url: URL,
        targetSampleRate: Double = Self.sampleRate,
        maxDuration: Double
    ) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let maxInputFrames = AVAudioFrameCount(
            min(
                inputFile.length,
                AVAudioFramePosition(ceil(maxDuration * inputFormat.sampleRate))
            )
        )

        guard maxInputFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxInputFrames) else {
            return []
        }

        try inputFile.read(into: inputBuffer, frameCount: maxInputFrames)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return []
        }

        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(inputBuffer.frameLength) * targetSampleRate / inputFormat.sampleRate) + targetSampleRate * 0.02)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return []
        }

        let inputProvider = AudioConverterInputProvider(inputBuffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }

        if status == .error, let conversionError {
            throw conversionError
        }

        guard let channel = outputBuffer.floatChannelData?[0], outputBuffer.frameLength > 0 else {
            return []
        }

        let count = Int(outputBuffer.frameLength)
        var samples = Array(UnsafeBufferPointer(start: channel, count: count))
        applyShortFade(to: &samples, sampleRate: targetSampleRate)
        return samples
    }

    static func addSamples(
        _ samples: [Float],
        at startFrame: Int,
        channel: UnsafeMutablePointer<Float>,
        totalFrames: Int,
        volume: Float
    ) {
        guard !samples.isEmpty, startFrame >= 0, startFrame < totalFrames else { return }
        let volume = max(0, min(volume, 1))

        for offset in samples.indices {
            let frame = startFrame + offset
            guard frame < totalFrames else { break }
            channel[frame] = max(-1, min(1, channel[frame] + samples[offset] * volume))
        }
    }

    private static func applyShortFade(to samples: inout [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        let fadeFrames = min(samples.count / 2, max(1, Int(sampleRate * 0.006)))
        guard fadeFrames > 1 else { return }

        for index in 0..<fadeFrames {
            let fadeIn = Float(index) / Float(fadeFrames)
            samples[index] *= fadeIn

            let endIndex = samples.count - 1 - index
            let fadeOut = Float(index) / Float(fadeFrames)
            samples[endIndex] *= fadeOut
        }
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let inputBuffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(inputBuffer: AVAudioPCMBuffer) {
        self.inputBuffer = inputBuffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            outStatus.pointee = .endOfStream
            return nil
        }

        didProvideInput = true
        outStatus.pointee = .haveData
        return inputBuffer
    }
}
