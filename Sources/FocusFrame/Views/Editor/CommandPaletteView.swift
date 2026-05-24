import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var editorVM: EditorVM
    let onOpenCaptions: () -> Void
    let onExport: () -> Void
    let onAddMusic: () -> Void
    let onSaveFrame: () -> Void
    let onExtractAssets: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(filteredSections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            ForEach(section.items) { item in
                                Button {
                                    item.action()
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.systemImage)
                                            .frame(width: 22)
                                            .foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.callout.weight(.semibold))
                                                .foregroundColor(.primary)
                                            if !item.subtitle.isEmpty {
                                                Text(item.subtitle)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if filteredSections.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "command")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No command found")
                                .font(.callout.weight(.semibold))
                            Text("Try style, captions, zoom, export, music, or keyboard.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: 560)
    }

    private var filteredSections: [CommandSection] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter {
                $0.title.lowercased().contains(normalizedQuery)
                    || $0.subtitle.lowercased().contains(normalizedQuery)
                    || $0.keywords.contains(where: { $0.lowercased().contains(normalizedQuery) })
                    || section.title.lowercased().contains(normalizedQuery)
            }
            return items.isEmpty ? nil : CommandSection(title: section.title, items: items)
        }
    }

    private var sections: [CommandSection] {
        [
            CommandSection(
                title: "Looks",
                items: EditorLookPreset.allCases.map { preset in
                    CommandItem(
                        title: "Apply \(preset.label) Look",
                        subtitle: preset.summary,
                        systemImage: preset.systemImage
                    ) {
                        editorVM.applyLookPreset(preset)
                    }
                }
            ),
            CommandSection(
                title: "Edit",
                items: [
                    CommandItem(title: "Timeline Tool", subtitle: "Switch to the main timeline.", systemImage: "timeline.selection") {
                        editorVM.selectedTool = .timeline
                    },
                    CommandItem(title: "Cut Tool", subtitle: "Cut or delete selected regions.", systemImage: "scissors") {
                        editorVM.selectedTool = .cut
                    },
                    CommandItem(title: "Segment Effects Tool", subtitle: "Apply audio and visual overrides to a selected range.", systemImage: "slider.horizontal.3", keywords: ["segments", "effects", "mute", "music", "sound"]) {
                        editorVM.selectedTool = .effects
                    },
                    CommandItem(title: "Speed Tool", subtitle: "Speed up or slow down ranges.", systemImage: "speedometer") {
                        editorVM.selectedTool = .speed
                    },
                    CommandItem(title: "Manual Zoom Tool", subtitle: "Add or adjust zoom focus.", systemImage: "plus.magnifyingglass") {
                        editorVM.selectedTool = .zoom
                    },
                    CommandItem(title: "Add Zoom Here", subtitle: "Insert a zoom at the playhead.", systemImage: "plus.magnifyingglass") {
                        editorVM.addZoomSegment(at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Speed Up Typing", subtitle: "Find typing clusters and apply speed changes.", systemImage: "keyboard.badge.ellipsis") {
                        _ = editorVM.speedUpTypingSegments(multiplier: 3.0)
                    },
                    CommandItem(title: "Regenerate Auto Zooms", subtitle: "Rebuild click-driven zoom blocks from mouse data.", systemImage: "wand.and.stars", keywords: ["mouse", "click", "focus", "autozoom", "auto zoom"]) {
                        editorVM.regenerateAutomaticZooms(replacingExisting: true)
                    },
                    CommandItem(title: "Apply Smart Finish", subtitle: "Apply the default polished look, focus, keyboard, and share metadata.", systemImage: "sparkles", keywords: ["smart", "finish", "effects", "polish", "screen studio"]) {
                        editorVM.applySmartFinish()
                    },
                    CommandItem(title: "Add Quiet Segment", subtitle: "Mute music, click sounds, and key sounds in the selected range.", systemImage: "speaker.slash", keywords: ["segment", "mute", "music", "sound", "quiet"]) {
                        let start = min(editorVM.selectedRangeStart ?? editorVM.playheadTime, editorVM.selectedRangeEnd ?? editorVM.playheadTime)
                        let end = max(editorVM.selectedRangeStart ?? editorVM.playheadTime + 5, editorVM.selectedRangeEnd ?? editorVM.playheadTime + 5)
                        _ = editorVM.addEffectSegment(startTime: start, endTime: min(editorVM.duration, end), preset: .quiet)
                        editorVM.selectedTool = .effects
                    }
                ]
            ),
            CommandSection(
                title: "Captions",
                items: [
                    CommandItem(title: "Generate Captions", subtitle: "Create local captions from audio.", systemImage: "waveform.and.magnifyingglass") {
                        Task { await editorVM.generateCaptions() }
                    },
                    CommandItem(title: "Edit Transcript", subtitle: "Open caption rows and import/export captions.", systemImage: "captions.bubble") {
                        onOpenCaptions()
                    },
                    CommandItem(title: "Clean Filler Words", subtitle: "Remove ums, uhs, and repeated verbal fillers.", systemImage: "text.badge.checkmark") {
                        _ = editorVM.cleanFillerWordsFromCaptions(removeEmptySegments: false)
                    },
                    CommandItem(title: "Cut Filler Pauses", subtitle: "Remove filler-only caption segments from the timeline.", systemImage: "text.badge.minus") {
                        _ = editorVM.cleanFillerWordsFromCaptions(removeEmptySegments: true)
                    },
                    CommandItem(title: "Generate Chapters", subtitle: "Build viewer chapters from captions.", systemImage: "list.bullet.rectangle") {
                        _ = editorVM.generateChaptersFromTranscript()
                    }
                ]
            ),
            CommandSection(
                title: "Visuals",
                items: [
                    CommandItem(title: "Layout: Overlay", subtitle: "Use the standard screen with camera overlay.", systemImage: CameraLayoutMode.defaultOverlay.systemImage) {
                        editorVM.addCameraLayout(mode: .defaultOverlay)
                    },
                    CommandItem(title: "Layout: Camera", subtitle: "Switch to a full camera scene.", systemImage: CameraLayoutMode.cameraOnly.systemImage) {
                        editorVM.addCameraLayout(mode: .cameraOnly)
                    },
                    CommandItem(title: "Layout: Screen", subtitle: "Hide camera for this section.", systemImage: CameraLayoutMode.screenOnly.systemImage) {
                        editorVM.addCameraLayout(mode: .screenOnly)
                    },
                    CommandItem(title: "Layout: Split", subtitle: "Show screen and camera side by side.", systemImage: CameraLayoutMode.sideBySide.systemImage) {
                        editorVM.addCameraLayout(mode: .sideBySide)
                    },
                    CommandItem(title: "Add Blur Mask", subtitle: "Hide sensitive content at the playhead.", systemImage: "rectangle.dashed") {
                        editorVM.addOverlay(type: .blur, at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Add Highlight", subtitle: "Draw attention to an area.", systemImage: "highlighter") {
                        editorVM.addOverlay(type: .highlight, at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Add Spotlight", subtitle: "Dim everything outside a focus area.", systemImage: "scope") {
                        editorVM.addOverlay(type: .spotlight, at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Add Text Callout", subtitle: "Place an editable text overlay.", systemImage: "text.bubble") {
                        editorVM.addOverlay(type: .text, at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Add Intro/Outro Cards", subtitle: "Create polished story cards from project metadata.", systemImage: "sparkles.tv") {
                        _ = editorVM.addSmartTitleCards()
                    },
                    CommandItem(title: "Add Section Card", subtitle: "Insert a lower-third title at the playhead.", systemImage: "text.rectangle") {
                        editorVM.addTitleCard(kind: .section, at: editorVM.playheadTime)
                    },
                    CommandItem(title: "Enable Watermark", subtitle: "Show a small brand mark on exported video.", systemImage: "seal") {
                        editorVM.project.style.watermarkEnabled = true
                        if editorVM.project.style.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let creator = editorVM.project.sharePageSettings?.creatorName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            editorVM.project.style.watermarkText = creator.isEmpty ? AppBrand.name : creator
                        }
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Add Music", subtitle: "Choose a local music or audio file.", systemImage: "music.note") {
                        onAddMusic()
                    }
                ]
            ),
            CommandSection(
                title: "Audio",
                items: [
                    CommandItem(title: "Enable Mic Cleanup", subtitle: "Apply microphone noise gate during export.", systemImage: "mic.badge.plus", keywords: ["microphone", "noise", "denoise", "voice", "cleanup"]) {
                        editorVM.project.style.micNoiseReductionEnabled = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Reduce Mic Noise", subtitle: "Use a stronger microphone gate for noisy recordings.", systemImage: "waveform.path.ecg", keywords: ["microphone", "noise", "gate", "quiet", "voice", "denoise"]) {
                        editorVM.project.style.micNoiseGateThreshold = -38
                        editorVM.project.style.micNoiseReductionEnabled = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Enable Click Sounds", subtitle: "Render mouse click sounds in preview/export.", systemImage: "cursorarrow.click.2", keywords: ["mouse", "sound", "click", "effects"]) {
                        editorVM.project.style.clickSoundEnabled = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Enable Key Sounds", subtitle: "Render keyboard sounds in export audio.", systemImage: "keyboard", keywords: ["keyboard", "sound", "keys", "effects"]) {
                        editorVM.project.style.keyboardSoundEnabled = true
                        editorVM.markProjectModified()
                    }
                ]
            ),
            CommandSection(
                title: "Cursor and Keys",
                items: [
                    CommandItem(title: "Show Keyboard Badges", subtitle: "Enable shortcut badges in preview and export.", systemImage: "keyboard.badge.eye", keywords: ["keys", "keyboard", "shortcut", "badge"]) {
                        editorVM.project.showKeyboardShortcuts = true
                        editorVM.project.style.showKeyboardShortcuts = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Hide Plain Keys", subtitle: "Show only modified shortcuts like Command or Option combinations.", systemImage: "keyboard.badge.ellipsis", keywords: ["keys", "keyboard", "shortcut", "single"]) {
                        editorVM.project.style.shortcutBadgeShowSingleKeys = false
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Show Plain Keys", subtitle: "Show single-key badges as well as shortcut combinations.", systemImage: "keyboard.badge.eye", keywords: ["keys", "keyboard", "shortcut", "single"]) {
                        editorVM.project.style.shortcutBadgeShowSingleKeys = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Hide Static Cursor", subtitle: "Fade cursor when it stops moving unless clicking.", systemImage: "cursorarrow.motionlines", keywords: ["mouse", "cursor", "static", "hide"]) {
                        editorVM.project.style.hideStaticCursor = true
                        editorVM.markProjectModified()
                    },
                    CommandItem(title: "Keep Cursor Visible", subtitle: "Always render cursor in preview and export.", systemImage: "cursorarrow", keywords: ["mouse", "cursor", "visible"]) {
                        editorVM.project.style.hideStaticCursor = false
                        editorVM.markProjectModified()
                    }
                ]
            ),
            CommandSection(
                title: "Share",
                items: [
                    CommandItem(title: "Save Current Frame", subtitle: "Export a thumbnail PNG from the playhead.", systemImage: "photo") {
                        onSaveFrame()
                    },
                    CommandItem(title: "Extract Raw Assets", subtitle: "Copy raw media and project JSON.", systemImage: "shippingbox") {
                        onExtractAssets()
                    },
                    CommandItem(title: "Export", subtitle: "Render video, GIF, cloud upload, or local share page.", systemImage: "square.and.arrow.up") {
                        onExport()
                    },
                    CommandItem(title: "Save Project", subtitle: "Persist local project changes.", systemImage: "tray.and.arrow.down") {
                        editorVM.saveProject()
                    }
                ]
            )
        ]
    }
}

private struct CommandSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [CommandItem]
}

private struct CommandItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    var keywords: [String] = []
    let action: () -> Void
}
