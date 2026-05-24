import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum ExportDestinationMode: CaseIterable, Identifiable {
    case file
    case localSharePage
    case clipboardFile
    case cloudLink

    var id: Self { self }

    var title: String {
        switch self {
        case .file:
            return "Save Video File"
        case .localSharePage:
            return "Local Share Page"
        case .clipboardFile:
            return "Copy File Reference"
        case .cloudLink:
            return "Upload and Copy Link"
        }
    }

    var subtitle: String {
        switch self {
        case .file:
            return "Render a video or GIF to a folder you choose."
        case .localSharePage:
            return "Export video plus an index.html watch page with captions, chapters, notes, comments, and reactions."
        case .clipboardFile:
            return "Copy the exported file reference for apps that accept pasted video files."
        case .cloudLink:
            return "Upload to your configured endpoint and copy the returned share URL."
        }
    }

    var systemImage: String {
        switch self {
        case .file:
            return "folder"
        case .localSharePage:
            return "play.rectangle.on.rectangle"
        case .clipboardFile:
            return "doc.on.clipboard"
        case .cloudLink:
            return "cloud"
        }
    }

    var usesTemporaryOutput: Bool {
        self == .clipboardFile || self == .cloudLink
    }
}

struct ExportSheet: View {
    @ObservedObject var exportVM: ExportVM
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedPreset: ExportProfile
    @State private var customWidth = 3840
    @State private var customHeight = 2160
    @State private var customFPS = 60
    @State private var customQuality: Float = 0.98
    @State private var customBitrateMbps: Double = 160
    @State private var destinationMode: ExportDestinationMode = .file
    @State private var statusMessage: String?
    @State private var lastOutputURL: URL?
    @State private var lastSharePageURL: URL?
    
    init(exportVM: ExportVM) {
        self.exportVM = exportVM
        let selectedProfile = exportVM.selectedProfile
        let customProfile = selectedProfile.name == "4K Custom" ? selectedProfile : ExportProfile.custom4K
        _selectedPreset = State(initialValue: selectedProfile)
        _customWidth = State(initialValue: customProfile.width)
        _customHeight = State(initialValue: customProfile.height)
        _customFPS = State(initialValue: customProfile.fps)
        _customQuality = State(initialValue: customProfile.quality)
        _customBitrateMbps = State(initialValue: customProfile.averageBitrateMbps ?? 160)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Export Preset")) {
                    Picker("Profile", selection: $selectedPreset) {
                        ForEach(ExportProfile.allPresets) { preset in
                            Text(preset.name).tag(preset)
                        }
                    }
                }
                
