import SwiftUI
import AppKit
import CoreImage

/// Displays the composited preview frame. The caller supplies a lazy `CIImage` graph
/// (`onFrameRequest`); this view rasterizes it (`createCGImage`) on a background queue so
/// the main thread — the playback timer and the rest of the UI — is never blocked by a
/// Core Image render pass. If a render is still in flight when the next frame is
/// requested, the request is coalesced to the latest time, so playback stays smooth and
/// drops frames rather than stuttering when rendering can't keep up.
struct VideoPreview: NSViewRepresentable {
    let time: Double
    let revision: Int
    let onFrameRequest: @MainActor (Double) -> CIImage?

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageAlignment = .alignCenter
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        context.coordinator.onFrameRequest = onFrameRequest
        context.coordinator.requestFrame(at: time, revision: revision, in: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        private let renderQueue = DispatchQueue(label: "focusframe.preview-render", qos: .userInitiated)
        private var lastRequestedTime = -Double.infinity
        private var lastRevision = -1
        private var isRendering = false
        private var pendingTime: Double?
        private var pendingRevision: Int = 0
        var onFrameRequest: (@MainActor (Double) -> CIImage?)?

        func requestFrame(at time: Double, revision: Int, in imageView: NSImageView) {
            let needsRender = abs(time - lastRequestedTime) > 0.001 || revision != lastRevision || imageView.image == nil
            guard needsRender else { return }

            // Coalesce: remember the latest requested time while a render is in flight.
            if isRendering {
                pendingTime = time
                pendingRevision = revision
                return
            }

            render(at: time, revision: revision, in: imageView)
        }

        private func render(at time: Double, revision: Int, in imageView: NSImageView) {
            lastRequestedTime = time
            lastRevision = revision
            isRendering = true

            // Build the lazy CIImage graph on the main actor (it reads editor state), then
            // rasterize it off-main.
            guard let ciImage = onFrameRequest?(time) else {
                isRendering = false
                if imageView.image == nil {
                    imageView.image = nil
                }
                return
            }

            let context = ciContext
            let extent = ciImage.extent
            renderQueue.async { [weak imageView] in
                let cgImage = extent.width > 0 && extent.height > 0
                    ? context.createCGImage(ciImage, from: extent)
                    : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let cgImage, let imageView {
                        imageView.image = NSImage(
                            cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height)
                        )
                    }
                    self.isRendering = false

                    // Drain the coalesced request for the latest time, if any.
                    if let nextTime = self.pendingTime {
                        let nextRevision = self.pendingRevision
                        self.pendingTime = nil
                        guard let imageView else { return }
                        self.render(at: nextTime, revision: nextRevision, in: imageView)
                    }
                }
            }
        }
    }
}
