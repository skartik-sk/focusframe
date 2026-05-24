import Foundation
import CoreMedia

struct ExportProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var width: Int
    var height: Int
    var fps: Int
    var codec: VideoCodec
    var quality: Float
    var averageBitrateMbps: Double? = nil
    var orientation: Orientation
    var format: ExportFormat
    
    enum VideoCodec: String, Codable {
        case h264
        case hevc
    }
    
    enum Orientation: String, Codable {
        case landscape
        case portrait
    }
    
    enum ExportFormat: String, Codable {
        case mp4
        case gif
        case mov
    }
    
    // Presets
    static let web1080p = ExportProfile(
        id: UUID(),
        name: "Web 1080p",
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 20,
        orientation: .landscape,
        format: .mp4
    )
    
    static let web720p = ExportProfile(
        id: UUID(),
        name: "Web 720p",
        width: 1280,
        height: 720,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 10,
        orientation: .landscape,
        format: .mp4
    )
    
    static let twitter = ExportProfile(
        id: UUID(),
        name: "Twitter",
        width: 1280,
        height: 720,
        fps: 60,
        codec: .h264,
        quality: 0.7,
        averageBitrateMbps: 14,
        orientation: .landscape,
        format: .mp4
    )

    static let youtube1080p = ExportProfile(
        id: UUID(),
        name: "YouTube 1080p",
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        quality: 0.85,
        averageBitrateMbps: 28,
        orientation: .landscape,
        format: .mp4
    )

    static let youtube4K = ExportProfile(
        id: UUID(),
        name: "YouTube 4K",
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .h264,
        quality: 0.98,
        averageBitrateMbps: 120,
        orientation: .landscape,
        format: .mp4
    )

    static let maxClarity4K = ExportProfile(
        id: UUID(),
        name: "Max Clarity 4K",
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .h264,
        quality: 1.0,
        averageBitrateMbps: 180,
        orientation: .landscape,
        format: .mp4
    )

    static let square = ExportProfile(
        id: UUID(),
        name: "Square 1:1",
        width: 1080,
        height: 1080,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 16,
        orientation: .landscape,
        format: .mp4
    )

    static let linkedin = ExportProfile(
        id: UUID(),
        name: "LinkedIn",
        width: 1920,
        height: 1080,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 20,
        orientation: .landscape,
        format: .mp4
    )
    
    static let tiktok = ExportProfile(
        id: UUID(),
        name: "TikTok",
        width: 1080,
        height: 1920,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 18,
        orientation: .portrait,
        format: .mp4
    )
    
    static let instagram = ExportProfile(
        id: UUID(),
        name: "Instagram",
        width: 1080,
        height: 1920,
        fps: 60,
        codec: .h264,
        quality: 0.8,
        averageBitrateMbps: 18,
        orientation: .portrait,
        format: .mp4
    )
    
    static let gifExport = ExportProfile(
        id: UUID(),
        name: "GIF",
        width: 800,
        height: 600,
        fps: 15,
        codec: .h264,
        quality: 0.6,
        averageBitrateMbps: nil,
        orientation: .landscape,
        format: .gif
    )
    
    static let custom4K = ExportProfile(
        id: UUID(),
        name: "4K Custom",
        width: 3840,
        height: 2160,
        fps: 60,
        codec: .h264,
        quality: 0.98,
        averageBitrateMbps: 160,
        orientation: .landscape,
        format: .mp4
    )
    
    static let allPresets: [ExportProfile] = [
        .web1080p,
        .web720p,
        .youtube1080p,
        .youtube4K,
        .maxClarity4K,
        .twitter,
        .linkedin,
        .square,
        .tiktok,
        .instagram,
        .gifExport,
        .custom4K
    ]
}
