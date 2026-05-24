import Foundation

struct CaptionSegment: Codable, Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var text: String
}

enum CaptionFileFormat: String, CaseIterable {
    case json
    case srt
    case vtt

    static func infer(from url: URL) -> CaptionFileFormat {
        switch url.pathExtension.lowercased() {
        case "srt":
            return .srt
        case "vtt":
            return .vtt
        default:
            return .json
        }
    }
}

enum CaptionImportError: LocalizedError, Equatable {
    case fileTooLarge(maxBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maxBytes):
            let megabytes = max(1, maxBytes / (1024 * 1024))
            return "Caption file is too large. Choose a file under \(megabytes) MB."
        }
    }
}
