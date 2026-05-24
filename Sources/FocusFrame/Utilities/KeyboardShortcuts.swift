import Foundation
import AppKit

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case newRecording = "New Recording"
    case toggleRecording = "Toggle Recording"
    case stopRecording = "Stop Recording"
    case export = "Export"
    case undo = "Undo"
    case redo = "Redo"
    case playPause = "Play/Pause"
    case fullPreview = "Full Preview"
    case seekForward = "Seek Forward"
    case seekBackward = "Seek Backward"
    case deleteSelection = "Delete Selection"
    case commandMenu = "Command Menu"
    case showShortcuts = "Keyboard Shortcuts"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .newRecording:
            return "Open the source picker."
        case .toggleRecording:
            return "Start recording or stop the active recording."
        case .stopRecording:
            return "Stop and finalize the active recording."
        case .export:
            return "Open export options from the editor."
        case .undo:
            return "Undo the latest editor change."
        case .redo:
            return "Redo the latest editor change."
        case .playPause:
            return "Play or pause the editor, and pause/resume while recording."
        case .fullPreview:
            return "Open the editor preview in a larger player."
        case .seekForward:
            return "Move the editor playhead forward."
        case .seekBackward:
            return "Move the editor playhead backward."
        case .deleteSelection:
            return "Delete the selected zoom or timeline item."
        case .commandMenu:
            return "Open the editor command menu."
        case .showShortcuts:
            return "Open this shortcut guide."
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    enum CodingKeys: String, CodingKey {
        case key
        case modifiersRawValue
    }

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        let rawValue = try container.decode(UInt.self, forKey: .modifiersRawValue)
        modifiers = NSEvent.ModifierFlags(rawValue: rawValue).intersection(Self.supportedModifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.rawValue, forKey: .modifiersRawValue)
    }

    static func `default`(for action: ShortcutAction) -> KeyboardShortcut? {
        switch action {
        case .newRecording:
            return KeyboardShortcut(key: "n", modifiers: [.command])
        case .toggleRecording:
            return KeyboardShortcut(key: "r", modifiers: [.command])
        case .stopRecording:
            return KeyboardShortcut(key: ".", modifiers: [.command])
        case .export:
            return KeyboardShortcut(key: "e", modifiers: [.command, .shift])
        case .undo:
            return KeyboardShortcut(key: "z", modifiers: [.command])
        case .redo:
            return KeyboardShortcut(key: "z", modifiers: [.command, .shift])
        case .playPause:
            return KeyboardShortcut(key: " ", modifiers: [])
        case .fullPreview:
            return KeyboardShortcut(key: "f", modifiers: [])
        case .seekForward:
            return KeyboardShortcut(key: "→", modifiers: [.command])
        case .seekBackward:
            return KeyboardShortcut(key: "←", modifiers: [.command])
        case .deleteSelection:
            return KeyboardShortcut(key: "delete", modifiers: [])
        case .commandMenu:
            return KeyboardShortcut(key: "k", modifiers: [.command])
        case .showShortcuts:
            return KeyboardShortcut(key: "/", modifiers: [.command])
        }
    }

    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func from(event: NSEvent) -> KeyboardShortcut? {
        guard let key = normalizedKey(from: event), !key.isEmpty else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection(supportedModifiers)
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    func matches(event: NSEvent) -> Bool {
        guard let eventKey = Self.normalizedKey(from: event) else {
            return false
        }
        return eventKey == key
            && event.modifierFlags.intersection(Self.supportedModifiers) == modifiers
    }

    var displayString: String {
        var symbols = ""

        if modifiers.contains(.command) {
            symbols += "⌘"
        }
        if modifiers.contains(.option) {
            symbols += "⌥"
        }
        if modifiers.contains(.control) {
            symbols += "⌃"
        }
        if modifiers.contains(.shift) {
            symbols += "⇧"
        }

        return symbols + displayKeyName
    }

    private var displayKeyName: String {
        switch key {
        case " ":
            return "Space"
        case "delete":
            return "Delete"
        case "forwardDelete":
            return "Fn Delete"
        case "←", "→", "↑", "↓":
            return key
        default:
            return key.uppercased()
        }
    }

    private static func normalizedKey(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 49:
            return " "
        case 51:
            return "delete"
        case 117:
            return "forwardDelete"
        case 123:
            return "←"
        case 124:
            return "→"
        case 125:
            return "↓"
        case 126:
            return "↑"
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        return characters.lowercased()
    }
}

@MainActor
final class KeyboardShortcutManager: ObservableObject {
    static let shared = KeyboardShortcutManager()

