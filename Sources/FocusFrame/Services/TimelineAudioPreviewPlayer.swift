import Foundation
import AVFoundation

/// Timeline audio preview built on AVAudioEngine so volume boost (>1×) is audible
/// while editing — AVPlayer/AVAudioPlayer cap their volume property at 1.0, but an
/// AVAudioMixerNode applies values above 1.0 as real gain.
@MainActor
final class TimelineAudioPreviewPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var loadedURL: URL?
    /// Project-timeline second where the currently scheduled segment starts.
    private var segmentStartSeconds: Double = 0
    private var isPlaying = false
    private var currentRate: Float = 1

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    func configure(url: URL?) {
        guard loadedURL != url else { return }

        stopPlayback()
        loadedURL = url
        file = nil

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            print("Preview load failed for \(url.lastPathComponent): \(error)")
            file = nil
        }
    }

    func play(projectTime: Double, volume: Float, rate: Float) {
        startSegment(at: Self.sanitizedProjectTime(projectTime), volume: volume, rate: rate)
    }

    func pause() {
        stopPlayback()
    }

    func stop() {
        stopPlayback()
        loadedURL = nil
        file = nil
    }

    func seek(projectTime: Double) {
        guard isPlaying else { return }
        startSegment(at: Self.sanitizedProjectTime(projectTime), volume: currentVolume, rate: currentRate)
    }

    func sync(projectTime: Double, volume: Float, rate: Float, shouldPlay: Bool) {
        applyVolume(volume)

        guard shouldPlay else {
            stopPlayback()
            return
        }

        let targetRate = Self.clampedRate(rate)
        let desired = Self.sanitizedProjectTime(projectTime)
        let current = currentPosition()

        // Restart the segment when seeking or when the rate changed; otherwise let it run.
        let drifted = abs(current - desired) > (targetRate > 1.01 ? 0.18 : 0.32)
        if !isPlaying || drifted || abs(currentRate - targetRate) > 0.02 {
            startSegment(at: desired, volume: volume, rate: targetRate)
        }
    }

    // MARK: - Internals

    private var currentVolume: Float = 1

    private func applyVolume(_ volume: Float) {
        // Mixer volumes above 1.0 act as genuine amplification (unlike AVPlayer).
        let sanitized = volume.isFinite ? max(0, min(volume, 8)) : 0
        currentVolume = sanitized
        engine.mainMixerNode.outputVolume = sanitized
    }

    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            print("Preview engine failed to start: \(error)")
            return false
        }
    }

    private func startSegment(at projectTime: Double, volume: Float, rate: Float) {
        guard let file else { return }
        guard ensureEngineRunning() else { return }

        applyVolume(volume)
        let clampedRate = Self.clampedRate(rate)
        currentRate = clampedRate

        let format = file.processingFormat
        let totalFrames = max(0, Int(file.length))
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return }

        let startFrame = Int(min(projectTime, Double(totalFrames) / sampleRate) * sampleRate)
        guard startFrame < totalFrames else {
            stopPlayback()
            return
        }

        playerNode.stop()
        playerNode.scheduleSegment(
            file,
            startingFrame: AVAudioFramePosition(startFrame),
            frameCount: AVAudioFrameCount(totalFrames - startFrame),
            at: nil,
            completionHandler: nil
        )
        playerNode.prepare(withFrameCount: AVAudioFrameCount(totalFrames - startFrame))

        segmentStartSeconds = Double(startFrame) / sampleRate
        if #available(macOS 14.0, *) {
            playerNode.rate = clampedRate
        }
        playerNode.play()
        isPlaying = true
    }

    private func stopPlayback() {
        guard isPlaying || engine.isRunning else { return }
        playerNode.stop()
        isPlaying = false
    }

    private func currentPosition() -> Double {
        guard isPlaying,
              let file,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return segmentStartSeconds
        }
        let offsetSeconds = Double(playerTime.sampleTime) / playerTime.sampleRate
        return segmentStartSeconds + offsetSeconds
    }

    nonisolated static func sanitizedProjectTime(_ projectTime: Double) -> Double {
        projectTime.isFinite ? max(0, projectTime) : 0
    }

    nonisolated static func clampedRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return max(0.25, min(rate, 4.0))
    }
}
