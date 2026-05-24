import SwiftUI

struct ZoomTrackView: View {
    @ObservedObject var editorVM: EditorVM
    let currentTime: Double
    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    
    var body: some View {
        GeometryReader { geometry in
            let safeDuration = max(editorVM.duration, 0.001)
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .contentShape(Rectangle())
                    .gesture(addZoomGesture(width: geometry.size.width, duration: safeDuration))
                
                // Zoom segments
                ForEach(editorVM.zoomSegments) { segment in
                    EditableZoomSegmentBlock(
                        segment: segment,
                        isSelected: editorVM.selectedZoomSegmentID == segment.id,
                        duration: safeDuration,
                        totalWidth: geometry.size.width,
                        height: geometry.size.height,
                        showsDeleteControls: showsDeleteControls,
                        extendsWithShift: extendsWithShift,
                        onSelect: {
                            editorVM.selectZoomSegment(segment.id)
                        },
                        onBeginEdit: {
                            editorVM.beginInteractiveEdit()
                        },
                        onUpdate: { start, end in
                            editorVM.updateZoomSegmentTiming(segment.id, startTime: start, endTime: end)
                        },
                        onEndEdit: {
                            editorVM.endInteractiveEdit()
                        },
                        onRemove: {
                            editorVM.removeZoomSegment(segment.id)
                        }
                    )
                }
                
                // Current time indicator
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .position(x: (currentTime / safeDuration) * geometry.size.width, y: geometry.size.height / 2)
            }
        }
        .frame(height: 50)
    }

    private func addZoomGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard abs(value.translation.width) < 3, abs(value.translation.height) < 3 else { return }
                let clampedX = max(0, min(width, value.location.x))
                let time = Double(clampedX / max(width, 1)) * duration
                editorVM.addZoomSegment(at: time)
                editorVM.selectedTool = .zoom
            }
    }
}

struct EditableZoomSegmentBlock: View {
    let segment: ZoomSegment
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
        let startX = (segment.startTime / safeDuration) * totalWidth
        let width = max((segment.duration / safeDuration) * totalWidth, 14)
        let color: Color = segment.source == .automatic ? .blue : .green
        
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
                )
            HStack(spacing: 0) {
                ResizeHandle(color: color)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                if showsDeleteControls && width > 28 {
                    TimelineDeleteButton(action: onRemove)
                        .offset(y: -7)
                }
                ResizeHandle(color: color)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
            if width > 42 {
                Text(segment.zoomRect == .zero ? "Full" : "Zoom")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
        .frame(width: width, height: 30)
        .position(x: startX + width / 2, y: height / 2)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .highPriorityGesture(moveGesture)
        .contextMenu {
            Button("Remove Zoom", action: onRemove)
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
            dragStart = segment.startTime
            dragEnd = segment.endTime
        }
    }
}
