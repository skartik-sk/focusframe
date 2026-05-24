import XCTest
import AppKit
@testable import FocusFrame

final class BackgroundImageHistoryTests: XCTestCase {
    func testBackgroundImageHistoryDeduplicatesAndKeepsNewestFirst() throws {
        let suiteName = "FocusFrame.BackgroundImageHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try writeTinyPNG(to: first)
        try writeTinyPNG(to: second)

        BackgroundImageHistory.add(first, defaults: defaults)
        BackgroundImageHistory.add(second, defaults: defaults)
        BackgroundImageHistory.add(first, defaults: defaults)

        let urls = BackgroundImageHistory.load(defaults: defaults)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["first.png", "second.png"])
    }

    func testBackgroundImageHistoryDropsMissingFiles() throws {
        let suiteName = "FocusFrame.BackgroundImageHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("existing.png")
        let missing = directory.appendingPathComponent("missing.png")
        try writeTinyPNG(to: existing)
        defaults.set([missing.path, existing.path], forKey: BackgroundImageHistory.storageKey)

        let urls = BackgroundImageHistory.load(defaults: defaults)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["existing.png"])
        XCTAssertEqual(defaults.stringArray(forKey: BackgroundImageHistory.storageKey), [existing.path])
    }

    func testBackgroundImageHistoryIgnoresDirectories() throws {
        let suiteName = "FocusFrame.BackgroundImageHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nestedDirectory = directory.appendingPathComponent("not-image", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        BackgroundImageHistory.add(nestedDirectory, defaults: defaults)

        XCTAssertTrue(BackgroundImageHistory.load(defaults: defaults).isEmpty)
    }

    func testBackgroundImageHistoryIgnoresNonImageFiles() throws {
        let suiteName = "FocusFrame.BackgroundImageHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let textFile = directory.appendingPathComponent("notes.png")
        try Data("not really an image".utf8).write(to: textFile)

        XCTAssertFalse(BackgroundImageHistory.add(textFile, defaults: defaults))
        XCTAssertTrue(BackgroundImageHistory.load(defaults: defaults).isEmpty)
    }

    func testBackgroundImageHistoryCapsEntries() throws {
        let suiteName = "FocusFrame.BackgroundImageHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for index in 0..<(BackgroundImageHistory.maxEntries + 3) {
            let url = directory.appendingPathComponent("image-\(index).png")
            try writeTinyPNG(to: url)
            BackgroundImageHistory.add(url, defaults: defaults)
        }

        let urls = BackgroundImageHistory.load(defaults: defaults)
        XCTAssertEqual(urls.count, BackgroundImageHistory.maxEntries)
        XCTAssertEqual(urls.first?.lastPathComponent, "image-\(BackgroundImageHistory.maxEntries + 2).png")
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-background-history-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeTinyPNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try pngData.write(to: url)
    }
}
