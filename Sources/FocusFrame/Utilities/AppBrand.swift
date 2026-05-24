import Foundation

enum AppBrand {
    static let name = "FocusFrame"
    static let bundleIdentifier = "com.focusframe.app"
    static let supportDirectoryName = "FocusFrame"

    static func applicationSupportDirectory(named childDirectory: String) -> URL {
        let appSupport = applicationSupportRoot()
        let brandedParent = appSupport.appendingPathComponent(supportDirectoryName, isDirectory: true)
        let brandedDirectory = brandedParent.appendingPathComponent(childDirectory, isDirectory: true)

        if !FileManager.default.fileExists(atPath: brandedDirectory.path) {
            try? FileManager.default.createDirectory(at: brandedDirectory, withIntermediateDirectories: true)
        }

        return brandedDirectory
    }

    private static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
