import XCTest
@testable import FocusFrame
import AVFoundation

final class AudioProcessorTests: XCTestCase {

    var processor: AudioProcessor!
    var testAudioURL: URL!
    var outputURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        processor = AudioProcessor()

        // Create a test audio file
        testAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_audio_\(UUID().uuidString).m4a")
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("output_\(UUID().uuidString).m4a")

        try createTestAudioFile(at: testAudioURL)
    }

    override func tearDown() async throws {
        processor = nil

        // Clean up test files
        if FileManager.default.fileExists(atPath: testAudioURL.path) {
            try? FileManager.default.removeItem(at: testAudioURL)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        try await super.tearDown()
    }

    // MARK: - Test: Normalize Audio

    func testNormalizeAudio() async throws {
        let config = AudioProcessor.Config(targetLUFS: -16)
        let resultURL = try await processor.normalize(inputURL: testAudioURL, outputURL: outputURL, config: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Output file should exist")
        XCTAssertEqual(resultURL, outputURL, "Should return the output URL")

        // Verify output is a valid audio file
        let asset = AVAsset(url: resultURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "Output should have duration")
    }

    // MARK: - Test: Apply Noise Gate

    func testApplyNoiseGate() async throws {
        let threshold: Float = -45
        let resultURL = try await processor.applyNoiseGate(inputURL: testAudioURL, outputURL: outputURL, threshold: threshold)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Output file should exist")

        let asset = AVAsset(url: resultURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "Output should have duration")
    }

    // MARK: - Test: Mix Tracks

    func testMixTracks() async throws {
        // Create a second test audio file
        let testAudioURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_audio_2_\(UUID().uuidString).m4a")

        try createTestAudioFile(at: testAudioURL2)

        // Mix the two tracks
        let volumes: [Float] = [1.0, 0.5]
        let resultURL = try await processor.mixTracks(
            trackURLs: [testAudioURL, testAudioURL2],
            outputURL: outputURL,
            volumes: volumes
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Mixed output should exist")

        // Clean up
        try? FileManager.default.removeItem(at: testAudioURL2)
    }

    // MARK: - Test: Config Properties

    func testConfigProperties() {
        let config = AudioProcessor.Config(
            targetLUFS: -18,
            noiseGateThreshold: -50,
            compressionRatio: 4.0,
            makeupGain: 3.0
        )

        XCTAssertEqual(config.targetLUFS, -18)
        XCTAssertEqual(config.noiseGateThreshold, -50)
        XCTAssertEqual(config.compressionRatio, 4.0)
        XCTAssertEqual(config.makeupGain, 3.0)
    }

    // MARK: - Test: Default Config

    func testDefaultConfig() {
        let config = AudioProcessor.Config()

        XCTAssertEqual(config.targetLUFS, -16)
        XCTAssertEqual(config.noiseGateThreshold, -45)
        XCTAssertEqual(config.compressionRatio, 3.0)
        XCTAssertEqual(config.makeupGain, 2.0)
    }

    // MARK: - Test: Handle Invalid Input

    func testHandleInvalidInput() async throws {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/audio.m4a")

        do {
            _ = try await processor.normalize(inputURL: invalidURL, outputURL: outputURL)
            XCTFail("Should throw error for invalid input")
        } catch {
            // Expected error
            XCTAssertNotNil(error, "Should throw error for invalid input")
        }
    }

    // MARK: - Test: Empty Track List

    func testEmptyTrackList() async throws {
        let resultURL = try await processor.mixTracks(
            trackURLs: [],
            outputURL: outputURL,
            volumes: []
        )

        // Should return output URL even with empty input
        XCTAssertEqual(resultURL, outputURL)
    }

    // MARK: - Test: Volume Mismatch

    func testVolumeMismatch() async throws {
        let volumes: [Float] = [1.0] // Only one volume for two tracks
        let testAudioURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("test_audio_3_\(UUID().uuidString).m4a")

        try createTestAudioFile(at: testAudioURL2)

        // Should handle volume mismatch gracefully
        let resultURL = try await processor.mixTracks(
            trackURLs: [testAudioURL, testAudioURL2],
            outputURL: outputURL,
            volumes: volumes
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Should handle volume mismatch")

        // Clean up
        try? FileManager.default.removeItem(at: testAudioURL2)
    }

    // MARK: - Test: Performance

    func testPerformance() async throws {
        let config = AudioProcessor.Config()

        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<10 {
            _ = try? await processor.normalize(inputURL: testAudioURL, outputURL: outputURL, config: config)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("Audio processing time: \(duration)s for 10 iterations")

        XCTAssertLessThan(duration, 10.0, "Should complete 10 iterations in reasonable time")
    }

    // MARK: - Test: Process With All Config Options

    func testProcessWithAllConfigOptions() async throws {
        let config = AudioProcessor.Config(
            targetLUFS: -16,
            noiseGateThreshold: -45,
            compressionRatio: 3.0,
            makeupGain: 2.0
        )

        let resultURL = try await processor.process(inputURL: testAudioURL, outputURL: outputURL, config: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path), "Process should create output file")

        let asset = AVAsset(url: resultURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "Processed audio should have duration")
    }

    // MARK: - Test: Multiple Sequential Processes

    func testMultipleSequentialProcesses() async throws {
        let tempURL1 = FileManager.default.temporaryDirectory.appendingPathComponent("temp1_\(UUID().uuidString).m4a")
        let tempURL2 = FileManager.default.temporaryDirectory.appendingPathComponent("temp2_\(UUID().uuidString).m4a")

        // First process
        _ = try await processor.normalize(inputURL: testAudioURL, outputURL: tempURL1)

        // Second process on first output
        _ = try await processor.normalize(inputURL: tempURL1, outputURL: tempURL2)

        // Third process on second output
        _ = try await processor.normalize(inputURL: tempURL2, outputURL: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "Should handle sequential processing")

        // Clean up
        try? FileManager.default.removeItem(at: tempURL1)
        try? FileManager.default.removeItem(at: tempURL2)
    }

    private func createTestAudioFile(at url: URL, duration: Double = 1.0) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioProcessorTests", code: 1)
        }

        buffer.frameLength = frameCount
        let channels = Int(format.channelCount)
        for channel in 0..<channels {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                samples[frame] = Float(sin(Double(frame) * 0.01)) * 0.1
            }
        }

        try file.write(from: buffer)
    }
}
