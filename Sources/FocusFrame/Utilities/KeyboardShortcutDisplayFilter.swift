import Foundation

enum KeyboardShortcutDisplayFilter {
    static func activeShortcuts(
        at time: Double,
        events: [KeyPressEvent],
        style: StylePreset
    ) -> [KeyPressEvent] {
        let duration = max(0.4, min(style.shortcutBadgeDuration, 3.0))
        return events.filter { event in
            guard time >= event.timestamp, time <= event.timestamp + duration else {
                return false
            }

            if !style.shortcutBadgeShowSingleKeys,
               event.modifiers.isEmpty,
               event.characters?.count == 1 {
                return false
            }

            return true
        }
    }
}
