import Foundation
import Carbon
import CoreGraphics

struct KeyPressEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Double
    let keyCode: UInt16
    let modifiers: ModifierFlags
    let characters: String?
    let displayString: String

    var isModifierOnly: Bool {
        characters == nil
    }

    func sanitizedForUse() -> KeyPressEvent? {
        guard timestamp.isFinite else { return nil }
        let safeTimestamp = min(max(timestamp, 0), Self.maxTimelineSeconds)
        let safeModifiers = modifiers.sanitizedForUse()
        let safeCharacters = Self.cleanedText(characters)
        let cleanedDisplay = Self.cleanedText(displayString)
        let fallbackDisplay = safeModifiers.symbolString + (safeCharacters ?? "Key")
        let safeDisplay = cleanedDisplay ?? fallbackDisplay

        return KeyPressEvent(
            id: id,
            timestamp: safeTimestamp,
            keyCode: keyCode,
            modifiers: safeModifiers,
            characters: safeCharacters,
            displayString: safeDisplay
        )
    }

    static func sanitized(_ events: [KeyPressEvent]) -> [KeyPressEvent] {
        let sorted = events
            .compactMap { $0.sanitizedForUse() }
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.displayString < rhs.displayString
                }
                return lhs.timestamp < rhs.timestamp
            }
            .prefix(maxLoadedEventCount)

        var deduped: [KeyPressEvent] = []
        deduped.reserveCapacity(sorted.count)
        for event in sorted {
            if let last = deduped.last,
               last.keyCode == event.keyCode,
               last.modifiers == event.modifiers,
               abs(last.timestamp - event.timestamp) < 0.03 {
                continue
            }
            deduped.append(event)
        }
        return deduped
    }

    private static let maxTimelineSeconds: Double = 24 * 60 * 60
    private static let maxLoadedEventCount = 100_000
    private static let maxTextLength = 32

    private static func cleanedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maxTextLength))
    }
}

struct ModifierFlags: OptionSet, Codable, Equatable {
    let rawValue: UInt

    static let command = ModifierFlags(rawValue: 1 << 0)
    static let option  = ModifierFlags(rawValue: 1 << 1)
    static let control = ModifierFlags(rawValue: 1 << 2)
    static let shift   = ModifierFlags(rawValue: 1 << 3)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(from flags: CGEventFlags) {
        var value: UInt = 0
        if flags.contains(.maskCommand) { value |= ModifierFlags.command.rawValue }
        if flags.contains(.maskAlternate) { value |= ModifierFlags.option.rawValue }
        if flags.contains(.maskControl) { value |= ModifierFlags.control.rawValue }
        if flags.contains(.maskShift) { value |= ModifierFlags.shift.rawValue }
        self.rawValue = value
    }

    var symbolString: String {
        var s = ""
        if contains(.command) { s += "⌘" }
        if contains(.option)  { s += "⌥" }
        if contains(.control) { s += "⌃" }
        if contains(.shift)   { s += "⇧" }
        return s
    }

    func sanitizedForUse() -> ModifierFlags {
        let allowed = ModifierFlags.command.rawValue |
            ModifierFlags.option.rawValue |
            ModifierFlags.control.rawValue |
            ModifierFlags.shift.rawValue
        return ModifierFlags(rawValue: rawValue & allowed)
    }
}
