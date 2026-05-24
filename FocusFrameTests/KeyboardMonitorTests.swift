import XCTest
@testable import FocusFrame

final class KeyboardMonitorTests: XCTestCase {
    func testPersistEmptyEventsRemovesStaleFileAndReturnsNil() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-empty-keys-\(UUID().uuidString).json")
        try Data("[{\"stale\":true}]".utf8).write(to: outputURL)

        let persistedURL = KeyboardMonitor.persist(events: [], to: outputURL)

        XCTAssertNil(persistedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPersistRecordedEventsWritesFileAndReturnsURL() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-keys-\(UUID().uuidString).json")
        let event = KeyPressEvent(
            id: UUID(),
            timestamp: 0.42,
            keyCode: 0,
            modifiers: [.command],
            characters: "a",
            displayString: "⌘A"
        )

        let persistedURL = KeyboardMonitor.persist(events: [event], to: outputURL)

        XCTAssertEqual(persistedURL, outputURL)
        let data = try Data(contentsOf: outputURL)
        let decoded = try JSONDecoder().decode([KeyPressEvent].self, from: data)
        XCTAssertEqual(decoded.map(\.displayString), ["⌘A"])
        try? FileManager.default.removeItem(at: outputURL)
    }

    func testPersistSanitizesUnsafeAndDuplicateEvents() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-sanitized-keys-\(UUID().uuidString).json")
        let duplicateID = UUID()
        let events = [
            KeyPressEvent(
                id: UUID(),
                timestamp: .nan,
                keyCode: 0,
                modifiers: [],
                characters: "x",
                displayString: "X"
            ),
            KeyPressEvent(
                id: duplicateID,
                timestamp: 0.5,
                keyCode: 1,
                modifiers: ModifierFlags(rawValue: UInt.max),
                characters: "  b\n ",
                displayString: "  ⌘⌥⌃⇧B\n "
            ),
            KeyPressEvent(
                id: UUID(),
                timestamp: 0.51,
                keyCode: 1,
                modifiers: [.command, .option, .control, .shift],
                characters: "b",
                displayString: "⌘⌥⌃⇧B"
            )
        ]

        let persistedURL = KeyboardMonitor.persist(events: events, to: outputURL)

        XCTAssertEqual(persistedURL, outputURL)
        let data = try Data(contentsOf: outputURL)
        let decoded = try JSONDecoder().decode([KeyPressEvent].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, duplicateID)
        XCTAssertEqual(decoded.first?.timestamp, 0.5)
        XCTAssertEqual(decoded.first?.characters, "b")
        XCTAssertEqual(decoded.first?.displayString, "⌘⌥⌃⇧B")
        XCTAssertEqual(decoded.first?.modifiers, [.command, .option, .control, .shift])
        try? FileManager.default.removeItem(at: outputURL)
    }
}
