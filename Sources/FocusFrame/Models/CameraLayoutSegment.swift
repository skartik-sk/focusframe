import Foundation

enum CameraLayoutMode: String, Codable, CaseIterable, Identifiable {
    case defaultOverlay
    case cameraOnly
    case screenOnly
    case sideBySide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOverlay:
            return "Overlay"
        case .cameraOnly:
            return "Camera"
        case .screenOnly:
            return "Screen"
        case .sideBySide:
            return "Split"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultOverlay:
            return "rectangle.inset.filled.and.person.filled"
        case .cameraOnly:
            return "person.crop.rectangle"
        case .screenOnly:
            return "display"
        case .sideBySide:
            return "rectangle.split.2x1"
        }
    }
}

struct CameraLayoutSegment: Codable, Identifiable, Equatable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    var mode: CameraLayoutMode

    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        mode: CameraLayoutMode
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.mode = mode
    }

    func intersects(time: Double) -> Bool {
        time >= startTime && time <= endTime
    }
}
