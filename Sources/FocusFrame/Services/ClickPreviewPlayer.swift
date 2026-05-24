import Foundation
import AVFoundation

final class ClickPreviewPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var filePlayer: AVAudioPlayer?
    private var isReady = false

    init() {
        engine.attach(player)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ClickSoundSynthesizer.sampleRate,
            channels: 1,
            interleaved: false
        )
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isReady = true
        }
    }

    func playClick(volume: Float, style: ClickSoundStyle, fileURL: URL?) {
        if let url = SoundEffectLibrary.clickURL(style: style, customURL: fileURL),
           playFile(url: url, volume: volume) {
            return
        }

        guard isReady,
              let buffer = ClickSoundSynthesizer.makeClickBuffer(volume: volume, style: style) else {
            return
        }

        play(buffer: buffer)
    }

    func playKeyboard(volume: Float, style: KeyboardSoundStyle, fileURL: URL?) {
        if let url = SoundEffectLibrary.keyboardURL(style: style, customURL: fileURL),
           playFile(url: url, volume: volume) {
            return
        }

        guard isReady,
              let buffer = ClickSoundSynthesizer.makeClickBuffer(volume: volume, style: style.fallbackClickStyle) else {
            return
        }

        play(buffer: buffer)
    }

    private func play(buffer: AVAudioPCMBuffer) {
        do {
            filePlayer?.stop()
            if !engine.isRunning {
                try engine.start()
            }
            player.volume = 1.0
            player.scheduleBuffer(buffer, at: nil)
            if !player.isPlaying {
                player.play()
            }
        } catch {
            // Preview click sound is non-critical; export still renders clicks.
        }
    }

    private func playFile(url: URL, volume: Float) -> Bool {
        do {
            player.stop()
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = max(0, min(volume, 1))
            player.prepareToPlay()
            player.play()
            filePlayer = player
            return true
        } catch {
            return false
        }
    }

    func stop() {
        player.stop()
        filePlayer?.stop()
        filePlayer = nil
        engine.stop()
    }
}
