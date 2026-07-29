import SwiftUI

/// Shared drag feedback for a single lane. While a clip is being dragged or resized,
/// it publishes the time its controlling edge snapped to (if any) so the lane can draw
/// a full-height snap guide line. Only one clip drags at a time, so one object per lane
/// is sufficient.
@MainActor
final class TimelineDragFeedback: ObservableObject {
    @Published var snapGuideTime: Double?
}

/// The visual + behavioural identity of a ranged timeline clip, independent of the
/// underlying model. Every track (zoom, title, overlay, effect, camera, cut, speed,
/// hide-cursor) maps its segments into a `TimelineClipView`, so rendering and the
/// drag/resize/snap engine are defined exactly once.
enum TimelineClipKind {
    case zoom(manual: Bool)
    case title
    case overlay
    case effect
    case camera
    case cut
    case speed
    case hideCursor

    var color: Color {
        switch self {
        case .zoom(let manual): return manual ? Color.green : Color.blue
        case .title: return Color.orange
        case .overlay: return Color.teal
        case .effect: return Color.indigo
        case .camera: return Color.purple
        case .cut: return Color.red
        case .speed: return Color.blue
        case .hideCursor: return Color.orange
        }
    }

    var systemImage: String {
        switch self {
        case .zoom: return "plus.magnifyingglass"
        case .title: return "text.rectangle"
        case .overlay: return "rectangle.on.rectangle"
        case .effect: return "slider.horizontal.3"
        case .camera: return "rectangle.split.2x1"
        case .cut: return "scissors"
        case .speed: return "speedometer"
        case .hideCursor: return "cursorarrow.slash"
        }
    }
}

/// One unified ranged clip. Replaces the per-track block views that previously each
/// re-implemented move/resize/delete gestures.
struct TimelineClipView: View {
    let kind: TimelineClipKind
    let label: String
    let startTime: Double
    let endTime: Double
    let isSelected: Bool

    /// Full timeline duration (seconds).
    let duration: Double
    /// Pixel width of the lane's time-mapped content.
    let totalWidth: CGFloat
    /// Pixel height of the lane (the clip is centred within it).
    let laneHeight: CGFloat
    /// Minimum clip duration in seconds enforced while resizing.
    let minimumDuration: Double

    let showsDeleteControls: Bool
    let extendsWithShift: Bool
    let snapCandidates: [Double]
    let snapThresholdSeconds: Double
    let snapEnabled: Bool

    let onSelect: () -> Void
    let onBeginEdit: () -> Void
    let onUpdate: (Double, Double) -> Void
    let onEndEdit: () -> Void
    let onRemove: () -> Void

    @ObservedObject var dragFeedback: TimelineDragFeedback

    @State private var dragStart: Double?
    @State private var dragEnd: Double?

    private var safeDuration: Double { max(duration, 0.001) }

    var body: some View {
        let startX = (startTime / safeDuration) * totalWidth
        let width = max(((endTime - startTime) / safeDuration) * totalWidth, minimumPixelWidth)
        let clipHeight = min(30, laneHeight - 8)

        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(kind.color.opacity(0.18))

            labelContent(width: width)

            HStack(spacing: 0) {
                ResizeHandle(color: kind.color)
                    .highPriorityGesture(resizeGesture(edge: .leading))
                Spacer(minLength: 0)
                ResizeHandle(color: kind.color)
                    .highPriorityGesture(resizeGesture(edge: .trailing))
            }
        }
        .frame(width: width, height: clipHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(kind.color.opacity(isSelected ? 0.95 : 0.4), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0.16), radius: isSelected ? 3.5 : 2, y: 1)
        .overlay(alignment: .topTrailing) {
            if showsDeleteControls {
                TimelineDeleteButton(action: onRemove)
                    .offset(x: 6, y: -6)
            }
        }
        .position(x: startX + width / 2, y: laneHeight / 2)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .highPriorityGesture(moveGesture)
    }

    @ViewBuilder
    private func labelContent(width: CGFloat) -> some View {
        if width >= 46 {
            Label(label, systemImage: kind.systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundColor(kind.color)
                .lineLimit(1)
                .labelStyle(.titleAndIcon)
        } else if width >= 22 {
            Image(systemName: kind.systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundColor(kind.color)
        }
    }

    private var minimumPixelWidth: CGFloat {
        switch kind {
        case .cut, .hideCursor: return 12
        case .zoom: return 14
        default: return 34
        }
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }

                if extendsWithShift {
                    if delta >= 0 {
                        let proposedEnd = min(safeDuration, dragEnd + delta)
                        let snapped = snapValue(proposedEnd)
                        publishSnap(snapped)
                        onUpdate(dragStart, snapped.time)
                    } else {
                        let proposedStart = max(0, dragStart + delta)
                        let snapped = snapValue(proposedStart)
                        publishSnap(snapped)
                        onUpdate(snapped.time, dragEnd)
                    }
                } else {
                    let length = max(minimumDuration, dragEnd - dragStart)
                    let rawStart = max(0, min(safeDuration - length, dragStart + delta))
                    let snapped = snapValue(rawStart)
                    publishSnap(snapped)
                    let newStart = max(0, min(safeDuration - length, snapped.time))
                    onUpdate(newStart, newStart + length)
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                dragFeedback.snapGuideTime = nil
                onEndEdit()
            }
    }

    private func resizeGesture(edge: ResizeEdge) -> some Gesture {
        DragGesture()
            .onChanged { value in
                initializeDragState()
                let delta = Double(value.translation.width / max(totalWidth, 1)) * safeDuration
                guard let dragStart, let dragEnd else { return }

                switch edge {
                case .leading:
                    let proposed = min(dragEnd - minimumDuration, dragStart + delta)
                    let snapped = snapValue(proposed)
                    publishSnap(snapped)
                    onUpdate(snapped.time, dragEnd)
                case .trailing:
                    let proposed = max(dragStart + minimumDuration, dragEnd + delta)
                    let snapped = snapValue(proposed)
                    publishSnap(snapped)
                    onUpdate(dragStart, snapped.time)
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragEnd = nil
                dragFeedback.snapGuideTime = nil
                onEndEdit()
            }
    }

    private func initializeDragState() {
        if dragStart == nil {
            onBeginEdit()
            dragStart = startTime
            dragEnd = endTime
        }
    }

    private func snapValue(_ value: Double) -> TimelineSnapResult {
        guard snapEnabled else { return TimelineSnapResult(time: value, snapped: false) }
        return TimelineSnapper.snap(value, candidates: snapCandidates, thresholdSeconds: snapThresholdSeconds)
    }

    private func publishSnap(_ result: TimelineSnapResult) {
        dragFeedback.snapGuideTime = result.snapped ? result.time : nil
    }
}

// MARK: - Shared primitives

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
                .frame(width: 14)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(0.85))
                .frame(width: 4, height: 12)
        }
        .frame(width: 14)
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
