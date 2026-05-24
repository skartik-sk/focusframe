import Foundation
import ScreenCaptureKit
import Combine
import AVFoundation
import CoreGraphics

@MainActor
class RecordingVM: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: Double = 0
    @Published var selectedDisplay: SCDisplay?
    @Published var displays: [SCDisplay] = []
    
    @Published var capturesMic = RecordingVM.defaultCapturesMic
    @Published var capturesSystemAudio = true
    @Published var capturesWebcam = false
    @Published var generatesSubtitles = true
    @Published var microphoneDevices: [MediaDeviceOption] = MediaDeviceCatalog.microphoneOptions()
    @Published var cameraDevices: [MediaDeviceOption] = MediaDeviceCatalog.cameraOptions()
    @Published var selectedMicrophoneID = MediaDeviceOption.defaultID
    @Published var selectedCameraID = MediaDeviceOption.defaultID
    @Published var cropRect: CGRect? = nil
    @Published var hideDesktopIcons = false
    @Published var lastErrorMessage: String?
    @Published var isStopping = false
    @Published var speakerNotes = ""

    private var captureEngine: CaptureEngine?
    private let cursorTracker = CursorTracker()
    private let micRecorder = MicrophoneRecorder()
    private let keyboardMonitor = KeyboardMonitor()
    private let webcamCapture = WebcamCapture()
    private let transcriptionEngine = TranscriptionEngine()
    private let desktopIconHider = DesktopIconHider()
    private var projectDir: URL?
    private var currentProjectID: UUID?
    private var keysURL: URL?
    private var activeWebcamURL: URL?
    private var micAudioActive = false
    private var activeSystemAudioCapture = false

    private var timer: Timer?
    private var startTime: Date?

    private static var defaultCapturesMic: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    nonisolated static func existingRecordedMediaURL(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func refreshMediaDevices() {
        microphoneDevices = MediaDeviceCatalog.microphoneOptions()
        cameraDevices = MediaDeviceCatalog.cameraOptions()

        if !microphoneDevices.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = MediaDeviceOption.defaultID
        }
        if !cameraDevices.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = MediaDeviceOption.defaultID
        }
    }

    var selectedMicrophoneName: String {
        microphoneDevices.first(where: { $0.id == selectedMicrophoneID })?.name ?? "Default Microphone"
    }

    var selectedCameraName: String {
        cameraDevices.first(where: { $0.id == selectedCameraID })?.name ?? "Default Camera"
    }

    func loadDisplays() async {
        guard PrivacyPermissions.hasUsageDescription(.screenCapture) else {
            let message = PrivacyPermissions.missingUsageMessage(for: .screenCapture)
            lastErrorMessage = message
            print(message)
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            self.displays = content.displays
            if let first = displays.first {
                self.selectedDisplay = first
            }
            lastErrorMessage = displays.isEmpty ? "No displays are available to record." : nil
        } catch {
            let message = "Failed to load displays: \(error.localizedDescription)"
            lastErrorMessage = message
            print(message)
        }
    }

    func startRecording() async throws {
        lastErrorMessage = nil
        guard !isRecording && captureEngine == nil else {
            let error = RecordingVMError.alreadyRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        guard PrivacyPermissions.hasUsageDescription(.screenCapture) else {
            throw MissingPrivacyUsageDescriptionError(permission: .screenCapture)
        }

        guard let display = selectedDisplay else {
            let error = RecordingVMError.noDisplaySelected
            lastErrorMessage = error.localizedDescription
            throw error
        }

        if generatesSubtitles {
            let canGenerateSubtitles = await transcriptionEngine.requestAuthorizationIfNeeded()
            if !canGenerateSubtitles {
                generatesSubtitles = false
                lastErrorMessage = "Speech recognition is unavailable, so auto subtitles were disabled for this recording."
            }
        }

        let recordingsDir = FileManager.recordingsDirectory
        let projectID = UUID()
        let projectDir = recordingsDir.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        self.projectDir = projectDir
        self.currentProjectID = projectID

        let videoURL = projectDir.appendingPathComponent("raw_video.mov")
        let cursorURL = projectDir.appendingPathComponent("cursor_data.json")
        let micURL = projectDir.appendingPathComponent("mic_audio.m4a")
        let webcamURL = projectDir.appendingPathComponent("webcam.mov")
        keysURL = projectDir.appendingPathComponent("key_events.json")
        activeWebcamURL = nil
        micAudioActive = false
        activeSystemAudioCapture = false
        refreshMediaDevices()
        
        var config = CaptureEngine.Config(display: display)
        config.capturesAudio = capturesSystemAudio
        config.captureRect = cropRect

        captureEngine = CaptureEngine(outputURL: videoURL)
        do {
            try await captureEngine?.start(config: config)
            activeSystemAudioCapture = capturesSystemAudio
        } catch {
            if config.capturesAudio {
                print("Failed to start system audio capture, retrying screen-only capture: \(error)")
                try? FileManager.default.removeItem(at: videoURL)

                config.capturesAudio = false
                captureEngine = CaptureEngine(outputURL: videoURL)
                do {
                    try await captureEngine?.start(config: config)
                    capturesSystemAudio = false
                    activeSystemAudioCapture = false
                    lastErrorMessage = "System audio could not start, so this recording continued with screen video only."
                } catch {
                    captureEngine = nil
                    self.projectDir = nil
                    currentProjectID = nil
                    try? FileManager.default.removeItem(at: projectDir)
                    lastErrorMessage = error.localizedDescription
                    throw error
                }
            } else {
                captureEngine = nil
                self.projectDir = nil
                currentProjectID = nil
                try? FileManager.default.removeItem(at: projectDir)
                lastErrorMessage = error.localizedDescription
                throw error
            }
        }

        isRecording = true
        isPaused = false
        startTime = Date()
        recordingDuration = 0
        startDurationTimer()
        print("Recording started: \(videoURL.path)")

        let sourceRect = cropRect ?? CGRect(
            x: 0,
            y: 0,
            width: display.width,
            height: display.height
        )
        cursorTracker.start(
            outputURL: cursorURL,
            captureRect: sourceRect,
            displayBounds: CGDisplayBounds(display.displayID)
        )

        if let keysURL = keysURL {
            keyboardMonitor.start(outputURL: keysURL)
        }

        if hideDesktopIcons {
            try? desktopIconHider.hideIcons()
        }
        
        if capturesMic {
            if PrivacyPermissions.hasUsageDescription(.microphone) {
                let microphoneAllowed = await requestMicrophoneAccessIfNeeded()
                if microphoneAllowed {
                    do {
                        let recorder = micRecorder
                        let selectedDevice = MediaDeviceCatalog.device(for: selectedMicrophoneID, mediaType: .audio)
                        try await Task.detached(priority: .userInitiated) {
                            try recorder.start(outputURL: micURL, device: selectedDevice)
                        }.value
                        micAudioActive = true
                    } catch {
                        micAudioActive = false
                        capturesMic = false
                        lastErrorMessage = "Microphone recording could not start: \(error.localizedDescription)"
                        print("Failed to start microphone capture: \(error)")
                    }
                } else {
                    micAudioActive = false
                    capturesMic = false
                    lastErrorMessage = "Microphone permission is disabled. Recording will continue without microphone audio."
                }
            } else {
                micAudioActive = false
                capturesMic = false
                let message = PrivacyPermissions.missingUsageMessage(for: .microphone)
                lastErrorMessage = message
                print(message)
            }
        }

        if capturesWebcam {
            if PrivacyPermissions.hasUsageDescription(.camera) {
                do {
                    let capture = webcamCapture
                    let selectedDevice = MediaDeviceCatalog.device(for: selectedCameraID, mediaType: .video)
                    try await Task.detached(priority: .userInitiated) {
                        try capture.start(outputURL: webcamURL, device: selectedDevice)
                    }.value
                    activeWebcamURL = webcamURL
                } catch {
                    activeWebcamURL = nil
                    capturesWebcam = false
                    lastErrorMessage = "Webcam recording could not start: \(error.localizedDescription)"
                    print("Failed to start webcam capture: \(error)")
                }
            } else {
                activeWebcamURL = nil
                capturesWebcam = false
                let message = PrivacyPermissions.missingUsageMessage(for: .camera)
                lastErrorMessage = message
                print(message)
            }
        }
    }

    @Published var finishedProject: RecordingProject?

    func stopRecording() async throws {
        guard !isStopping else { return }
        guard isRecording || captureEngine != nil else { return }

        isStopping = true
        defer { isStopping = false }

        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false

        var stopError: Error?
        let videoURL: URL?
        do {
            videoURL = try await captureEngine?.stop()
        } catch {
            stopError = error
            videoURL = nil
            lastErrorMessage = error.localizedDescription
            print("Recording stop failed: \(error.localizedDescription)")
        }

        let cursorURL = cursorTracker.stop()
        let keysResult = keyboardMonitor.stop()
        var micURL: URL? = nil
        if micAudioActive {
            let recorder = micRecorder
            micURL = await Task.detached(priority: .userInitiated) {
                await recorder.stop()
            }.value
        }
        let webcamCapture = webcamCapture
        let webcamURL = await Task.detached(priority: .userInitiated) {
            await webcamCapture.stop()
        }.value
        let finalizedWebcamURL = Self.existingRecordedMediaURL(webcamURL ?? activeWebcamURL)

        if hideDesktopIcons {
            try? desktopIconHider.restoreIcons()
        }

        if let videoURL = videoURL {
            let videoAsset = AVAsset(url: videoURL)
            let assetDuration = try? await videoAsset.load(.duration)
            let audioTracks = (try? await videoAsset.loadTracks(withMediaType: .audio)) ?? []
            let hasEmbeddedSystemAudio = activeSystemAudioCapture && !audioTracks.isEmpty
            let duration = assetDuration?.seconds.isFinite == true
                ? (assetDuration?.seconds ?? 0)
                : Date().timeIntervalSince(startTime ?? Date())
            let sourceRect = cropRect ?? CGRect(
                x: 0,
                y: 0,
                width: selectedDisplay?.width ?? 1920,
                height: selectedDisplay?.height ?? 1080
            )
            let shouldGenerateCaptions = generatesSubtitles
            let captionsURL = (projectDir ?? videoURL.deletingLastPathComponent())
                .appendingPathComponent("captions.json")

            let project = RecordingProject(
                id: currentProjectID ?? UUID(),
                createdAt: Date(),
                modifiedAt: Date(),
                title: "New Recording",
                videoFileURL: videoURL,
                cursorDataFileURL: cursorURL,
                keyEventsFileURL: keysResult,
                micAudioFileURL: micURL,
                systemAudioFileURL: hasEmbeddedSystemAudio ? videoURL : nil,
                webcamFileURL: finalizedWebcamURL,
                captionsFileURL: nil,
                duration: CMTime(seconds: duration, preferredTimescale: 600),
                sourceRect: sourceRect,
                displayID: selectedDisplay?.displayID ?? 0,
                zoomSegments: [],
                editActions: [],
                cropRect: cropRect,
                style: .default,
                hideDesktopIcons: hideDesktopIcons,
                showKeyboardShortcuts: keysResult != nil,
                webcamEnabled: finalizedWebcamURL != nil,
                subtitlesEnabled: false
            )
            var projectWithNotes = project
            projectWithNotes.systemAudioEnabled = hasEmbeddedSystemAudio
            let notes = speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            projectWithNotes.speakerNotes = notes.isEmpty ? nil : notes
            do {
                try FileManager.default.saveRecordingProject(projectWithNotes)
            } catch {
                lastErrorMessage = "Recording finished, but saving project metadata failed: \(error.localizedDescription)"
                print("Failed to save finalized project: \(error)")
            }
            self.finishedProject = projectWithNotes
            print("Recording finalized: \(videoURL.path), duration: \(duration)s")

            if shouldGenerateCaptions {
                generateCaptionsAfterSaving(
                    project: projectWithNotes,
                    audioURL: micURL ?? videoURL,
                    outputURL: captionsURL
                )
            }
        }

        currentProjectID = nil
        projectDir = nil
        captureEngine = nil
        activeWebcamURL = nil
        micAudioActive = false
        activeSystemAudioCapture = false

        if let stopError {
            throw stopError
        }
    }

    private func generateCaptionsAfterSaving(project: RecordingProject, audioURL: URL?, outputURL: URL) {
        Task { @MainActor in
            guard let captionsFileURL = await generateCaptionsIfNeeded(audioURL: audioURL, outputURL: outputURL) else {
                return
            }

            var updatedProject = project
            updatedProject.captionsFileURL = captionsFileURL
            updatedProject.subtitlesEnabled = true
            updatedProject.modifiedAt = Date()

            do {
                try FileManager.default.saveRecordingProject(updatedProject)
                if finishedProject?.id == updatedProject.id {
                    finishedProject = updatedProject
                }
            } catch {
                lastErrorMessage = "Captions finished, but updating project metadata failed: \(error.localizedDescription)"
                print("Failed to save caption metadata: \(error)")
            }
        }
    }

    private func generateCaptionsIfNeeded(audioURL: URL?, outputURL: URL) async -> URL? {
        guard generatesSubtitles, let audioURL else { return nil }
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }

        do {
            let segments = try await transcriptionEngine.transcribe(audioURL: audioURL)
            guard !segments.isEmpty else { return nil }

            let data = try JSONEncoder().encode(segments)
            try data.write(to: outputURL)

            let srtURL = outputURL.deletingPathExtension().appendingPathExtension("srt")
            let vttURL = outputURL.deletingPathExtension().appendingPathExtension("vtt")
            try? transcriptionEngine.writeSRT(segments: segments, to: srtURL)
            try? transcriptionEngine.writeVTT(segments: segments, to: vttURL)

            return outputURL
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("No speech detected") {
                print("No speech detected; captions skipped.")
                return nil
            }
            print("Failed to generate captions: \(error)")
            return nil
        }
    }
    
    func togglePause() {
        guard isRecording || captureEngine != nil else { return }

        isPaused.toggle()
        
        if isPaused {
            timer?.invalidate()
            captureEngine?.pause()
            cursorTracker.pause()
            keyboardMonitor.pause()
            micRecorder.pause()
            webcamCapture.pause()
        } else {
            captureEngine?.resume()
            cursorTracker.resume()
            keyboardMonitor.resume()
            micRecorder.resume()
            webcamCapture.resume()
            startDurationTimer()
        }
    }

    private func startDurationTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isPaused else { return }
                self.recordingDuration += 1
            }
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum RecordingVMError: LocalizedError {
    case noDisplaySelected
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .noDisplaySelected:
            return "Choose a display before starting the recording."
        case .alreadyRecording:
            return "A recording is already in progress."
        }
    }
}
