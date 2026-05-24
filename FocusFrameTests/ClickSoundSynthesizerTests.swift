import XCTest
import AVFoundation
@testable import FocusFrame

final class ClickSoundSynthesizerTests: XCTestCase {
    func testClickBufferIsAudible() throws {
        let buffer = try XCTUnwrap(ClickSoundSynthesizer.makeClickBuffer(volume: 0.75, style: .mouse))
        let metrics = try metrics(for: buffer)

        XCTAssertGreaterThan(metrics.peak, 0.08)
        XCTAssertLessThan(metrics.peak, 0.55)
        XCTAssertGreaterThan(metrics.averageEnergy, 0.003)
        XCTAssertLessThan(metrics.averageEnergy, 0.03)
        XCTAssertLessThan(metrics.tailEnergy, metrics.attackEnergy * 0.35)
    }

    func testAllClickSoundStylesRenderSignal() throws {
        for style in ClickSoundStyle.allCases {
            let buffer = try XCTUnwrap(ClickSoundSynthesizer.makeClickBuffer(volume: 0.75, style: style))
            let metrics = try metrics(for: buffer)

            XCTAssertGreaterThan(metrics.peak, 0.035, "\(style.rawValue) should produce an audible click")
            XCTAssertLessThan(metrics.peak, 0.7, "\(style.rawValue) should not overpower project audio")
        }
    }

    func testClickVolumeScalesWithoutForcedMinimum() throws {
        let quiet = try XCTUnwrap(ClickSoundSynthesizer.makeClickBuffer(volume: 0.15, style: .mouse))
        let loud = try XCTUnwrap(ClickSoundSynthesizer.makeClickBuffer(volume: 0.75, style: .mouse))

        let quietPeak = try metrics(for: quiet).peak
        let loudPeak = try metrics(for: loud).peak

        XCTAssertLessThan(quietPeak, loudPeak * 0.35)
    }

    private func metrics(for buffer: AVAudioPCMBuffer) throws -> (peak: Float, averageEnergy: Float, attackEnergy: Float, tailEnergy: Float) {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let frameLength = Int(buffer.frameLength)
        let attackEnd = min(frameLength, Int(0.020 * ClickSoundSynthesizer.sampleRate))
        let tailStart = min(frameLength, Int(0.050 * ClickSoundSynthesizer.sampleRate))

        var peak: Float = 0
        var averageEnergy: Float = 0
        var attackEnergy: Float = 0
        var tailEnergy: Float = 0
        var attackCount: Float = 0
        var tailCount: Float = 0

        for index in 0..<frameLength {
            let sample = abs(samples[index])
            peak = max(peak, sample)
            averageEnergy += sample
            if index < attackEnd {
                attackEnergy += sample
                attackCount += 1
            }
            if index >= tailStart {
                tailEnergy += sample
                tailCount += 1
            }
        }

        averageEnergy /= Float(max(frameLength, 1))
        attackEnergy /= max(attackCount, 1)
        tailEnergy /= max(tailCount, 1)

        return (peak, averageEnergy, attackEnergy, tailEnergy)
    }
}
