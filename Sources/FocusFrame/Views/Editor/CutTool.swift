import SwiftUI

struct CutTool: View {
    @ObservedObject var editorVM: EditorVM
    @State private var selectionStart: Double = 0
    @State private var selectionEnd: Double = 0
    @State private var isSelecting = false
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Cut Tool")
                    .font(.headline)
                
                Spacer()
                
                Button("Reset") {
                    resetSelection()
                }
                .disabled(!isSelecting && selectionStart == 0 && selectionEnd == 0)
                
                Button("Cut Selection") {
                    cutSelection()
                }
                .disabled(!hasValidSelection)
                .buttonStyle(.borderedProminent)
            }
            
            GeometryReader { geometry in
                let safeDuration = max(editorVM.duration, 0.001)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                    
                    // Cut regions overlay
                    ForEach(editorVM.editActions.filter { $0.type == .cut }) { cutAction in
                        CutRegionOverlay(
                            action: cutAction,
                            duration: safeDuration,
                            totalWidth: geometry.size.width
                        )
                    }
                    
                    // Selection rectangle
                    if hasValidSelection {
                        let startX = min(selectionStart, selectionEnd)
                        let endX = max(selectionStart, selectionEnd)
                        
                        Rectangle()
                            .fill(Color.red.opacity(0.3))
                            .frame(width: (endX - startX) / safeDuration * geometry.size.width)
                            .position(
                                x: startX / safeDuration * geometry.size.width + (endX - startX) / safeDuration * geometry.size.width / 2,
                                y: geometry.size.height / 2
                            )
                    }
                    
                    // Current time indicator
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .position(
                            x: (editorVM.playheadTime / safeDuration) * geometry.size.width,
                            y: geometry.size.height / 2
                        )
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleDrag(value, width: geometry.size.width)
                        }
                        .onEnded { _ in
                            isSelecting = false
                        }
                )
            }
            .frame(height: 60)
            
            // Selection info
            if hasValidSelection {
                HStack {
                    let duration = abs(selectionEnd - selectionStart)
                    Text("Selection: \(formatTime(duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("This region will be removed")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
            }

            let cuts = editorVM.editActions.filter { $0.type == .cut }
            if !cuts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cuts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(cuts) { action in
                        HStack {
                            Image(systemName: "scissors")
                                .foregroundColor(.red)
                            Text("\(formatTime(action.startTime)) - \(formatTime(action.endTime))")
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Button(role: .destructive) {
                                editorVM.removeCutAction(action.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete cut")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
    }
    
    private var hasValidSelection: Bool {
        abs(selectionEnd - selectionStart) > 0.5
    }
    
    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        let safeDuration = max(editorVM.duration, 0.001)
        let time = Double(value.location.x / max(width, 1)) * safeDuration
        let clampedTime = max(0, min(safeDuration, time))
        
        if !isSelecting {
            isSelecting = true
            selectionStart = clampedTime
            selectionEnd = clampedTime
        } else {
            selectionEnd = clampedTime
        }
        editorVM.selectedRangeStart = selectionStart
        editorVM.selectedRangeEnd = selectionEnd
    }
    
    private func cutSelection() {
        let normalizedStart = min(selectionStart, selectionEnd)
        let normalizedEnd = max(selectionStart, selectionEnd)
        
        editorVM.cutRegion(startTime: normalizedStart, endTime: normalizedEnd)
        resetSelection()
    }
    
    private func resetSelection() {
        selectionStart = 0
        selectionEnd = 0
        isSelecting = false
        editorVM.selectedRangeStart = nil
        editorVM.selectedRangeEnd = nil
    }
    
    private func formatTime(_ seconds: Double) -> String {
        TimecodeFormatter.positional(seconds)
    }
}

struct CutRegionOverlay: View {
    let action: EditAction
    let duration: Double
    let totalWidth: CGFloat
    
    var body: some View {
        let safeDuration = max(duration, 0.001)
        let safeStart = action.startTime.isFinite ? max(0, min(safeDuration, action.startTime)) : 0
        let safeActionDuration = action.duration.isFinite ? max(0, min(safeDuration - safeStart, action.duration)) : 0
        let startX = (safeStart / safeDuration) * totalWidth
        let width = (safeActionDuration / safeDuration) * totalWidth
        
        return Rectangle()
            .fill(Color.red.opacity(0.2))
            .frame(width: width)
            .position(x: startX + width / 2, y: 30)
            .overlay(
                VStack {
                    Image(systemName: "scissors")
                        .font(.caption2)
                    Text("Cut")
                        .font(.caption2)
                }
                    .foregroundColor(.red)
            )
    }
}
