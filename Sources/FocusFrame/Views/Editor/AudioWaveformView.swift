import SwiftUI
import AVFoundation

struct AudioWaveformView: View {
    let audioURL: URL?
    let currentTime: Double
    let duration: Double
    let editActions: [EditAction]
    let loops: Bool
    let muteCutRanges: Bool

    @State private var waveformSamples: [Float] = []
    @State private var rawWaveform: RawWaveform?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var remapTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isLoading {
                    WaveformSkeletonView()
                } else if !waveformSamples.isEmpty {
                    WaveformBarsView(
                        samples: waveformSamples,
                        currentTime: currentTime,
                        duration: max(duration, 0.001),
                        size: geometry.size
                    )
                } else {
                    Label(loadError ?? "No audio", systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(height: 60)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: rawWaveformRequestID) {
            await loadWaveform()
        }
        .onChange(of: mappingRequestID) { _ in
            scheduleWaveformRemap()
        }
        .onDisappear {
            remapTask?.cancel()
        }
    }

    private var rawWaveformRequestID: String {
        audioURL?.path ?? "none"
    }

    private var mappingRequestID: String {
        let edits = editActions
            .map { action in
                "\(action.type.rawValue):\(rounded(action.startTime)):\(rounded(action.endTime)):\(rounded(action.value ?? 0))"
            }
            .joined(separator: "|")
        return [
            rounded(duration),
            loops ? "loop" : "once",
            muteCutRanges ? "cuts" : "raw",
            edits
        ].joined(separator: "#")
    }

    @MainActor
    private func loadWaveform() async {
        waveformSamples = []
        rawWaveform = nil
        loadError = nil
        isLoading = true

        guard let url = audioURL, FileManager.default.fileExists(atPath: url.path) else {
            isLoading = false
            loadError = "No audio"
            return
        }

        do {
            let rawWaveform = try await Task.detached(priority: .utility) {
                try await AudioWaveformAnalyzer.generateRawWaveform(from: url)
            }.value
            guard !Task.isCancelled else { return }
            self.rawWaveform = rawWaveform
            remapLoadedWaveform()
            loadError = waveformSamples.isEmpty ? "No audio" : nil
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            print("Failed to load waveform: \(error)")
            loadError = "Waveform unavailable"
            isLoading = false
        }
    }

    @MainActor
    private func remapLoadedWaveform() {
        guard let rawWaveform else { return }
        waveformSamples = WaveformTimelineMapper.map(
            rawSamples: rawWaveform.samples,
            options: WaveformTimelineMapper.Options(
                displayDuration: duration,
                audioDuration: rawWaveform.duration,
                displaySampleCount: 960,
                editActions: editActions,
                loops: loops,
                muteCutRanges: muteCutRanges
            )
        )
        loadError = waveformSamples.isEmpty ? "No audio" : nil
    }

