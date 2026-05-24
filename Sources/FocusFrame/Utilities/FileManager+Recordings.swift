import Foundation

extension FileManager {
    static let maxProjectMetadataBytes: UInt64 = 5 * 1024 * 1024

    static var recordingsDirectory: URL {
        AppBrand.applicationSupportDirectory(named: "Recordings")
    }
    
    func saveRecordingProject(_ project: RecordingProject) throws {
        let fileURL = Self.recordingsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project.sanitizedForUse())
        try data.write(to: fileURL)
    }
    
    func loadRecordingProjects(includeInvalid: Bool = false) throws -> [RecordingProject] {
        let files = try contentsOfDirectory(at: Self.recordingsDirectory, includingPropertiesForKeys: nil)
        var projects: [RecordingProject] = []
        
        for file in files where file.pathExtension == "json" {
            do {
                guard try metadataFileIsLoadable(file) else { continue }
                let data = try Data(contentsOf: file)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let project = try decoder.decode(RecordingProject.self, from: data).sanitizedForUse()
                if FileManager.default.fileExists(atPath: project.videoFileURL.path),
                   includeInvalid || hasUsableMovieFile(project.videoFileURL) {
                    projects.append(project)
                }
            } catch {
                print("Failed to load project \(file.lastPathComponent): \(error)")
            }
        }
        
        return projects.sorted { $0.createdAt > $1.createdAt }
    }

    private func hasUsableMovieFile(_ url: URL) -> Bool {
        guard let attributes = try? attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.int64Value > 1024
    }

    private func metadataFileIsLoadable(_ url: URL) throws -> Bool {
        let attributes = try attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.uint64Value <= Self.maxProjectMetadataBytes
    }
    
    func deleteRecordingProject(id: UUID) throws {
        let fileURL = Self.recordingsDirectory.appendingPathComponent("\(id.uuidString).json")
        let projectDir = Self.recordingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        
        if fileExists(atPath: projectDir.path) {
            try removeItem(at: projectDir)
        }
        if fileExists(atPath: fileURL.path) {
            try removeItem(at: fileURL)
        }
    }
}
