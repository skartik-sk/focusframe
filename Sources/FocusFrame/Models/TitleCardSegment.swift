import Foundation
import CoreGraphics

struct TitleCardSegment: Codable, Identifiable, Equatable {
    var id: UUID
    var startTime: Double
    var endTime: Double
    var kind: TitleCardKind
    var style: TitleCardStyle
    var title: String
    var subtitle: String
    var accentColor: CodableColor
    var backgroundOpacity: Float

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        kind: TitleCardKind,
        style: TitleCardStyle = .cinematic,
        title: String,
        subtitle: String = "",
        accentColor: CodableColor = CodableColor(r: 0.23, g: 0.51, b: 0.96),
        backgroundOpacity: Float = 0.82
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.kind = kind
        self.style = style
        self.title = title
        self.subtitle = subtitle
        self.accentColor = accentColor
        self.backgroundOpacity = backgroundOpacity
    }

    func intersects(time: Double) -> Bool {
        time >= startTime && time <= endTime
    }
}

enum TitleCardKind: String, Codable, CaseIterable, Identifiable {
    case intro
    case section
    case outro

    var id: String { rawValue }

    var label: String {
        switch self {
        case .intro:
            return "Intro"
        case .section:
            return "Section"
        case .outro:
            return "Outro"
        }
    }
}

enum TitleCardStyle: String, Codable, CaseIterable, Identifiable {
    case cinematic
    case clean
    case gradient
    case lowerThird

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cinematic:
            return "Cinematic"
        case .clean:
            return "Clean"
        case .gradient:
            return "Gradient"
        case .lowerThird:
            return "Lower Third"
        }
    }
}
