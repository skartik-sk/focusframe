import Foundation

struct EditAction: Codable, Identifiable {
    let id: UUID
    var type: EditType
    var startTime: Double
    var endTime: Double
    var value: Double?   // for speed: the multiplier (0.5–4.0)
    var description: String
    var createdAt: Date
    
    enum EditType: String, Codable {
        case cut          // remove this time range
        case speedChange  // change playback speed
        case hideCursor   // hide cursor in this time range
    }
    
    var duration: Double {
        return endTime - startTime
    }
    
    init(type: EditType, startTime: Double, endTime: Double, value: Double? = nil, description: String = "") {
        self.id = UUID()
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.value = value
        self.description = description
        self.createdAt = Date()
    }
    
    func intersects(time: Double) -> Bool {
        return time >= startTime && time <= endTime
    }
    
    func overlaps(with action: EditAction) -> Bool {
        return !(endTime <= action.startTime || startTime >= action.endTime)
    }
    
    func contains(action: EditAction) -> Bool {
        return startTime <= action.startTime && endTime >= action.endTime
    }
    
    static func cut(startTime: Double, endTime: Double, description: String = "Cut") -> EditAction {
        EditAction(type: .cut, startTime: startTime, endTime: endTime, description: description)
    }
    
    static func speedChange(startTime: Double, endTime: Double, multiplier: Double, description: String = "Speed Change") -> EditAction {
        EditAction(type: .speedChange, startTime: startTime, endTime: endTime, value: multiplier, description: description)
    }

    static func hideCursor(startTime: Double, endTime: Double, description: String = "Hide Cursor") -> EditAction {
        EditAction(type: .hideCursor, startTime: startTime, endTime: endTime, description: description)
    }
}
