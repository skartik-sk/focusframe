import SwiftUI

struct SegmentEffectsTool: View {
    @ObservedObject var editorVM: EditorVM
    @State private var selectedPreset: EffectSegmentPreset = .quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Label("Segment Effects", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Picker("Preset", selection: $selectedPreset) {
                    ForEach(EffectSegmentPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 170)

                Button {
                    addSegment()
                } label: {
                    Label("Add Segment", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)

                Text(selectedPreset.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()
            }

            if let segment = selectedSegment {
                selectedSegmentControls(segment)
            } else {
                Text("Drag a range on the ruler, then add a segment. Segment overrides affect only that time range in preview and export.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func selectedSegmentControls(_ segment: EffectSegment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Name", text: Binding(
                    get: { segment.name },
                    set: { name in update(segment) { $0.name = name } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

                TextField("Start", value: Binding(
                    get: { segment.startTime },
                    set: { start in update(segment) { $0.startTime = start } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 74)

                TextField("End", value: Binding(
                    get: { segment.endTime },
                    set: { end in update(segment) { $0.endTime = end } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 74)

                Button(role: .destructive) {
                    editorVM.removeEffectSegment(segment.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Remove selected segment")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], alignment: .leading, spacing: 10) {
                overridePicker("Music", value: segment.music) { state in update(segment) { $0.music = state } }
                overridePicker("Click Sound", value: segment.clickSound) { state in update(segment) { $0.clickSound = state } }
                overridePicker("Key Sound", value: segment.keyboardSound) { state in update(segment) { $0.keyboardSound = state } }
                overridePicker("Keyboard Badges", value: segment.keyboardBadges) { state in update(segment) { $0.keyboardBadges = state } }
                overridePicker("Cursor", value: segment.cursor) { state in update(segment) { $0.cursor = state } }
                overridePicker("Subtitles", value: segment.subtitles) { state in update(segment) { $0.subtitles = state } }
                overridePicker("Visual Overlays", value: segment.overlays) { state in update(segment) { $0.overlays = state } }
                overridePicker("Webcam", value: segment.webcam) { state in update(segment) { $0.webcam = state } }
                overridePicker("Watermark", value: segment.watermark) { state in update(segment) { $0.watermark = state } }
            }

            HStack(spacing: 18) {
                volumeOverride(
                    "Screen",
                    value: segment.sourceAudioVolume,
                    fallback: editorVM.project.style.sourceAudioVolume
                ) { value in update(segment) { $0.sourceAudioVolume = value } }

                volumeOverride(
                    "Mic",
                    value: segment.micAudioVolume,
                    fallback: editorVM.project.style.micAudioVolume
                ) { value in update(segment) { $0.micAudioVolume = value } }

                volumeOverride(
                    "Music",
                    value: segment.musicVolume,
                    fallback: editorVM.project.style.backgroundMusicVolume
                ) { value in update(segment) { $0.musicVolume = value } }
            }
        }
    }

    private func overridePicker(
        _ title: String,
        value: EffectOverride,
        onChange: @escaping @MainActor @Sendable (EffectOverride) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 94, alignment: .leading)
            Picker(title, selection: Binding(
                get: { value },
                set: { state in
                    Task { @MainActor in
                        onChange(state)
                    }
                }
            )) {
                ForEach(EffectOverride.allCases) { state in
                    Text(state.label).tag(state)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func volumeOverride(
        _ title: String,
        value: Float?,
        fallback: Float,
        onChange: @escaping (Float?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("\(title) volume", isOn: Binding(
                get: { value != nil },
                set: { enabled in onChange(enabled ? fallback : nil) }
            ))
            .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                DeferredDoubleSliderRow(
                    title: "",
                    value: Binding(
                        get: { Double(value ?? fallback) },
                        set: { onChange(Float($0)) }
                    ),
                    range: 0...1,
                    labelWidth: 0,
                    valueWidth: 42,
                    formatter: { String(format: "%.0f%%", $0 * 100) }
                )
                .disabled(value == nil)
            }
        }
        .frame(maxWidth: 190)
    }

    private var selectedSegment: EffectSegment? {
        guard case let .effectSegment(id)? = editorVM.selectedTimelineItem else { return nil }
        return editorVM.effectSegments.first { $0.id == id }
    }

    private var normalizedRange: (Double, Double)? {
        guard let start = editorVM.selectedRangeStart,
              let end = editorVM.selectedRangeEnd else {
            return nil
        }
        let lower = max(0, min(start, end))
        let upper = min(editorVM.duration, max(start, end))
        guard upper - lower >= 0.05 else { return nil }
        return (lower, upper)
    }

    private func addSegment() {
        let range = normalizedRange ?? (
            max(0, editorVM.playheadTime),
            min(editorVM.duration, editorVM.playheadTime + 5)
        )
        _ = editorVM.addEffectSegment(
            startTime: range.0,
            endTime: range.1,
            preset: selectedPreset
        )
    }

    private func update(_ segment: EffectSegment, mutate: (inout EffectSegment) -> Void) {
        var updated = segment
        mutate(&updated)
        editorVM.updateEffectSegment(updated)
    }
}