    @Published private var shortcuts: [ShortcutAction: KeyboardShortcut] = [:]
    @Published var isCapturingShortcut = false
    private let userDefaults: UserDefaults
    private let storageKey = "FocusFrame.KeyboardShortcuts.v1"
    private var eventMonitor: Any?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        setupDefaultShortcuts()
        loadPersistedShortcuts()
    }

    private func setupDefaultShortcuts() {
        shortcuts.removeAll()
        for action in ShortcutAction.allCases {
            if let shortcut = KeyboardShortcut.default(for: action) {
                shortcuts[action] = shortcut
            }
        }
    }

    func registerShortcut(_ action: ShortcutAction, shortcut: KeyboardShortcut) {
        removeShortcutConflicts(shortcut, keeping: action)
        shortcuts[action] = shortcut
        persistShortcuts()
    }

    func resetShortcut(_ action: ShortcutAction) {
        if let shortcut = KeyboardShortcut.default(for: action) {
            shortcuts[action] = shortcut
        } else {
            shortcuts.removeValue(forKey: action)
        }
        persistShortcuts()
    }

    func resetAllShortcuts() {
        setupDefaultShortcuts()
        persistShortcuts()
    }

    func getShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        return shortcuts[action]
    }

    func getShortcutString(for action: ShortcutAction) -> String? {
        guard let shortcut = shortcuts[action] else { return nil }
        return shortcut.displayString
    }

    func allShortcuts() -> [(action: ShortcutAction, shortcut: KeyboardShortcut?)] {
        ShortcutAction.allCases.map { ($0, shortcuts[$0]) }
    }

    func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil
            }
            return event
        }
    }

    nonisolated func stopMonitoring() {
        Task { @MainActor in
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let action = matchingAction(for: event) else {
            return false
        }

        NotificationCenter.default.post(name: Notification.Name("Shortcut.\(action.rawValue)"), object: nil)
        return true
    }

    func matchingAction(for event: NSEvent, isTextInputActive: Bool? = nil) -> ShortcutAction? {
        guard !isCapturingShortcut else { return nil }
        if isTextInputActive ?? Self.isTextInputResponder(NSApp.keyWindow?.firstResponder) {
            return nil
        }

        return ShortcutAction.allCases.first { action in
            shortcuts[action]?.matches(event: event) == true
        }
    }

    static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        if let control = responder as? NSControl,
           control.currentEditor() != nil {
            return true
        }
        return false
    }

    private func loadPersistedShortcuts() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        do {
            let saved = try JSONDecoder().decode([StoredShortcut].self, from: data)
            for item in saved {
                removeShortcutConflicts(item.shortcut, keeping: item.action)
                shortcuts[item.action] = item.shortcut
            }
        } catch {
            userDefaults.removeObject(forKey: storageKey)
        }
    }

    private func persistShortcuts() {
        let saved = shortcuts
            .map { StoredShortcut(action: $0.key, shortcut: $0.value) }
            .sorted { $0.action.rawValue < $1.action.rawValue }
        if let data = try? JSONEncoder().encode(saved) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func removeShortcutConflicts(_ shortcut: KeyboardShortcut, keeping action: ShortcutAction) {
        for (candidate, existingShortcut) in shortcuts where candidate != action && existingShortcut == shortcut {
            shortcuts.removeValue(forKey: candidate)
        }
    }
}

private struct StoredShortcut: Codable {
    let action: ShortcutAction
    let shortcut: KeyboardShortcut
}

// MARK: - Keyboard Shortcut Notifications

extension Notification.Name {
    static let shortcutNewRecording = Notification.Name("Shortcut.New Recording")
    static let shortcutToggleRecording = Notification.Name("Shortcut.Toggle Recording")
    static let shortcutStopRecording = Notification.Name("Shortcut.Stop Recording")
    static let shortcutExport = Notification.Name("Shortcut.Export")
    static let shortcutUndo = Notification.Name("Shortcut.Undo")
    static let shortcutRedo = Notification.Name("Shortcut.Redo")
    static let shortcutPlayPause = Notification.Name("Shortcut.Play/Pause")
    static let shortcutFullPreview = Notification.Name("Shortcut.Full Preview")
    static let shortcutSeekForward = Notification.Name("Shortcut.Seek Forward")
    static let shortcutSeekBackward = Notification.Name("Shortcut.Seek Backward")
    static let shortcutDeleteSelection = Notification.Name("Shortcut.Delete Selection")
    static let shortcutCommandMenu = Notification.Name("Shortcut.Command Menu")
    static let shortcutShowShortcuts = Notification.Name("Shortcut.Keyboard Shortcuts")
}
