import SwiftUI

struct RecordingOverlay: View {
    @ObservedObject var recordingVM: RecordingVM

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timeString(from: recordingVM.recordingDuration))
                    .font(.monospacedDigit(.title3)())
                    .foregroundColor(.red)
                    .frame(width: 80, alignment: .leading)

                Button(action: {
                    recordingVM.togglePause()
                }) {
                    Image(systemName: recordingVM.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .disabled(recordingVM.isStopping || !recordingVM.isRecording)
                .accessibilityLabel(recordingVM.isPaused ? "Resume recording" : "Pause recording")

                Button(action: {
                    Task {
                        do {
                            try await recordingVM.stopRecording()
                        } catch {
                            recordingVM.lastErrorMessage = error.localizedDescription
                        }
                    }
                }) {
                    if recordingVM.isStopping {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "stop.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.red)
                    }
                }
                .buttonStyle(.plain)
                .disabled(recordingVM.isStopping)
                .accessibilityLabel("Stop recording")
            }

            if let message = recordingVM.lastErrorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            if !recordingVM.speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Text(recordingVM.speakerNotes)
                    .font(.callout)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(12)
        .background(Material.regular)
        .cornerRadius(20)
        .shadow(radius: 10)
    }

    private func timeString(from interval: Double) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
