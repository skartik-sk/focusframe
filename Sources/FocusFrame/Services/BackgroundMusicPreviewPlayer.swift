import Foundation
import AVFoundation

@MainActor
final class BackgroundMusicPreviewPlayer {
    var durationDidChange: ((Double) -> Void)?

    private var player: AVPlayer?
    private var loadedURL: URL?
    private var durationTask: Task<Void, Never>?
    private var duration: Double = 0

    deinit {
        durationTask?.cancel()
    }

    func configure(url: URL?) {
        guard loadedURL != url else { return }

        stop()
        durationTask?.cancel()
        durationTask = nil
        loadedURL = url
        duration = 0
        durationDidChange?(0)

        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }

        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        durationTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let loadedDuration = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.loadedURL == url else { return }
                self.duration = loadedDuration.isFinite ? max(0, loadedDuration) : 0
                self.durationDidChange?(self.duration)
            }
        }
    }

    func play(projectTime: Double, volume: Float, loop: Bool) {
        guard let player else { return }
        player.volume = Self.clampedVolume(volume)
        seek(to: projectTime, loop: loop, tolerance: .zero)
        player.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.pause()
        player = nil
    }

    func seek(projectTime: Double, loop: Bool) {
        seek(to: projectTime, loop: loop, tolerance: CMTime(seconds: 0.03, preferredTimescale: 600))
    }

    func sync(projectTime: Double, volume: Float, loop: Bool) {
        guard let player else { return }
        player.volume = Self.clampedVolume(volume)

        let desiredSeconds = mediaTime(for: projectTime, loop: loop)
        let currentSeconds = player.currentTime().seconds
        if !currentSeconds.isFinite || abs(currentSeconds - desiredSeconds) > 0.45 {
            seek(to: projectTime, loop: loop, tolerance: CMTime(seconds: 0.06, preferredTimescale: 600))
        }

        if player.rate == 0, shouldPlay(at: desiredSeconds, loop: loop) {
            player.play()
        }
    }

    private func seek(to projectTime: Double, loop: Bool, tolerance: CMTime) {
        guard let player else { return }
        let seconds = mediaTime(for: projectTime, loop: loop)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func mediaTime(for projectTime: Double, loop: Bool) -> Double {
        let time = Self.sanitizedProjectTime(projectTime)
        guard duration.isFinite, duration > 0 else { return time }
        if loop {
            return time.truncatingRemainder(dividingBy: duration)
        }
        return min(time, duration)
    }

    private func shouldPlay(at mediaTime: Double, loop: Bool) -> Bool {
        loop || duration <= 0 || mediaTime < duration - 0.05
    }

    nonisolated static func sanitizedProjectTime(_ projectTime: Double) -> Double {
        projectTime.isFinite ? max(0, projectTime) : 0
    }

    nonisolated static func clampedVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        return max(0, min(volume, 1))
    }
}
