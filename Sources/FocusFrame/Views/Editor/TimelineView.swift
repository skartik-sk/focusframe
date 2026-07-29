import SwiftUI
import AppKit

private enum TimelineScrollTarget {
    static let playhead = "timeline-playhead-scroll-target"
}

enum TimelinePreferences {
    static let zoomScaleKey = "FocusFrame.Timeline.ZoomScale"
    static let expandedHeightKey = "FocusFrame.Timeline.Height"
    static let defaultZoomScale = 1.0
    static let defaultExpandedHeight = 320.0

    static func sanitizedZoomScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultZoomScale }
        return min(8, max(1, value))
    }

    static func sanitizedExpandedHeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultExpandedHeight }
        return min(520, max(220, value))
    }
}

// MARK: - Orchestrator

struct TimelineView: View {
    @ObservedObject var editorVM: EditorVM
    let compact: Bool

    @State private var isDragging = false
    @State private var dragAnchorTime: Double?
    @State private var optionDeleteMode = false
    @State private var shiftExtendMode = false
    @State private var snapDisabled = false
    @State private var localFlagsMonitor: Any?
    @State private var globalFlagsMonitor: Any?
    @State private var resizeStartHeight: Double?
    @AppStorage(TimelinePreferences.zoomScaleKey) private var timelineZoomScale: Double = 1.0
    @AppStorage(TimelinePreferences.expandedHeightKey) private var expandedTimelineHeight: Double = 320

    init(editorVM: EditorVM, compact: Bool = false) {
        self.editorVM = editorVM
        self.compact = compact
    }

