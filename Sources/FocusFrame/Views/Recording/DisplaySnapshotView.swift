import SwiftUI
import ScreenCaptureKit
import AppKit

struct DisplaySnapshotView: View {
    let display: SCDisplay
    let refreshID: UUID
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(1)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Preview unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .task(id: "\(display.displayID)-\(refreshID.uuidString)") {
            loadSnapshot()
        }
    }

    private func loadSnapshot() {
        guard let cgImage = CGDisplayCreateImage(display.displayID) else {
            image = nil
            return
        }

        image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
    }
}
