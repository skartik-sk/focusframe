import Foundation
import AVFoundation
import Accelerate

final class AudioProcessor: @unchecked Sendable {
    struct Config {
        var targetLUFS: Float = -16
        var noiseGateThreshold: Float = -45
        var compressionRatio: Float = 3.0
        var makeupGain: Float = 2.0
    }

    func process(inputURL: URL, outputURL: URL, config: Config = .init()) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AudioProcessorError.inputNotFound
        }
        try removeExistingFile(at: outputURL)

        do {
            let processedURL = try await Task.detached(priority: .userInitiated, operation: {
                try self.processPCM(inputURL: inputURL, outputURL: outputURL, config: config)
            }).value
            return processedURL
        } catch {
            try removeExistingFile(at: outputURL)
        }

        let asset = AVAsset(url: inputURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            try FileManager.default.copyItem(at: inputURL, to: outputURL)
            return outputURL
        }
        let duration = try await asset.load(.duration)

        let composition = AVMutableComposition()
        let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioProcessorError.exportSessionUnavailable
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        if let compTrack {
            let inputParams = AVMutableAudioMixInputParameters(track: compTrack)
            inputParams.setVolume(Self.sanitizedMakeupGain(config.makeupGain), at: .zero)

            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [inputParams]
            export.audioMix = audioMix
        }

        await export.export()

        if let error = export.error {
            throw error
        }

        return outputURL
    }

    private func processPCM(inputURL: URL, outputURL: URL, config: Config) throws -> URL {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat

        // Whole-file processing lets the spectral noise reducer learn the noise profile
        // from the quietest moments across the entire recording (two-pass), which is far
        // more accurate than streaming estimates. Cap memory; very long files skip only
        // the spectral stage and still get the gate/HPF/limiter chain.
        let totalFrames = Int(inputFile.length)
        let maxWholeFileFrames = 10 * 60 * Int(inputFormat.sampleRate)
        let useSpectralStage = totalFrames > 0 && totalFrames <= maxWholeFileFrames

        let channelCount = max(1, Int(inputFormat.channelCount))
        var channelSamples = [[Float]](repeating: [], count: channelCount)
        for index in 0..<channelCount {
            channelSamples[index].reserveCapacity(totalFrames)
        }

        let chunkSize: AVAudioFrameCount = 8192
        if useSpectralStage {
            while inputFile.framePosition < inputFile.length {
                let remaining = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: min(chunkSize, remaining)
                ) else { break }
                try inputFile.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                if let channels = buffer.floatChannelData {
                    for index in 0..<channelCount {
                        channelSamples[index].append(
                            contentsOf: UnsafeBufferPointer(start: channels[index], count: Int(buffer.frameLength))
                        )
                    }
                }
            }

            for index in 0..<channelCount {
                SpectralNoiseReducer().reduceNoise(samples: &channelSamples[index], sampleRate: Float(inputFormat.sampleRate))
            }
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 192_000
        ]
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)

        let gateThreshold = pow(10.0, Double(Self.sanitizedNoiseGateThreshold(config.noiseGateThreshold)) / 20.0)
        let floorGain: Float = 0.06
        let makeupGain = Self.sanitizedMakeupGain(config.makeupGain)
        let compressionRatio = Self.sanitizedCompressionRatio(config.compressionRatio)

        // DSP state carried across blocks so the gate envelope and high-pass filter are
        // continuous. Resetting them per 8192-frame block pumps the gate at every boundary.
        var envelopes = [Float](repeating: 0, count: channelCount)
        var hpfPreviousInputs = [Float](repeating: 0, count: channelCount)
        var hpfPreviousOutputs = [Float](repeating: 0, count: channelCount)

        func cleanupChannel(
            _ channelIndex: Int,
            frameLength: Int,
            samples: UnsafeMutablePointer<Float>
        ) {
            applyVoiceCleanup(
                channelIndex: channelIndex,
                frameLength: frameLength,
                sampleRate: Float(inputFormat.sampleRate),
                threshold: Float(gateThreshold),
                floorGain: floorGain,
                makeupGain: makeupGain,
                compressionRatio: compressionRatio,
                samples: samples,
                envelope: &envelopes[channelIndex],
                hpfPreviousInput: &hpfPreviousInputs[channelIndex],
                hpfPreviousOutput: &hpfPreviousOutputs[channelIndex]
            )
        }

        if useSpectralStage {
            let capacity = AVAudioFrameCount(chunkSize)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity) else {
                throw AudioProcessorError.exportSessionUnavailable
            }
            var offset = 0
            let totalFrames = channelSamples[0].count
            while offset < totalFrames {
                let length = min(Int(capacity), totalFrames - offset)
                outBuffer.frameLength = AVAudioFrameCount(length)

                for index in 0..<channelCount {
                    channelSamples[index].withUnsafeMutableBufferPointer { destination in
                        guard let base = destination.baseAddress else { return }
                        cleanupChannel(index, frameLength: length, samples: base + offset)
                        outBuffer.floatChannelData?[index].update(from: base + offset, count: length)
                    }
                }
                try outputFile.write(from: outBuffer)
                offset += length
            }
        } else {
            inputFile.framePosition = 0
            while inputFile.framePosition < inputFile.length {
                let remaining = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: min(chunkSize, remaining)
                ) else { break }
                try inputFile.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                guard let channels = buffer.floatChannelData else { break }
                let frameLength = Int(buffer.frameLength)
                for index in 0..<channelCount {
                    cleanupChannel(index, frameLength: frameLength, samples: channels[index])
                }
                try outputFile.write(from: buffer)
            }
        }

        return outputURL
    }

    private func applyVoiceCleanup(
        channelIndex: Int,
        frameLength: Int,
        sampleRate: Float,
        threshold: Float,
        floorGain: Float,
        makeupGain: Float,
        compressionRatio: Float,
        samples: UnsafeMutablePointer<Float>,
        envelope: inout Float,
        hpfPreviousInput: inout Float,
        hpfPreviousOutput: inout Float
    ) {
        let attackCoefficient = envelopeCoefficient(milliseconds: 8, sampleRate: sampleRate)
        let releaseCoefficient = envelopeCoefficient(milliseconds: 120, sampleRate: sampleRate)
        let ratio = max(1, compressionRatio)

        applyHighPassFilter(
            to: samples,
            frameLength: frameLength,
            sampleRate: sampleRate,
            cutoff: 85,
            previousInput: &hpfPreviousInput,
            previousOutput: &hpfPreviousOutput
        )
        let adaptiveThreshold = min(0.08, max(threshold, estimateNoiseFloor(samples: samples, frameLength: frameLength) * 1.7))
        let closeThreshold = adaptiveThreshold * 0.55
        // Envelope is carried across blocks; resetting it to 0 per block re-closes the
        // gate for several ms at every boundary (audible ~6 Hz flutter).
        for frame in 0..<frameLength {
            let sample = samples[frame]
            let rectified = abs(sample)
            let coefficient = rectified > envelope ? attackCoefficient : releaseCoefficient
            envelope = coefficient * envelope + (1 - coefficient) * rectified
            let openness = smoothstep((envelope - closeThreshold) / max(adaptiveThreshold - closeThreshold, 0.000_001))
            let gateGain = floorGain + (1 - floorGain) * openness
            let cleaned = sample * gateGain * makeupGain
            samples[frame] = softLimit(cleaned, ratio: ratio)
        }
    }

    private func applyHighPassFilter(
        to samples: UnsafeMutablePointer<Float>,
        frameLength: Int,
        sampleRate: Float,
        cutoff: Float,
        previousInput: inout Float,
        previousOutput: inout Float
    ) {
        guard frameLength > 1, sampleRate > 0, cutoff > 0 else { return }
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)

        // `previousInput`/`previousOutput` are carried across blocks so the filter is
        // continuous — resetting them per block inserts a transient at every boundary.
        for frame in 0..<frameLength {
            let input = samples[frame]
            let output = alpha * (previousOutput + input - previousInput)
            samples[frame] = output
            previousInput = input
            previousOutput = output
        }
    }

    private func estimateNoiseFloor(samples: UnsafeMutablePointer<Float>, frameLength: Int) -> Float {
        let windowSize = min(max(frameLength / 12, 128), 1024)
        guard windowSize > 0 else { return 0 }
        var windows: [Float] = []
        var start = 0
        while start < frameLength {
            let end = min(frameLength, start + windowSize)
            var sum: Float = 0
            for frame in start..<end {
                let value = samples[frame]
                sum += value * value
            }
            let rms = sqrt(sum / Float(max(end - start, 1)))
            windows.append(rms)
            start = end
        }
        guard !windows.isEmpty else { return 0 }
        windows.sort()
        let index = min(windows.count - 1, max(0, Int(Float(windows.count - 1) * 0.25)))
        return windows[index]
    }

    private func envelopeCoefficient(milliseconds: Float, sampleRate: Float) -> Float {
        exp(-1.0 / max(1, sampleRate * milliseconds / 1_000.0))
    }

    private func smoothstep(_ value: Float) -> Float {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }

    private func softLimit(_ sample: Float, ratio: Float) -> Float {
        let magnitude = abs(sample)
        let knee: Float = 0.68
        guard magnitude > knee else {
            return max(-1, min(1, sample))
        }
        let compressed = knee + (magnitude - knee) / ratio
        return max(-1, min(1, sample.sign == .minus ? -compressed : compressed))
    }

    func normalize(inputURL: URL, outputURL: URL, config: Config = .init()) async throws -> URL {
        return try await process(inputURL: inputURL, outputURL: outputURL, config: config)
    }

    func applyNoiseGate(inputURL: URL, outputURL: URL, threshold: Float = -45) async throws -> URL {
        var config = Config()
        config.noiseGateThreshold = threshold
        return try await process(inputURL: inputURL, outputURL: outputURL, config: config)
    }

    func mixTracks(trackURLs: [URL], outputURL: URL, volumes: [Float]) async throws -> URL {
        try removeExistingFile(at: outputURL)

        guard !trackURLs.isEmpty else {
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
            return outputURL
        }

        let composition = AVMutableComposition()
        var inputParams: [AVAudioMixInputParameters] = []

        for (index, trackURL) in trackURLs.enumerated() {
            let asset = AVAsset(url: trackURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)

            let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid + Int32(index))
            try compTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            if let compTrack {
                let params = AVMutableAudioMixInputParameters(track: compTrack)
                let volume = index < volumes.count ? Self.clampedVolume(volumes[index]) : 1.0
                params.setVolume(volume, at: .zero)
                inputParams.append(params)
            }
        }

        guard !inputParams.isEmpty else {
            FileManager.default.createFile(atPath: outputURL.path, contents: Data())
            return outputURL
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioProcessorError.exportSessionUnavailable
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParams
        export.audioMix = audioMix

        await export.export()

        if let error = export.error {
            throw error
        }

        return outputURL
    }

    /// Applies linear gain to an audio file with soft limiting to prevent harsh clipping.
    /// Used for volume boost (>1×) because AVAudioMix.setVolume clamps at 1.0.
    func applyLinearGain(inputURL: URL, outputURL: URL, gain: Float) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AudioProcessorError.inputNotFound
        }
        try removeExistingFile(at: outputURL)

        return try await Task.detached(priority: .userInitiated) {
            let inputFile = try AVAudioFile(forReading: inputURL)
            let format = inputFile.processingFormat
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: 192_000
            ]
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)

            let chunkSize: AVAudioFrameCount = 8192
            while inputFile.framePosition < inputFile.length {
                let remaining = AVAudioFrameCount(inputFile.length - inputFile.framePosition)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: min(chunkSize, remaining)
                ) else { break }
                try inputFile.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }

                let frameLength = Int(buffer.frameLength)
                for channel in 0..<Int(format.channelCount) {
                    let samples = channels[channel]
                    for frame in 0..<frameLength {
                        // Soft-knee limiter keeps boosted audio from hard-clipping.
                        let amplified = samples[frame] * gain
                        let magnitude = abs(amplified)
                        if magnitude > 0.95 {
                            let limited = 0.95 + (magnitude - 0.95) / max(gain, 1.5)
                            samples[frame] = amplified.sign == .minus ? -limited : limited
                        } else {
                            samples[frame] = amplified
                        }
                    }
                }
                try outputFile.write(from: buffer)
            }
            return outputURL
        }.value
    }

    private func removeExistingFile(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func clampedVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        return min(max(volume, 0), 1)
    }

    nonisolated static func sanitizedMakeupGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return 1 }
        return min(max(gain, 0.1), 4)
    }

    nonisolated static func sanitizedNoiseGateThreshold(_ threshold: Float) -> Float {
        guard threshold.isFinite else { return -45 }
        return min(max(threshold, -90), -15)
    }

    nonisolated static func sanitizedCompressionRatio(_ ratio: Float) -> Float {
        guard ratio.isFinite else { return 3 }
        return min(max(ratio, 1), 20)
    }
}

enum AudioProcessorError: Error {
    case inputNotFound
    case exportSessionUnavailable
}