    private let gutterWidth: CGFloat = 112
    private let rulerHeight: CGFloat = 30
    private let filmstripHeight: CGFloat = 64
    private let slimLaneHeight: CGFloat = 38
    private let audioLaneHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                timelineResizeDivider
            }

            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    let bodyWidth = max(0, geometry.size.width - gutterWidth)
                    let contentWidth = max(bodyWidth, bodyWidth * CGFloat(clampedTimelineZoomScale))

                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(spacing: 0) {
                            // Fixed left gutter — pinned horizontally, scrolls vertically with content.
                            VStack(spacing: 0) {
                                ForEach(laneSpecs) { spec in
                                    TimelineGutterRow(spec: spec)
                                }
                            }
                            .frame(width: gutterWidth)
                            .background(Color(nsColor: .windowBackgroundColor))

                            // Scrolling body — one lane per spec, single shared playhead.
                            ScrollView(.horizontal, showsIndicators: false) {
                                ZStack(alignment: .topLeading) {
                                    VStack(spacing: 0) {
                                        ForEach(laneSpecs) { spec in
                                            spec.bodyContent
                                                .frame(width: contentWidth, height: spec.height)
                                        }
                                    }

                                    playheadOverlay(width: contentWidth)
                                    selectionBandOverlay(width: contentWidth)
                                }
                                .frame(width: contentWidth, height: timelineHeight)
                            }
                        }
                    }
                    .onChange(of: timelineZoomScale) { _ in
                        centerTimelineOnPlayhead(using: scrollProxy)
                    }
                }
            }
            .frame(height: timelineScrollHeight)

            if !compact {
                timelineControls
            }
        }
        .frame(height: timelineViewportHeight)
        .onAppear(perform: startModifierMonitoring)
        .onDisappear(perform: stopModifierMonitoring)
    }

    // MARK: - Lane specs (gutter + body stay aligned because both render from this)

    private var laneSpecs: [TimelineLaneSpec] {
        var specs: [TimelineLaneSpec] = []

        // Ruler
        specs.append(TimelineLaneSpec(
            id: "ruler",
            height: rulerHeight,
            gutterTitle: "",
            bodyContent: AnyView(
                TimelineRulerBody(duration: editorVM.duration, onChange: handleScrubChanged, onEnd: handleScrubEnded)
            )
        ))

        // Video group
        specs.append(TimelineLaneSpec(
            id: "video",
            height: filmstripHeight,
            gutterTitle: "Video",
            gutterIcon: "film",
            gutterTrailing: filmstripTrailingText,
            addControl: videoAddMenu,
            bodyContent: AnyView(
                VideoTimelineLane(
                    editorVM: editorVM,
                    duration: editorVM.duration,
                    height: filmstripHeight,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    videoURL: editorVM.project.videoFileURL
                )
            ),
            groupAccent: .blue
        ))

        if !editorVM.titleCards.isEmpty {
            specs.append(titleCardLaneSpec())
        }
        if !editorVM.overlays.isEmpty {
            specs.append(overlayLaneSpec())
        }
        if editorVM.selectedTool == .effects || !editorVM.effectSegments.isEmpty {
            specs.append(effectSegmentLaneSpec())
        }
        if editorVM.project.webcamFileURL != nil {
            specs.append(cameraLayoutLaneSpec())
        }

        // Edits group
        specs.append(TimelineLaneSpec(
            id: "edits",
            height: slimLaneHeight,
            gutterTitle: "Edits",
            gutterIcon: "scissors",
            bodyContent: AnyView(
                ClipLane(
                    duration: editorVM.duration,
                    height: slimLaneHeight,
                    playhead: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    clips: editActionDescriptors,
                    background: Color(nsColor: .underPageBackgroundColor)
                )
            ),
            groupAccent: .orange
        ))

        if editorVM.hasKeyboardEvents {
            specs.append(TimelineLaneSpec(
                id: "keys",
                height: slimLaneHeight,
                gutterTitle: "Keys",
                gutterIcon: "keyboard",
                bodyContent: AnyView(
                    KeysTimelineLane(
                        editorVM: editorVM,
                        duration: editorVM.duration,
                        height: slimLaneHeight,
                        showsDeleteControls: optionDeleteMode
                    )
                ),
                groupAccent: .orange
            ))
        }

        // Audio group
        specs.append(audioLaneSpec(
            id: "audio-main",
            title: mainAudioTrackTitle,
            icon: "waveform",
            url: editorVM.project.systemAudioFileURL ?? editorVM.project.videoFileURL,
            loops: false,
            trailing: mainAudioTrailingText
        ))
        if let micURL = editorVM.project.micAudioFileURL {
            specs.append(audioLaneSpec(
                id: "audio-mic",
                title: "Mic",
                icon: "mic",
                url: micURL,
                loops: false,
                trailing: audioEditSummary
            ))
        }
        if editorVM.project.style.backgroundMusicURL != nil {
            specs.append(audioLaneSpec(
                id: "audio-music",
                title: "Music",
                icon: "music.note",
                url: editorVM.project.style.backgroundMusicURL,
                loops: editorVM.project.style.backgroundMusicLoop,
                trailing: musicTrailingText
            ))
        }

        return specs
    }

    // MARK: - Lane builders

    private func titleCardLaneSpec() -> TimelineLaneSpec {
        let menu = AnyView(Menu {
            ForEach(TitleCardKind.allCases) { kind in
                Button(kind.label) { editorVM.addTitleCard(kind: kind, at: editorVM.playheadTime) }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24))

        return TimelineLaneSpec(
            id: "title-cards",
            height: slimLaneHeight,
            gutterTitle: "Title",
            gutterIcon: "text.rectangle",
            addControl: menu,
            bodyContent: AnyView(
                ClipLane(
                    duration: editorVM.duration,
                    height: slimLaneHeight,
                    playhead: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    clips: titleCardDescriptors,
                    background: Color(nsColor: .underPageBackgroundColor)
                )
            ),
            groupAccent: .blue
        )
    }

    private func overlayLaneSpec() -> TimelineLaneSpec {
        let menu = AnyView(Menu {
            ForEach(OverlayType.allCases, id: \.self) { type in
                Button(type.label) { editorVM.addOverlay(type: type, at: editorVM.playheadTime) }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24))

        return TimelineLaneSpec(
            id: "overlays",
            height: slimLaneHeight,
            gutterTitle: "Overlays",
            gutterIcon: "rectangle.on.rectangle",
            addControl: menu,
            bodyContent: AnyView(
                ClipLane(
                    duration: editorVM.duration,
                    height: slimLaneHeight,
                    playhead: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    clips: overlayDescriptors,
                    background: Color(nsColor: .underPageBackgroundColor)
                )
            ),
            groupAccent: .blue
        )
    }

    private func effectSegmentLaneSpec() -> TimelineLaneSpec {
        let menu = AnyView(Menu {
            ForEach(EffectSegmentPreset.allCases) { preset in
                Button(preset.title) {
                    _ = editorVM.addEffectSegment(
                        startTime: editorVM.playheadTime,
                        endTime: min(editorVM.duration, editorVM.playheadTime + 5),
                        preset: preset
                    )
                }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24))

        return TimelineLaneSpec(
            id: "effect-segments",
            height: slimLaneHeight,
            gutterTitle: "Effects",
            gutterIcon: "slider.horizontal.3",
            addControl: menu,
            bodyContent: AnyView(
                ClipLane(
                    duration: editorVM.duration,
                    height: slimLaneHeight,
                    playhead: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    clips: effectSegmentDescriptors,
                    background: Color(nsColor: .underPageBackgroundColor)
                )
            ),
            groupAccent: .blue
        )
    }

    private func cameraLayoutLaneSpec() -> TimelineLaneSpec {
        let menu = AnyView(Menu {
            ForEach(CameraLayoutMode.allCases) { mode in
                Button(mode.label) { editorVM.addCameraLayout(mode: mode) }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24))

        return TimelineLaneSpec(
            id: "camera-layouts",
            height: slimLaneHeight,
            gutterTitle: "Camera",
            gutterIcon: "rectangle.split.2x1",
            addControl: menu,
            bodyContent: AnyView(
                ClipLane(
                    duration: editorVM.duration,
                    height: slimLaneHeight,
                    playhead: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode,
                    snapEnabled: snapEnabled,
                    clips: cameraLayoutDescriptors,
                    background: Color(nsColor: .underPageBackgroundColor)
                )
            ),
            groupAccent: .blue
        )
    }

    private func audioLaneSpec(id: String, title: String, icon: String, url: URL?, loops: Bool, trailing: String?) -> TimelineLaneSpec {
        TimelineLaneSpec(
            id: id,
            height: audioLaneHeight,
            gutterTitle: title,
            gutterIcon: icon,
            gutterTrailing: trailing,
            bodyContent: AnyView(
                AudioWaveformView(
                    audioURL: url,
                    currentTime: editorVM.playheadTime,
                    duration: max(editorVM.duration, 0.001),
                    editActions: editorVM.project.editActions,
                    loops: loops,
                    muteCutRanges: true
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 4)
            ),
            groupAccent: .teal
        )
    }

    private var videoAddMenu: AnyView {
        AnyView(Menu {
            Menu("Add Title Card") {
                ForEach(TitleCardKind.allCases) { kind in
                    Button(kind.label) { editorVM.addTitleCard(kind: kind, at: editorVM.playheadTime) }
                }
            }
            Menu("Add Overlay") {
                ForEach(OverlayType.allCases, id: \.self) { type in
                    Button(type.label) { editorVM.addOverlay(type: type, at: editorVM.playheadTime) }
                }
            }
            Menu("Add Effect Segment") {
                ForEach(EffectSegmentPreset.allCases) { preset in
                    Button(preset.title) {
                        _ = editorVM.addEffectSegment(
                            startTime: editorVM.playheadTime,
                            endTime: min(editorVM.duration, editorVM.playheadTime + 5),
                            preset: preset
                        )
                    }
                }
            }
            Divider()
            Button("Add Zoom at Playhead") { editorVM.addZoomSegment(at: editorVM.playheadTime) }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24, height: 24))
    }

    // MARK: - Clip descriptors

    private var editActionDescriptors: [ClipDescriptor] {
        editorVM.editActions.map { action in
            let kind: TimelineClipKind
            let label: String
            switch action.type {
            case .cut:
                kind = .cut
                label = "Cut"
            case .speedChange:
                kind = .speed
                label = action.value.map { String(format: "%.1fx", $0) } ?? "Speed"
            case .hideCursor:
                kind = .hideCursor
                label = "Hide"
            }
            return ClipDescriptor(
                id: action.id,
                kind: kind,
                label: label,
                startTime: action.startTime,
                endTime: action.endTime,
                isSelected: editorVM.selectedTimelineItem == .editAction(action.id),
                minimumDuration: 0.2,
                onSelect: {
                    editorVM.selectEditAction(action.id)
                    editorVM.seek(to: action.startTime)
                },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    editorVM.updateEditActionTiming(action.id, startTime: start, endTime: end)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeEditAction(action.id) }
            )
        }
    }

    private var titleCardDescriptors: [ClipDescriptor] {
        editorVM.titleCards.map { card in
            let trimmed = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClipDescriptor(
                id: card.id,
                kind: .title,
                label: trimmed.isEmpty ? card.kind.label : trimmed,
                startTime: card.startTime,
                endTime: card.endTime,
                isSelected: editorVM.selectedTimelineItem == .titleCard(card.id),
                minimumDuration: 0.4,
                onSelect: {
                    editorVM.selectTitleCard(card.id)
                    editorVM.seek(to: card.startTime)
                },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    var updated = card
                    updated.startTime = start
                    updated.endTime = end
                    editorVM.updateTitleCard(updated)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeTitleCard(card.id) }
            )
        }
    }

    private var overlayDescriptors: [ClipDescriptor] {
        editorVM.overlays.map { overlay in
            let label: String
            if overlay.type == .text {
                let trimmed = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
                label = trimmed.isEmpty ? overlay.type.label : trimmed
            } else {
                label = overlay.type.label
            }
            return ClipDescriptor(
                id: overlay.id,
                kind: .overlay,
                label: label,
                startTime: overlay.startTime,
                endTime: overlay.endTime,
                isSelected: editorVM.selectedTimelineItem == .overlay(overlay.id),
                minimumDuration: 0.2,
                onSelect: {
                    editorVM.selectOverlay(overlay.id)
                    editorVM.seek(to: overlay.startTime)
                },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    var updated = overlay
                    updated.startTime = start
                    updated.endTime = end
                    editorVM.updateOverlay(updated)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeOverlay(overlay.id) }
            )
        }
    }

    private var effectSegmentDescriptors: [ClipDescriptor] {
        editorVM.effectSegments.map { segment in
            ClipDescriptor(
                id: segment.id,
                kind: .effect,
                label: segment.name,
                startTime: segment.startTime,
                endTime: segment.endTime,
                isSelected: editorVM.selectedTimelineItem == .effectSegment(segment.id),
                minimumDuration: 0.4,
                onSelect: {
                    editorVM.selectEffectSegment(segment.id)
                    editorVM.selectedTool = .effects
                    editorVM.seek(to: segment.startTime)
                },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    var updated = segment
                    updated.startTime = start
                    updated.endTime = end
                    editorVM.updateEffectSegment(updated)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeEffectSegment(segment.id) }
            )
        }
    }

    private var cameraLayoutDescriptors: [ClipDescriptor] {
        editorVM.cameraLayouts.map { layout in
            ClipDescriptor(
                id: layout.id,
                kind: .camera,
                label: layout.mode.label,
                startTime: layout.startTime,
                endTime: layout.endTime,
                isSelected: editorVM.selectedTimelineItem == .cameraLayout(layout.id),
                minimumDuration: 0.4,
                onSelect: {
                    editorVM.selectCameraLayout(layout.id)
                    editorVM.seek(to: layout.startTime)
                },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    var updated = layout
                    updated.startTime = start
                    updated.endTime = end
                    editorVM.updateCameraLayout(updated)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeCameraLayout(layout.id) }
            )
        }
    }

    // MARK: - Scrub (ruler)

    private func handleScrubChanged(x: CGFloat, width: CGFloat) {
        guard !editorVM.isTimelineItemInteractionActive else { return }
        let fraction = max(0, min(1, x / max(width, 1)))
        let time = fraction * safeDuration
        if !isDragging {
            dragAnchorTime = time
            editorVM.selectedRangeStart = time
            editorVM.selectedRangeEnd = time
        }
        isDragging = true
        editorVM.seek(to: time)
        editorVM.selectedRangeEnd = time
    }

    private func handleScrubEnded(x: CGFloat, width: CGFloat) {
        defer {
            isDragging = false
            dragAnchorTime = nil
        }
        guard !editorVM.isTimelineItemInteractionActive else { return }
        if let anchor = dragAnchorTime {
            editorVM.selectedRangeStart = anchor
            editorVM.selectedRangeEnd = editorVM.playheadTime
        }
    }

    // MARK: - Overlays (single playhead + selection band)

    @ViewBuilder
    private func playheadOverlay(width: CGFloat) -> some View {
        let x = playheadX(width: width)
        Rectangle()
            .fill(Color.clear)
            .frame(width: 1, height: timelineHeight)
            .position(x: x, y: timelineHeight / 2)
            .id(TimelineScrollTarget.playhead)
            .allowsHitTesting(false)

        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .frame(height: timelineHeight)
            .position(x: x, y: timelineHeight / 2)
            .allowsHitTesting(false)

        Circle()
            .fill(Color.accentColor)
            .frame(width: 11, height: 11)
            .overlay(Circle().fill(Color.white).frame(width: 3.5, height: 3.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            .position(x: x, y: rulerHeight / 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func selectionBandOverlay(width: CGFloat) -> some View {
        if let range = selectedRangeBand(width: width) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    Rectangle()
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                )
                .frame(width: range.width, height: timelineHeight)
                .position(x: range.midX, y: timelineHeight / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Controls bar

    private var timelineControls: some View {
        HStack(spacing: 8) {
            Button {
                timelineZoomScale = max(1, clampedTimelineZoomScale / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom timeline out")

            Slider(
                value: Binding(
                    get: { clampedTimelineZoomScale },
                    set: { timelineZoomScale = TimelinePreferences.sanitizedZoomScale($0) }
                ),
                in: 1...8
            )
            .frame(width: 140)
            .help("Timeline zoom")

            Button {
                timelineZoomScale = min(8, clampedTimelineZoomScale * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom timeline in")

            Text(String(format: "%.1fx", clampedTimelineZoomScale))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)

            if editorVM.isApplyingTimelineChanges || editorVM.isLoadingProjectMedia {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help(editorVM.isLoadingProjectMedia ? "Preparing editor media" : "Applying timeline changes")
            }

            Spacer()

            modifierHint
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var modifierHint: some View {
        if shiftExtendMode {
            Label("Extend", systemImage: "arrow.left.and.right")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.accentColor)
        } else if optionDeleteMode {
            Label("Delete", systemImage: "xmark.circle")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.red)
        } else if snapDisabled {
            Label("Snap off", systemImage: "magnet.slash")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
        } else {
            Text("Drag clips · Shift extends · ⌥ deletes · ⌃ disables snap")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var timelineResizeDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 1)
            ResizeTimelineHeightHandle()
            Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(timelineHeightResizeGesture)
        .help("Drag to resize timeline")
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Derived layout values

    private var safeDuration: Double { max(editorVM.duration, 0.001) }

    private func playheadX(width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, editorVM.playheadTime / safeDuration))) * width
    }

    private var snapEnabled: Bool { !snapDisabled }

    private var timelineHeight: CGFloat {
        laneSpecs.reduce(0) { $0 + $1.height }
    }

    private var timelineViewportHeight: CGFloat {
        timelineScrollHeight + (compact ? 0 : 44)
    }

    private var timelineScrollHeight: CGFloat {
        if compact {
            return min(timelineHeight, 190)
        }
        return min(timelineHeight, CGFloat(clampedExpandedTimelineHeight))
    }

    private var clampedTimelineZoomScale: Double {
        TimelinePreferences.sanitizedZoomScale(timelineZoomScale)
    }

    private var clampedExpandedTimelineHeight: Double {
        TimelinePreferences.sanitizedExpandedHeight(expandedTimelineHeight)
    }

    private var filmstripTrailingText: String? {
        let zoomCount = editorVM.zoomSegments.count
        return zoomCount == 0 ? nil : "\(zoomCount) zoom\(zoomCount == 1 ? "" : "s")"
    }

    private var timelineHeightResizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartHeight == nil {
                    resizeStartHeight = clampedExpandedTimelineHeight
                }
                let startHeight = resizeStartHeight ?? clampedExpandedTimelineHeight
                expandedTimelineHeight = TimelinePreferences.sanitizedExpandedHeight(startHeight - Double(value.translation.height))
            }
            .onEnded { _ in
                resizeStartHeight = nil
            }
    }

    private func centerTimelineOnPlayhead(using scrollProxy: ScrollViewProxy) {
        guard !compact else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                scrollProxy.scrollTo(TimelineScrollTarget.playhead, anchor: .center)
            }
        }
    }

    private func selectedRangeBand(width: CGFloat) -> CGRect? {
        guard let start = editorVM.selectedRangeStart,
              let end = editorVM.selectedRangeEnd,
              abs(end - start) >= 0.05 else {
            return nil
        }
        let left = min(start, end) / safeDuration * width
        let bandWidth = max(2, abs(end - start) / safeDuration * width)
        return CGRect(x: left, y: 0, width: bandWidth, height: timelineHeight)
    }

    // MARK: - Modifier key monitoring

    private func startModifierMonitoring() {
        updateModifierModes()
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                applyModifierFlags(event.modifierFlags)
                return event
            }
        }
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                Task { @MainActor in self.applyModifierFlags(event.modifierFlags) }
            }
        }
    }

    private func stopModifierMonitoring() {
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        optionDeleteMode = false
        shiftExtendMode = false
        snapDisabled = false
    }

    private func updateModifierModes() {
        applyModifierFlags(NSEvent.modifierFlags)
    }

    @MainActor
    private func applyModifierFlags(_ flags: NSEvent.ModifierFlags) {
        optionDeleteMode = flags.contains(.option)
        shiftExtendMode = flags.contains(.shift)
        snapDisabled = flags.contains(.control)
    }

    // MARK: - Audio summary helpers

    private var audioEditSummary: String? {
        let cuts = editorVM.project.editActions.filter { $0.type == .cut }.count
        let speeds = editorVM.project.editActions.filter { $0.type == .speedChange }.count
        if cuts == 0 && speeds == 0 { return nil }
        if cuts > 0 && speeds > 0 { return "\(cuts) cut\(cuts == 1 ? "" : "s") / \(speeds) speed" }
        if cuts > 0 { return "\(cuts) cut\(cuts == 1 ? "" : "s")" }
        return "\(speeds) speed"
    }

    private var mainAudioTrackTitle: String {
        if editorVM.project.micAudioFileURL == nil {
            return "Audio"
        }
        return editorVM.project.systemAudioEnabled == true ? "System" : "Screen"
    }

    private var mainAudioTrailingText: String? {
        let systemAudioText: String?
        if editorVM.project.systemAudioEnabled == true {
            systemAudioText = "system audio"
        } else if editorVM.project.micAudioFileURL != nil {
            systemAudioText = "no system audio"
        } else {
            systemAudioText = nil
        }
        switch (systemAudioText, audioEditSummary) {
        case let (status?, edits?): return "\(status) / \(edits)"
        case let (status?, nil): return status
        case let (nil, edits?): return edits
        case (nil, nil): return nil
        }
    }

    private var musicTrailingText: String? {
        let durationLabel = editorVM.backgroundMusicDuration > 0 ? formatDuration(editorVM.backgroundMusicDuration) : nil
        if editorVM.project.style.backgroundMusicLoop {
            return durationLabel.map { "\($0) loop" } ?? "loop"
        }
        return durationLabel
    }

    private func formatDuration(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }
}

