import SwiftUI
import AVFoundation
import AppKit

struct HomeView: View {
    @StateObject private var recordingVM = RecordingVM()
    @State private var showingSourcePicker = false
    @State private var recentProjects: [RecordingProject] = []
    @State private var selectedProject: RecordingProject?
    @State private var refreshing = false
    @State private var showingShortcutSettings = false
    @State private var pendingDeleteProject: RecordingProject?
    @State private var homeStatusMessage: String?
    @State private var recentRecordingsTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack {
                if let project = recordingVM.finishedProject ?? selectedProject {
                    DeferredEditorHost(project: project) {
                        recordingVM.finishedProject = nil
                        selectedProject = nil
                        loadRecentRecordings()
                    }
                } else if recordingVM.isRecording {
                    RecordingOverlay(recordingVM: recordingVM)
                } else {
                    dashboard
                }
            }
            .navigationTitle(AppBrand.name)
            .sheet(isPresented: $showingSourcePicker) {
                SourcePicker(recordingVM: recordingVM)
            }
            .sheet(isPresented: $showingShortcutSettings) {
                ShortcutSettingsView(manager: KeyboardShortcutManager.shared)
            }
            .alert(
                "Delete Recording?",
                isPresented: Binding(
                    get: { pendingDeleteProject != nil },
                    set: { if !$0 { pendingDeleteProject = nil } }
                ),
                presenting: pendingDeleteProject
            ) { project in
                Button("Delete", role: .destructive) {
                    deleteProject(project)
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteProject = nil
                }
            } message: { project in
                Text("This removes \(project.title) and its local recording files.")
            }
            .task {
                loadRecentRecordings()
                postRecordingStatus()
            }
            .onDisappear {
                recentRecordingsTask?.cancel()
                recentRecordingsTask = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .startRecording)) { _ in
                showingSourcePicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutNewRecording)) { _ in
                guard !recordingVM.isRecording else { return }
                showingSourcePicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutToggleRecording)) { _ in
                if recordingVM.isRecording {
                    Task {
                        do {
                            try await recordingVM.stopRecording()
                        } catch {
                            recordingVM.lastErrorMessage = error.localizedDescription
                        }
                    }
                } else {
                    showingSourcePicker = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutPlayPause)) { _ in
                guard recordingVM.isRecording else { return }
                recordingVM.togglePause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuToggleRecordingPause)) { _ in
                guard recordingVM.isRecording else { return }
                recordingVM.togglePause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutStopRecording)) { _ in
                guard recordingVM.isRecording else { return }
                Task {
                    do {
                        try await recordingVM.stopRecording()
                    } catch {
                        recordingVM.lastErrorMessage = error.localizedDescription
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .menuStopRecording)) { _ in
                guard recordingVM.isRecording else { return }
                Task {
                    do {
                        try await recordingVM.stopRecording()
                    } catch {
                        recordingVM.lastErrorMessage = error.localizedDescription
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .shortcutShowShortcuts)) { _ in
                showingShortcutSettings = true
            }
            .onChange(of: recordingVM.isRecording) { _ in
                postRecordingStatus()
            }
            .onChange(of: recordingVM.isPaused) { _ in
                postRecordingStatus()
            }
            .onChange(of: recordingVM.finishedProject) { newValue in
                if let project = newValue {
                    expandMainWindowForEditor()
                    Task {
                        try? FileManager.default.saveRecordingProject(project)
                        loadRecentRecordings()
                    }
                }
            }
            .onChange(of: selectedProject) { newValue in
                if newValue != nil {
                    expandMainWindowForEditor()
                }
            }
        }
    }

    private func postRecordingStatus() {
        NotificationCenter.default.post(
            name: .recordingStatusChanged,
            object: nil,
            userInfo: [
                "isRecording": recordingVM.isRecording,
                "isPaused": recordingVM.isPaused
            ]
        )
    }
    
    private func loadRecentRecordings() {
        refreshing = true
        recentRecordingsTask?.cancel()

        recentRecordingsTask = Task {
            do {
                let playableProjects = try await RecentRecordingLoader.loadPlayableProjects()
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.recentProjects = playableProjects
                    self.refreshing = false
                    self.recentRecordingsTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("Failed to load recordings: \(error)")
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.recentProjects = []
                    self.refreshing = false
                    self.recentRecordingsTask = nil
                }
            }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Create a polished screen recording")
                        .font(.title2.weight(.semibold))
                    Text("Record, auto-zoom, tune the presentation, and export locally.")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    showingShortcutSettings = true
                } label: {
                    Image(systemName: "keyboard")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Keyboard shortcuts")

                Button {
                    showingSourcePicker = true
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(minWidth: 168)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)

            Divider()

            HStack {
                Text("Recent")
                    .font(.headline)

                if refreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                Spacer()

                if let homeStatusMessage {
                    Text(homeStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button(action: loadRecentRecordings) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh recordings")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ScrollView {
                if recentProjects.isEmpty {
                    EmptyRecordingsView {
                        showingSourcePicker = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 340)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(recentProjects) { project in
                            Button {
                                selectedProject = project
                            } label: {
                                RecordingCard(project: project)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(project.title)")
                            .contextMenu {
                                Button("Open") {
                                    selectedProject = project
                                }
                                Button("Reveal Files") {
                                    revealProjectFiles(project)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeleteProject = project
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private func revealProjectFiles(_ project: RecordingProject) {
        NSWorkspace.shared.activateFileViewerSelecting([project.videoFileURL])
        homeStatusMessage = "Revealed \(project.videoFileURL.lastPathComponent)."
    }

    private func expandMainWindowForEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
                  let screen = window.screen ?? NSScreen.main else {
                return
            }

            let targetFrame = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            if window.frame.width < targetFrame.width - 20 || window.frame.height < targetFrame.height - 20 {
                window.setFrame(targetFrame, display: true, animate: true)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func deleteProject(_ project: RecordingProject) {
        do {
            try FileManager.default.deleteRecordingProject(id: project.id)
            if selectedProject?.id == project.id {
                selectedProject = nil
            }
            if recordingVM.finishedProject?.id == project.id {
                recordingVM.finishedProject = nil
            }
            pendingDeleteProject = nil
            homeStatusMessage = "Deleted \(project.title)."
            loadRecentRecordings()
        } catch {
            pendingDeleteProject = nil
            homeStatusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

private struct DeferredEditorHost: View {
    let project: RecordingProject
    let onClose: () -> Void
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                EditorView(project: project)
                    .toolbar {
                        Button("Close Editor", action: onClose)
                    }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening editor")
                        .font(.headline)
                    Text(project.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .task(id: project.id) {
            isReady = false
            await Task.yield()
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isReady = true
        }
    }
}

struct EmptyRecordingsView: View {
    let startRecording: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                Text("No recordings yet")
                    .font(.headline)
                Text("Start with a short clip, then use the editor to tune zooms, cursor, captions, and export.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

struct RecordingCard: View {
    let project: RecordingProject
    @State private var thumbnail: NSImage?
    @State private var thumbnailTask: Task<Void, Never>?
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 132)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .background(Color.black.opacity(0.1))
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.12))
                        .frame(height: 132)
                        .overlay(
                            Image(systemName: "video")
                                .font(.system(size: 38))
                                .foregroundColor(.secondary.opacity(0.5))
                        )
                }

                Text(durationString(project.duration.seconds))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.66))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text(project.title)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 6) {
                ForEach(featureBadges, id: \.self) { badge in
                    RecordingFeatureBadge(title: badge)
                }

                Spacer()

                Text(dateString(project.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovering ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            thumbnailTask?.cancel()
            thumbnailTask = nil
        }
    }

    private var featureBadges: [String] {
        var badges: [String] = []
        if project.systemAudioEnabled == true || project.micAudioFileURL != nil { badges.append("Audio") }
        if project.webcamFileURL != nil { badges.append("Camera") }
        if project.captionsFileURL != nil { badges.append("Captions") }
        if project.keyEventsFileURL != nil { badges.append("Keys") }
        if !(project.titleCardSegments ?? []).isEmpty { badges.append("Cards") }
        return badges.isEmpty ? ["Raw"] : Array(badges.prefix(3))
    }
    
    private func loadThumbnail() {
        thumbnailTask?.cancel()
        let videoURL = project.videoFileURL
        thumbnailTask = Task {
            let worker = Task.detached(priority: .utility) {
                guard !Task.isCancelled,
                      FileManager.default.fileExists(atPath: videoURL.path) else {
                    return nil as CGImage?
                }
                let asset = AVAsset(url: videoURL)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                imageGenerator.maximumSize = CGSize(width: 520, height: 300)
                imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
                imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)

                guard !Task.isCancelled else { return nil as CGImage? }
                let time = CMTime(seconds: 0, preferredTimescale: 600)
                return try? imageGenerator.copyCGImage(at: time, actualTime: nil)
            }

            let cgImage = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled else { return }
            thumbnail = cgImage.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
    
    private func durationString(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }
    
    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

private enum RecentRecordingLoader {
    static func loadPlayableProjects() async throws -> [RecordingProject] {
        let projects = try await Task.detached(priority: .utility) {
            try FileManager.default.loadRecordingProjects()
        }.value
        var playableProjects: [RecordingProject] = []

        for project in projects {
            try Task.checkCancellation()
            if await isProjectPlayable(project) {
                playableProjects.append(project)
            }
        }

        return playableProjects
    }

    private static func isProjectPlayable(_ project: RecordingProject) async -> Bool {
        guard !Task.isCancelled else { return false }
        let asset = AVAsset(url: project.videoFileURL)
        guard let duration = try? await asset.load(.duration) else {
            return false
        }

        guard !Task.isCancelled else { return false }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0
    }
}

private struct RecordingFeatureBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.13))
            .foregroundColor(.accentColor)
            .clipShape(Capsule())
    }
}
