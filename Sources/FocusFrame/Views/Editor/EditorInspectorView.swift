import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EditorInspectorView: View {
    @ObservedObject var editorVM: EditorVM
    @Binding var showingExportSheet: Bool
    @State private var settingsStatusMessage: String?
    @State private var showingCaptionEditor = false
    @State private var inspectorMode: InspectorMode = .smart
    @State private var finishSummary: ProductionFinishSummary?
    @State private var showSmartFeatureStatus = false
    @State private var recentBackgroundImages = BackgroundImageHistory.load()
    @State private var isImportingSettings = false
    nonisolated private static let maxSettingsImportBytes: UInt64 = 2 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Customize")
                            .font(.headline)
                        Text("Local project settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            importSettings()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help("Import settings")
                        .disabled(isImportingSettings)

                        Button {
                            exportSettings()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .help("Export settings")

                        Button {
                            editorVM.saveProject()
                        } label: {
                            Image(systemName: "tray.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help("Save project")
                    }
                }
                if let settingsStatusMessage {
                    Text(settingsStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Inspector", selection: $inspectorMode) {
                            Text("Smart").tag(InspectorMode.smart)
                            Text("Advanced").tag(InspectorMode.advanced)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if inspectorMode == .smart {
                            smartInspectorContent
                        } else {
                    inspectorSection("Preview") {
                        Picker("Mode", selection: $editorVM.previewRenderMode) {
                            ForEach(PreviewRenderMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Text("Performance disables heavier preview effects only. Export still uses full quality.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    inspectorSection("Look") {
                        Picker("Background", selection: styleBinding(\.backgroundType)) {
                            Text("Solid").tag(BackgroundType.solid)
                            Text("Gradient").tag(BackgroundType.gradient)
                            Text("Image").tag(BackgroundType.image)
                        }

                        switch editorVM.project.style.backgroundType {
                        case .solid:
                            ColorPicker("Color", selection: colorBinding(\.backgroundColor))
                        case .gradient:
                            ColorPicker("Start", selection: gradientColorBinding(index: 0))
                            ColorPicker("End", selection: gradientColorBinding(index: 1))
                            valueSlider(
                                "Angle",
                                value: styleBinding(\.backgroundGradientAngle),
                                range: 0...360,
                                suffix: "deg"
                            )
                        case .image:
                            backgroundImageControls
                            if let imageURL = editorVM.project.style.backgroundImageURL {
                                Text(imageURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        valueSlider("Padding", value: styleBinding(\.padding), range: 0...180, suffix: "px")
                        valueSlider("Corners", value: styleBinding(\.cornerRadius), range: 0...60, suffix: "px")
                    }

                    inspectorSection("Depth") {
                        Toggle("Shadow", isOn: styleBinding(\.shadowEnabled))
                        if editorVM.project.style.shadowEnabled {
                            valueSlider("Radius", value: styleBinding(\.shadowRadius), range: 0...80, suffix: "px")
                            valueSlider("Offset Y", value: styleBinding(\.shadowOffsetY), range: -30...50, suffix: "px")
                            valueSlider("Opacity", value: shadowOpacityBinding, range: 0...1, suffix: "")
                        }
                        Toggle("Motion blur", isOn: styleBinding(\.motionBlurEnabled))
                        if editorVM.project.style.motionBlurEnabled {
                            valueSlider("Blur", value: styleBinding(\.motionBlurStrength), range: 0...12, suffix: "")
                        }
                    }

                    inspectorSection("Cursor") {
                        valueSlider("Scale", value: styleBinding(\.cursorScale), range: 0.5...3, suffix: "x")
                        valueSlider("Auto Zoom", value: autoZoomScaleBinding, range: 1.05...2.4, suffix: "x")
                        Picker("Motion", selection: styleBinding(\.cursorStyle)) {
                            Text("Rapid").tag(CursorMovementStyle.rapid)
                            Text("Quick").tag(CursorMovementStyle.quick)
                            Text("Default").tag(CursorMovementStyle.default)
                            Text("Slow").tag(CursorMovementStyle.slow)
                        }
                        Toggle("Hide when idle", isOn: styleBinding(\.hideStaticCursor))
                        Toggle("High-res cursor", isOn: styleBinding(\.useHighResCursors))
                        Toggle("Click sound", isOn: styleBinding(\.clickSoundEnabled))
                        if editorVM.project.style.clickSoundEnabled {
                            Picker("Click Source", selection: styleBinding(\.clickSoundStyle)) {
                                ForEach(ClickSoundStyle.allCases, id: \.self) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            if editorVM.project.style.clickSoundStyle == .custom {
                                soundFileControls(
                                    title: "Click file",
                                    url: editorVM.project.style.clickSoundFileURL,
                                    choose: selectClickSoundFile,
                                    clear: clearClickSoundFile
                                )
                            }
                            valueSlider("Click Vol", value: styleBinding(\.clickSoundVolume), range: 0...1, suffix: "")
                            Button {
                                editorVM.previewClickSound()
                            } label: {
                                Label("Preview Click", systemImage: "speaker.wave.2")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    inspectorSection("Overlays") {
                        HStack {
                            Toggle("Subtitles", isOn: subtitlesEnabledBinding)
                                .disabled(editorVM.project.captionsFileURL == nil)
                            Spacer()
                            if editorVM.project.captionsFileURL == nil {
                                Button {
                                    Task {
                                        await editorVM.generateCaptions()
                                    }
                                } label: {
                                    if editorVM.isGeneratingCaptions {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "waveform.and.magnifyingglass")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(!editorVM.canGenerateCaptions || editorVM.isGeneratingCaptions)
                                .help("Generate captions")
                            }
                        }
                        if let captionStatus = editorVM.captionStatusMessage {
                            Text(captionStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Button {
                            showingCaptionEditor = true
                        } label: {
                            Label("Edit Transcript", systemImage: "captions.bubble")
                        }
                        .buttonStyle(.bordered)
                        if editorVM.project.subtitlesEnabled == true || editorVM.project.captionsFileURL != nil {
                            Picker("Subtitle Pos", selection: styleBinding(\.subtitlePosition)) {
                                Text("Bottom").tag(SubtitlePosition.bottomCenter)
                                Text("Middle").tag(SubtitlePosition.middleCenter)
                                Text("Top").tag(SubtitlePosition.topCenter)
                            }
                            valueSlider("Sub Size", value: styleBinding(\.subtitleFontSize), range: 16...42, suffix: "px")
                            valueSlider("Sub BG", value: styleBinding(\.subtitleBackgroundOpacity), range: 0...1, suffix: "")
                        }
                        Toggle("Keyboard badges", isOn: keyboardShortcutsBinding)
                        if editorVM.project.showKeyboardShortcuts || editorVM.project.style.showKeyboardShortcuts {
                            Picker("Key Pos", selection: styleBinding(\.shortcutBadgePosition)) {
                                ForEach(ShortcutPosition.allCases) { position in
                                    Text(position.label).tag(position)
                                }
                            }
                            Picker("Key Style", selection: styleBinding(\.shortcutBadgeStyle)) {
                                ForEach(ShortcutBadgeStyle.allCases) { style in
                                    Text(style.label).tag(style)
                                }
                            }
                            valueSlider("Key Size", value: styleBinding(\.shortcutBadgeFontSize), range: 12...34, suffix: "px")
                            valueSlider("Opacity", value: styleBinding(\.shortcutBadgeBackgroundOpacity), range: 0.15...1, suffix: "")
                            valueSlider("Key Hold", value: styleBinding(\.shortcutBadgeDuration), range: 0.4...3.0, suffix: "s")
                            Toggle("Single keys", isOn: styleBinding(\.shortcutBadgeShowSingleKeys))
                            Toggle("Custom colors", isOn: styleBinding(\.shortcutBadgeUseCustomColors))
                            if editorVM.project.style.shortcutBadgeUseCustomColors {
                                ColorPicker("Fill", selection: colorBinding(\.shortcutBadgeBackgroundColor))
                                ColorPicker("Text", selection: colorBinding(\.shortcutBadgeTextColor))
                            }
                            Toggle("Keypress sound", isOn: styleBinding(\.keyboardSoundEnabled))
                            if editorVM.project.style.keyboardSoundEnabled {
                                Picker("Key Source", selection: styleBinding(\.keyboardSoundStyle)) {
                                    ForEach(KeyboardSoundStyle.allCases, id: \.self) { style in
                                        Text(style.label).tag(style)
                                    }
                                }
                                if editorVM.project.style.keyboardSoundStyle == .custom {
                                    soundFileControls(
                                        title: "Key file",
                                        url: editorVM.project.style.keyboardSoundFileURL,
                                        choose: selectKeyboardSoundFile,
                                        clear: clearKeyboardSoundFile
                                    )
                                }
                                valueSlider("Key Vol", value: styleBinding(\.keyboardSoundVolume), range: 0...1, suffix: "")
                                Button {
                                    editorVM.previewKeyboardSound()
                                } label: {
                                    Label("Preview Key", systemImage: "speaker.wave.2")
                                }
                                .buttonStyle(.bordered)
                            }
                            Button {
                                let count = editorVM.speedUpTypingSegments(multiplier: 3.0)
                                settingsStatusMessage = count > 0
                                    ? "Applied speed-up to \(count) typing segment\(count == 1 ? "" : "s")."
                                    : "No typing segments found."
                            } label: {
                                Label("Speed Up Typing", systemImage: "keyboard.badge.ellipsis")
                            }
                            .buttonStyle(.bordered)
                        }
                        if !editorVM.hasKeyboardEvents {
                            Text("No key presses were recorded for this project.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Toggle("Webcam", isOn: webcamEnabledBinding)
                            .disabled(editorVM.project.webcamFileURL == nil)

                        if editorVM.project.webcamEnabled {
                            Picker("Webcam", selection: styleBinding(\.webcamPosition)) {
                                Text("Bottom Right").tag(WebcamPosition.bottomRight)
                                Text("Bottom Left").tag(WebcamPosition.bottomLeft)
                                Text("Top Right").tag(WebcamPosition.topRight)
                                Text("Top Left").tag(WebcamPosition.topLeft)
                            }
                            Picker("Shape", selection: styleBinding(\.webcamShape)) {
                                Text("Circle").tag(WebcamShape.circle)
                                Text("Rounded").tag(WebcamShape.roundedRect)
                                Text("Square").tag(WebcamShape.square)
                            }
                            if editorVM.project.style.webcamShape == .roundedRect {
                                valueSlider("Roundness", value: styleBinding(\.webcamCornerRadius), range: 0...96, suffix: "px")
                            }
                            Toggle("Mirror", isOn: styleBinding(\.webcamMirror))
                            valueSlider("Size", value: styleBinding(\.webcamSize), range: 96...280, suffix: "px")
                            if editorVM.project.style.webcamShape != .circle {
                                valueSlider("Width", value: styleBinding(\.webcamWidth), range: 96...420, suffix: "px")
                                valueSlider("Height", value: styleBinding(\.webcamHeight), range: 96...320, suffix: "px")
                            }
                            valueSlider("Nudge X", value: styleBinding(\.webcamOffsetX), range: -480...480, suffix: "px")
                            valueSlider("Nudge Y", value: styleBinding(\.webcamOffsetY), range: -360...360, suffix: "px")
                            valueSlider("Zoom Size", value: styleBinding(\.webcamZoomScale), range: 0.35...1.2, suffix: "x")
                            Toggle("Enhance", isOn: styleBinding(\.webcamEnhanceEnabled))
                            if editorVM.project.style.webcamEnhanceEnabled {
                                valueSlider("Bright", value: styleBinding(\.webcamBrightness), range: -0.08...0.12, suffix: "")
                                valueSlider("Contrast", value: styleBinding(\.webcamContrast), range: 0.9...1.22, suffix: "")
                                valueSlider("Color", value: styleBinding(\.webcamSaturation), range: 0.8...1.35, suffix: "")
                            }
                            Toggle("Frame", isOn: styleBinding(\.webcamBorderEnabled))
                            if editorVM.project.style.webcamBorderEnabled {
                                valueSlider("Border", value: styleBinding(\.webcamBorderWidth), range: 0.5...8, suffix: "px")
                            }
                            Toggle("Cam Shadow", isOn: styleBinding(\.webcamShadowEnabled))
                            if editorVM.project.style.webcamShadowEnabled {
                                valueSlider("Shadow", value: styleBinding(\.webcamShadowOpacity), range: 0...0.8, suffix: "")
                            }
                            Button {
                                editorVM.project.style.webcamOffsetX = 0
                                editorVM.project.style.webcamOffsetY = 0
                                editorVM.project.style.webcamWidth = 0
                                editorVM.project.style.webcamHeight = 0
                                editorVM.project.style.webcamZoomScale = 0.9
                                editorVM.project.style.webcamEnhanceEnabled = true
                                editorVM.project.style.webcamBrightness = 0.035
                                editorVM.project.style.webcamContrast = 1.06
                                editorVM.project.style.webcamSaturation = 1.08
                                editorVM.project.style.webcamBorderEnabled = true
                                editorVM.project.style.webcamBorderWidth = 2
                                editorVM.project.style.webcamShadowEnabled = true
                                editorVM.project.style.webcamShadowOpacity = 0.32
                                editorVM.markProjectModified()
                            } label: {
                                Label("Reset Webcam", systemImage: "scope")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    inspectorSection("Visual Marks") {
                        HStack(spacing: 6) {
                            Button("Blur") {
                                editorVM.addOverlay(type: .blur, at: editorVM.playheadTime)
                            }
                            Button("Highlight") {
                                editorVM.addOverlay(type: .highlight, at: editorVM.playheadTime)
                            }
                            Button("Spotlight") {
                                editorVM.addOverlay(type: .spotlight, at: editorVM.playheadTime)
                            }
                            Button("Text") {
                                editorVM.addOverlay(type: .text, at: editorVM.playheadTime)
                            }
                        }
                        .buttonStyle(.bordered)

                        if (editorVM.project.overlayElements ?? []).isEmpty {
                            Text("Add blur, highlight, spotlight, or text overlays at the playhead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        } else {
                            ForEach(editorVM.project.overlayElements ?? []) { overlay in
                                overlayRow(overlay)
                            }
                        }
                    }

                    inspectorSection("Chapters & Notes") {
                        HStack(spacing: 8) {
                            Button {
                                let count = editorVM.generateChaptersFromTranscript()
                                settingsStatusMessage = "Generated \(count) chapter\(count == 1 ? "" : "s")."
                            } label: {
                                Label("Generate", systemImage: "list.bullet.rectangle")
                            }
                            Button {
                                editorVM.addChapter(at: editorVM.playheadTime)
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            Button {
                                exportChapters()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)

                        if (editorVM.project.chapterMarkers ?? []).isEmpty {
                            Text("Generate chapters from captions or add a marker at the playhead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        } else {
                            ForEach(editorVM.project.chapterMarkers ?? []) { chapter in
                                chapterRow(chapter)
                            }
                        }

                        Text("Speaker Notes")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        TextEditor(text: speakerNotesBinding)
                            .font(.system(size: 12))
                            .frame(minHeight: 82)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    inspectorSection("Title Cards & Brand") {
                        HStack(spacing: 8) {
                            Button {
                                let count = editorVM.addSmartTitleCards()
                                settingsStatusMessage = "Prepared \(count) story card\(count == 1 ? "" : "s")."
                            } label: {
                                Label("Auto Cards", systemImage: "sparkles.tv")
                            }
                            Menu {
                                ForEach(TitleCardKind.allCases) { kind in
                                    Button(kind.label) {
                                        editorVM.addTitleCard(kind: kind, at: editorVM.playheadTime)
                                    }
                                }
                            } label: {
                                Label("Add Card", systemImage: "plus.rectangle.on.rectangle")
                            }
                        }
                        .buttonStyle(.bordered)

                        if editorVM.titleCards.isEmpty {
                            Text("Add intro, outro, or lower-third section cards for finished videos.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        } else {
                            ForEach(editorVM.titleCards) { card in
                                titleCardRow(card)
                            }
                        }

                        watermarkControls
                    }

                    inspectorSection("Audio") {
                        valueSlider("Screen Vol", value: styleBinding(\.sourceAudioVolume), range: 0...1, suffix: "")
                        if editorVM.project.micAudioFileURL != nil {
                            valueSlider("Mic Vol", value: styleBinding(\.micAudioVolume), range: 0...1, suffix: "")
                        } else {
                            Text("No microphone track in this project.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Toggle("Mic noise reduction", isOn: styleBinding(\.micNoiseReductionEnabled))
                            .disabled(editorVM.project.micAudioFileURL == nil)
                        if editorVM.project.style.micNoiseReductionEnabled {
                            valueSlider("Noise Gate", value: styleBinding(\.micNoiseGateThreshold), range: -65 ... -25, suffix: "dB")
                                .disabled(editorVM.project.micAudioFileURL == nil)
                            Text("Applied to the microphone track during export.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Button {
                            selectBackgroundMusic()
                        } label: {
                            Label("Add Music", systemImage: "music.note")
                        }
                        .buttonStyle(.bordered)

                        if let musicURL = editorVM.project.style.backgroundMusicURL {
                            HStack {
                                Text(musicURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    editorVM.removeBackgroundMusic()
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove music")
                            }
                            valueSlider("Music Vol", value: styleBinding(\.backgroundMusicVolume), range: 0...1, suffix: "")
                            Toggle("Loop music", isOn: styleBinding(\.backgroundMusicLoop))
                            valueSlider("Fade In", value: styleBinding(\.backgroundMusicFadeIn), range: 0...5, suffix: "s")
                            valueSlider("Fade Out", value: styleBinding(\.backgroundMusicFadeOut), range: 0...5, suffix: "s")
                            Toggle("Duck under voice", isOn: styleBinding(\.backgroundMusicDuckingEnabled))
                            if editorVM.project.style.backgroundMusicDuckingEnabled {
                                valueSlider("Duck Vol", value: styleBinding(\.backgroundMusicDuckingVolume), range: 0...1, suffix: "")
                                if editorVM.project.captionsFileURL == nil {
                                    Text("Generate or import captions to duck music around speech.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }

                    inspectorSection("Utilities") {
                        Button {
                            saveThumbnail()
                        } label: {
                            Label("Save Current Frame", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            exportRawAssets()
                        } label: {
                            Label("Extract Raw Assets", systemImage: "shippingbox")
                        }
                        .buttonStyle(.bordered)
                    }

                    inspectorSection("Share Page") {
                        TextField("Page title", text: shareSettingsBinding(\.titleOverride))
                            .textFieldStyle(.roundedBorder)
                        TextField("Creator", text: shareSettingsBinding(\.creatorName))
                            .textFieldStyle(.roundedBorder)
                        TextField("Description", text: shareSettingsBinding(\.description), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        TextField("CTA label", text: shareSettingsBinding(\.callToActionLabel))
                            .textFieldStyle(.roundedBorder)
                        TextField("CTA URL", text: shareSettingsBinding(\.callToActionURL))
                            .textFieldStyle(.roundedBorder)
                        ColorPicker("Accent", selection: shareAccentBinding)
                    }

                    inspectorSection("Output") {
                        Button {
                            editorVM.saveProject()
                            showingExportSheet = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: editorVM.selectedTimelineItem) { selection in
                    focusInspector(on: selection, proxy: proxy)
                }
            }
        }
        .frame(width: 320)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showingCaptionEditor) {
            CaptionEditorView(editorVM: editorVM)
        }
    }

    private enum InspectorMode {
        case smart
        case advanced
    }

    private func focusInspector(on selection: TimelineSelection?, proxy: ScrollViewProxy) {
        guard let selection else { return }

        let target: String
        switch selection {
        case .zoom:
            editorVM.selectedTool = .zoom
            inspectorMode = .advanced
            target = "Cursor"
        case .editAction(let id):
            switch editorVM.project.editActions.first(where: { $0.id == id })?.type {
            case .speedChange:
                editorVM.selectedTool = .speed
                inspectorMode = .smart
                target = "Cleanup"
            case .cut:
                editorVM.selectedTool = .cut
                inspectorMode = .advanced
                target = "Preview"
            case .hideCursor:
                editorVM.selectedTool = .timeline
                inspectorMode = .advanced
                target = "Cursor"
            case nil:
                editorVM.selectedTool = .timeline
                inspectorMode = .advanced
                target = "Preview"
            }
        case .overlay:
            editorVM.selectedTool = .timeline
            inspectorMode = .advanced
            target = "Visual Marks"
        case .titleCard:
            editorVM.selectedTool = .timeline
            inspectorMode = .advanced
            target = "Title Cards & Brand"
        case .cameraLayout:
            editorVM.selectedTool = .timeline
            inspectorMode = .smart
            target = "Layouts"
        case .effectSegment:
            editorVM.selectedTool = .effects
            inspectorMode = .advanced
            target = "Audio"
        case .keyEvent:
            editorVM.selectedTool = .timeline
            inspectorMode = .advanced
            target = "Overlays"
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    private var smartInspectorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            smartFinishPanel

            inspectorSection("Quick Looks") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(EditorLookPreset.allCases) { preset in
                        Button {
                            editorVM.applyLookPreset(preset)
                            settingsStatusMessage = "Applied \(preset.label) look."
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: preset.systemImage)
                                    .font(.title3)
                                Text(preset.label)
                                    .font(.callout.weight(.semibold))
                                Text(preset.summary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                            .padding(10)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            inspectorSection("Background") {
                Picker("Type", selection: styleBinding(\.backgroundType)) {
                    Text("Solid").tag(BackgroundType.solid)
                    Text("Gradient").tag(BackgroundType.gradient)
                    Text("Image").tag(BackgroundType.image)
                }

                switch editorVM.project.style.backgroundType {
                case .solid:
                    ColorPicker("Color", selection: colorBinding(\.backgroundColor))
                case .gradient:
                    ColorPicker("Start", selection: gradientColorBinding(index: 0))
                    ColorPicker("End", selection: gradientColorBinding(index: 1))
                    valueSlider(
                        "Angle",
                        value: styleBinding(\.backgroundGradientAngle),
                        range: 0...360,
                        suffix: "deg"
                    )
                case .image:
                    backgroundImageControls
                    if let imageURL = editorVM.project.style.backgroundImageURL {
                        Text(imageURL.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            DisclosureGroup(isExpanded: $showSmartFeatureStatus) {
                featureStatusPanel
                    .padding(.top, 8)
            } label: {
                Label("Feature Status", systemImage: "checklist")
                    .font(.callout.weight(.semibold))
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            inspectorSection("Essentials") {
                smartToggleRow(
                    title: "Captions",
                    subtitle: editorVM.project.captionsFileURL == nil ? "Generate or import first" : "Show transcript on video",
                    systemImage: "captions.bubble",
                    isOn: subtitlesEnabledBinding
                )
                .disabled(editorVM.project.captionsFileURL == nil)

                HStack(spacing: 8) {
                    Button {
                        showingCaptionEditor = true
                    } label: {
                        Label("Transcript", systemImage: "text.bubble")
                    }
                    Button {
                        Task { await editorVM.generateCaptions() }
                    } label: {
                        if editorVM.isGeneratingCaptions {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate", systemImage: "waveform.and.magnifyingglass")
                        }
                    }
                    .disabled(!editorVM.canGenerateCaptions || editorVM.isGeneratingCaptions)
                }
                .buttonStyle(.bordered)

                smartToggleRow(
                    title: "Keyboard",
                    subtitle: editorVM.hasKeyboardEvents ? "Show recorded shortcut badges" : "No recorded keys in this project",
                    systemImage: "keyboard",
                    isOn: keyboardShortcutsBinding
                )
                .disabled(!editorVM.hasKeyboardEvents)

                smartToggleRow(
                    title: "Webcam",
                    subtitle: editorVM.project.webcamFileURL == nil ? "No webcam stream recorded" : "Use camera overlay",
                    systemImage: "video",
                    isOn: webcamEnabledBinding
                )
                .disabled(editorVM.project.webcamFileURL == nil)
            }

            inspectorSection("Story & Brand") {
                HStack(spacing: 8) {
                    Button {
                        let count = editorVM.addSmartTitleCards()
                        settingsStatusMessage = "Prepared \(count) story card\(count == 1 ? "" : "s")."
                    } label: {
                        Label("Intro/Outro", systemImage: "sparkles.tv")
                    }
                    Button {
                        editorVM.addTitleCard(kind: .section, at: editorVM.playheadTime)
                        settingsStatusMessage = "Added section card."
                    } label: {
                        Label("Section", systemImage: "text.rectangle")
                    }
                }
                .buttonStyle(.bordered)

                watermarkControls
            }

            if editorVM.project.webcamEnabled {
                inspectorSection("Layouts") {
                    HStack(spacing: 8) {
                        ForEach(CameraLayoutMode.allCases) { mode in
                            Button {
                                editorVM.addCameraLayout(mode: mode)
                                settingsStatusMessage = "Added \(mode.label) layout."
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: mode.systemImage)
                                    Text(mode.label)
                                        .font(.caption2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text("Layouts appear on the timeline and render in preview/export.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                inspectorSection("Camera Polish") {
                    Toggle("Enhance facecam", isOn: styleBinding(\.webcamEnhanceEnabled))
                    if editorVM.project.style.webcamEnhanceEnabled {
                        valueSlider("Bright", value: styleBinding(\.webcamBrightness), range: -0.08...0.12, suffix: "")
                        valueSlider("Contrast", value: styleBinding(\.webcamContrast), range: 0.9...1.22, suffix: "")
                        valueSlider("Color", value: styleBinding(\.webcamSaturation), range: 0.8...1.35, suffix: "")
                    }
                    Toggle("Camera frame", isOn: styleBinding(\.webcamBorderEnabled))
                    Toggle("Camera shadow", isOn: styleBinding(\.webcamShadowEnabled))
                    valueSlider("Size", value: styleBinding(\.webcamSize), range: 96...280, suffix: "px")
                    valueSlider("Zoom Size", value: styleBinding(\.webcamZoomScale), range: 0.35...1.2, suffix: "x")
                }
            }

            inspectorSection("Focus") {
                valueSlider("Auto Zoom", value: autoZoomScaleBinding, range: 1.05...2.4, suffix: "x")
                Button {
                    editorVM.regenerateAutomaticZooms(replacingExisting: true)
                    settingsStatusMessage = "Regenerated click-driven zooms."
                } label: {
                    Label("Auto Detect Zooms", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                valueSlider("Cursor", value: styleBinding(\.cursorScale), range: 0.5...3, suffix: "x")
                Toggle("Hide idle cursor", isOn: styleBinding(\.hideStaticCursor))
                Toggle("Click sound", isOn: styleBinding(\.clickSoundEnabled))
                if editorVM.project.style.clickSoundEnabled {
                    Picker("Click Source", selection: styleBinding(\.clickSoundStyle)) {
                        ForEach(ClickSoundStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    if editorVM.project.style.clickSoundStyle == .custom {
                        soundFileControls(
                            title: "Click file",
                            url: editorVM.project.style.clickSoundFileURL,
                            choose: selectClickSoundFile,
                            clear: clearClickSoundFile
                        )
                    }
                    valueSlider("Click Vol", value: styleBinding(\.clickSoundVolume), range: 0...1, suffix: "")
                    Button {
                        editorVM.previewClickSound()
                    } label: {
                        Label("Preview Click", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                }
                Toggle("Keypress sound", isOn: styleBinding(\.keyboardSoundEnabled))
                if editorVM.hasKeyboardEvents {
                    Toggle("Single keys", isOn: styleBinding(\.shortcutBadgeShowSingleKeys))
                }
                if editorVM.project.style.keyboardSoundEnabled {
                    Picker("Key Source", selection: styleBinding(\.keyboardSoundStyle)) {
                        ForEach(KeyboardSoundStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    if editorVM.project.style.keyboardSoundStyle == .custom {
                        soundFileControls(
                            title: "Key file",
                            url: editorVM.project.style.keyboardSoundFileURL,
                            choose: selectKeyboardSoundFile,
                            clear: clearKeyboardSoundFile
                        )
                    }
                    valueSlider("Key Vol", value: styleBinding(\.keyboardSoundVolume), range: 0...1, suffix: "")
                    Button {
                        editorVM.previewKeyboardSound()
                    } label: {
                        Label("Preview Key", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    editorVM.addZoomSegment(at: editorVM.playheadTime)
                } label: {
                    Label("Add Zoom Here", systemImage: "plus.magnifyingglass")
                }
                .buttonStyle(.bordered)
            }

            inspectorSection("Cleanup") {
                HStack(spacing: 8) {
                    Button {
                        let count = editorVM.cleanFillerWordsFromCaptions(removeEmptySegments: false)
                        settingsStatusMessage = count > 0 ? "Removed \(count) filler word\(count == 1 ? "" : "s")." : "No filler words found."
                    } label: {
                        Label("Clean Fillers", systemImage: "text.badge.checkmark")
                    }
                    Button {
                        let count = editorVM.speedUpTypingSegments(multiplier: 3.0)
                        settingsStatusMessage = count > 0 ? "Sped up \(count) typing segment\(count == 1 ? "" : "s")." : "No typing segments found."
                    } label: {
                        Label("Typing", systemImage: "keyboard.badge.ellipsis")
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Button {
                        _ = editorVM.generateChaptersFromTranscript()
                    } label: {
                        Label("Chapters", systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        selectBackgroundMusic()
                    } label: {
                        Label("Music", systemImage: "music.note")
                    }
                }
                .buttonStyle(.bordered)

                Toggle("Mic noise reduction", isOn: styleBinding(\.micNoiseReductionEnabled))
                    .disabled(editorVM.project.micAudioFileURL == nil)
                if editorVM.project.style.micNoiseReductionEnabled {
                    Button {
                        editorVM.project.style.micNoiseGateThreshold = -38
                        editorVM.markProjectModified()
                        settingsStatusMessage = "Applied stronger mic cleanup."
                    } label: {
                        Label("Reduce Mic Noise", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.bordered)
                    .disabled(editorVM.project.micAudioFileURL == nil)
                    valueSlider("Noise Gate", value: styleBinding(\.micNoiseGateThreshold), range: -65 ... -25, suffix: "dB")
                        .disabled(editorVM.project.micAudioFileURL == nil)
                }
                if editorVM.project.micAudioFileURL == nil {
                    Text("Record microphone audio to use voice cleanup on export.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            inspectorSection("Share Page") {
                TextField("Page title", text: shareSettingsBinding(\.titleOverride))
                    .textFieldStyle(.roundedBorder)
                TextField("Creator", text: shareSettingsBinding(\.creatorName))
                    .textFieldStyle(.roundedBorder)
                TextField("Description", text: shareSettingsBinding(\.description), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("CTA label", text: shareSettingsBinding(\.callToActionLabel))
                        .textFieldStyle(.roundedBorder)
                    TextField("CTA URL", text: shareSettingsBinding(\.callToActionURL))
                        .textFieldStyle(.roundedBorder)
                }
                ColorPicker("Accent", selection: shareAccentBinding)
            }

            inspectorSection("Output") {
                Button {
                    editorVM.saveProject()
                    showingExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Smart Finish prepares the project settings. Export renders the finished video file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var smartFinishPanel: some View {
        let readiness = editorVM.productionReadiness

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart Finish")
                        .font(.headline)
                    Text("Applies the best local defaults for look, focus, story cards, captions, keyboard, camera, and branding.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                readinessChip("Look", ready: readiness.hasLook)
                readinessChip("Focus", ready: readiness.hasFocus)
                readinessChip("Cards", ready: readiness.hasStoryCards)
                readinessChip("Brand", ready: readiness.hasBranding)
            }

            HStack(spacing: 6) {
                readinessChip("Captions", ready: readiness.hasCaptions)
                readinessChip("Keys", ready: readiness.hasKeyboard)
                readinessChip("Camera", ready: readiness.hasCamera)
                readinessChip("Share", ready: readiness.hasShareMetadata)
            }

            Button {
                finishSummary = editorVM.applySmartFinish()
                if let finishSummary {
                    settingsStatusMessage = "Smart Finish applied: \(finishSummary.titleCardCount) story card\(finishSummary.titleCardCount == 1 ? "" : "s"), \(finishSummary.chapterCount) chapter\(finishSummary.chapterCount == 1 ? "" : "s")."
                }
            } label: {
                Label("Apply Smart Finish", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let finishSummary {
                Text(finishDetailText(finishSummary))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text("\(readiness.completedCount)/\(readiness.totalCount) finishing checks are already active.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var featureStatusPanel: some View {
        inspectorSection("Feature Status") {
            featureStatusRow(
                title: "Captions",
                stateLabel: editorVM.project.captionsFileURL == nil ? (editorVM.canGenerateCaptions ? "Can Generate" : "Needs Audio") : "Ready",
                detail: editorVM.project.captionsFileURL == nil
                    ? (editorVM.canGenerateCaptions ? "Generate captions from recorded audio or import SRT/VTT." : "Record microphone audio or import captions in Transcript.")
                    : "Subtitles are available for preview, export, and local share pages.",
                systemImage: "captions.bubble",
                state: editorVM.project.captionsFileURL == nil ? (editorVM.canGenerateCaptions ? .available : .needsInput) : .ready
            )

            featureStatusRow(
                title: "Keyboard Badges",
                stateLabel: editorVM.hasKeyboardEvents ? "Ready" : "Needs Keys",
                detail: editorVM.hasKeyboardEvents
                    ? "Recorded key presses can render as shortcut badges in preview/export."
                    : "No key presses were captured in this recording.",
                systemImage: "keyboard",
                state: editorVM.hasKeyboardEvents ? .ready : .needsInput
            )

            featureStatusRow(
                title: "Webcam",
                stateLabel: editorVM.project.webcamFileURL == nil ? "Needs Camera" : "Ready",
                detail: editorVM.project.webcamFileURL == nil
                    ? "No webcam stream was recorded for this project."
                    : "Camera shape, position, size, polish, and layout controls are active.",
                systemImage: "video",
                state: editorVM.project.webcamFileURL == nil ? .needsInput : .ready
            )

            featureStatusRow(
                title: "Music",
                stateLabel: editorVM.project.style.backgroundMusicURL == nil ? "Optional" : "Ready",
                detail: editorVM.project.style.backgroundMusicURL == nil
                    ? "Add local music from Cleanup or Advanced Audio when needed."
                    : "Music will render with volume, loop, fade, and ducking settings.",
                systemImage: "music.note",
                state: editorVM.project.style.backgroundMusicURL == nil ? .available : .ready
            )

            featureStatusRow(
                title: "Local Share",
                stateLabel: "Ready",
                detail: "Export can create a local watch page with video, captions, chapters, notes, comments, and reactions.",
                systemImage: "play.rectangle.on.rectangle",
                state: .ready
            )

            featureStatusRow(
                title: "Cloud Link",
                stateLabel: isCloudShareConfigured ? "Ready" : "Setup Needed",
                detail: isCloudShareConfigured
                    ? "Export can upload to FOCUSFRAME_UPLOAD_ENDPOINT and copy the returned URL."
                    : "Set FOCUSFRAME_UPLOAD_ENDPOINT before cloud upload appears as an active destination.",
                systemImage: "cloud",
                state: isCloudShareConfigured ? .ready : .needsSetup
            )
        }
    }

    private func readinessChip(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(ready ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(ready ? .accentColor : .secondary)
            .clipShape(Capsule())
    }

    private func finishDetailText(_ summary: ProductionFinishSummary) -> String {
        var enabled: [String] = []
        if summary.captionsEnabled { enabled.append("captions") }
        if summary.keyboardEnabled { enabled.append("keyboard") }
        if summary.webcamEnabled { enabled.append("camera") }
        if summary.watermarkEnabled { enabled.append("watermark") }
        let suffix = enabled.isEmpty ? "No optional overlays were available." : "Enabled " + enabled.joined(separator: ", ") + "."
        return "\(summary.titleCardCount) story cards and \(summary.chapterCount) chapters prepared. \(suffix)"
    }

    private enum FeatureStatusState {
        case ready
        case available
        case needsInput
        case needsSetup

        var color: Color {
            switch self {
            case .ready:
                return .accentColor
            case .available:
                return .green
            case .needsInput:
                return .secondary
            case .needsSetup:
                return .orange
            }
        }

        var background: Color {
            switch self {
            case .ready:
                return Color.accentColor.opacity(0.14)
            case .available:
                return Color.green.opacity(0.14)
            case .needsInput:
                return Color(nsColor: .controlBackgroundColor)
            case .needsSetup:
                return Color.orange.opacity(0.16)
            }
        }
    }

    private func featureStatusRow(
        title: String,
        stateLabel: String,
        detail: String,
        systemImage: String,
        state: FeatureStatusState
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(state.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(stateLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(state.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(state.background)
                        .clipShape(Capsule())
                }

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func smartToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: sectionIcon(for: title))
                    .foregroundColor(sectionTint(for: title))
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(10)
            .background(sectionTint(for: title).opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(sectionTint(for: title).opacity(0.20), lineWidth: 1)
            )
        }
        .id(title)
    }

    private func sectionTint(for title: String) -> Color {
        switch title {
        case "Focus", "Cursor":
            return .blue
        case "Overlays", "Visual Marks":
            return .purple
        case "Audio", "Cleanup":
            return .teal
        case "Camera Polish", "Layouts":
            return .mint
        case "Story & Brand", "Title Cards & Brand":
            return .orange
        case "Share Page", "Output":
            return .green
        case "Feature Status", "Essentials":
            return .accentColor
        default:
            return .secondary
        }
    }

    private func sectionIcon(for title: String) -> String {
        switch title {
        case "Focus", "Cursor":
            return "scope"
        case "Overlays", "Visual Marks":
            return "sparkles"
        case "Audio", "Cleanup":
            return "waveform"
        case "Camera Polish", "Layouts":
            return "video"
        case "Story & Brand", "Title Cards & Brand":
            return "sparkles.tv"
        case "Share Page":
            return "play.rectangle.on.rectangle"
        case "Output":
            return "square.and.arrow.up"
        case "Feature Status":
            return "checklist"
        case "Essentials":
            return "slider.horizontal.3"
        default:
            return "circle.grid.2x2"
        }
    }

    private var watermarkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Brand watermark", isOn: styleBinding(\.watermarkEnabled))
            if editorVM.project.style.watermarkEnabled {
                TextField("Watermark text", text: styleBinding(\.watermarkText))
                    .textFieldStyle(.roundedBorder)
                Picker("Position", selection: styleBinding(\.watermarkPosition)) {
                    ForEach(WatermarkPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                valueSlider("Opacity", value: styleBinding(\.watermarkOpacity), range: 0.12...1.0, suffix: "")
                valueSlider("Scale", value: styleBinding(\.watermarkScale), range: 0.7...2.2, suffix: "x")
            }
        }
    }

    @ViewBuilder
    private func soundFileControls(
        title: String,
        url: URL?,
        choose: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                choose()
            } label: {
                Label(title, systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.bordered)

            if let url {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Remove custom sound")
            }
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String
    ) -> some View {
        DeferredCGFloatSliderRow(
            title: title,
            value: value,
            range: range,
            formatter: { formatted($0, suffix: suffix) }
        )
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        DeferredDoubleSliderRow(
            title: title,
            value: value,
            range: range,
            formatter: { String(format: suffix == "s" ? "%.1f%@" : "%.2f%@", $0, suffix) }
        )
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        suffix: String
    ) -> some View {
        DeferredFloatSliderRow(
            title: title,
            value: value,
            range: range,
            formatter: { String(format: "%.2f%@", $0, suffix) }
        )
    }

    @ViewBuilder
    private func overlayRow(_ overlay: OverlayElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Type", selection: overlayBinding(overlay, \.type)) {
                    ForEach(OverlayType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    editorVM.removeOverlay(overlay.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove overlay")
            }

            HStack(spacing: 8) {
                TextField("Start", value: overlayBinding(overlay, \.startTime), format: .number)
                    .textFieldStyle(.roundedBorder)
                TextField("End", value: overlayBinding(overlay, \.endTime), format: .number)
                    .textFieldStyle(.roundedBorder)
            }

            if overlay.type == .text {
                TextField("Text", text: overlayBinding(overlay, \.text), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }

            compactOverlaySlider("X", overlay: overlay, keyPath: \.rect.origin.x)
            compactOverlaySlider("Y", overlay: overlay, keyPath: \.rect.origin.y)
            compactOverlaySlider("W", overlay: overlay, keyPath: \.rect.size.width)
            compactOverlaySlider("H", overlay: overlay, keyPath: \.rect.size.height)
            valueSlider("Strength", value: overlayBinding(overlay, \.intensity), range: 0...1, suffix: "")
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func compactOverlaySlider(
        _ title: String,
        overlay: OverlayElement,
        keyPath: WritableKeyPath<OverlayElement, CGFloat>
    ) -> some View {
        valueSlider(title, value: overlayBinding(overlay, keyPath), range: 0...1, suffix: "")
    }

    private func overlayBinding<Value>(
        _ overlay: OverlayElement,
        _ keyPath: WritableKeyPath<OverlayElement, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                let current = editorVM.project.overlayElements?.first(where: { $0.id == overlay.id }) ?? overlay
                return current[keyPath: keyPath]
            },
            set: { newValue in
                var current = editorVM.project.overlayElements?.first(where: { $0.id == overlay.id }) ?? overlay
                current[keyPath: keyPath] = newValue
                editorVM.updateOverlay(current)
            }
        )
    }

    @ViewBuilder
    private func titleCardRow(_ card: TitleCardSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Kind", selection: titleCardBinding(card, \.kind)) {
                    ForEach(TitleCardKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Picker("Style", selection: titleCardBinding(card, \.style)) {
                    ForEach(TitleCardStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Button(role: .destructive) {
                    editorVM.removeTitleCard(card.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove title card")
            }

            TextField("Title", text: titleCardBinding(card, \.title))
                .textFieldStyle(.roundedBorder)
            TextField("Subtitle", text: titleCardBinding(card, \.subtitle), axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                TextField("Start", value: titleCardBinding(card, \.startTime), format: .number)
                    .textFieldStyle(.roundedBorder)
                TextField("End", value: titleCardBinding(card, \.endTime), format: .number)
                    .textFieldStyle(.roundedBorder)
            }

            ColorPicker("Accent", selection: titleCardAccentBinding(card))
            valueSlider("Backdrop", value: titleCardBinding(card, \.backgroundOpacity), range: 0.1...0.95, suffix: "")
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func titleCardBinding<Value>(
        _ card: TitleCardSegment,
        _ keyPath: WritableKeyPath<TitleCardSegment, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                let current = editorVM.project.titleCardSegments?.first(where: { $0.id == card.id }) ?? card
                return current[keyPath: keyPath]
            },
            set: { newValue in
                var current = editorVM.project.titleCardSegments?.first(where: { $0.id == card.id }) ?? card
                current[keyPath: keyPath] = newValue
                editorVM.updateTitleCard(current)
            }
        )
    }

    private func titleCardAccentBinding(_ card: TitleCardSegment) -> Binding<Color> {
        Binding(
            get: {
                let current = editorVM.project.titleCardSegments?.first(where: { $0.id == card.id }) ?? card
                return Color(cgColor: current.accentColor.cgColor)
            },
            set: { color in
                var current = editorVM.project.titleCardSegments?.first(where: { $0.id == card.id }) ?? card
                current.accentColor = CodableColor(from: color)
                editorVM.updateTitleCard(current)
            }
        )
    }

    @ViewBuilder
    private func chapterRow(_ chapter: ChapterMarker) -> some View {
        HStack(spacing: 8) {
            TextField("Time", value: chapterBinding(chapter, \.time), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
            TextField("Title", text: chapterBinding(chapter, \.title))
                .textFieldStyle(.roundedBorder)
            Button(role: .destructive) {
                editorVM.removeChapter(chapter.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func chapterBinding<Value>(
        _ chapter: ChapterMarker,
        _ keyPath: WritableKeyPath<ChapterMarker, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                let current = editorVM.project.chapterMarkers?.first(where: { $0.id == chapter.id }) ?? chapter
                return current[keyPath: keyPath]
            },
            set: { newValue in
                var current = editorVM.project.chapterMarkers?.first(where: { $0.id == chapter.id }) ?? chapter
                current[keyPath: keyPath] = newValue
                editorVM.updateChapter(current)
            }
        )
    }

    private var speakerNotesBinding: Binding<String> {
        Binding(
            get: { editorVM.project.speakerNotes ?? "" },
            set: { newValue in
                editorVM.project.speakerNotes = newValue
                editorVM.markProjectModified()
            }
        )
    }

    private func shareSettingsBinding(_ keyPath: WritableKeyPath<SharePageSettings, String>) -> Binding<String> {
        Binding(
            get: {
                (editorVM.project.sharePageSettings ?? SharePageSettings())[keyPath: keyPath]
            },
            set: { newValue in
                var settings = editorVM.project.sharePageSettings ?? SharePageSettings()
                settings[keyPath: keyPath] = newValue
                editorVM.project.sharePageSettings = settings
                editorVM.markProjectModified()
            }
        )
    }

    private var shareAccentBinding: Binding<Color> {
        Binding(
            get: {
                Color(cgColor: (editorVM.project.sharePageSettings ?? SharePageSettings()).accentColor.cgColor)
            },
            set: { color in
                var settings = editorVM.project.sharePageSettings ?? SharePageSettings()
                settings.accentColor = CodableColor(from: color)
                editorVM.project.sharePageSettings = settings
                editorVM.markProjectModified()
            }
        )
    }

    private func styleBinding<Value>(_ keyPath: WritableKeyPath<StylePreset, Value>) -> Binding<Value> {
        Binding(
            get: { editorVM.project.style[keyPath: keyPath] },
            set: { newValue in
                editorVM.project.style[keyPath: keyPath] = newValue
                editorVM.markProjectModified()
            }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<StylePreset, CodableColor>) -> Binding<Color> {
        Binding(
            get: { Color(cgColor: editorVM.project.style[keyPath: keyPath].cgColor) },
            set: { color in
                editorVM.project.style[keyPath: keyPath] = CodableColor(from: color)
                editorVM.markProjectModified()
            }
        )
    }

    private func gradientColorBinding(index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = editorVM.project.style.backgroundGradientColors
                let fallback = index == 0 ? CodableColor(r: 0.12, g: 0.13, b: 0.15) : CodableColor(r: 0.25, g: 0.29, b: 0.35)
                return Color(cgColor: colors.indices.contains(index) ? colors[index].cgColor : fallback.cgColor)
            },
            set: { color in
                var colors = editorVM.project.style.backgroundGradientColors
                while colors.count <= index {
                    colors.append(CodableColor(r: 0.15, g: 0.17, b: 0.20))
                }
                colors[index] = CodableColor(from: color)
                editorVM.project.style.backgroundGradientColors = colors
                editorVM.markProjectModified()
            }
        )
    }

    private var shadowOpacityBinding: Binding<Float> {
        styleBinding(\.shadowOpacity)
    }

    private var autoZoomScaleBinding: Binding<CGFloat> {
        Binding(
            get: { editorVM.project.style.autoZoomScale },
            set: { newValue in
                editorVM.project.style.autoZoomScale = newValue
                editorVM.regenerateAutomaticZooms()
                editorVM.markProjectModified()
            }
        )
    }

    private var subtitlesEnabledBinding: Binding<Bool> {
        Binding(
            get: { editorVM.project.subtitlesEnabled == true },
            set: {
                editorVM.project.subtitlesEnabled = $0
                editorVM.markProjectModified()
            }
        )
    }

    private var isCloudShareConfigured: Bool {
        CloudShareService.Config.environment.uploadEndpoint != nil
    }

    private var keyboardShortcutsBinding: Binding<Bool> {
        Binding(
            get: { editorVM.project.showKeyboardShortcuts },
            set: {
                editorVM.project.showKeyboardShortcuts = $0
                editorVM.project.style.showKeyboardShortcuts = $0
                editorVM.markProjectModified()
            }
        )
    }

    private var webcamEnabledBinding: Binding<Bool> {
        Binding(
            get: { editorVM.project.webcamEnabled },
            set: {
                editorVM.project.webcamEnabled = $0
                editorVM.markProjectModified()
            }
        )
    }

    private func formatted(_ value: CGFloat, suffix: String) -> String {
        if suffix == "x" {
            return String(format: "%.1f%@", Double(value), suffix)
        }
        return "\(Int(value))\(suffix)"
    }

    private func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            applyBackgroundImage(url, status: "Background image selected.")
        }
    }

    private func useDesktopWallpaperBackground() {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            settingsStatusMessage = "No desktop wallpaper image was found."
            return
        }

        applyBackgroundImage(url, status: "Using desktop wallpaper as background.")
    }

    private var backgroundImageControls: some View {
        HStack(spacing: 8) {
            Button {
                selectBackgroundImage()
            } label: {
                Label("Choose Image", systemImage: "photo")
            }
            .buttonStyle(.bordered)

            Button {
                useDesktopWallpaperBackground()
            } label: {
                Label("Use Desktop", systemImage: "desktopcomputer")
            }
            .buttonStyle(.bordered)

            if !recentBackgroundImages.isEmpty {
                Menu {
                    ForEach(recentBackgroundImages, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            applyBackgroundImage(url, status: "Background restored from history.")
                        }
                    }
                    Divider()
                    Button("Clear History") {
                        BackgroundImageHistory.clear()
                        recentBackgroundImages = []
                        settingsStatusMessage = "Background history cleared."
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    private func applyBackgroundImage(_ url: URL, status: String) {
        guard BackgroundImageHistory.add(url) else {
            recentBackgroundImages = BackgroundImageHistory.load()
            settingsStatusMessage = "Background image could not be loaded."
            return
        }
        editorVM.project.style.backgroundType = .image
        editorVM.project.style.backgroundImageURL = url
        recentBackgroundImages = BackgroundImageHistory.load()
        editorVM.markProjectModified()
        settingsStatusMessage = status
    }

    private func selectBackgroundMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            editorVM.setBackgroundMusic(url: url)
        }
    }

    private func selectClickSoundFile() {
        selectSoundFile { url in
            editorVM.project.style.clickSoundFileURL = url
            editorVM.project.style.clickSoundStyle = .custom
            editorVM.markProjectModified()
        }
    }

    private func selectKeyboardSoundFile() {
        selectSoundFile { url in
            editorVM.project.style.keyboardSoundFileURL = url
            editorVM.project.style.keyboardSoundStyle = .custom
            editorVM.markProjectModified()
        }
    }

    private func clearClickSoundFile() {
        editorVM.project.style.clickSoundFileURL = nil
        editorVM.markProjectModified()
    }

    private func clearKeyboardSoundFile() {
        editorVM.project.style.keyboardSoundFileURL = nil
        editorVM.markProjectModified()
    }

    private func selectSoundFile(_ apply: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            apply(url)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "focusframe-settings.json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = ProjectSettingsSnapshot(
                style: editorVM.project.style,
                sharePageSettings: editorVM.project.sharePageSettings,
                titleCardSegments: editorVM.project.titleCardSegments,
                cameraLayoutSegments: editorVM.project.cameraLayoutSegments,
                overlayElements: editorVM.project.overlayElements,
                chapterMarkers: editorVM.project.chapterMarkers,
                effectSegments: editorVM.project.effectSegments
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: url)
            settingsStatusMessage = "Settings exported."
        } catch {
            settingsStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func saveThumbnail() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "thumbnail.png"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editorVM.saveCurrentFrame(to: url)
            settingsStatusMessage = "Frame saved."
        } catch {
            settingsStatusMessage = "Frame save failed: \(error.localizedDescription)"
        }
    }

    private func exportRawAssets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editorVM.exportRawAssets(to: url)
            settingsStatusMessage = "Raw assets exported."
        } catch {
            settingsStatusMessage = "Raw export failed: \(error.localizedDescription)"
        }
    }

    private func exportChapters() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "chapters.txt"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try editorVM.exportChapters(to: url)
            settingsStatusMessage = "Chapters exported."
        } catch {
            settingsStatusMessage = "Chapter export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImportingSettings = true
        settingsStatusMessage = "Importing settings..."
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Self.settingsImportData(from: url)
                }.value
                let decoder = JSONDecoder()
                if let snapshot = try? decoder.decode(ProjectSettingsSnapshot.self, from: data) {
                    let sanitized = snapshot.sanitized(appliedTo: editorVM.project)
                    editorVM.project.style = sanitized.style
                    editorVM.project.sharePageSettings = sanitized.sharePageSettings
                    editorVM.project.titleCardSegments = sanitized.titleCardSegments
                    editorVM.project.cameraLayoutSegments = sanitized.cameraLayoutSegments
                    editorVM.project.overlayElements = sanitized.overlayElements
                    editorVM.project.chapterMarkers = sanitized.chapterMarkers
                    editorVM.project.effectSegments = sanitized.effectSegments
                } else {
                    editorVM.project.style = try decoder.decode(StylePreset.self, from: data)
                }
                editorVM.markProjectModified()
                settingsStatusMessage = "Settings imported."
            } catch {
                settingsStatusMessage = "Import failed: \(error.localizedDescription)"
            }
            isImportingSettings = false
        }
    }

    nonisolated private static func settingsImportData(from url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= maxSettingsImportBytes else {
            throw SettingsImportError.fileTooLarge(maxBytes: maxSettingsImportBytes)
        }
        return try Data(contentsOf: url)
    }
}

private struct ProjectSettingsSnapshot: Codable {
    var style: StylePreset
    var sharePageSettings: SharePageSettings?
    var titleCardSegments: [TitleCardSegment]?
    var cameraLayoutSegments: [CameraLayoutSegment]?
    var overlayElements: [OverlayElement]?
    var chapterMarkers: [ChapterMarker]?
    var effectSegments: [EffectSegment]?

    func sanitized(appliedTo project: RecordingProject) -> ProjectSettingsSnapshot {
        var candidate = project
        candidate.style = style
        candidate.sharePageSettings = sharePageSettings
        candidate.titleCardSegments = titleCardSegments
        candidate.cameraLayoutSegments = cameraLayoutSegments
        candidate.overlayElements = overlayElements
        candidate.chapterMarkers = chapterMarkers
        candidate.effectSegments = effectSegments

        let sanitizedProject = candidate.sanitizedForUse()
        return ProjectSettingsSnapshot(
            style: sanitizedProject.style,
            sharePageSettings: sanitizedProject.sharePageSettings,
            titleCardSegments: sanitizedProject.titleCardSegments,
            cameraLayoutSegments: sanitizedProject.cameraLayoutSegments,
            overlayElements: sanitizedProject.overlayElements,
            chapterMarkers: sanitizedProject.chapterMarkers,
            effectSegments: sanitizedProject.effectSegments
        )
    }
}

private enum SettingsImportError: LocalizedError {
    case fileTooLarge(maxBytes: UInt64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maxBytes):
            let megabytes = max(1, maxBytes / (1024 * 1024))
            return "Settings file is too large. Choose a file under \(megabytes) MB."
        }
    }
}
