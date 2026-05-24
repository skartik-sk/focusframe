import Foundation
import ImageIO

enum BackgroundImageHistory {
    static let storageKey = "FocusFrame.BackgroundImageHistory.v1"
    static let maxEntries = 12
    static let maxImageFileBytes: UInt64 = 80 * 1024 * 1024

    static func load(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let paths = defaults.stringArray(forKey: storageKey) ?? []
        var seen = Set<String>()
        var urls: [URL] = []

        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isUsableFile(url, fileManager: fileManager) else { continue }
            guard seen.insert(url.path).inserted else { continue }
            urls.append(url)
        }

        let limitedURLs = Array(urls.prefix(maxEntries))
        let cleanedPaths = limitedURLs.map(\.path)
        if cleanedPaths != paths {
            defaults.set(cleanedPaths, forKey: storageKey)
        }

        return limitedURLs
    }

    @discardableResult
    static func add(
        _ url: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard isUsableFile(standardizedURL, fileManager: fileManager) else { return false }

        var urls = load(defaults: defaults, fileManager: fileManager)
        urls.removeAll { $0.standardizedFileURL.path == standardizedURL.path }
        urls.insert(standardizedURL, at: 0)
        save(Array(urls.prefix(maxEntries)), defaults: defaults)
        return true
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func save(_ urls: [URL], defaults: UserDefaults) {
        defaults.set(urls.map(\.path), forKey: storageKey)
    }

    private static func isUsableFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > 0,
              fileSize.uint64Value <= maxImageFileBytes else {
            return false
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            return false
        }
        return true
    }
}
