import Foundation
import AVFoundation

enum ClickSoundSynthesizer {
    static let sampleRate = 44_100.0

    static func addClickSound(
        at startFrame: Int,
        channel: UnsafeMutablePointer<Float>,
        totalFrames: Int,
        sampleRate: Double = Self.sampleRate,
        volume: Float,
        style: ClickSoundStyle = .mouse
    ) {
        guard startFrame >= 0, startFrame < totalFrames else { return }
        let volume = max(0, min(volume, 1))
        let profile = profile(for: style)
        let length = Int(profile.length * sampleRate)

        for offset in 0..<length {
            let frame = startFrame + offset
            guard frame < totalFrames else { break }

            let t = Double(offset) / sampleRate
            var sample = tactileTransient(
                time: t,
                seed: offset,
                frequencyA: profile.frequencyA,
                frequencyB: profile.frequencyB,
                decay: profile.decay,
                noiseAmount: profile.noiseAmount
            )

            if t >= profile.upstrokeDelay {
                let shiftedTime = t - profile.upstrokeDelay
                sample += tactileTransient(
                    time: shiftedTime,
                    seed: offset + 1_337,
                    frequencyA: profile.frequencyA * 1.2,
                    frequencyB: profile.frequencyB * 1.08,
                    decay: profile.decay * 1.25,
                    noiseAmount: profile.noiseAmount * 0.72
                ) * profile.upstrokeGain
            }

            channel[frame] += Float(sample * profile.gain) * volume
            channel[frame] = max(-1, min(1, channel[frame]))
        }
    }

    static func makeClickBuffer(volume: Float, style: ClickSoundStyle = .mouse) -> AVAudioPCMBuffer? {
        let length = AVAudioFrameCount(max(0.08, profile(for: style).length + 0.025) * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = length
        for index in 0..<Int(length) {
            channel[index] = 0
        }
        addClickSound(
            at: 0,
            channel: channel,
            totalFrames: Int(length),
            volume: volume,
            style: style
        )
        return buffer
    }

    private struct Profile {
        let length: Double
        let upstrokeDelay: Double
        let upstrokeGain: Double
        let frequencyA: Double
        let frequencyB: Double
        let decay: Double
        let noiseAmount: Double
        let gain: Double
    }

    private static func profile(for style: ClickSoundStyle) -> Profile {
        switch style {
        case .provided, .custom:
            return Profile(
                length: 0.070,
                upstrokeDelay: 0.034,
                upstrokeGain: 0.36,
                frequencyA: 880,
                frequencyB: 2_650,
                decay: 110,
                noiseAmount: 0.16,
                gain: 0.48
            )
        case .mouse:
            return Profile(
                length: 0.070,
                upstrokeDelay: 0.034,
                upstrokeGain: 0.36,
                frequencyA: 880,
                frequencyB: 2_650,
                decay: 110,
                noiseAmount: 0.16,
                gain: 0.48
            )
        case .trackpad:
            return Profile(
                length: 0.052,
                upstrokeDelay: 0.025,
                upstrokeGain: 0.28,
                frequencyA: 680,
                frequencyB: 1_900,
                decay: 138,
                noiseAmount: 0.10,
                gain: 0.36
            )
        case .soft:
            return Profile(
                length: 0.064,
                upstrokeDelay: 0.030,
                upstrokeGain: 0.22,
                frequencyA: 520,
                frequencyB: 1_420,
                decay: 104,
                noiseAmount: 0.07,
                gain: 0.30
            )
        case .typewriter:
            return Profile(
                length: 0.095,
                upstrokeDelay: 0.042,
                upstrokeGain: 0.46,
                frequencyA: 1_480,
                frequencyB: 3_900,
                decay: 84,
                noiseAmount: 0.28,
                gain: 0.58
            )
        }
    }

    private static func tactileTransient(
        time: Double,
        seed: Int,
        frequencyA: Double,
        frequencyB: Double,
        decay: Double,
        noiseAmount: Double
    ) -> Double {
        let attackProgress = max(0, min(1, time / 0.0012))
        let attack = attackProgress * attackProgress * (3 - 2 * attackProgress)
        let bodyRelease = exp(-decay * time)
        let snapRelease = exp(-(decay * 1.8) * time)
        let body = sin(2 * .pi * frequencyA * time) * 0.30 * bodyRelease
        let snap = sin(2 * .pi * frequencyB * time) * 0.10 * snapRelease
        let friction = deterministicNoise(seed) * noiseAmount * snapRelease
        return softLimit((body + snap + friction) * attack)
    }

    private static func softLimit(_ value: Double) -> Double {
        tanh(value * 1.35) / 1.35
    }

    private static func deterministicNoise(_ seed: Int) -> Double {
        let value = UInt64(truncatingIfNeeded: seed &* 1_103_515_245 &+ 12_345)
        let mixed = (value >> 16) & 0x7fff
        return (Double(mixed) / 16_383.5) - 1.0
    }
}
