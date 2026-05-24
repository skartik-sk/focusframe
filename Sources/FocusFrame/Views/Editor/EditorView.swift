import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorView: View {
    let project: RecordingProject
    @StateObject private var editorVM: EditorVM
    @StateObject private var exportVM: ExportVM
    @State private var currentTime: Double = 0
    @State private var resumePlaybackAfterScrub = false
    @State private var showingExportSheet = false
    @State private var showingCaptionEditor = false
    @State private var showingCommandPalette = false
    @State private var showingShortcutSettings = false
    @State private var showingFullPreview = false
    @State private var finishStatusMessage: String?
    @State private var localKeyMonitor: Any?

    init(project: RecordingProject) {
        self.project = project
        _editorVM = StateObject(wrappedValue: EditorVM(project: project))
        _exportVM = StateObject(wrappedValue: {
            let vm = ExportVM()
            vm.project = project
            return vm
        }())
    }
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                editorToolbar

                ZStack {
                    Color.black

                    if !editorVM.isLoadingProjectMedia {
                        VideoPreview(time: currentTime, revision: editorVM.renderRevision) { time in
                            editorVM.getFrame(at: time)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(18)
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 46, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    if editorVM.isLoadingProjectMedia {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(editorVM.editorLoadStatusMessage ?? "Preparing editor...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleEditorPlayback()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                editorTimeline
            }
            .frame(minWidth: 720)

            Divider()

            EditorInspectorView(
                editorVM: editorVM,
                showingExportSheet: $showingExportSheet
            )
        }
        .frame(minWidth: 1040, minHeight: 680)
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(exportVM: exportVM)
                .onAppear {
                    exportVM.project = editorVM.project
                    editorVM.saveProject()
                }
        }
        .sheet(isPresented: $showingCaptionEditor) {
            CaptionEditorView(editorVM: editorVM)
        }
        .sheet(isPresented: $showingCommandPalette) {
            CommandPaletteView(
                editorVM: editorVM,
                onOpenCaptions: {
                    showingCaptionEditor = true
                },
                onExport: {
                    openExportSheet()
                },
                onAddMusic: {
                    selectBackgroundMusic()
                },
                onSaveFrame: {
                    saveThumbnail()
                },
                onExtractAssets: {
                    exportRawAssets()
                }
            )
        }
        .sheet(isPresented: $showingShortcutSettings) {
            ShortcutSettingsView(manager: KeyboardShortcutManager.shared)
        }
        .sheet(isPresented: $showingFullPreview) {
            FullPreviewView(editorVM: editorVM)
        }
        .onDisappear {
            editorVM.pausePlayback()
            editorVM.cancelBackgroundWork()
            try? FileManager.default.saveRecordingProject(editorVM.project)
            stopLocalKeyMonitor()
        }
        .onAppear(perform: startLocalKeyMonitor)
        .onReceive(editorVM.$playheadTime) { newValue in
            currentTime = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutPlayPause)) { _ in
            toggleEditorPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutFullPreview)) { _ in
            showingFullPreview = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutStopRecording)) { _ in
            editorVM.pausePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutDeleteSelection)) { _ in
            deleteSelectedTimelineItem()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutUndo)) { _ in
            editorVM.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutRedo)) { _ in
            editorVM.redo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutSeekForward)) { _ in
            editorVM.seek(to: editorVM.playheadTime + 5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutSeekBackward)) { _ in
            editorVM.seek(to: editorVM.playheadTime - 5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutExport)) { _ in
            openExportSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutCommandMenu)) { _ in
            showingCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutShowShortcuts)) { _ in
            showingShortcutSettings = true
        }
        .onChange(of: showingExportSheet) { isShowing in
            if isShowing {
                exportVM.project = editorVM.project
                editorVM.saveProject()
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
    }

    private func toggleEditorPlayback() {
        editorVM.togglePlayback()
    }

    private func openExportSheet() {
        exportVM.project = editorVM.project
        editorVM.saveProject()
        showingExportSheet = true
    }

    private func deleteSelectedTimelineItem() {
        let label = editorVM.selectedTimelineItemLabel ?? "timeline item"
        guard editorVM.removeSelectedTimelineItem() else {
            finishStatusMessage = "Select a timeline block before deleting."
            return
        }
        finishStatusMessage = "Removed selected \(label)."
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            if editorVM.nudgeSelectedTimelineItem(by: -0.1) {
                finishStatusMessage = "Moved \(editorVM.selectedTimelineItemLabel ?? "selection") left."
            } else {
                editorVM.seek(to: editorVM.playheadTime - 1)
            }
        case .right:
            if editorVM.nudgeSelectedTimelineItem(by: 0.1) {
                finishStatusMessage = "Moved \(editorVM.selectedTimelineItemLabel ?? "selection") right."
            } else {
                editorVM.seek(to: editorVM.playheadTime + 1)
            }
        case .up:
            if editorVM.nudgeSelectedOverlay(dy: -0.02) {
                finishStatusMessage = "Moved overlay up."
            }
        case .down:
            if editorVM.nudgeSelectedOverlay(dy: 0.02) {
                finishStatusMessage = "Moved overlay down."
            }
        @unknown default:
            break
        }
    }

    private func startLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleLocalKeyDown(event) ? nil : event
        }
    }

    private func stopLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard !isEditingText else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandLikeModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        guard modifiers.intersection(commandLikeModifiers).isEmpty else { return false }
        let extendsSelection = modifiers.contains(.shift)

        switch event.keyCode {
        case EditorKeyCode.escape:
            if editorVM.selectedTimelineItem != nil ||
                editorVM.selectedRangeStart != nil ||
                editorVM.selectedRangeEnd != nil {
                editorVM.clearTimelineInteractionSelection()
                finishStatusMessage = "Timeline selection cleared."
                return true
            }
            return false
        case EditorKeyCode.leftArrow:
            if extendsSelection {
                if editorVM.extendSelectedTimelineItemEnd(by: -0.1) {
                    finishStatusMessage = "Trimmed \(editorVM.selectedTimelineItemLabel ?? "selection")."
                    return true
                }
            }
            handleMoveCommand(.left)
            return true
        case EditorKeyCode.rightArrow:
            if extendsSelection {
                if editorVM.extendSelectedTimelineItemEnd(by: 0.1) {
                    finishStatusMessage = "Extended \(editorVM.selectedTimelineItemLabel ?? "selection")."
                    return true
                }
            }
            handleMoveCommand(.right)
            return true
        case EditorKeyCode.upArrow:
            handleMoveCommand(.up)
            return true
        case EditorKeyCode.downArrow:
            handleMoveCommand(.down)
            return true
        case EditorKeyCode.f:
            showingFullPreview = true
            return true
        case EditorKeyCode.delete, EditorKeyCode.forwardDelete:
            deleteSelectedTimelineItem()
            return true
        default:
            return false
        }
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private var editorToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editorVM.project.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(finishStatusMessage ?? (formatTime(currentTime) + " / " + formatTime(editorVM.duration)))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Tool", selection: $editorVM.selectedTool) {
                Label("Timeline", systemImage: "timeline.selection").tag(EditorTool.timeline)
                Label("Cut", systemImage: "scissors").tag(EditorTool.cut)
                Label("Effects", systemImage: "slider.horizontal.3").tag(EditorTool.effects)
                Label("Speed", systemImage: "speedometer").tag(EditorTool.speed)
                Label("Zoom", systemImage: "plus.magnifyingglass").tag(EditorTool.zoom)
            }
            .pickerStyle(.segmented)
            .frame(width: 440)

            Button {
                showingCommandPalette = true
            } label: {
                Image(systemName: "command")
            }
            .help("Command menu")

            Button {
                showingShortcutSettings = true
            } label: {
                Image(systemName: "keyboard")
            }
            .help("Keyboard shortcuts")

            Button {
                showingFullPreview = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Open full preview")

            Button {
                editorVM.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(editorVM.undoStack.isEmpty)
            .help("Undo")

            Button {
                editorVM.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(editorVM.redoStack.isEmpty)
            .help("Redo")

            Button(role: .destructive) {
                deleteSelectedTimelineItem()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(editorVM.selectedTimelineItem == nil)
            .help("Delete selected timeline item")

            actionsMenu

            Button {
                let summary = editorVM.applySmartFinish()
                finishStatusMessage = finishSummaryText(summary)
            } label: {
                Label("Smart Finish", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .help("Prepare project settings without rendering a file")

            Button {
                openExportSheet()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .help("Render the current project to a video file, share page, clipboard reference, or cloud link")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                let summary = editorVM.applySmartFinish()
                finishStatusMessage = finishSummaryText(summary)
            } label: {
                Label("Smart Finish", systemImage: "wand.and.stars")
            }

            Divider()

            Button {
                editorVM.addZoomSegment(at: currentTime)
                finishStatusMessage = "Zoom added at \(formatTime(currentTime))."
            } label: {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
            }

            Button {
                cutSelectedRange()
            } label: {
                Label("Cut Selection", systemImage: "scissors")
            }
            .disabled(normalizedSelectedRange == nil)

            Button {
                hideCursorInSelectedRange()
            } label: {
                Label("Hide Cursor in Selection", systemImage: "cursorarrow.slash")
            }
            .disabled(normalizedSelectedRange == nil)

            Button {
                addQuietSegmentInSelectedRange()
            } label: {
                Label("Quiet Segment", systemImage: "speaker.slash")
            }
            .disabled(normalizedSelectedRange == nil)

            Button {
                let count = editorVM.speedUpTypingSegments(multiplier: 3.0)
                finishStatusMessage = count == 0
                    ? "No typing clusters were found."
                    : "Applied speed-up to \(count) typing segment\(count == 1 ? "" : "s")."
            } label: {
                Label("Speed Up Typing", systemImage: "keyboard.badge.ellipsis")
            }

            Button {
                Task {
                    finishStatusMessage = "Generating captions..."
                    await editorVM.generateCaptions()
                    finishStatusMessage = editorVM.captionStatusMessage ?? "Caption generation finished."
                }
            } label: {
                Label("Generate Captions", systemImage: "captions.bubble")
            }
            .disabled(!editorVM.canGenerateCaptions || editorVM.isGeneratingCaptions)

            Button {
                showingCaptionEditor = true
            } label: {
                Label("Edit Transcript", systemImage: "text.bubble")
            }

            Button {
                selectBackgroundMusic()
            } label: {
                Label("Add Music", systemImage: "music.note")
            }

            if editorVM.project.style.backgroundMusicURL != nil {
                Button(role: .destructive) {
                    editorVM.removeBackgroundMusic()
                    finishStatusMessage = "Music removed."
                } label: {
                    Label("Remove Music", systemImage: "speaker.slash")
                }
            }

            Menu {
                Button("Blur") {
                    editorVM.addOverlay(type: .blur, at: currentTime)
                    finishStatusMessage = "Blur overlay added."
                }
                Button("Highlight") {
                    editorVM.addOverlay(type: .highlight, at: currentTime)
                    finishStatusMessage = "Highlight overlay added."
                }
                Button("Spotlight") {
                    editorVM.addOverlay(type: .spotlight, at: currentTime)
                    finishStatusMessage = "Spotlight overlay added."
                }
                Button("Text Callout") {
                    editorVM.addOverlay(type: .text, at: currentTime)
                    finishStatusMessage = "Text callout added."
                }
            } label: {
                Label("Add Overlay", systemImage: "rectangle.on.rectangle")
            }

            Button {
                finishStatusMessage = editorVM.copyCurrentFrameAsImage()
                    ? "Current frame copied as an image."
                    : "Could not copy the current frame."
            } label: {
                Label("Copy Current Frame", systemImage: "photo.on.rectangle")
            }

            Button {
                saveThumbnail()
            } label: {
                Label("Save Current Frame", systemImage: "photo")
            }

            Button {
                exportRawAssets()
            } label: {
                Label("Extract Raw Assets", systemImage: "shippingbox")
            }

            Divider()

            Button {
                editorVM.saveProject()
                finishStatusMessage = "Project saved."
            } label: {
                Label("Save Project", systemImage: "tray.and.arrow.down")
            }

            Button {
                openExportSheet()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("More actions")
    }

    private var editorTimeline: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    editorVM.togglePlayback()
                } label: {
                    Image(systemName: editorVM.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Slider(value: $currentTime, in: 0...editorVM.duration) { editing in
                    if editing {
                        resumePlaybackAfterScrub = editorVM.isPlaying
                        editorVM.pausePlayback()
                    } else {
                        editorVM.seek(to: currentTime)
                        if resumePlaybackAfterScrub {
                            editorVM.startPlayback()
                        }
                        resumePlaybackAfterScrub = false
                    }
                }

                Text(formatTime(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            TimelineView(editorVM: editorVM, compact: editorVM.selectedTool != .timeline)

            if editorVM.selectedTool != .timeline {
                ScrollView(.vertical) {
                    activeToolPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var activeToolPanel: some View {
        switch editorVM.selectedTool {
        case .timeline:
            EmptyView()
        case .cut:
            CutTool(editorVM: editorVM)
        case .effects:
            SegmentEffectsTool(editorVM: editorVM)
        case .speed:
            SpeedTool(editorVM: editorVM)
        case .zoom:
            ManualZoomTool(editorVM: editorVM)
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }

    private func finishSummaryText(_ summary: ProductionFinishSummary) -> String {
        var parts = ["\(summary.titleCardCount) cards"]
        if summary.captionsEnabled {
            parts.append("captions")
        }
        if summary.keyboardEnabled {
            parts.append("keys")
        }
        if summary.webcamEnabled {
            parts.append("camera")
        }
        if summary.watermarkEnabled {
            parts.append("brand")
        }
        return "Smart Finish applied: " + parts.joined(separator: ", ")
    }

    private var normalizedSelectedRange: (Double, Double)? {
        guard let start = editorVM.selectedRangeStart,
              let end = editorVM.selectedRangeEnd else {
            return nil
        }

        let lower = max(0, min(start, end))
        let upper = min(editorVM.duration, max(start, end))
        guard upper - lower >= 0.05 else { return nil }
        return (lower, upper)
    }

    private func cutSelectedRange() {
        guard let range = normalizedSelectedRange else { return }
        editorVM.cutRegion(startTime: range.0, endTime: range.1)
        finishStatusMessage = "Cut added: \(formatTime(range.0)) - \(formatTime(range.1))."
    }

    private func hideCursorInSelectedRange() {
        guard let range = normalizedSelectedRange else { return }
        editorVM.hideCursorRegion(startTime: range.0, endTime: range.1)
        finishStatusMessage = "Cursor hidden: \(formatTime(range.0)) - \(formatTime(range.1))."
    }

    private func addQuietSegmentInSelectedRange() {
        guard let range = normalizedSelectedRange else { return }
        _ = editorVM.addEffectSegment(startTime: range.0, endTime: range.1, preset: .quiet)
        editorVM.selectedTool = .effects
        finishStatusMessage = "Quiet segment added: \(formatTime(range.0)) - \(formatTime(range.1))."
    }

    private func selectBackgroundMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            editorVM.setBackgroundMusic(url: url)
            finishStatusMessage = "Music added: \(url.lastPathComponent)."
        }
    }

    private func saveThumbnail() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "thumbnail.png"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try editorVM.saveCurrentFrame(to: url)
                finishStatusMessage = "Saved current frame: \(url.lastPathComponent)."
            } catch {
                finishStatusMessage = "Could not save frame: \(error.localizedDescription)"
            }
        }
    }

    private func exportRawAssets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try editorVM.exportRawAssets(to: url)
                finishStatusMessage = "Raw assets extracted to \(url.lastPathComponent)."
            } catch {
                finishStatusMessage = "Could not extract raw assets: \(error.localizedDescription)"
            }
        }
    }
}

private enum EditorKeyCode {
    static let escape: UInt16 = 53
    static let f: UInt16 = 3
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

private struct FullPreviewView: View {
    @ObservedObject var editorVM: EditorVM
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime: Double = 0
    @State private var resumePlaybackAfterScrub = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    editorVM.togglePlayback()
                } label: {
                    Image(systemName: editorVM.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Slider(value: $currentTime, in: 0...editorVM.duration) { editing in
                    if editing {
                        resumePlaybackAfterScrub = editorVM.isPlaying
                        editorVM.pausePlayback()
                    } else {
                        editorVM.seek(to: currentTime)
                        if resumePlaybackAfterScrub {
                            editorVM.startPlayback()
                        }
                        resumePlaybackAfterScrub = false
                    }
                }

                Text(formatTime(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close preview")
            }
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor))

            ZStack {
                Color.black
                VideoPreview(time: currentTime, revision: editorVM.renderRevision) { time in
                    editorVM.getFrame(at: time)
                }
                .padding(18)
            }
        }
        .frame(minWidth: 1120, minHeight: 720)
        .onAppear {
            currentTime = editorVM.playheadTime
        }
        .onDisappear {
            editorVM.pausePlayback()
        }
        .onReceive(editorVM.$playheadTime) { time in
            currentTime = time
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }
}
