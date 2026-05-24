import SwiftUI

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

struct TimelineView: View {
    @ObservedObject var editorVM: EditorVM
    let compact: Bool
    @State private var isDragging = false
    @State private var dragAnchorTime: Double?
    @State private var optionDeleteMode = false
    @State private var shiftExtendMode = false
    @State private var localFlagsMonitor: Any?
    @State private var globalFlagsMonitor: Any?
    @State private var resizeStartHeight: Double?
    @AppStorage(TimelinePreferences.zoomScaleKey) private var timelineZoomScale: Double = 1.0
    @AppStorage(TimelinePreferences.expandedHeightKey) private var expandedTimelineHeight: Double = 320

    init(editorVM: EditorVM, compact: Bool = false) {
        self.editorVM = editorVM
        self.compact = compact
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                timelineResizeDivider
            }

            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    let contentWidth = max(geometry.size.width, geometry.size.width * CGFloat(clampedTimelineZoomScale))
                    ScrollView([.horizontal, .vertical]) {
                        timelineContent(width: contentWidth)
                            .frame(width: contentWidth, height: timelineHeight)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
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
        .onAppear {
            startModifierMonitoring()
        }
        .onDisappear(perform: stopModifierMonitoring)
    }

    private var timelineControls: some View {
        HStack(spacing: 8) {
            Button {
                timelineZoomScale = max(1, clampedTimelineZoomScale / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 18)
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
            .frame(width: 150)
            .help("Timeline zoom")

            Button {
                timelineZoomScale = min(8, clampedTimelineZoomScale * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 18)
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

            if shiftExtendMode {
                Label("Extend", systemImage: "arrow.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
            } else if optionDeleteMode {
                Label("Delete", systemImage: "xmark.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.red)
            } else {
                Text("Shift-drag extends. Option shows delete.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var timelineResizeDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(height: 1)
            ResizeTimelineHeightHandle()
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(height: 1)
        }
        .padding(.horizontal, 10)
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(timelineHeightResizeGesture)
        .help("Drag to resize timeline")
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func timelineContent(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                TimelineRuler(
                    duration: editorVM.duration,
                    currentTime: $editorVM.playheadTime
                )
                .contentShape(Rectangle())
                .gesture(selectionGesture(width: width))

                if !editorVM.titleCards.isEmpty {
                    TitleCardTimelineTrackView(
                        editorVM: editorVM,
                        currentTime: editorVM.playheadTime,
                        showsDeleteControls: optionDeleteMode,
                        extendsWithShift: shiftExtendMode
                    )
                }

                ZoomTrackView(
                    editorVM: editorVM,
                    currentTime: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode
                )

                EditRegionsTrackView(
                    editorVM: editorVM,
                    currentTime: editorVM.playheadTime,
                    showsDeleteControls: optionDeleteMode,
                    extendsWithShift: shiftExtendMode
                )

                if editorVM.selectedTool == .effects || !editorVM.effectSegments.isEmpty {
                    EffectSegmentsTimelineTrackView(
                        editorVM: editorVM,
                        currentTime: editorVM.playheadTime,
                        showsDeleteControls: optionDeleteMode,
                        extendsWithShift: shiftExtendMode
                    )
                }

                if !editorVM.overlays.isEmpty {
                    OverlayTimelineTrackView(
                        editorVM: editorVM,
                        currentTime: editorVM.playheadTime,
                        showsDeleteControls: optionDeleteMode,
                        extendsWithShift: shiftExtendMode
                    )
                }

                if editorVM.hasKeyboardEvents {
                    ShortcutTimelineTrackView(
                        editorVM: editorVM,
                        currentTime: editorVM.playheadTime,
                        showsDeleteControls: optionDeleteMode
                    )
                }

                if editorVM.project.webcamFileURL != nil {
                    CameraLayoutTimelineTrackView(
                        editorVM: editorVM,
                        currentTime: editorVM.playheadTime,
                        showsDeleteControls: optionDeleteMode,
                        extendsWithShift: shiftExtendMode
                    )
                }

                AudioTimelineTrackView(
                    title: mainAudioTrackTitle,
                    systemImage: "waveform",
                    audioURL: editorVM.project.systemAudioFileURL ?? editorVM.project.videoFileURL,
                    currentTime: editorVM.playheadTime,
                    duration: editorVM.duration,
                    editActions: editorVM.project.editActions,
                    loops: false,
                    trailingText: mainAudioTrailingText
                )

                if let micAudioURL = editorVM.project.micAudioFileURL {
                    AudioTimelineTrackView(
                        title: "Mic",
                        systemImage: "mic",
                        audioURL: micAudioURL,
                        currentTime: editorVM.playheadTime,
                        duration: editorVM.duration,
                        editActions: editorVM.project.editActions,
                        loops: false,
                        trailingText: audioEditSummary
                    )
                }

                if editorVM.project.style.backgroundMusicURL != nil {
                    AudioTimelineTrackView(
                        title: "Music",
                        systemImage: "music.note",
                        audioURL: editorVM.project.style.backgroundMusicURL,
                        currentTime: editorVM.playheadTime,
                        duration: editorVM.duration,
                        editActions: editorVM.project.editActions,
                        loops: editorVM.project.style.backgroundMusicLoop,
                        trailingText: musicTrailingText
                    )
                }
            }

            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: timelineHeight)
                .position(x: playheadX(width: width), y: timelineHeight / 2)
                .id(TimelineScrollTarget.playhead)
                .allowsHitTesting(false)

            if let range = selectedRangeBand(width: width) {
                Rectangle()
                    .fill(Color.red.opacity(0.12))
                    .overlay(
                        Rectangle()
                            .stroke(Color.red.opacity(0.45), lineWidth: 1)
                    )
                    .frame(width: range.width, height: timelineHeight)
                    .position(x: range.midX, y: timelineHeight / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var safeDuration: Double {
        max(editorVM.duration, 0.001)
    }

    private func playheadX(width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(1, editorVM.playheadTime / safeDuration))) * width
    }

    private func selectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !editorVM.isTimelineItemInteractionActive else { return }
                let clampedX = max(0, min(width, value.location.x))
                let fraction = max(0, min(1, clampedX / max(width, 1)))
                let newTime = fraction * safeDuration

                if !isDragging {
                    dragAnchorTime = newTime
                    editorVM.selectedRangeStart = newTime
                    editorVM.selectedRangeEnd = newTime
                }

                isDragging = true
                editorVM.seek(to: newTime)
                editorVM.selectedRangeEnd = newTime
            }
            .onEnded { _ in
                defer {
                    isDragging = false
                    dragAnchorTime = nil
                }
                guard !editorVM.isTimelineItemInteractionActive else { return }
                if let dragAnchorTime {
                    editorVM.selectedRangeStart = dragAnchorTime
                    editorVM.selectedRangeEnd = editorVM.playheadTime
                }
            }
    }

    private var timelineHeight: CGFloat {
        var height: CGFloat = compact ? 190 : 226
        if !editorVM.titleCards.isEmpty {
            height += 42
        }
        if editorVM.hasKeyboardEvents {
            height += 42
        }
        if !editorVM.overlays.isEmpty {
            height += 42
        }
        if editorVM.selectedTool == .effects || !editorVM.effectSegments.isEmpty {
            height += 42
        }
        if editorVM.project.webcamFileURL != nil {
            height += 42
        }
        if editorVM.project.micAudioFileURL != nil {
            height += 56
        }
        if editorVM.project.style.backgroundMusicURL != nil {
            height += 56
        }
        return height
    }

    private var timelineViewportHeight: CGFloat {
        timelineScrollHeight + (compact ? 0 : 48)
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

    private func startModifierMonitoring() {
        updateModifierModes()
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionDeleteMode = event.modifierFlags.contains(.option)
                shiftExtendMode = event.modifierFlags.contains(.shift)
                return event
            }
        }
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                Task { @MainActor in
                    optionDeleteMode = event.modifierFlags.contains(.option)
                    shiftExtendMode = event.modifierFlags.contains(.shift)
                }
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
    }

    private func updateModifierModes() {
        optionDeleteMode = NSEvent.modifierFlags.contains(.option)
        shiftExtendMode = NSEvent.modifierFlags.contains(.shift)
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
        case let (status?, edits?):
            return "\(status) / \(edits)"
        case let (status?, nil):
            return status
        case let (nil, edits?):
            return edits
        case (nil, nil):
            return nil
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

struct TitleCardTimelineTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                HStack(spacing: 6) {
                    Label("Cards", systemImage: "sparkles.tv")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        ForEach(TitleCardKind.allCases) { kind in
                            Button(kind.label) {
                                editorVM.addTitleCard(kind: kind, at: editorVM.playheadTime)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)

                ForEach(editorVM.titleCards) { card in
                    TitleCardTimelineBlock(
                        card: card,
                        isSelected: editorVM.selectedTimelineItem == .titleCard(card.id),
                        duration: editorVM.duration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectTitleCard(card.id)
                            editorVM.seek(to: card.startTime)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: editorVM.updateTitleCard,
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeTitleCard(card.id)
                        }
                    )
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2)
                    .position(
                        x: (currentTime / max(editorVM.duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .frame(height: 36)
    }
}

private struct TitleCardTimelineBlock: View {
    let card: TitleCardSegment
    let isSelected: Bool
    let duration: Double
    let totalWidth: CGFloat
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (TitleCardSegment) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        let startX = (card.startTime / max(duration, 0.001)) * totalWidth
        let width = max((max(0.1, card.endTime - card.startTime) / max(duration, 0.001)) * totalWidth, 34)

        ZStack(alignment: .topTrailing) {
            Label(card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.kind.label : card.title, systemImage: "text.rectangle")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .frame(width: width, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.orange.opacity(0.26))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.orange)
            HStack(spacing: 0) {
                ResizeHandle(color: .orange)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                ResizeHandle(color: .orange)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            .frame(width: width, height: 24)
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
            .position(x: startX + width / 2, y: height / 2)
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .highPriorityGesture(moveGesture)
            .contextMenu {
                ForEach(TitleCardStyle.allCases) { style in
                    Button(style.label) {
                        var updated = card
                        updated.style = style
                        onUpdate(updated)
                    }
                }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * duration
                guard let dragStart, let dragEnd else { return }
                var updated = card
                if extendsWithShift {
                    if delta >= 0 {
                        updated.startTime = dragStart
                        updated.endTime = min(duration, dragEnd + delta)
                    } else {
                        updated.startTime = max(0, dragStart + delta)
                        updated.endTime = dragEnd
                    }
                } else {
                    let length = max(0.4, dragEnd - dragStart)
                    updated.startTime = max(0, min(duration - length, dragStart + delta))
                    updated.endTime = updated.startTime + length
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * duration
                guard let dragStart, let dragEnd else { return }
                var updated = card
                switch edge {
                case .leading:
                    updated.startTime = dragStart + delta
                    updated.endTime = dragEnd
                case .trailing:
                    updated.startTime = dragStart
                    updated.endTime = dragEnd + delta
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = card.startTime
            dragEnd = card.endTime
        }
    }
}

struct ShortcutTimelineTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool

    var body: some View {
        GeometryReader { geometry in
            let visibleEvents = TimelineEventSampler.sampleKeyEvents(
                editorVM.recordedKeyEvents,
                duration: editorVM.duration,
                width: geometry.size.width
            )
            let hiddenCount = max(0, editorVM.recordedKeyEvents.count - visibleEvents.count)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                HStack(spacing: 6) {
                    Label("Keys", systemImage: "keyboard")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                            .help("Dense key events are sampled in the timeline. Preview and export still use all recorded keys.")
                    }
                }
                .padding(.horizontal, 8)
                .allowsHitTesting(false)

                ForEach(visibleEvents) { event in
                    let x = (event.timestamp / max(editorVM.duration, 0.001)) * geometry.size.width
                    ShortcutEventBlock(
                        event: event,
                        isSelected: editorVM.selectedTimelineItem == .keyEvent(event.id),
                        showsDeleteControls: showsDeleteControls,
                        onSelect: {
                            editorVM.removeKeyEvent(event.id)
                        },
                        onRemove: {
                            editorVM.removeKeyEvent(event.id)
                        }
                    )
                        .position(x: max(28, min(geometry.size.width - 28, x)), y: geometry.size.height / 2)
                        .contextMenu {
                            Button("Hide this key") {
                                editorVM.removeKeyEvent(event.id)
                            }
                            Button("Hide all \(event.displayString)") {
                                _ = editorVM.removeKeyEvents(matching: event.displayString)
                            }
                        }
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2)
                    .position(
                        x: (currentTime / max(editorVM.duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .frame(height: 36)
    }
}

private struct ShortcutEventBlock: View {
    let event: KeyPressEvent
    let isSelected: Bool
    let showsDeleteControls: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(event.displayString)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.26))
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.accentColor)
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .help("Click to hide this shortcut badge. Right-click to hide all matching badges.")
    }
}

struct CameraLayoutTimelineTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                HStack(spacing: 6) {
                    Label("Layouts", systemImage: "rectangle.split.2x1")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        ForEach(CameraLayoutMode.allCases) { mode in
                            Button(mode.label) {
                                editorVM.addCameraLayout(mode: mode)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)

                ForEach(editorVM.cameraLayouts) { layout in
                    CameraLayoutBlock(
                        layout: layout,
                        isSelected: editorVM.selectedTimelineItem == .cameraLayout(layout.id),
                        duration: editorVM.duration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectCameraLayout(layout.id)
                            editorVM.seek(to: layout.startTime)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: editorVM.updateCameraLayout,
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeCameraLayout(layout.id)
                        }
                    )
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2)
                    .position(
                        x: (currentTime / max(editorVM.duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .frame(height: 36)
    }
}

struct EffectSegmentsTimelineTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                HStack(spacing: 6) {
                    Label("Segments", systemImage: "slider.horizontal.3")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
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
                    .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)

                ForEach(editorVM.effectSegments) { segment in
                    EffectSegmentTimelineBlock(
                        segment: segment,
                        isSelected: editorVM.selectedTimelineItem == .effectSegment(segment.id),
                        duration: editorVM.duration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectEffectSegment(segment.id)
                            editorVM.selectedTool = .effects
                            editorVM.seek(to: segment.startTime)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: editorVM.updateEffectSegment,
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeEffectSegment(segment.id)
                        }
                    )
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2)
                    .position(
                        x: (currentTime / max(editorVM.duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .frame(height: 36)
    }
}

private struct EffectSegmentTimelineBlock: View {
    let segment: EffectSegment
    let isSelected: Bool
    let duration: Double
    let totalWidth: CGFloat
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (EffectSegment) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        let safeDuration = max(duration, 0.001)
        let startX = (segment.startTime / safeDuration) * totalWidth
        let width = max((segment.duration / safeDuration) * totalWidth, 34)

        ZStack(alignment: .topTrailing) {
            Label(segment.name, systemImage: "slider.horizontal.3")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .frame(width: width, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.indigo.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.indigo)
            HStack(spacing: 0) {
                ResizeHandle(color: .indigo)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                ResizeHandle(color: .indigo)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            .frame(width: width, height: 24)
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
        .position(x: startX + width / 2, y: height / 2)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .highPriorityGesture(moveGesture)
        .contextMenu {
            ForEach(EffectSegmentPreset.allCases) { preset in
                Button(preset.title) {
                    var updated = segment
                    preset.apply(to: &updated)
                    onUpdate(updated)
                }
            }
            Divider()
            Button("Remove Segment", role: .destructive, action: onRemove)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                var updated = segment
                if extendsWithShift {
                    if delta >= 0 {
                        updated.startTime = dragStart
                        updated.endTime = min(safeDuration, dragEnd + delta)
                    } else {
                        updated.startTime = max(0, dragStart + delta)
                        updated.endTime = dragEnd
                    }
                } else {
                    let length = max(0.4, dragEnd - dragStart)
                    updated.startTime = max(0, min(safeDuration - length, dragStart + delta))
                    updated.endTime = updated.startTime + length
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                var updated = segment
                switch edge {
                case .leading:
                    updated.startTime = dragStart + delta
                    updated.endTime = dragEnd
                case .trailing:
                    updated.startTime = dragStart
                    updated.endTime = dragEnd + delta
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = segment.startTime
            dragEnd = segment.endTime
        }
    }
}

private struct CameraLayoutBlock: View {
    let layout: CameraLayoutSegment
    let isSelected: Bool
    let duration: Double
    let totalWidth: CGFloat
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (CameraLayoutSegment) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        let startX = (layout.startTime / max(duration, 0.001)) * totalWidth
        let width = max((max(0.1, layout.endTime - layout.startTime) / max(duration, 0.001)) * totalWidth, 28)

        ZStack(alignment: .topTrailing) {
            Label(layout.mode.label, systemImage: layout.mode.systemImage)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .frame(width: width, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.purple.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.purple : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.purple)
            HStack(spacing: 0) {
                ResizeHandle(color: .purple)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                ResizeHandle(color: .purple)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            .frame(width: width, height: 24)
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
            .position(x: startX + width / 2, y: height / 2)
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .highPriorityGesture(moveGesture)
            .contextMenu {
                ForEach(CameraLayoutMode.allCases) { mode in
                    Button(mode.label) {
                        var updated = layout
                        updated.mode = mode
                        onUpdate(updated)
                    }
                }
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * duration
                guard let dragStart, let dragEnd else { return }
                var updated = layout
                if extendsWithShift {
                    if delta >= 0 {
                        updated.startTime = dragStart
                        updated.endTime = min(duration, dragEnd + delta)
                    } else {
                        updated.startTime = max(0, dragStart + delta)
                        updated.endTime = dragEnd
                    }
                } else {
                    let length = max(0.4, dragEnd - dragStart)
                    updated.startTime = max(0, min(duration - length, dragStart + delta))
                    updated.endTime = updated.startTime + length
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * duration
                guard let dragStart, let dragEnd else { return }
                var updated = layout
                switch edge {
                case .leading:
                    updated.startTime = dragStart + delta
                    updated.endTime = dragEnd
                case .trailing:
                    updated.startTime = dragStart
                    updated.endTime = dragEnd + delta
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = layout.startTime
            dragEnd = layout.endTime
        }
    }
}

struct OverlayTimelineTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                HStack(spacing: 6) {
                    Label("Effects", systemImage: "rectangle.on.rectangle")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        ForEach(OverlayType.allCases, id: \.self) { type in
                            Button(type.label) {
                                editorVM.addOverlay(type: type, at: editorVM.playheadTime)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)

                ForEach(editorVM.overlays) { overlay in
                    OverlayTimelineBlock(
                        overlay: overlay,
                        isSelected: editorVM.selectedTimelineItem == .overlay(overlay.id),
                        duration: editorVM.duration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectOverlay(overlay.id)
                            editorVM.seek(to: overlay.startTime)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: editorVM.updateOverlay,
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeOverlay(overlay.id)
                        }
                    )
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 2)
                    .position(
                        x: (currentTime / max(editorVM.duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .frame(height: 36)
    }
}

private struct OverlayTimelineBlock: View {
    let overlay: OverlayElement
    let isSelected: Bool
    let duration: Double
    let totalWidth: CGFloat
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (OverlayElement) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        let safeDuration = max(duration, 0.001)
        let startX = (overlay.startTime / safeDuration) * totalWidth
        let width = max(((overlay.endTime - overlay.startTime) / safeDuration) * totalWidth, 34)

        ZStack(alignment: .topTrailing) {
            Label(overlayLabel, systemImage: overlayIcon)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .frame(width: width, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.teal.opacity(0.26))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isSelected ? Color.teal : Color.clear, lineWidth: 2)
                        )
                )
                .foregroundColor(.teal)
            HStack(spacing: 0) {
                ResizeHandle(color: .teal)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                ResizeHandle(color: .teal)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            .frame(width: width, height: 24)
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 7, y: -7)
            }
        }
            .position(x: startX + width / 2, y: height / 2)
            .simultaneousGesture(TapGesture().onEnded(onSelect))
            .highPriorityGesture(moveGesture)
            .contextMenu {
                ForEach(OverlayType.allCases, id: \.self) { type in
                    Button(type.label) {
                        var updated = overlay
                        updated.type = type
                        onUpdate(updated)
                    }
                }
                Divider()
                Button("Remove Effect", role: .destructive, action: onRemove)
            }
    }

    private var overlayLabel: String {
        if overlay.type == .text {
            let text = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return overlay.type.label
    }

    private var overlayIcon: String {
        switch overlay.type {
        case .blur:
            return "rectangle.dashed"
        case .highlight:
            return "highlighter"
        case .spotlight:
            return "circle.dashed"
        case .text:
            return "textformat"
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                var updated = overlay
                if extendsWithShift {
                    if delta >= 0 {
                        updated.startTime = dragStart
                        updated.endTime = min(safeDuration, dragEnd + delta)
                    } else {
                        updated.startTime = max(0, dragStart + delta)
                        updated.endTime = dragEnd
                    }
                } else {
                    let length = max(0.2, dragEnd - dragStart)
                    let newStart = max(0, min(safeDuration - length, dragStart + delta))
                    updated.startTime = newStart
                    updated.endTime = newStart + length
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                var updated = overlay
                switch edge {
                case .leading:
                    updated.startTime = dragStart + delta
                    updated.endTime = dragEnd
                case .trailing:
                    updated.startTime = dragStart
                    updated.endTime = dragEnd + delta
                }
                onUpdate(updated)
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = overlay.startTime
            dragEnd = overlay.endTime
        }
    }
}

struct AudioTimelineTrackView: View {
    let title: String
    let systemImage: String
    let audioURL: URL?
    let currentTime: Double
    let duration: Double
    let editActions: [EditAction]
    let loops: Bool
    let trailingText: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)

            AudioWaveformView(
                audioURL: audioURL,
                currentTime: currentTime,
                duration: max(duration, 0.001),
                editActions: editActions,
                loops: loops,
                muteCutRanges: true
            )
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct EditRegionsTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if let start = editorVM.selectedRangeStart,
                   let end = editorVM.selectedRangeEnd,
                   abs(end - start) >= 0.05 {
                    let left = min(start, end) / safeDuration * geometry.size.width
                    let width = abs(end - start) / safeDuration * geometry.size.width
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: width)
                        .position(x: left + width / 2, y: geometry.size.height / 2)
                }

                ForEach(editorVM.editActions) { action in
                    EditableEditActionBlock(
                        action: action,
                        isSelected: editorVM.selectedTimelineItem == .editAction(action.id),
                        duration: editorVM.duration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectEditAction(action.id)
                            editorVM.seek(to: action.startTime)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: { start, end in
                            editorVM.updateEditActionTiming(action.id, startTime: start, endTime: end)
                        },
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeEditAction(action.id)
                        }
                    )
                }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .position(x: (currentTime / safeDuration) * geometry.size.width, y: geometry.size.height / 2)
            }
        }
        .frame(height: 36)
    }

    private var safeDuration: Double {
        max(editorVM.duration, 0.001)
    }
}

struct EditableEditActionBlock: View {
    let action: EditAction
    let isSelected: Bool
    let duration: Double
    let totalWidth: CGFloat
    let height: CGFloat
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (Double, Double) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    var body: some View {
        let safeDuration = max(duration, 0.001)
        let startX = (action.startTime / safeDuration) * totalWidth
        let width = max((action.duration / safeDuration) * totalWidth, 12)
        let fillColor: Color = switch action.type {
        case .cut:
            .red.opacity(0.3)
        case .speedChange:
            .blue.opacity(0.3)
        case .hideCursor:
            .orange.opacity(0.32)
        }
        let accentColor: Color = switch action.type {
        case .cut:
            .red
        case .speedChange:
            .blue
        case .hideCursor:
            .orange
        }
        let label: String = switch action.type {
        case .cut:
            "Cut"
        case .speedChange:
            "Speed"
        case .hideCursor:
            "Hide Cursor"
        }

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? accentColor : Color.clear, lineWidth: 2)
                )
            HStack(spacing: 0) {
                ResizeHandle(color: accentColor)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                if showsDeleteControls {
                    TimelineDeleteButton(action: onRemove)
                        .offset(y: -8)
                }
                ResizeHandle(color: accentColor)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(accentColor)
        }
        .frame(width: width, height: 24)
        .position(x: startX + width / 2, y: height / 2)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .highPriorityGesture(moveGesture)
        .contextMenu {
            Button("Remove", action: onRemove)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                if extendsWithShift {
                    if delta >= 0 {
                        onUpdate(dragStart, min(safeDuration, dragEnd + delta))
                    } else {
                        onUpdate(max(0, dragStart + delta), dragEnd)
                    }
                } else {
                    let length = dragEnd - dragStart
                    let newStart = max(0, min(safeDuration - length, dragStart + delta))
                    onUpdate(newStart, newStart + length)
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let safeDuration = max(duration, 0.001)
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }
                switch edge {
                case .leading:
                    onUpdate(dragStart + delta, dragEnd)
                case .trailing:
                    onUpdate(dragStart, dragEnd + delta)
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = action.startTime
            dragEnd = action.endTime
        }
    }
}

enum ResizeEdge {
    case leading
    case trailing
}

struct ResizeHandle: View {
    let color: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 16)
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.82))
                .frame(width: 6)
        }
        .frame(width: 16)
        .contentShape(Rectangle())
    }
}

struct ResizeTimelineHeightHandle: View {
    var body: some View {
        VStack(spacing: 3) {
            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 26, height: 3)
            Capsule()
                .fill(Color.secondary.opacity(0.38))
                .frame(width: 26, height: 3)
        }
        .frame(width: 42, height: 28)
        .contentShape(Rectangle())
    }
}

struct TimelineDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .shadow(radius: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .help("Remove selected timeline item")
    }
}

struct TimelineRuler: View {
    let duration: Double
    @Binding var currentTime: Double
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(TimelineTickPlanner.ticks(duration: duration, width: geometry.size.width), id: \.self) { second in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.28))
                            .frame(width: 1, height: 6)
                        Text(formatTime(second))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(width: 54)
                    }
                    .position(
                        x: (Double(second) / max(duration, 0.001)) * geometry.size.width,
                        y: geometry.size.height / 2
                    )
                }
                
                // Playhead line
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2)
                    .position(x: (currentTime / max(duration, 0.001)) * geometry.size.width, y: geometry.size.height / 2)
                
                // Playhead handle
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .position(x: (currentTime / max(duration, 0.001)) * geometry.size.width, y: geometry.size.height / 2)
            }
        }
        .frame(height: 30)
    }
    
    private func formatTime(_ seconds: Int) -> String {
        TimecodeFormatter.positional(seconds)
    }
}

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
