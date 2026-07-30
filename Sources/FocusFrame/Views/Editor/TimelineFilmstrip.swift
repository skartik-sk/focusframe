import SwiftUI
import AVFoundation
import AppKit

/// A horizontally tiled strip of real video frames — the Screen Studio signature lane.
///
/// Thumbnails are sampled once per clip of timeline (count derived from duration, not
/// viewport width) on a background task, cached for the view's lifetime, and re-sampled
/// only when the source URL or duration changes. Mirrors `AudioWaveformView`'s async +
/// cancellation pattern.
struct FilmstripView: View {
    let videoURL: URL?
    let duration: Double

    @State private var thumbnails: [CGImage] = []

    private var thumbCount: Int {
        guard duration.isFinite, duration > 0 else { return 8 }
        let raw = Int((duration / 1.5).rounded(.up))
        return min(48, max(8, raw))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if thumbnails.isEmpty {
                    FilmstripSkeletonView()
                } else {
                    let perThumb = geo.size.width / CGFloat(thumbnails.count)
                    HStack(spacing: 0) {
                        ForEach(thumbnails.indices, id: \.self) { index in
                            frameView(image: thumbnails[index], width: perThumb, height: geo.size.height)
                        }
                    }
                    // Subtle scrim so floating clips stay legible.
                    Color.black.opacity(0.12).allowsHitTesting(false)
                }
            }
        }
        .task(id: requestID) {
            await load()
        }
    }

    @ViewBuilder
    private func frameView(image: CGImage, width: CGFloat, height: CGFloat) -> some View {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        Image(nsImage: nsImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 1)
            }
    }

    private var requestID: String {
        "\(videoURL?.path ?? "none")#\(String(format: "%.2f", duration))#\(thumbCount)"
    }

    @MainActor
    private func load() async {
        guard let url = videoURL, FileManager.default.fileExists(atPath: url.path) else {
            thumbnails = []
            return
        }
        thumbnails = []
        let count = thumbCount

        let generated: [CGImage]
        do {
            generated = try await Task.detached(priority: .utility) {
                try await Self.generate(url: url, count: count)
            }.value
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        thumbnails = generated
    }

    private static func generate(url: URL, count: Int) async throws -> [CGImage] {
        let asset = AVAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0 else { return [] }

        // Synchronous decode (mirrors AudioWaveformView's AVAssetReader pattern) so the
        // non-Sendable generator is never sent across an `await` boundary.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 120)

        var images: [CGImage] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            let fraction = (Double(index) + 0.5) / Double(count)
            let seconds = min(total, max(0, total * fraction))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            var actualTime = CMTime.zero
            let image = try generator.copyCGImage(at: time, actualTime: &actualTime)
            images.append(image)
        }
        return images
    }
}

private struct FilmstripSkeletonView: View {
    @State private var phase: Double = 0

    var body: some View {
        SwiftUI.TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let frameCount = max(6, Int(size.width / 90))
                let frameWidth = size.width / CGFloat(frameCount)
                let baseColor = Color.gray.opacity(0.22)
                for index in 0..<frameCount {
                    let x = CGFloat(index) * frameWidth
                    let wave = 0.18 + 0.12 * sin(Double(index) * 0.6 + t * 1.4)
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: frameWidth, height: size.height)),
                        with: .color(baseColor.opacity(0.5 + wave))
                    )
                }
            }
        }
    }
}
