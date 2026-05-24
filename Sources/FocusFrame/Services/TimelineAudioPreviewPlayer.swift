import Foundation
import AVFoundation

@MainActor
final class TimelineAudioPreviewPlayer {
    private var player: AVPlayer?
    private var loadedURL: URL?

    func configure(url: URL?) {
        guard loadedURL != url else { return }

        stop()
        loadedURL = url

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
    }

    func play(projectTime: Double, volume: Float, rate: Float) {
        guard let player else { return }
        player.volume = Self.clampedVolume(volume)
        seek(to: projectTime, tolerance: .zero)
        player.playImmediately(atRate: Self.clampedRate(rate))
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.pause()
        player = nil
    }

    func seek(projectTime: Double) {
        seek(to: projectTime, tolerance: CMTime(seconds: 0.03, preferredTimescale: 600))
    }

    func sync(projectTime: Double, volume: Float, rate: Float, shouldPlay: Bool) {
        guard let player else { return }

        player.volume = Self.clampedVolume(volume)
        let desiredSeconds = Self.sanitizedProjectTime(projectTime)
        let currentSeconds = player.currentTime().seconds
        let tolerance = rate > 1.01 ? 0.18 : 0.32
        if !currentSeconds.isFinite || abs(currentSeconds - desiredSeconds) > tolerance {
            seek(to: desiredSeconds, tolerance: CMTime(seconds: 0.035, preferredTimescale: 600))
        }

        guard shouldPlay else {
            player.pause()
            return
        }

        let targetRate = Self.clampedRate(rate)
        if abs(player.rate - targetRate) > 0.02 || player.rate == 0 {
            player.playImmediately(atRate: targetRate)
        }
    }

    private func seek(to projectTime: Double, tolerance: CMTime) {
        guard let player else { return }
        let time = CMTime(seconds: Self.sanitizedProjectTime(projectTime), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    nonisolated static func sanitizedProjectTime(_ projectTime: Double) -> Double {
        projectTime.isFinite ? max(0, projectTime) : 0
    }

    nonisolated static func clampedVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        return max(0, min(volume, 1))
    }

    nonisolated static func clampedRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return max(0.25, min(rate, 4.0))
    }
}
