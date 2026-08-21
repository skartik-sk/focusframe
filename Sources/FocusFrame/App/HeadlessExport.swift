import Foundation
import AVFoundation

/// Headless export mode: exports a recording from the library without showing any UI.
///
/// Usage:
///   FocusFrame --export-recording <project-UUID> [--export-output /path/to/out.mp4] [--export-preset web1080p|web720p|youtube1080p]
///
/// The process prints progress to stdout and exits 0 on success, 1 on failure.
enum HeadlessExport {
    struct Configuration {
        let projectID: UUID
        let outputURL: URL
        let preset: ExportProfile
    }

    /// True when any headless/CLI mode is running — the app must never show UI.
    static var isActive: Bool {
        let args = CommandLine.arguments
        return args.contains("--export-recording") || args.contains("--clean-audio")
    }

    static var configuration: Configuration? {
        // Utility mode: clean a single audio file and exit.
        // FocusFrame --clean-audio <input> <output>
        if CommandLine.arguments.contains("--clean-audio") {
            return nil
        }

        guard let idIndex = CommandLine.arguments.firstIndex(of: "--export-recording"),
              idIndex + 1 < CommandLine.arguments.count,
              let projectID = UUID(uuidString: CommandLine.arguments[idIndex + 1]) else {
            return nil
        }

        let outputURL: URL
        if let outIndex = CommandLine.arguments.firstIndex(of: "--export-output"),
           outIndex + 1 < CommandLine.arguments.count {
            outputURL = URL(fileURLWithPath: (CommandLine.arguments[outIndex + 1] as NSString).expandingTildeInPath)
        } else {
            outputURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/FocusFrame-export-\(projectID.uuidString.prefix(8)).mp4")
        }

        let presetName = argumentValue(for: "--export-preset") ?? "web1080p"
        var preset = switch presetName {
        case "web720p": ExportProfile.web720p
        case "youtube1080p": ExportProfile.youtube1080p
        default: ExportProfile.web1080p
        }

        if let qualityText = argumentValue(for: "--export-quality"),
           let quality = Float(qualityText), (0...1).contains(quality) {
            preset.quality = quality
        }
        if let bitrateText = argumentValue(for: "--export-bitrate"),
           let bitrate = Double(bitrateText), bitrate > 0 {
            preset.averageBitrateMbps = bitrate
        }
        if let micVolumeText = argumentValue(for: "--mic-volume"),
           let micVolume = Float(micVolumeText), micVolume >= 0 {
            micVolumeOverride = micVolume
        }

        return Configuration(projectID: projectID, outputURL: outputURL, preset: preset)
    }

    /// Test hook: applied to project.style.micAudioVolume before exporting.
    nonisolated(unsafe) static var micVolumeOverride: Float?

    private static func argumentValue(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor
    static func runAndExit(_ configuration: Configuration) async -> Never {
        print("[HeadlessExport] exporting \(configuration.projectID.uuidString) → \(configuration.outputURL.path)")

        do {
            let projects = try FileManager.default.loadRecordingProjects()
            guard var project = projects.first(where: { $0.id == configuration.projectID }) else {
                FileHandle.standardError.write("No recording found with ID \(configuration.projectID.uuidString)\n".data(using: .utf8)!)
                exit(1)
            }
            if let micVolumeOverride {
                project.style.micAudioVolume = micVolumeOverride
            }

            try? FileManager.default.removeItem(at: configuration.outputURL)

            let vm = ExportVM()
            vm.outputURL = configuration.outputURL

            let progressTask = Task.detached {
                var lastReported = -1
                while !Task.isCancelled {
                    let percent = Int(vm.progress * 100)
                    if percent != lastReported {
                        lastReported = percent
                        print("progress: \(percent)%")
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            defer { progressTask.cancel() }

            let startedAt = Date()
            let exportedURL = try await vm.export(project: project, profile: configuration.preset)
            let elapsed = Date().timeIntervalSince(startedAt)

            let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
            let sizeMB = Double((attributes[.size] as? NSNumber)?.int64Value ?? 0) / 1_000_000

            let tracks = try await AVAsset(url: exportedURL).loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                FileHandle.standardError.write("Exported file has no video track\n".data(using: .utf8)!)
                exit(1)
            }

            print("DONE \(exportedURL.path) (\(String(format: "%.1f", sizeMB)) MB in \(String(format: "%.0f", elapsed))s)")
            exit(0)
        } catch {
            FileHandle.standardError.write("FAILED: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
