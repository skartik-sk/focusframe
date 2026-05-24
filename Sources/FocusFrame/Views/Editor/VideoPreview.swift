import SwiftUI
import AppKit
import CoreImage

struct VideoPreview: NSViewRepresentable {
    let time: Double
    let revision: Int
    let onFrameRequest: @MainActor (Double) -> CVPixelBuffer?
    
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
        context.coordinator.updateFrame(at: time, revision: revision, in: nsView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    final class Coordinator {
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        private var lastRequestedTime = -Double.infinity
        private var lastRevision = -1
        private var lastRenderWallTime = Date.distantPast
        private let minimumRenderInterval: TimeInterval = 1.0 / 24.0
        var onFrameRequest: (@MainActor (Double) -> CVPixelBuffer?)?

        func updateFrame(at time: Double, revision: Int, in imageView: NSImageView) {
            let needsRender = abs(time - lastRequestedTime) > 0.001 || revision != lastRevision || imageView.image == nil
            guard needsRender else { return }

            let now = Date()
            let revisionChanged = revision != lastRevision
            if imageView.image != nil,
               !revisionChanged,
               now.timeIntervalSince(lastRenderWallTime) < minimumRenderInterval {
                return
            }

            lastRequestedTime = time
            lastRevision = revision
            lastRenderWallTime = now

            autoreleasepool {
                guard let frameBuffer = onFrameRequest?(time) else {
                    if imageView.image == nil {
                        imageView.image = nil
                    }
                    return
                }

                let width = CVPixelBufferGetWidth(frameBuffer)
                let height = CVPixelBufferGetHeight(frameBuffer)
                guard width > 0, height > 0 else {
                    if imageView.image == nil {
                        imageView.image = nil
                    }
                    return
                }

                let frame = CIImage(cvPixelBuffer: frameBuffer)
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                guard let cgImage = ciContext.createCGImage(frame, from: rect) else {
                    if imageView.image == nil {
                        imageView.image = nil
                    }
                    return
                }

                imageView.image = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: width, height: height)
                )
            }
        }
    }
}
