import Foundation
import Cocoa

final class DesktopIconHider {
    private var originalIcons: [[URL]] = []
    private var desktopURLs: [URL]
    private var isHiding = false
    private let backupURL: URL

    private static let desktopFileName = "DesktopIconHider_backup.json"
    static let maxBackupFileBytes: UInt64 = 2 * 1024 * 1024

    init(
        desktopURLs: [URL] = DesktopIconHider.getDesktopURLs(),
        backupURL: URL = DesktopIconHider.defaultBackupURL()
    ) {
        self.desktopURLs = desktopURLs
        self.backupURL = backupURL
    }

    static func getDesktopURLs() -> [URL] {
        let fileManager = FileManager.default

        let urls = fileManager.urls(for: .desktopDirectory, in: .userDomainMask)
        return urls.isEmpty ? [] : urls
    }

    func hideIcons() throws {
        guard !isHiding else { return }

        if desktopURLs.isEmpty {
            desktopURLs = Self.getDesktopURLs()
        }
        originalIcons.removeAll()

        let fileManager = FileManager.default

        for desktopURL in desktopURLs {
            let contents = try fileManager.contentsOfDirectory(
                at: desktopURL,
                includingPropertiesForKeys: nil
            )

            let icons = contents.filter { url in
                let hiddenURL = desktopURL.appendingPathComponent(".\(url.lastPathComponent)")
                return !url.lastPathComponent.hasPrefix(".") &&
                    !fileManager.fileExists(atPath: hiddenURL.path)
            }

            originalIcons.append(icons)
        }

        try saveBackup()

        for (index, desktopURL) in desktopURLs.enumerated() {
            let icons = originalIcons[index]

            for iconURL in icons {
                let hiddenURL = desktopURL.appendingPathComponent(".\(iconURL.lastPathComponent)")

                do {
                    try fileManager.moveItem(at: iconURL, to: hiddenURL)
                } catch {
                    print("Failed to hide icon \(iconURL): \(error)")
                }
            }
        }

        isHiding = true
    }

    func restoreIcons() throws {
        let iconsToRestore = sanitizedIconsForRestore(isHiding ? originalIcons : try loadBackup())
        guard !iconsToRestore.isEmpty else { return }

        let fileManager = FileManager.default

        for icons in iconsToRestore {
            for iconURL in icons {
                let desktopURL = iconURL.deletingLastPathComponent()
                let hiddenURL = desktopURL.appendingPathComponent(".\(iconURL.lastPathComponent)")

                if fileManager.fileExists(atPath: hiddenURL.path) {
                    do {
                        try fileManager.moveItem(at: hiddenURL, to: iconURL)
                    } catch {
                        print("Failed to restore icon \(iconURL): \(error)")
                    }
                }
            }
        }

        originalIcons.removeAll()
        isHiding = false
        try clearBackup()
    }

    func saveBackup() throws {
        let backupData = try JSONEncoder().encode(originalIcons)
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupData.write(to: backupURL, options: .atomic)
    }

    func loadBackup() throws -> [[URL]] {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return []
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= Self.maxBackupFileBytes else {
            return []
        }

        let data = try Data(contentsOf: backupURL)
        return try JSONDecoder().decode([[URL]].self, from: data)
    }

    func clearBackup() throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
    }

    private func sanitizedIconsForRestore(_ icons: [[URL]]) -> [[URL]] {
        let allowedDesktopPaths = Set(desktopURLs.map { $0.standardizedFileURL.path })
        return icons.compactMap { desktopIcons in
            let sanitized = desktopIcons.filter { iconURL in
                allowedDesktopPaths.contains(iconURL.deletingLastPathComponent().standardizedFileURL.path) &&
                    !iconURL.lastPathComponent.hasPrefix(".")
            }
            return sanitized.isEmpty ? nil : sanitized
        }
    }

    private static func defaultBackupURL() -> URL {
        AppBrand.applicationSupportDirectory(named: "DesktopIconBackups")
            .appendingPathComponent(desktopFileName)
    }
}
