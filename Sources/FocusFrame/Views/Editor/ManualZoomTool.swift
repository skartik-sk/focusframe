import SwiftUI

struct ManualZoomTool: View {
    @ObservedObject var editorVM: EditorVM
    @State private var centerX: Double = 0.5
    @State private var centerY: Double = 0.5
    @State private var width: Double = 0.25
    @State private var height: Double = 0.25
    @State private var duration: Double = 1.5

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Zoom")
                    .font(.headline)
                Spacer()
                Button {
                    editorVM.regenerateAutomaticZooms(replacingExisting: true)
                } label: {
                    Label("Auto Detect", systemImage: "cursorarrow.click.2")
                }
                .help("Regenerate click-driven zooms from recorded cursor clicks")

                Button("Add At Playhead") {
                    addZoomAtPlayhead()
                }
                .buttonStyle(.borderedProminent)
            }

            if let segment = selectedSegment {
                selectedZoomControls(segment)
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("New Manual Zoom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                DeferredDoubleSliderRow(
                    title: "Center X",
                    value: $centerX,
                    range: 0...1,
                    labelWidth: 64,
                    formatter: { String(format: "%.2f", $0) }
                )
                DeferredDoubleSliderRow(
                    title: "Center Y",
                    value: $centerY,
                    range: 0...1,
                    labelWidth: 64,
                    formatter: { String(format: "%.2f", $0) }
                )
                DeferredDoubleSliderRow(
                    title: "Width",
                    value: $width,
                    range: 0.1...1.0,
                    labelWidth: 64,
                    formatter: { String(format: "%.2f", $0) }
                )
                DeferredDoubleSliderRow(
                    title: "Height",
                    value: $height,
                    range: 0.1...1.0,
                    labelWidth: 64,
                    formatter: { String(format: "%.2f", $0) }
                )
                DeferredDoubleSliderRow(
                    title: "Duration",
                    value: $duration,
                    range: 0.5...5.0,
                    step: 0.25,
                    labelWidth: 64,
                    formatter: { String(format: "%.2fs", $0) }
                )
            }

            Text("Click a zoom block in the timeline to edit its timing and focus here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    @ViewBuilder
    private func selectedZoomControls(_ segment: ZoomSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(segment.source == .automatic ? "Selected Auto Zoom" : "Selected Manual Zoom", systemImage: "plus.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    editorVM.removeZoomSegment(segment.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete selected zoom")
            }

            DeferredDoubleSliderRow(
                title: "Start",
                value: Binding(
                    get: { segment.startTime },
                    set: { editorVM.updateZoomSegmentTiming(segment.id, startTime: $0, endTime: segment.endTime) }
                ),
                range: 0...max(editorVM.duration, 0.001),
                labelWidth: 56,
                formatter: timeLabel
            )

            DeferredDoubleSliderRow(
                title: "End",
                value: Binding(
                    get: { segment.endTime },
                    set: { editorVM.updateZoomSegmentTiming(segment.id, startTime: segment.startTime, endTime: $0) }
                ),
                range: 0...max(editorVM.duration, 0.001),
                labelWidth: 56,
                formatter: timeLabel
            )

            DeferredDoubleSliderRow(
                title: "Center X",
                value: Binding(
                    get: { normalizedCenterX(segment) },
                    set: { updateZoomRect(segment, centerX: $0) }
                ),
                range: 0...1,
                labelWidth: 56,
                valueWidth: 42,
                formatter: { String(format: "%.2f", $0) }
            )

            DeferredDoubleSliderRow(
                title: "Center Y",
                value: Binding(
                    get: { normalizedCenterY(segment) },
                    set: { updateZoomRect(segment, centerY: $0) }
                ),
                range: 0...1,
                labelWidth: 56,
                valueWidth: 42,
                formatter: { String(format: "%.2f", $0) }
            )

            DeferredDoubleSliderRow(
                title: "Width",
                value: Binding(
                    get: { normalizedWidth(segment) },
                    set: { updateZoomRect(segment, width: $0) }
                ),
                range: 0.1...1,
                labelWidth: 56,
                valueWidth: 42,
                formatter: { String(format: "%.2f", $0) }
            )

            DeferredDoubleSliderRow(
                title: "Height",
                value: Binding(
                    get: { normalizedHeight(segment) },
                    set: { updateZoomRect(segment, height: $0) }
                ),
                range: 0.1...1,
                labelWidth: 56,
                valueWidth: 42,
                formatter: { String(format: "%.2f", $0) }
            )
        }
    }

    private var selectedSegment: ZoomSegment? {
        guard let id = editorVM.selectedZoomSegmentID else { return nil }
        return editorVM.zoomSegments.first { $0.id == id }
    }

    private func normalizedCenterX(_ segment: ZoomSegment) -> Double {
        let source = safeSourceRect
        return max(0, min(1, Double((segment.zoomRect.midX - source.minX) / max(source.width, 1))))
    }

    private func normalizedCenterY(_ segment: ZoomSegment) -> Double {
        let source = safeSourceRect
        return max(0, min(1, Double((segment.zoomRect.midY - source.minY) / max(source.height, 1))))
    }

    private func normalizedWidth(_ segment: ZoomSegment) -> Double {
        let source = safeSourceRect
        return max(0.1, min(1, Double(segment.zoomRect.width / max(source.width, 1))))
    }

    private func normalizedHeight(_ segment: ZoomSegment) -> Double {
        let source = safeSourceRect
        return max(0.1, min(1, Double(segment.zoomRect.height / max(source.height, 1))))
    }

    private func updateZoomRect(
        _ segment: ZoomSegment,
        centerX: Double? = nil,
        centerY: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        let source = safeSourceRect
        let rectWidth = min(source.width, max(50, source.width * CGFloat(width ?? normalizedWidth(segment))))
        let rectHeight = min(source.height, max(50, source.height * CGFloat(height ?? normalizedHeight(segment))))
        let cx = source.minX + source.width * CGFloat(centerX ?? normalizedCenterX(segment))
        let cy = source.minY + source.height * CGFloat(centerY ?? normalizedCenterY(segment))
        var rect = CGRect(
            x: cx - rectWidth / 2,
            y: cy - rectHeight / 2,
            width: rectWidth,
            height: rectHeight
        )
        rect.origin.x = max(source.minX, min(source.maxX - rect.width, rect.origin.x))
        rect.origin.y = max(source.minY, min(source.maxY - rect.height, rect.origin.y))
        editorVM.updateZoomSegment(segment.id, zoomRect: rect)
    }

    private func addZoomAtPlayhead() {
        let source = safeSourceRect
        let rectW = max(50, source.width * width)
        let rectH = max(50, source.height * height)
        let cx = source.origin.x + source.width * centerX
        let cy = source.origin.y + source.height * centerY
        let rect = CGRect(
            x: cx - rectW / 2,
            y: cy - rectH / 2,
            width: rectW,
            height: rectH
        )

        editorVM.addManualZoomSegment(at: editorVM.playheadTime, duration: duration, rect: rect)
    }

    private var safeSourceRect: CGRect {
        let rect = editorVM.project.sourceRect
        guard rect.width > 0, rect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        return rect
    }

    private func timeLabel(_ time: Double) -> String {
        TimecodeFormatter.positional(time)
    }
}
