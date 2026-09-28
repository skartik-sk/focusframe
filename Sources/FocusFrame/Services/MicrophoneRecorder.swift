import Foundation
import AVFoundation
@preconcurrency import CoreAudio
import AudioUnit

/// Captures microphone audio via AVAudioEngine and writes AAC at the device's
/// native sample rate.
///
/// Why no explicit AVAudioConverter (the previous approach): on this macOS the
/// converter is broken for 16 kHz→48 kHz device conversion — `convert(to:withInputFrom:)`
/// consumes every input block call and still returns `.inputRanDry`, producing a
/// zero-frame file; and installing the engine tap with a non-hardware format yields
/// no callbacks at all. Feeding the writer the hardware-rate buffers directly and
/// declaring the AAC file at the same rate is reliable on every device class
/// (Bluetooth 16 kHz, built-in 48 kHz, USB). Downstream consumers are rate-agnostic:
/// AudioProcessor reads the file's own rate, SoundEffectMixer resamples explicitly,
/// and AVPlayer handles any rate.
///
/// macOS 27 regression this class also defends against: routing the engine input
/// unit with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` can
/// leave the unit running but silent — `engine.start()` succeeds and the tap never
/// fires. Routing is skipped when the requested device is already the system
/// default, and a liveness watchdog falls back to the default device when a routed
/// unit delivers no callbacks within a couple of seconds.
final class MicrophoneRecorder: @unchecked Sendable {
    /// Serializes all file writes and state changes; tap callbacks hop onto this queue.
    private let captureQueue = DispatchQueue(label: "com.screenrecorder.microphone")
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var outputURL: URL?
    private var isRunning = false
    private var isPaused = false
    private let liveness = LivenessCounter()
    /// Non-fatal notice for the last start — set when capture fell back to the default
    /// microphone because the requested device produced no input. Read by RecordingVM.
    private(set) var lastFallbackNotice: String?

    func start(outputURL: URL, device: AVCaptureDevice? = nil) throws {
        try captureQueue.sync {
            stopImmediatelyLocked()
            lastFallbackNotice = nil

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            self.outputURL = outputURL

            do {
                // The engine input unit follows the default system input device on its
                // own; only genuinely non-default devices need the AudioUnit property,
                // which is the call macOS 27 can break (started unit, zero callbacks).
                let baseline = try startEnginePipeline(routingToDevice: Self.routableDevice(device))
                if !waitForInputCallbacks(baseline: baseline, timeout: 2.0) {
                    stopEngineLocked()
                    let requestedName = device?.localizedName ?? "the selected microphone"
                    print("MicrophoneRecorder: '\(requestedName)' opened but delivered no input; retrying on the default microphone")

                    let fallbackBaseline = try startEnginePipeline(routingToDevice: nil)
                    guard waitForInputCallbacks(baseline: fallbackBaseline, timeout: 2.0) else {
                        throw MicrophoneRecorderError.inputNotResponding
                    }
                    lastFallbackNotice = "\(requestedName) produced no audio, so this recording uses the default microphone (\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"))."
                }
            } catch {
                cleanupFailedStartLocked()
                throw error
            }
        }
    }

    func stop() async -> URL? {
        let result: URL? = captureQueue.sync {
            guard isRunning else {
                clearLocked()
                return nil
            }
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            isRunning = false

            defer { clearLocked() }
            if let outputURL, let file, file.length > 0 {
                return outputURL
            }
            if let outputURL {
                print("MicrophoneRecorder: discarding mic file — engine ran but wrote 0 frames of audio")
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

    /// Returns the device to route to, or nil when the requested device already is the
    /// system default (routing is unnecessary for it and actively harmful on macOS 27).
    nonisolated static func routableDevice(_ device: AVCaptureDevice?) -> AVCaptureDevice? {
        guard let device else { return nil }
        guard let defaultDevice = AVCaptureDevice.default(for: .audio) else { return nil }
        return device.uniqueID == defaultDevice.uniqueID ? nil : device
    }

    /// Starts a fresh engine at the device's native rate. Returns the liveness counter
    /// baseline captured immediately before `engine.start()` so the caller can detect a
    /// silent unit. Runs on captureQueue only.
    @discardableResult
    private func startEnginePipeline(routingToDevice routedDevice: AVCaptureDevice?) throws -> Int {
        // Fresh engine per start: a poisoned input unit stays poisoned, so restarts
        // must not reuse it. The previous instance is fully stopped by the caller.
        let engine = AVAudioEngine()
        self.engine = engine
        file = nil

        let inputNode = engine.inputNode
        if let routedDevice {
            routeCoreAudioDevice(device: routedDevice, on: inputNode)
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneRecorderError.configurationFailed
        }

        guard let outputURL else {
            throw MicrophoneRecorderError.configurationFailed
        }
        let channelCount = Int(inputFormat.channelCount)
        // No AVEncoderBitRateKey: the macOS 27 AAC encoder rejects explicit bitrates
        // that are high relative to the sample rate (e.g. 96 kbps @ 16 kHz throws
        // '!dat'); the encoder's automatic default is always accepted.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(inputFormat.sampleRate),
            AVNumberOfChannelsKey: channelCount
        ]
        self.file = try AVAudioFile(forWriting: outputURL, settings: settings)
        isPaused = false
        isRunning = true

        let baseline = liveness.count()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.liveness.increment()
            self.captureQueue.async {
                self.writeBuffer(buffer)
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
        return baseline
    }

    /// The tap must deliver buffers within `timeout` of engine start; a unit that opens
    /// but never streams would otherwise record an empty file. Runs on captureQueue;
    /// short sleeps only block startup, before any meaningful audio is due.
    private func waitForInputCallbacks(baseline: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if liveness.count() > baseline {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return liveness.count() > baseline
    }

    /// The tap buffers arrive in the hardware format, which is exactly what the file
    /// was created for — a straight write, no conversion. Runs on captureQueue only.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, !isPaused, let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("Mic write error: \(error)")
        }
    }

    /// Routes the engine's input unit to a specific CoreAudio device (matched by UID).
    private func routeCoreAudioDevice(device: AVCaptureDevice, on node: AVAudioInputNode) {
        guard let deviceID = Self.coreAudioDeviceID(forUID: device.uniqueID), let audioUnit = node.audioUnit else {
            print("MicrophoneRecorder: could not resolve CoreAudio device for '\(device.localizedName)'; using the default input")
            return
        }
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
            print("Could not route mic to device \(device.uniqueID): OSStatus \(status)")
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
    private func stopEngineLocked() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
        file = nil
        isRunning = false
    }

    /// Runs on captureQueue only.
    private func stopImmediatelyLocked() {
        if isRunning, let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        clearLocked()
    }

    /// Runs on captureQueue only: rolls back a failed start, leaving no orphan file.
    private func cleanupFailedStartLocked() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        clearLocked()
    }

    /// Runs on captureQueue only.
    private func clearLocked() {
        engine = nil
        file = nil
        outputURL = nil
        isRunning = false
        isPaused = false
    }
}

/// Tap callbacks arrive on an engine-internal queue while state changes run on
/// captureQueue — this counter is the one thing both sides touch.
final class LivenessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

enum MicrophoneRecorderError: LocalizedError {
    case deviceUnavailable
    case configurationFailed
    case writerFailedToStart
    case inputNotResponding

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No microphone device is available."
        case .configurationFailed:
            return "The selected microphone could not be configured."
        case .writerFailedToStart:
            return "The microphone audio writer could not start."
        case .inputNotResponding:
            return "The microphone opened but produced no audio. Try a different input device in System Settings → Sound, then record again."
        }
    }
}
