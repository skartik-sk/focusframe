import SwiftUI
import AVFoundation

struct MicrophoneLevelMeter: View {
    let level: Float

    var body: some View {
        let clampedLevel = Self.clampedLevel(level)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, proxy.size.width * CGFloat(clampedLevel)))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(clampedLevel * 100)) percent")
    }

    nonisolated static func clampedLevel(_ level: Float) -> Float {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }
}

final class MicrophoneLevelMonitor: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published var level: Float = 0

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.screenrecorder.microphone-level")
    private var configuredDeviceID: String?
    private var isRunning = false

    func start(deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.configure(deviceID: deviceID)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.isRunning = true
            } catch {
                print("Microphone level preview failed: \(error)")
                self.publish(level: 0)
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isRunning = false
            self.publish(level: 0)
        }
    }

    private func configure(deviceID: String?) throws {
        if configuredDeviceID == deviceID, !session.inputs.isEmpty {
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let device = MediaDeviceCatalog.device(for: deviceID, mediaType: .audio) else {
            throw MicrophoneRecorderError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw MicrophoneRecorderError.configurationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else {
            throw MicrophoneRecorderError.configurationFailed
        }
        session.addOutput(output)
        configuredDeviceID = deviceID
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning else { return }
        publish(level: measuredLevel(from: sampleBuffer))
    }

    private func measuredLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }

        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        guard byteLength > 0 else { return 0 }

        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerChannel = streamDescription.pointee.mBitsPerChannel
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0

        if isFloat, bitsPerChannel == 32 {
            var data = [Float](repeating: 0, count: byteLength / MemoryLayout<Float>.size)
            guard !data.isEmpty,
                  CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength, destination: &data) == noErr else {
                return 0
            }
            let rms = sqrt(data.reduce(0.0) { $0 + Double($1 * $1) } / Double(data.count))
            return Float(min(1, rms * 4))
        }

        if bitsPerChannel == 16 {
            var data = [Int16](repeating: 0, count: byteLength / MemoryLayout<Int16>.size)
            guard !data.isEmpty,
                  CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength, destination: &data) == noErr else {
                return 0
            }
            let rms = sqrt(data.reduce(0.0) { sum, sample in
                let value = Double(sample) / Double(Int16.max)
                return sum + value * value
            } / Double(data.count))
            return Float(min(1, rms * 4))
        }

        return 0
    }

    private func publish(level: Float) {
        Task { @MainActor [weak self] in
            self?.level = level
        }
    }
}
