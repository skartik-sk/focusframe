import Foundation

struct ChapterMarker: Codable, Identifiable, Equatable {
    let id: UUID
    var time: Double
    var title: String

    init(id: UUID = UUID(), time: Double, title: String) {
        self.id = id
        self.time = time
        self.title = title
    }
}
