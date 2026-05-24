import XCTest
import AppKit
@testable import FocusFrame

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {
    func testDefaultShortcutsIncludeGuideCommandMenuAndDelete() {
        let manager = KeyboardShortcutManager(userDefaults: isolatedDefaults())

        XCTAssertEqual(manager.getShortcutString(for: .showShortcuts), "⌘/")
        XCTAssertEqual(manager.getShortcutString(for: .commandMenu), "⌘K")
        XCTAssertEqual(manager.getShortcutString(for: .deleteSelection), "Delete")
        XCTAssertEqual(manager.getShortcutString(for: .playPause), "Space")
        XCTAssertEqual(manager.getShortcutString(for: .fullPreview), "F")
    }

    func testShortcutChangesPersistAcrossManagerInstances() {
        let defaults = isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: defaults)
        let shortcut = KeyboardShortcut(key: "x", modifiers: [.command, .option])

        manager.registerShortcut(.export, shortcut: shortcut)

        let reloaded = KeyboardShortcutManager(userDefaults: defaults)
        XCTAssertEqual(reloaded.getShortcut(for: .export), shortcut)
        XCTAssertEqual(reloaded.getShortcutString(for: .export), "⌘⌥X")
    }

    func testResetShortcutRestoresDefault() {
        let manager = KeyboardShortcutManager(userDefaults: isolatedDefaults())
        manager.registerShortcut(.export, shortcut: KeyboardShortcut(key: "x", modifiers: [.command]))

        manager.resetShortcut(.export)

        XCTAssertEqual(manager.getShortcutString(for: .export), "⌘⇧E")
    }

    func testShortcutMatchingIsSuppressedWhileEditingText() throws {
        let manager = KeyboardShortcutManager(userDefaults: isolatedDefaults())
        let spaceEvent = try makeKeyEvent(
            keyCode: 49,
            characters: " ",
            charactersIgnoringModifiers: " "
        )

        XCTAssertEqual(manager.matchingAction(for: spaceEvent, isTextInputActive: false), .playPause)
        XCTAssertNil(manager.matchingAction(for: spaceEvent, isTextInputActive: true))
    }

    func testRegisteringDuplicateShortcutRemovesOlderAssignment() {
        let manager = KeyboardShortcutManager(userDefaults: isolatedDefaults())
        let shortcut = KeyboardShortcut(key: "x", modifiers: [.command])

        manager.registerShortcut(.export, shortcut: shortcut)
        manager.registerShortcut(.newRecording, shortcut: shortcut)

        XCTAssertNil(manager.getShortcut(for: .export))
        XCTAssertEqual(manager.getShortcut(for: .newRecording), shortcut)
    }

    func testShortcutMatchingUsesActionOrderInsteadOfDictionaryOrder() throws {
        let manager = KeyboardShortcutManager(userDefaults: isolatedDefaults())
        let exportShortcut = KeyboardShortcut(key: "x", modifiers: [.command])
        manager.registerShortcut(.export, shortcut: exportShortcut)
        let event = try makeKeyEvent(
            keyCode: 7,
            characters: "x",
            charactersIgnoringModifiers: "x",
            modifiers: [.command]
        )

        XCTAssertEqual(manager.matchingAction(for: event, isTextInputActive: false), .export)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "FocusFrameTests.KeyboardShortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
