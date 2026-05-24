import Foundation
import CoreGraphics

struct OverlayElement: Codable, Identifiable, Equatable {
    let id: UUID
    var type: OverlayType
    var startTime: Double
    var endTime: Double
    var rect: CGRect
    var text: String
    var intensity: Float

    init(
        id: UUID = UUID(),
        type: OverlayType,
        startTime: Double,
        endTime: Double,
        rect: CGRect,
        text: String = "",
        intensity: Float = 0.75
    ) {
        self.id = id
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.rect = rect
        self.text = text
        self.intensity = intensity
    }

    func intersects(time: Double) -> Bool {
        time >= startTime && time <= endTime
    }
}

enum OverlayType: String, Codable, CaseIterable {
    case blur
    case highlight
    case spotlight
    case text

    var label: String {
        switch self {
        case .blur:
            return "Blur"
        case .highlight:
            return "Highlight"
        case .spotlight:
            return "Spotlight"
        case .text:
            return "Text"
        }
    }
}
