import SwiftUI

struct SpeedTool: View {
    @ObservedObject var editorVM: EditorVM
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var speedMultiplier: Double = 1.0

    var body: some View {
        VStack(spacing: 12) {
            header
            if let selectedSpeedAction {
                selectedSpeedControls(selectedSpeedAction)
                Divider()
            }
            rangeControls
            speedControls

            if !editorVM.editActions.filter({ $0.type == .speedChange }).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speed Regions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(editorVM.editActions.filter { $0.type == .speedChange }) { action in
                        HStack {
                            Text("\(timeLabel(action.startTime)) - \(timeLabel(action.endTime))")
                            Spacer()
                            Text(String(format: "%.2fx", action.value ?? 1.0))
                                .foregroundColor(.blue)
                            Button(role: .destructive) {
                                editorVM.removeEditAction(action.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editorVM.selectEditAction(action.id)
                            editorVM.seek(to: action.startTime)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .onAppear {
            syncRangeFromSelectionOrPlayhead()
            speedMultiplier = 1.0
        }
        .onChange(of: editorVM.selectedRangeStart) { _ in
            syncRangeFromSelectionOrPlayhead()
        }
        .onChange(of: editorVM.selectedRangeEnd) { _ in
            syncRangeFromSelectionOrPlayhead()
        }
    }

    private var header: some View {
        HStack {
            Text("Speed Tool")
                .font(.headline)
            Spacer()
            Button("Use Playhead", action: usePlayheadRange)
            Button("Whole Clip", action: useWholeClip)
            Button("Reset", action: reset)
            Button("Apply") {
                applySpeed()
            }
            .buttonStyle(.borderedProminent)
            .disabled(abs(endTime - startTime) < 0.25 || abs(speedMultiplier - 1.0) < 0.001)
        }
    }

    @ViewBuilder
    private func selectedSpeedControls(_ action: EditAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Selected Speed Segment", systemImage: "speedometer")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            DeferredDoubleSliderRow(
                title: "Start",
                value: Binding(
                    get: { action.startTime },
                    set: { editorVM.updateEditActionTiming(action.id, startTime: $0, endTime: action.endTime) }
                ),
                range: 0...editorVM.duration,
                labelWidth: 48,
                formatter: timeLabel
            )

            DeferredDoubleSliderRow(
                title: "End",
                value: Binding(
                    get: { action.endTime },
                    set: { editorVM.updateEditActionTiming(action.id, startTime: action.startTime, endTime: $0) }
                ),
                range: 0...editorVM.duration,
                labelWidth: 48,
                formatter: timeLabel
            )

            HStack(spacing: 8) {
                speedSegmentPresetButton(action, value: 0.5, label: "0.5x")
                speedSegmentPresetButton(action, value: 1.0, label: "1x")
                speedSegmentPresetButton(action, value: 1.5, label: "1.5x")
                speedSegmentPresetButton(action, value: 2.0, label: "2x")
                Spacer()
                Button(role: .destructive) {
                    editorVM.removeEditAction(action.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            DeferredDoubleSliderRow(
                title: "Speed",
                value: Binding(
                    get: { action.value ?? 1.0 },
                    set: { editorVM.updateSpeedActionMultiplier(action.id, multiplier: $0) }
                ),
                range: 0.5...4.0,
                step: 0.25,
                labelWidth: 48,
                formatter: { String(format: "%.2fx", $0) }
            )
        }
    }

    @ViewBuilder
    private func speedSegmentPresetButton(_ action: EditAction, value: Double, label: String) -> some View {
        if abs((action.value ?? 1.0) - value) < 0.001 {
            Button(label) {
                editorVM.updateSpeedActionMultiplier(action.id, multiplier: value)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(label) {
                editorVM.updateSpeedActionMultiplier(action.id, multiplier: value)
            }
            .buttonStyle(.bordered)
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Range")
                .font(.caption)
                .foregroundColor(.secondary)
            DeferredDoubleSliderRow(
                title: "Start",
                value: $startTime,
                range: 0...editorVM.duration,
                labelWidth: 48,
                formatter: timeLabel
            )
            DeferredDoubleSliderRow(
                title: "End",
                value: $endTime,
                range: 0...editorVM.duration,
                labelWidth: 48,
                formatter: timeLabel
            )
        }
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed: \(String(format: "%.2fx", speedMultiplier))")
                .font(.subheadline)
            HStack(spacing: 8) {
                speedPresetButton(0.5, label: "0.5x")
                speedPresetButton(1.0, label: "1x")
                speedPresetButton(1.5, label: "1.5x")
                speedPresetButton(2.0, label: "2x")
            }
            DeferredDoubleSliderRow(
                title: "Value",
                value: $speedMultiplier,
                range: 0.5...4.0,
                step: 0.25,
                labelWidth: 48,
                formatter: { String(format: "%.2fx", $0) }
            )
            HStack {
                Text("0.5x")
                Spacer()
                Text("1x")
                Spacer()
                Text("4x")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func speedPresetButton(_ value: Double, label: String) -> some View {
        if abs(speedMultiplier - value) < 0.001 {
            Button(label) {
                speedMultiplier = value
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(label) {
                speedMultiplier = value
            }
            .buttonStyle(.bordered)
        }
    }

    private func reset() {
        speedMultiplier = 1.0
        useWholeClip()
    }

    private func applySpeed() {
        let s = min(startTime, endTime)
        let e = max(startTime, endTime)
        editorVM.setSpeed(startTime: s, endTime: e, multiplier: speedMultiplier)
    }

    private func syncRangeFromSelectionOrPlayhead() {
        if let selectedStart = editorVM.selectedRangeStart,
           let selectedEnd = editorVM.selectedRangeEnd,
           abs(selectedEnd - selectedStart) >= 0.25 {
            startTime = min(selectedStart, selectedEnd)
            endTime = max(selectedStart, selectedEnd)
            return
        }

        useWholeClip()
    }

    private func useWholeClip() {
        startTime = 0
        endTime = editorVM.duration
    }

    private func usePlayheadRange() {
        startTime = max(0, editorVM.playheadTime - 1)
        endTime = min(editorVM.duration, editorVM.playheadTime + 1)
    }

    private func timeLabel(_ time: Double) -> String {
        TimecodeFormatter.positional(time)
    }

    private var selectedSpeedAction: EditAction? {
        guard case let .editAction(id)? = editorVM.selectedTimelineItem else { return nil }
        return editorVM.editActions.first { $0.id == id && $0.type == .speedChange }
    }
}