// MARK: - Clip descriptor

/// A ranged clip projected from any track model into the unified rendering/gesture
/// pipeline. Carries closures bound to the originating model so the generic
/// `TimelineClipView` never needs to know the concrete segment type.
struct ClipDescriptor: Identifiable {
    let id: UUID
    let kind: TimelineClipKind
    let label: String
    let startTime: Double
    let endTime: Double
    let isSelected: Bool
    let minimumDuration: Double
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (Double, Double) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @MainActor
    func makeView(
        duration: Double,
        totalWidth: CGFloat,
        laneHeight: CGFloat,
        showsDeleteControls: Bool,
        extendsWithShift: Bool,
        snapCandidates: [Double],
        snapThresholdSeconds: Double,
        snapEnabled: Bool,
        dragFeedback: TimelineDragFeedback
    ) -> TimelineClipView {
        TimelineClipView(
            kind: kind,
            label: label,
            startTime: startTime,
            endTime: endTime,
            isSelected: isSelected,
            duration: duration,
            totalWidth: totalWidth,
            laneHeight: laneHeight,
            minimumDuration: minimumDuration,
            showsDeleteControls: showsDeleteControls,
            extendsWithShift: extendsWithShift,
            snapCandidates: snapCandidates,
            snapThresholdSeconds: snapThresholdSeconds,
            snapEnabled: snapEnabled,
            onSelect: onSelect,
            onBeginEdit: onBeginEdit,
            onUpdate: onUpdate,
            onEndEdit: onEndEdit,
            onRemove: onRemove,
            dragFeedback: dragFeedback
        )
    }
}

