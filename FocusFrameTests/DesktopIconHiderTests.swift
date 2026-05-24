import XCTest
@testable import FocusFrame

final class DesktopIconHiderTests: XCTestCase {
    func testDesktopIconsRestoreWithSameInstance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let hider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )

        try hider.hideIcons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.visibleFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hiddenFileURL.path))

        try hider.restoreIcons()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.visibleFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hiddenFileURL.path))
    }

    func testDesktopIconsRestoreFromBackupWithFreshInstance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let hider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )

        try hider.hideIcons()
        let freshHider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )
        try freshHider.restoreIcons()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.visibleFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hiddenFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    func testDesktopIconHiderSkipsFilesWithExistingHiddenCounterpart() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data("already-hidden".utf8).write(to: fixture.hiddenFileURL)
        let hider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )

        try hider.hideIcons()
        try hider.restoreIcons()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.visibleFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hiddenFileURL.path))
    }

    func testDesktopIconRestoreIgnoresBackupEntriesOutsideConfiguredDesktops() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let outsideDirectory = fixture.rootURL.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideVisibleURL = outsideDirectory.appendingPathComponent("Secret.txt")
        let outsideHiddenURL = outsideDirectory.appendingPathComponent(".Secret.txt")
        try Data("hidden".utf8).write(to: outsideHiddenURL)
        let backupData = try JSONEncoder().encode([[outsideVisibleURL]])
        try backupData.write(to: fixture.backupURL)
        let hider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )

        try hider.restoreIcons()

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideVisibleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideHiddenURL.path))
    }

    func testDesktopIconRestoreRejectsOversizedBackup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data(repeating: 0, count: Int(DesktopIconHider.maxBackupFileBytes) + 1)
            .write(to: fixture.backupURL)
        let hider = DesktopIconHider(
            desktopURLs: [fixture.desktopURL],
            backupURL: fixture.backupURL
        )

        try hider.restoreIcons()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.visibleFileURL.path))
    }

    private func makeFixture() throws -> DesktopIconFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-desktop-icons-\(UUID().uuidString)", isDirectory: true)
        let desktopURL = rootURL.appendingPathComponent("Desktop", isDirectory: true)
        let backupURL = rootURL.appendingPathComponent("backup.json")
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        let visibleFileURL = desktopURL.appendingPathComponent("Demo.txt")
        try Data("demo".utf8).write(to: visibleFileURL)
        return DesktopIconFixture(
            rootURL: rootURL,
            desktopURL: desktopURL,
            backupURL: backupURL,
            visibleFileURL: visibleFileURL
        )
    }
}

private struct DesktopIconFixture {
    let rootURL: URL
    let desktopURL: URL
    let backupURL: URL
    let visibleFileURL: URL

    var hiddenFileURL: URL {
        desktopURL.appendingPathComponent(".\(visibleFileURL.lastPathComponent)")
    }
}