                if selectedPreset.name == "4K Custom" {
                    Section(header: Text("Custom Settings")) {
                        HStack {
                            Text("Width")
                            TextField("Width", value: $customWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                            Text("px")
                        }
                        
                        HStack {
                            Text("Height")
                            TextField("Height", value: $customHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                            Text("px")
                        }
                        
                        HStack {
                            Text("Frame Rate")
                            Picker("FPS", selection: $customFPS) {
                                ForEach([15, 24, 30, 60], id: \.self) { fps in
                                    Text("\(fps)").tag(fps)
                                }
                            }
                        }
                        
                        DeferredFloatSliderRow(
                            title: "Quality",
                            value: $customQuality,
                            range: 0.1...1.0,
                            step: 0.1,
                            labelWidth: 70,
                            formatter: { "\(Int($0 * 100))%" }
                        )

                        DeferredDoubleSliderRow(
                            title: "Bitrate",
                            value: $customBitrateMbps,
                            range: 8...240,
                            step: 1,
                            labelWidth: 70,
                            formatter: { "\(Int($0)) Mbps" }
                        )
                    }
                }
                
                Section(header: Text("Export Options")) {
                    Picker("Format", selection: $selectedPreset.format) {
                        Text("MP4").tag(ExportProfile.ExportFormat.mp4)
                        Text("GIF").tag(ExportProfile.ExportFormat.gif)
                        Text("MOV").tag(ExportProfile.ExportFormat.mov)
                    }
                    
                    Picker("Orientation", selection: $selectedPreset.orientation) {
                        Text("Landscape").tag(ExportProfile.Orientation.landscape)
                        Text("Portrait").tag(ExportProfile.Orientation.portrait)
                    }
                    
                    Picker("Codec", selection: $selectedPreset.codec) {
                        Text("H.264").tag(ExportProfile.VideoCodec.h264)
                        Text("HEVC").tag(ExportProfile.VideoCodec.hevc)
                    }

                    if let bitrate = selectedPreset.name == "4K Custom" ? customBitrateMbps : selectedPreset.averageBitrateMbps {
                        Text("Target bitrate: \(Int(bitrate)) Mbps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Destination")) {
                    ForEach(ExportDestinationMode.allCases) { mode in
                        destinationButton(for: mode)
                    }

                    HStack {
                        Button {
                            chooseExportLocation()
                        } label: {
                            Label("Choose Location", systemImage: "folder.badge.plus")
                        }
                        .disabled(!destinationNeedsLocation || exportVM.isExporting)

                        Spacer()

                        if let url = exportVM.outputURL, destinationNeedsLocation {
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(destinationDetailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Section {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let lastOutputURL {
                        Button {
                            revealInFinder(lastOutputURL)
                        } label: {
                            Label("Reveal Export", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let lastSharePageURL {
                        Button {
                            NSWorkspace.shared.open(lastSharePageURL)
                        } label: {
                            Label("Open Share Page", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if exportVM.isExporting {
                        VStack(spacing: 8) {
                            ProgressView(value: exportVM.progress)
                                .progressViewStyle(.linear)
                            
                            Text("\(Int(exportVM.progress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Export Video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(exportVM.isExporting ? "Stop" : "Cancel") {
                        if exportVM.isExporting {
                            exportVM.cancelExport()
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        startExport()
                    }
                    .disabled(!canStartExport)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 540, height: 660)
        .onAppear {
            ensureDefaultOutputURL()
        }
        .onChange(of: selectedPreset.format) { _ in
            if !destinationMode.usesTemporaryOutput {
                ensureDefaultOutputURL(replacingExtensionOnly: true)
            }
        }
        .onChange(of: selectedPreset.id) { _ in
            guard selectedPreset.name == "4K Custom" else { return }
            customWidth = selectedPreset.width
            customHeight = selectedPreset.height
            customFPS = selectedPreset.fps
            customQuality = selectedPreset.quality
            customBitrateMbps = selectedPreset.averageBitrateMbps ?? 160
        }
    }
    
    private func chooseExportLocation() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = allowedContentTypes(for: selectedPreset.format)
        savePanel.nameFieldStringValue = defaultExportFilename(for: selectedPreset)
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                exportVM.outputURL = url
            }
        }
    }
    
    private func startExport() {
        // Update the selected profile with custom values if needed
        if selectedPreset.name == "4K Custom" {
            selectedPreset = ExportProfile(
                id: selectedPreset.id,
                name: selectedPreset.name,
                width: customWidth,
                height: customHeight,
                fps: customFPS,
                codec: selectedPreset.codec,
                quality: customQuality,
                averageBitrateMbps: customBitrateMbps,
                orientation: selectedPreset.orientation,
                format: selectedPreset.format
            )
        }
        
        exportVM.selectedProfile = selectedPreset
        statusMessage = nil
        lastOutputURL = nil
        lastSharePageURL = nil

        if destinationMode.usesTemporaryOutput {
            exportVM.outputURL = temporaryExportURL(for: selectedPreset)
        } else {
            ensureDefaultOutputURL()
        }
        
        Task {
            do {
                guard let project = exportVM.project else {
                    statusMessage = "No project is loaded for export."
                    return
                }
                
                let outputURL = try await exportVM.export(project: project, profile: selectedPreset)
                lastOutputURL = outputURL

                switch destinationMode {
                case .file:
                    statusMessage = "Export completed: \(outputURL.lastPathComponent)"
                case .localSharePage:
                    let localShareIndexURL = try LocalSharePackageService().createPackage(
                        videoURL: outputURL,
                        project: project
                    )
                    try ClipboardHelper.copyTextToClipboard(text: localShareIndexURL.absoluteString)
                    lastSharePageURL = localShareIndexURL
                    statusMessage = "Created local share page and copied its file link: \(localShareIndexURL.lastPathComponent)"
                case .clipboardFile:
                    try copyExportToClipboard(outputURL, format: selectedPreset.format)
                    statusMessage = "Copied exported file reference to clipboard."
                case .cloudLink:
                    let shareURL = try await CloudShareService().upload(fileURL: outputURL)
                    try ClipboardHelper.copyTextToClipboard(text: shareURL.absoluteString)
                    statusMessage = "Uploaded and copied share link: \(shareURL.absoluteString)"
                }
            } catch {
                statusMessage = exportFailureMessage(for: error)
                print("Export failed: \(error)")
            }
        }
    }

    private func ensureDefaultOutputURL(replacingExtensionOnly: Bool = false) {
        if replacingExtensionOnly, let current = exportVM.outputURL {
            exportVM.outputURL = current
                .deletingPathExtension()
                .appendingPathExtension(selectedPreset.format.rawValue)
            return
        }

        guard exportVM.outputURL == nil else { return }

        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("FocusFrame Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        exportVM.outputURL = directory.appendingPathComponent(defaultExportFilename(for: selectedPreset))
    }

    private func defaultExportFilename(for profile: ExportProfile) -> String {
        "focusframe_recording_\(Int(Date().timeIntervalSince1970)).\(profile.format.rawValue)"
    }

    private func allowedContentTypes(for format: ExportProfile.ExportFormat) -> [UTType] {
        switch format {
        case .gif:
            return [.gif]
        case .mov:
            return [.quickTimeMovie]
        case .mp4:
            return [.mpeg4Movie]
        }
    }

    private func exportFailureMessage(for error: Error) -> String {
        if error is CancellationError {
            return "Export cancelled."
        }

        let nsError = error as NSError
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            return "Export failed: \(reason)"
        }
        return "Export failed: \(error.localizedDescription)"
    }

    private func temporaryExportURL(for profile: ExportProfile) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-recording-\(UUID().uuidString).\(profile.format.rawValue)")
    }

    private func copyExportToClipboard(_ url: URL, format: ExportProfile.ExportFormat) throws {
        switch format {
        case .gif:
            try ClipboardHelper.copyGIFToClipboard(url: url)
        case .mp4, .mov:
            try ClipboardHelper.copyVideoToClipboard(url: url)
        }
    }

    @ViewBuilder
    private func destinationButton(for mode: ExportDestinationMode) -> some View {
        let available = isDestinationAvailable(mode)

        Button {
            guard available else { return }
            destinationMode = mode
            statusMessage = nil
            if mode.usesTemporaryOutput {
                exportVM.outputURL = nil
            } else {
                ensureDefaultOutputURL()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.systemImage)
                    .foregroundColor(mode == destinationMode ? .accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.callout.weight(.semibold))
                        if !available {
                            Text("Setup needed")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(Capsule())
                        }
                    }
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: mode == destinationMode ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(mode == destinationMode ? .accentColor : .secondary)
            }
            .padding(10)
            .background(mode == destinationMode ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(mode == destinationMode ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .opacity(available ? 1 : 0.58)
        }
        .buttonStyle(.plain)
        .disabled(!available || exportVM.isExporting)
    }

    private func isDestinationAvailable(_ mode: ExportDestinationMode) -> Bool {
        switch mode {
        case .cloudLink:
            return isCloudShareConfigured
        case .file, .localSharePage, .clipboardFile:
            return true
        }
    }

    private var destinationNeedsLocation: Bool {
        !destinationMode.usesTemporaryOutput
    }

    private var destinationDetailText: String {
        switch destinationMode {
        case .file:
            return exportVM.outputURL.map { "Export will be saved as \($0.lastPathComponent)." } ?? "Choose a location before exporting."
        case .localSharePage:
            return "Exports the video, creates a local share folder beside it, and copies the index.html file link."
        case .clipboardFile:
            return "The video is rendered to a temporary file, then copied as a macOS file reference. This does not copy raw video bytes."
        case .cloudLink:
            return isCloudShareConfigured
                ? "Endpoint and optional authorization come from your local launch environment."
                : "Set FOCUSFRAME_UPLOAD_ENDPOINT to enable cloud links."
        }
    }

    private var canStartExport: Bool {
        guard !exportVM.isExporting else { return false }
        guard exportVM.project != nil else { return false }
        guard isDestinationAvailable(destinationMode) else { return false }
        if destinationNeedsLocation {
            return exportVM.outputURL != nil
        }
        return true
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var isCloudShareConfigured: Bool {
        CloudShareService.Config.environment.uploadEndpoint != nil
    }
}