// MARK: - Snap math

enum TimelineSnapMath {
    static func candidates(playhead: Double, duration: Double, width: CGFloat, clips: [ClipDescriptor]) -> [Double] {
        var values: [Double] = [playhead]
        values.append(contentsOf: TimelineTickPlanner.ticks(duration: duration, width: width).map(Double.init))
        for clip in clips {
            values.append(clip.startTime)
            values.append(clip.endTime)
        }
        return values
    }

    static func threshold(duration: Double, width: CGFloat) -> Double {
        let pixelsPerSecond = width / max(duration, 0.001)
        return min(0.5, 10.0 / max(pixelsPerSecond, 1))
    }
}

// MARK: - Generic clip lane

/// A lane that renders any set of ranged clips against a plain background, with a
/// shared snap guide. Used by title / overlay / effect / camera / edits lanes.
struct ClipLane: View {
    let duration: Double
    let height: CGFloat
    let playhead: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let snapEnabled: Bool
    let clips: [ClipDescriptor]
    let background: Color

    @StateObject private var dragFeedback = TimelineDragFeedback()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let candidates = TimelineSnapMath.candidates(playhead: playhead, duration: duration, width: width, clips: clips)
            let threshold = TimelineSnapMath.threshold(duration: duration, width: width)

            ZStack(alignment: .topLeading) {
                background

                ForEach(clips) { descriptor in
                    descriptor.makeView(
                        duration: duration,
                        totalWidth: width,
                        laneHeight: height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        snapCandidates: candidates,
                        snapThresholdSeconds: threshold,
                        snapEnabled: snapEnabled,
                        dragFeedback: dragFeedback
                    )
                }

                snapGuide(width: width)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func snapGuide(width: CGFloat) -> some View {
        if let time = dragFeedback.snapGuideTime {
            let x = CGFloat(time / max(duration, 0.001)) * width
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1)
                .frame(height: height)
                .position(x: x, y: height / 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Video (filmstrip) lane

/// The hero lane: real video frames with zoom clips floating on top. Tapping an empty
/// area adds a zoom segment at that time (preserving the prior ZoomTrackView affordance).
struct VideoTimelineLane: View {
    @ObservedObject var editorVM: EditorVM
    let duration: Double
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let snapEnabled: Bool
    let videoURL: URL?

    @StateObject private var dragFeedback = TimelineDragFeedback()

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clips = zoomDescriptors
            let candidates = TimelineSnapMath.candidates(playhead: editorVM.playheadTime, duration: duration, width: width, clips: clips)
            let threshold = TimelineSnapMath.threshold(duration: duration, width: width)

            ZStack(alignment: .topLeading) {
                FilmstripView(videoURL: videoURL, duration: duration)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .gesture(addZoomGesture(width: width))

                ForEach(clips) { descriptor in
                    descriptor.makeView(
                        duration: duration,
                        totalWidth: width,
                        laneHeight: height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        snapCandidates: candidates,
                        snapThresholdSeconds: threshold,
                        snapEnabled: snapEnabled,
                        dragFeedback: dragFeedback
                    )
                }

                snapGuide(width: width)
            }
        }
        .frame(height: height)
    }

    private var zoomDescriptors: [ClipDescriptor] {
        editorVM.zoomSegments.map { segment in
            ClipDescriptor(
                id: segment.id,
                kind: .zoom(manual: segment.source == .manual),
                label: segment.zoomRect == .zero ? "Full" : "Zoom",
                startTime: segment.startTime,
                endTime: segment.endTime,
                isSelected: editorVM.selectedTimelineItem == .zoom(segment.id),
                minimumDuration: 0.3,
                onSelect: { editorVM.selectZoomSegment(segment.id) },
                onBeginEdit: { editorVM.beginInteractiveEdit() },
                onUpdate: { start, end in
                    editorVM.updateZoomSegmentTiming(segment.id, startTime: start, endTime: end)
                },
                onEndEdit: { editorVM.endInteractiveEdit() },
                onRemove: { editorVM.removeZoomSegment(segment.id) }
            )
        }
    }

    private func addZoomGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard abs(value.translation.width) < 3, abs(value.translation.height) < 3 else { return }
                let clampedX = max(0, min(width, value.location.x))
                let time = Double(clampedX / max(width, 1)) * max(duration, 0.001)
                editorVM.addZoomSegment(at: time)
                editorVM.selectedTool = .zoom
            }
    }

