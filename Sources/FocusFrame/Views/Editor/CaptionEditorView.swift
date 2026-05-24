import SwiftUI
import UniformTypeIdentifiers

struct CaptionEditorView: View {
    @ObservedObject var editorVM: EditorVM
    @Environment(\.dismiss) private var dismiss
    @State private var statusMessage: String?
    @State private var isImportingCaptions = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if editorVM.captionSegments.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(editorVM.captionSegments) { segment in
                        CaptionSegmentRow(
                            segment: segment,
                            onApply: { updated in
                                editorVM.updateCaptionSegment(updated)
                            },
                            onDelete: {
                                editorVM.removeCaptionSegment(segment.id)
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(width: 760, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript")
                    .font(.headline)
                Text("\(editorVM.captionSegments.count) caption segments")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                editorVM.addCaptionSegment(at: editorVM.playheadTime)
            } label: {
                Label("Add", systemImage: "plus")
            }

            Menu {
                Button("Clean Filler Words") {
                    cleanFillerWords(cuttingPauses: false)
                }
                Button("Cut Filler Pauses") {
                    cleanFillerWords(cuttingPauses: true)
                }
                Divider()
                Button("Import Captions") {
                    importCaptions()
                }
                .disabled(isImportingCaptions)
                Divider()
                Button("Export JSON") {
                    exportCaptions(format: .json)
                }
                Button("Export SRT") {
                    exportCaptions(format: .srt)
                }
                Button("Export VTT") {
                    exportCaptions(format: .vtt)
                }
            } label: {
                Label("Files", systemImage: "doc.badge.gearshape")
            }

            Button("Done") {
                dismiss()
            }
        }
        .padding(16)
    }

    private func cleanFillerWords(cuttingPauses: Bool) {
        let count = editorVM.cleanFillerWordsFromCaptions(removeEmptySegments: cuttingPauses)
        statusMessage = count > 0
            ? "Cleaned \(count) filler word\(count == 1 ? "" : "s")."
            : "No filler words found."
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 34))
                .foregroundColor(.secondary)
            Text("No captions yet")
                .font(.headline)
            Text("Generate captions, import SRT/VTT, or add a caption at the current playhead.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack {
                Button {
                    Task { await editorVM.generateCaptions() }
                } label: {
                    Label("Generate", systemImage: "waveform.and.magnifyingglass")
                }
                .disabled(!editorVM.canGenerateCaptions || editorVM.isGeneratingCaptions)

                Button {
                    importCaptions()
                } label: {
                    Label(isImportingCaptions ? "Importing" : "Import", systemImage: "square.and.arrow.down")
                }
                .disabled(isImportingCaptions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            if let message = statusMessage ?? editorVM.captionStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("Show captions", isOn: Binding(
                get: { editorVM.project.subtitlesEnabled == true },
                set: { enabled in
                    editorVM.project.subtitlesEnabled = enabled
                    editorVM.markProjectModified()
                }
            ))
            .toggleStyle(.checkbox)
        }
        .padding(14)
    }

    private func importCaptions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = captionContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImportingCaptions = true
        statusMessage = "Importing \(url.lastPathComponent)..."
        Task {
            do {
                try await editorVM.importCaptionsAsync(from: url)
                statusMessage = "Imported \(url.lastPathComponent)."
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
            isImportingCaptions = false
        }
    }

    private func exportCaptions(format: CaptionFileFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType(for: format)]
        panel.nameFieldStringValue = "captions.\(format.rawValue)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editorVM.exportCaptions(to: url)
            statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private var captionContentTypes: [UTType] {
        [
            .json,
            .plainText,
            UTType(filenameExtension: "srt"),
            UTType(filenameExtension: "vtt")
        ].compactMap { $0 }
    }

    private func contentType(for format: CaptionFileFormat) -> UTType {
        switch format {
        case .json:
            return .json
        case .srt:
            return UTType(filenameExtension: "srt") ?? .plainText
        case .vtt:
            return UTType(filenameExtension: "vtt") ?? .plainText
        }
    }
}

private struct CaptionSegmentRow: View {
    let segment: CaptionSegment
    let onApply: (CaptionSegment) -> Void
    let onDelete: () -> Void

    @State private var start: Double
    @State private var end: Double
    @State private var text: String

    init(
        segment: CaptionSegment,
        onApply: @escaping (CaptionSegment) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.segment = segment
        self.onApply = onApply
        self.onDelete = onDelete
        _start = State(initialValue: segment.start)
        _end = State(initialValue: segment.end)
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Start", value: $start, formatter: Self.timeFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                TextField("End", value: $end, formatter: Self.timeFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                TextField("Caption", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    onApply(CaptionSegment(id: segment.id, start: start, end: end, text: text))
                } label: {
                    Image(systemName: "checkmark")
                }
                .help("Apply caption edit")
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete caption")
            }
        }
        .padding(.vertical, 4)
    }

    private static let timeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.minimum = 0
        return formatter
    }()
}
