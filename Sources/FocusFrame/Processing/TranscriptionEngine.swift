import Foundation
import Speech
import AVFoundation

@MainActor
final class TranscriptionEngine: NSObject {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechURLRecognitionRequest?
    private var authorizationStatus = SFSpeechRecognizer.authorizationStatus()

    override init() {
        super.init()
        setupRecognizer()
    }

    private func setupRecognizer() {
        recognizer = SFSpeechRecognizer()
        recognizer?.delegate = self
    }

    func transcribe(audioURL: URL, locale: Locale = .current) async throws -> [CaptionSegment] {
        try await ensureAuthorized()
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        recognizer?.delegate = self

        request = SFSpeechURLRecognitionRequest(url: audioURL)
        request?.shouldReportPartialResults = false

        guard let request = request else {
            throw TranscriptionError.requestCreationFailed
        }

        guard let recognizer else {
            throw TranscriptionError.recognitionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            func resumeOnce(_ result: Result<[CaptionSegment], Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let segments):
                    continuation.resume(returning: segments)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else {
                        resumeOnce(.failure(TranscriptionError.recognitionFailed))
                        return
                    }

                    if let error = error {
                        resumeOnce(.failure(error))
                        return
                    }

                    guard let result = result, result.isFinal else {
                        return
                    }

                    let segments = self.parseTranscriptionResult(result)
                    resumeOnce(.success(segments))
                }
            }
        }
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        do {
            try await ensureAuthorized()
            return true
        } catch {
            print("Speech recognition is unavailable: \(error)")
            return false
        }
    }

    private func ensureAuthorized() async throws {
        guard PrivacyPermissions.hasUsageDescription(.speechRecognition) else {
            throw TranscriptionError.missingUsageDescription
        }

        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .authorized { return }
        if authorizationStatus != .notDetermined {
            throw TranscriptionError.notAuthorized
        }

        authorizationStatus = await Self.requestSpeechAuthorization()

        guard authorizationStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func parseTranscriptionResult(_ result: SFSpeechRecognitionResult) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        let transcription = result.bestTranscription

        guard !transcription.segments.isEmpty else {
            let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return [CaptionSegment(id: UUID(), start: 0, end: 3, text: text)]
            }
            return segments
        }

        var currentWords: [String] = []
        var currentStart = transcription.segments[0].timestamp
        var currentEnd = currentStart
        let maxWords = 8
        let maxDuration = 3.5

        for wordSegment in transcription.segments {
            let word = wordSegment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }

            if currentWords.isEmpty {
                currentStart = wordSegment.timestamp
            }

            currentWords.append(word)
            currentEnd = wordSegment.timestamp + wordSegment.duration

            if currentWords.count >= maxWords || currentEnd - currentStart >= maxDuration {
                segments.append(makeCaption(words: currentWords, start: currentStart, end: currentEnd))
                currentWords.removeAll()
            }
        }

        if !currentWords.isEmpty {
            segments.append(makeCaption(words: currentWords, start: currentStart, end: currentEnd))
        }

        return segments
    }

    private func makeCaption(words: [String], start: Double, end: Double) -> CaptionSegment {
        CaptionSegment(
            id: UUID(),
            start: max(0, start),
            end: max(start + 0.5, end),
            text: words.joined(separator: " ")
        )
    }

    func writeSRT(segments: [CaptionSegment], to outputURL: URL) throws {
        var lines: [String] = []
        for (idx, seg) in segments.enumerated() {
            lines.append("\(idx + 1)")
            lines.append("\(formatSRT(seg.start)) --> \(formatSRT(seg.end))")
            lines.append(seg.text)
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func formatSRT(_ time: Double) -> String {
        let totalMs = Self.safeMilliseconds(time)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let totalMin = totalSec / 60
        let min = totalMin % 60
        let hr = totalMin / 60
        return String(format: "%02d:%02d:%02d,%03d", hr, min, sec, ms)
    }

    func writeVTT(segments: [CaptionSegment], to outputURL: URL) throws {
        var lines: [String] = [
            "WEBVTT",
            ""
        ]

        for seg in segments {
            lines.append("\(formatVTT(seg.start)) --> \(formatVTT(seg.end))")
            lines.append(seg.text)
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func formatVTT(_ time: Double) -> String {
        let totalMs = Self.safeMilliseconds(time)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let sec = totalSec % 60
        let totalMin = totalSec / 60
        let min = totalMin % 60
        let hr = totalMin / 60
        return String(format: "%02d:%02d:%02d.%03d", hr, min, sec, ms)
    }

    nonisolated static func safeMilliseconds(_ time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return max(0, Int((time * 1000).rounded()))
    }
}

extension TranscriptionEngine: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            authorizationStatus = available ? .authorized : SFSpeechRecognizer.authorizationStatus()
        }
    }
}

enum TranscriptionError: Error {
    case notAuthorized
    case missingUsageDescription
    case requestCreationFailed
    case recognitionFailed
}