    @MainActor
    private func scheduleWaveformRemap() {
        remapTask?.cancel()
        remapTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 90_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            remapLoadedWaveform()
        }
    }

    private func rounded(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private enum AudioWaveformAnalyzer {
    static func generateRawWaveform(from url: URL) async throws -> RawWaveform {
        let asset = AVAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return RawWaveform(samples: [], duration: 0)
        }

        let loadedDuration = try await asset.load(.duration).seconds
        guard loadedDuration.isFinite, loadedDuration > 0 else {
            return RawWaveform(samples: [], duration: 0)
        }

        let bucketCount = max(120, min(4_800, Int(ceil(loadedDuration * 120))))
        var peaks = [Float](repeating: 0, count: bucketCount)

        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return RawWaveform(samples: [], duration: loadedDuration)
        }
        reader.add(output)

        let sampleRate = try await sampleRate(for: audioTrack) ?? 44_100
        let estimatedFrameCount = max(1, Int64(loadedDuration * sampleRate))
        var frameCursor: Int64 = 0

        reader.startReading()

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            guard byteLength >= MemoryLayout<Float>.size else { continue }

            var data = [Float](repeating: 0, count: byteLength / MemoryLayout<Float>.size)
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteLength,
                destination: &data
            )
            guard status == noErr, !data.isEmpty else { continue }

            let channelCount = max(1, data.count / frameCount)
            for frame in 0..<frameCount {
                let baseIndex = frame * channelCount
                guard baseIndex < data.count else { continue }

                var squared: Double = 0
                for channel in 0..<channelCount {
                    let sampleIndex = baseIndex + channel
                    guard sampleIndex < data.count else { continue }
                    let clamped = max(-1, min(1, data[sampleIndex]))
                    squared += Double(clamped * clamped)
                }

                let amplitude = Float(sqrt(squared / Double(channelCount)))
                let absoluteFrame = frameCursor + Int64(frame)
                let progress = Double(absoluteFrame) / Double(estimatedFrameCount)
                let bucket = max(0, min(bucketCount - 1, Int(progress * Double(bucketCount))))
                peaks[bucket] = max(peaks[bucket], amplitude)
            }

            frameCursor += Int64(frameCount)
        }

        if reader.status == .failed {
            throw reader.error ?? WaveformError.readFailed
        }

        let maxPeak = max(peaks.max() ?? 0, 0.0001)
        let normalized = peaks.map { peak -> Float in
            let value = Double(min(max(peak / maxPeak, 0), 1))
            return Float(pow(value, 0.72))
        }

        return RawWaveform(samples: normalized, duration: loadedDuration)
    }

    private static func sampleRate(for track: AVAssetTrack) async throws -> Double? {
        for description in try await track.load(.formatDescriptions) {
            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                let sampleRate = streamDescription.pointee.mSampleRate
                if sampleRate.isFinite, sampleRate > 0 {
                    return sampleRate
                }
            }
        }
        return nil
    }
}

private struct RawWaveform {
    let samples: [Float]
    let duration: Double
}

private enum WaveformError: Error {
    case readFailed
}

private struct WaveformSkeletonView: View {
    var body: some View {
        Canvas { context, size in
            let barCount = max(24, Int(size.width / 5))
            let barWidth = max(2, size.width / CGFloat(barCount) - 2)
            let centerY = size.height / 2
            let color = Color.secondary.opacity(0.18)

            for index in 0..<barCount {
                let phase = Double(index) * 0.42
                let amplitude = 0.2 + 0.45 * abs(sin(phase))
                let barHeight = max(3, CGFloat(amplitude) * (size.height - 10))
                let x = CGFloat(index) * size.width / CGFloat(barCount)
                let rect = CGRect(
                    x: x,
                    y: centerY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)),
                    with: .color(color)
                )
            }
        }
    }
}

private struct WaveformBarsView: View {
    let samples: [Float]
    let currentTime: Double
    let duration: Double
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            guard !samples.isEmpty else { return }
            let barCount = max(1, min(samples.count, Int(canvasSize.width / 3)))
            let barWidth = max(1.5, canvasSize.width / CGFloat(barCount) - 1.2)
            let centerY = canvasSize.height / 2
            let playedFraction = max(0, min(1, currentTime / max(duration, 0.001)))
            let playedX = playedFraction * canvasSize.width
            let idleColor = Color.secondary.opacity(0.28)
            let playedColor = Color.accentColor.opacity(0.88)

            for barIndex in 0..<barCount {
                let sampleStart = Int(Double(barIndex) / Double(barCount) * Double(samples.count))
                let sampleEnd = max(sampleStart + 1, Int(Double(barIndex + 1) / Double(barCount) * Double(samples.count)))
                let amplitude = samples[sampleStart..<min(sampleEnd, samples.count)].max() ?? 0
                let barHeight = max(2, CGFloat(amplitude) * (canvasSize.height - 8))
                let x = CGFloat(barIndex) * canvasSize.width / CGFloat(barCount)
                let rect = CGRect(
                    x: x,
                    y: centerY - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)),
                    with: .color(x <= playedX ? playedColor : idleColor)
                )
            }

            let playheadRect = CGRect(x: playedX, y: 0, width: 2, height: canvasSize.height)
            context.fill(Path(playheadRect), with: .color(Color.accentColor))
        }
        .frame(width: size.width, height: size.height)
    }
}
