import Foundation

struct PresetWithMetadata {
    let name: String
    let preset: StylePreset
}

class StylePresetManager {
    nonisolated(unsafe) static let shared = StylePresetManager()
    static let maxPresetFileBytes: UInt64 = 2 * 1024 * 1024
    
    private let presetsDirectory: URL
    private let presetsFile: URL
    
    init(presetsDirectory: URL? = nil) {
        self.presetsDirectory = presetsDirectory ?? AppBrand.applicationSupportDirectory(named: "StylePresets")
        presetsFile = self.presetsDirectory.appendingPathComponent("presets.json")

        createDirectoryIfNeeded()
    }
    
    // MARK: - Default Presets
    
    static let defaultPresets: [StylePreset] = [
        StylePreset(
            backgroundType: .solid,
            backgroundColor: CodableColor(r: 0.11, g: 0.11, b: 0.12),
            backgroundGradientColors: [],
            backgroundGradientAngle: 0,
            backgroundImageURL: nil,
            padding: 80,
            cornerRadius: 16,
            margin: 0,
            shadowEnabled: true,
            shadowRadius: 40,
            shadowOffsetX: 0,
            shadowOffsetY: 20,
            shadowOpacity: 0.3,
            shadowColor: CodableColor(r: 0, g: 0, b: 0),
            cursorScale: 1.5,
            cursorStyle: .default,
            hideStaticCursor: true,
            loopCursorPosition: false,
            useHighResCursors: true,
            webcamPosition: .bottomRight,
            webcamSize: 220,
            showKeyboardShortcuts: true,
            shortcutBadgePosition: .bottomCenter,
            shortcutBadgeStyle: .pillDark
        ),
        StylePreset(
            backgroundType: .gradient,
            backgroundColor: CodableColor(r: 0.1, g: 0.1, b: 0.1),
            backgroundGradientColors: [
                CodableColor(r: 0.1, g: 0.3, b: 0.5),
                CodableColor(r: 0.2, g: 0.5, b: 0.8)
            ],
            backgroundGradientAngle: 135,
            backgroundImageURL: nil,
            padding: 60,
            cornerRadius: 24,
            margin: 0,
            shadowEnabled: true,
            shadowRadius: 30,
            shadowOffsetX: 0,
            shadowOffsetY: 15,
            shadowOpacity: 0.4,
            shadowColor: CodableColor(r: 0, g: 0, b: 0),
            cursorScale: 1.8,
            cursorStyle: .quick,
            hideStaticCursor: true,
            loopCursorPosition: false,
            useHighResCursors: true,
            webcamPosition: .bottomLeft,
            webcamSize: 220,
            showKeyboardShortcuts: true,
            shortcutBadgePosition: .bottomCenter,
            shortcutBadgeStyle: .pillLight
        )
    ]
    
    // MARK: - Preset Management
    
    func savePreset(_ preset: StylePreset, name: String) throws {
        var presetDict = loadPresetDict()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset.sanitizedForUse())
        let base64String = data.base64EncodedString()
        
        presetDict[name] = base64String
        try savePresetDict(presetDict)
    }
    
    func loadCustomPresets() -> [PresetWithMetadata] {
        let presetDict = loadPresetDict()
        var presets: [PresetWithMetadata] = []
        
        for (name, base64String) in presetDict {
            if let data = Data(base64Encoded: base64String),
               let preset = try? JSONDecoder().decode(StylePreset.self, from: data) {
                presets.append(PresetWithMetadata(name: name, preset: preset))
            }
        }
        
        return presets
    }
    
    func deletePreset(named name: String) throws {
        var presetDict = loadPresetDict()
        guard presetDict.removeValue(forKey: name) != nil else {
            throw PresetError.presetNotFound
        }
        try savePresetDict(presetDict)
    }
    
    func updatePreset(named name: String, with preset: StylePreset) throws {
        var presetDict = loadPresetDict()
        guard presetDict[name] != nil else {
            throw PresetError.presetNotFound
        }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset.sanitizedForUse())
        presetDict[name] = data.base64EncodedString()
        
        try savePresetDict(presetDict)
    }
    
    func getAllPresets() -> [PresetWithMetadata] {
        let defaultPresets = Self.defaultPresets.map { preset in
            PresetWithMetadata(name: "Default", preset: preset)
        }
        let customPresets = loadCustomPresets()
        return defaultPresets + customPresets
    }
    
    func getPreset(named name: String) -> StylePreset? {
        let allPresets = getAllPresets()
        return allPresets.first { $0.name == name }?.preset
    }
    
    // MARK: - Private Helper Methods
    
    private func loadPresetDict() -> [String: String] {
        guard FileManager.default.fileExists(atPath: presetsFile.path) else {
            return [:]
        }
        
        do {
            guard let data = try dataIfLoadable(at: presetsFile) else {
                return [:]
            }
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            print("Failed to load preset dict: \(error)")
            return [:]
        }
    }
    
    private func savePresetDict(_ dict: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(dict)
        try data.write(to: presetsFile)
    }
    
    private func createDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: presetsDirectory.path) {
            try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        }
    }

    private func dataIfLoadable(at url: URL) throws -> Data? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= Self.maxPresetFileBytes else {
            return nil
        }
        return try Data(contentsOf: url)
    }
    
    // MARK: - Preset Export/Import
    
    func exportPreset(_ presetWithMetadata: PresetWithMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(presetWithMetadata.preset.sanitizedForUse())
        try data.write(to: url)
    }
    
    func importPreset(from url: URL) throws -> StylePreset {
        guard let data = try dataIfLoadable(at: url) else {
            throw PresetError.importFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StylePreset.self, from: data)
    }
    
    func exportAllPresets(to url: URL) throws {
        let presets = getAllPresets()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(presets.map { $0.preset })
        try data.write(to: url)
    }
    
    func importAllPresets(from url: URL, replaceExisting: Bool = false) throws {
        guard let data = try dataIfLoadable(at: url) else {
            throw PresetError.importFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedPresets = try decoder.decode([StylePreset].self, from: data)
        
        var presetDict = replaceExisting ? [:] : loadPresetDict()
        
        for (index, preset) in importedPresets.enumerated() {
            let name = "Imported Preset \(index + 1)"
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(preset)
            presetDict[name] = data.base64EncodedString()
        }
        
        try savePresetDict(presetDict)
    }
}

enum PresetError: Error {
    case invalidIndex
    case presetNotFound
    case saveFailed
    case loadFailed
    case importFailed
}
