import XCTest
@testable import FocusFrame

final class AppBrandTests: XCTestCase {
    func testAppBrandUsesFocusFrameIdentifiersOnly() {
        XCTAssertEqual(AppBrand.name, "FocusFrame")
        XCTAssertEqual(AppBrand.bundleIdentifier, "com.focusframe.app")
        XCTAssertEqual(AppBrand.supportDirectoryName, "FocusFrame")
    }

    func testStylePresetManagerRejectsOversizedPresetImports() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let presetsDirectory = root.appendingPathComponent("StylePresets", isDirectory: true)
        let manager = StylePresetManager(presetsDirectory: presetsDirectory)
        let oversizedPreset = root.appendingPathComponent("huge-preset.json")
        let oversizedBytes = Int(StylePresetManager.maxPresetFileBytes) + 1
        try Data(repeating: 0, count: oversizedBytes).write(to: oversizedPreset)

        do {
            _ = try manager.importPreset(from: oversizedPreset)
            XCTFail("Expected oversized preset import to fail")
        } catch PresetError.importFailed {
        } catch {
            XCTFail("Expected importFailed, got \(error)")
        }
    }

    func testStylePresetManagerReplaceExistingOnBulkImport() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let presetsDirectory = root.appendingPathComponent("StylePresets", isDirectory: true)
        try FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        try writePresetDictionary(["Current": try encodedStylePreset()], to: presetsDirectory.appendingPathComponent("presets.json"))

        let importURL = root.appendingPathComponent("imported-presets.json")
        let data = try JSONEncoder().encode([StylePreset.default])
        try data.write(to: importURL)

        let manager = StylePresetManager(presetsDirectory: presetsDirectory)
        try manager.importAllPresets(from: importURL, replaceExisting: true)

        let names = Set(manager.loadCustomPresets().map(\.name))
        XCTAssertEqual(names, ["Imported Preset 1"])
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("focusframe-brand-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func encodedStylePreset() throws -> String {
        let data = try JSONEncoder().encode(StylePresetManager.defaultPresets[0])
        return data.base64EncodedString()
    }

    private func writePresetDictionary(_ dictionary: [String: String], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(dictionary)
        try data.write(to: url)
    }
}
