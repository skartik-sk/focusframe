import Foundation

enum TimecodeFormatter {
    static func positional(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        return positional(Int(safeSeconds.rounded(.down)))
    }

    static func positional(_ seconds: Int) -> String {
        let totalSeconds = max(0, seconds)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
