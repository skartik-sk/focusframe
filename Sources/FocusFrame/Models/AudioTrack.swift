import Foundation

struct AudioTrack: Codable, Identifiable {
    let id: UUID
    var type: AudioTrackType
    var fileURL: URL
    var volume: Float
    var isMuted: Bool
    var noiseReductionEnabled: Bool
    var normalizationTarget: Float

    enum AudioTrackType: String, Codable {
        case microphone
        case systemAudio
    }
}