    @ViewBuilder
    private func snapGuide(width: CGFloat) -> some View {
        if let time = dragFeedback.snapGuideTime {
            let x = CGFloat(time / max(duration, 0.001)) * width
            Rectangle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 1)
                .frame(height: height)
                .position(x: x, y: height / 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Keys lane

struct KeysTimelineLane: View {
    @ObservedObject var editorVM: EditorVM
    let duration: Double
    let height: CGFloat
    let showsDeleteControls: Bool

    var body: some View {
        GeometryReader { geo in
            let events = TimelineEventSampler.sampleKeyEvents(
                editorVM.recordedKeyEvents,
                duration: duration,
                width: geo.size.width
            )
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(nsColor: .underPageBackgroundColor))

                ForEach(events) { event in
                    let x = (event.timestamp / max(duration, 0.001)) * geo.size.width
                    KeyPill(
                        text: event.displayString,
                        isSelected: editorVM.selectedTimelineItem == .keyEvent(event.id),
                        showsDelete: showsDeleteControls,
                        onRemove: { editorVM.removeKeyEvent(event.id) }
                    )
                    .position(x: max(26, min(geo.size.width - 26, x)), y: height / 2)
                    .contextMenu {
                        Button("Hide this key") { editorVM.removeKeyEvent(event.id) }
                        Button("Hide all \(event.displayString)") {
                            _ = editorVM.removeKeyEvents(matching: event.displayString)
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }
}

private struct KeyPill: View {
    let text: String
    let isSelected: Bool
    let showsDelete: Bool
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.26))
                        .overlay(
                            Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.accentColor)
                .onTapGesture { onRemove() }

            if showsDelete {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
        .help("Click to hide this shortcut badge. Right-click to hide all matching badges.")
    }
}

// MARK: - Ruler

/// The ruler: tick labels + a scrub/selection gesture. It draws no playhead of its own;
/// the single global playhead is overlaid by `TimelineView` so it spans every lane.
struct TimelineRulerBody: View {
    let duration: Double
    let onChange: (CGFloat, CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(TimelineTickPlanner.ticks(duration: duration, width: geo.size.width), id: \.self) { second in
                    let x = (Double(second) / max(duration, 0.001)) * geo.size.width
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 1, height: 6)
                        Text(formatTime(second))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .position(x: x, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clampedX = max(0, min(geo.size.width, value.location.x))
                        onChange(clampedX, geo.size.width)
                    }
                    .onEnded { value in
                        let clampedX = max(0, min(geo.size.width, value.location.x))
                        onEnd(clampedX, geo.size.width)
                    }
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatTime(_ seconds: Int) -> String {
        TimecodeFormatter.positional(seconds)
    }
}

// MARK: - Tick planner (signature used by EditorProFeatureTests)

enum TimelineTickPlanner {
    static func ticks(duration: Double, width: CGFloat, minimumSpacing: CGFloat = 76) -> [Int] {
        guard duration.isFinite, duration > 0 else { return [0] }
        let maxVisibleTicks = max(2, Int(width / max(minimumSpacing, 1)) + 1)
        let rawStep = duration / Double(maxVisibleTicks - 1)
        let step = niceStep(atLeast: rawStep)
        let lastSecond = max(0, Int(ceil(duration)))

        var ticks: [Int] = []
        var value = 0
        while value <= lastSecond {
            ticks.append(value)
            value += step
        }
        if ticks.last != lastSecond {
            ticks.append(lastSecond)
        }
        return ticks
    }

    private static func niceStep(atLeast rawStep: Double) -> Int {
        let candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
        return candidates.first { Double($0) >= rawStep } ?? Int(ceil(rawStep / 3_600)) * 3_600
    }
}

// MARK: - Resize handle (timeline height)

struct ResizeTimelineHeightHandle: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 26, height: 3)
            Capsule().fill(Color.secondary.opacity(0.38)).frame(width: 26, height: 3)
        }
        .frame(width: 42, height: 28)
        .contentShape(Rectangle())
    }
}
