import Foundation
import AVFoundation
@preconcurrency import CoreAudio
import AudioUnit

/// Captures microphone audio via AVAudioEngine with explicit sample-rate conversion.
///
/// Replaces the previous AVCaptureSession pipeline because Bluetooth headsets deliver
/// 16 kHz mono while wired mics deliver 48 kHz. AVCaptureSession's implicit conversion
/// to the writer's 48 kHz AAC produced quiet, noisy output for Bluetooth sources; here
/// the device rate is read directly and converted explicitly with AVAudioConverter.
final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    /// Serializes all file writes and state changes; tap callbacks hop onto this queue.
    private let captureQueue = DispatchQueue(label: "com.screenrecorder.microphone")
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var isRunning = false
    private var isPaused = false

    func start(outputURL: URL, device: AVCaptureDevice? = nil) throws {
        try captureQueue.sync {
            stopImmediatelyLocked()

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            let inputNode = engine.inputNode
            if let device {
                selectCoreAudioDevice(uid: device.uniqueID, on: inputNode)
            }

            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw MicrophoneRecorderError.configurationFailed
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw MicrophoneRecorderError.configurationFailed
            }
            self.converter = converter

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 192_000
            ]
            self.file = try AVAudioFile(forWriting: outputURL, settings: settings)
            self.outputURL = outputURL
            isPaused = false
            isRunning = true

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.captureQueue.async {
                    self?.convertAndWrite(buffer)
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                isRunning = false
                self.file = nil
                throw MicrophoneRecorderError.writerFailedToStart
            }
        }
    }

    func stop() async -> URL? {
        let result: URL? = captureQueue.sync {
            guard isRunning else {
                clearLocked()
                return nil
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false

            defer { clearLocked() }
            if let outputURL, let file, file.length > 0 {
                return outputURL
            }
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            return nil
        }
        return result
    }

    func pause() {
        captureQueue.async { [weak self] in
            self?.isPaused = true
        }
    }

    func resume() {
        captureQueue.async { [weak self] in
            self?.isPaused = false
        }
    }

    /// Runs on captureQueue only.
    private func convertAndWrite(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, !isPaused, let converter, let file else { return }

        let ratio = converter.outputFormat.sampleRate / max(converter.inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
        guard capacity > 0, let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        // The input block can be invoked several times per convert() call. Supply the
        // buffer exactly once, then signal end-of-input — returning the same buffer
        // twice duplicates audio (audible as echo/stutter).
        var didProvideInput = false

        // Drain every output buffer the converter produces for this input.
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData:
                if converted.frameLength > 0 {
                    try? file.write(from: converted)
                }
            case .endOfStream, .inputRanDry:
                return
            case .error:
                if let conversionError {
                    print("Mic conversion error: \(conversionError)")
                }
                return
            @unknown default:
                return
            }
        }
    }

    /// Routes the engine's input unit to a specific CoreAudio device (matched by UID).
    private func selectCoreAudioDevice(uid: String, on node: AVAudioInputNode) {
        guard let deviceID = Self.coreAudioDeviceID(forUID: uid), let audioUnit = node.audioUnit else { return }
        var resolvedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &resolvedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("Could not route mic to device \(uid): OSStatus \(status)")
        }
    }

    private static func coreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &size, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID) == noErr,
                  let resolved = deviceUID as String?, resolved == uid else { continue }
            return deviceID
        }
        return nil
    }

    /// Runs on captureQueue only.
    private func stopImmediatelyLocked() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        clearLocked()
    }

    /// Runs on captureQueue only.
    private func clearLocked() {
        converter = nil
        file = nil
        outputURL = nil
        isRunning = false
        isPaused = false
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
