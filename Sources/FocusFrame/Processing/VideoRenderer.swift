import Foundation
import Metal
import CoreImage
import AVFoundation
import CoreGraphics
import AppKit

class VideoRenderer {
    private static let maxBackgroundImageBytes: UInt64 = 80 * 1024 * 1024
    private let ciContext: CIContext
    private let motionBlurFilter = MotionBlurFilter()
    private let highResCursorImage: CIImage
    private let lowResCursorImage: CIImage
    private let cursorPixelSize: CGSize
    private let cursorHotSpot: CGPoint
    private let highResHandCursorImage: CIImage
    private let lowResHandCursorImage: CIImage
    private let handCursorPixelSize: CGSize
    private let handCursorHotSpot: CGPoint
    private var cachedBackgroundKey: BackgroundCacheKey?
    private var cachedBackgroundImage: CIImage?

    private struct BackgroundCacheKey: Equatable {
        let width: Int
        let height: Int
        let type: BackgroundType
        let color: CodableColor
        let gradientColors: [CodableColor]
        let gradientAngle: Double
        let imagePath: String?
        let imageModifiedAt: Date?

        init(size: CGSize, config: StylePreset) {
            width = Int(max(1, size.width).rounded())
            height = Int(max(1, size.height).rounded())
            type = config.backgroundType
            color = config.backgroundColor.sanitized()
            gradientColors = Array(config.backgroundGradientColors.prefix(4)).map { $0.sanitized() }
            gradientAngle = config.backgroundGradientAngle.isFinite ? config.backgroundGradientAngle : 0
            let standardizedURL = config.backgroundImageURL?.standardizedFileURL
            imagePath = standardizedURL?.path
            if let path = standardizedURL?.path,
               let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
                imageModifiedAt = attributes[.modificationDate] as? Date
            } else {
                imageModifiedAt = nil
            }
        }
    }
    
    struct FrameInputs {
        var sourceFrame: CIImage
        var timestamp: Double
        var zoomTransform: CGAffineTransform
        var cursorPosition: CGPoint?
        var cursorVisible: Bool
        var cursorAlpha: Float
        var cursorScale: CGFloat
        var isClicking: Bool
        var clickAnimationProgress: Double?
        var webcamFrame: CIImage?
        var activeShortcuts: [KeyPressEvent]
        var subtitleText: String?
        var motionBlurVelocity: CGPoint = .zero
        var activeOverlays: [OverlayElement] = []
        var activeTitleCards: [TitleCardSegment] = []
        var zoomScale: CGFloat = 1
        var cameraLayoutMode: CameraLayoutMode = .defaultOverlay
    }
    
    init() {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        let arrow = VideoRenderer.makeCursorImages(from: .arrow)
        highResCursorImage = arrow.high
        lowResCursorImage = arrow.low
        cursorPixelSize = arrow.pixelSize
        cursorHotSpot = arrow.hotSpot

        let hand = VideoRenderer.makeCursorImages(from: .pointingHand)
        highResHandCursorImage = hand.high
        lowResHandCursorImage = hand.low
        handCursorPixelSize = hand.pixelSize
        handCursorHotSpot = hand.hotSpot
    }
    
    func renderFrame(
        inputs: FrameInputs,
        config: StylePreset,
        outputSize: CGSize
    ) -> CVPixelBuffer? {
        let result = renderFrameImage(
            inputs: inputs,
            config: config,
            outputSize: outputSize
        )

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(outputSize.width),
            Int(outputSize.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            return nil
        }

        render(result, to: pb, outputSize: outputSize)
        return pb
    }

    func renderFrame(
        inputs: FrameInputs,
        config: StylePreset,
        outputSize: CGSize,
        into pixelBuffer: CVPixelBuffer
    ) {
        let result = renderFrameImage(
            inputs: inputs,
            config: config,
            outputSize: outputSize
        )
        render(result, to: pixelBuffer, outputSize: outputSize)
    }

    func renderFrameImage(
        inputs: FrameInputs,
        config: StylePreset,
        outputSize: CGSize
    ) -> CIImage {
        let viewportRect = CGRect(origin: .zero, size: outputSize)
        let canvasScale = canvasScale(for: outputSize)
        var composite = inputs.sourceFrame
            .transformed(by: inputs.zoomTransform)
            .cropped(to: viewportRect)

        if config.motionBlurEnabled {
            composite = motionBlurFilter.apply(
                to: composite,
                velocity: inputs.motionBlurVelocity,
                config: MotionBlurFilter.Config(
                    radius: max(0, config.motionBlurStrength),
                    angle: 0,
                    threshold: 0.5
                )
            )
        }
        
        let background = renderBackground(size: outputSize, config: config)

        if let webcam = inputs.webcamFrame, inputs.cameraLayoutMode == .cameraOnly {
            var result = renderCameraOnlyLayout(
                webcam,
                background: background,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = renderPostLayoutOverlays(
                result,
                inputs: inputs,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            return result.cropped(to: viewportRect)
        }

        if let webcam = inputs.webcamFrame, inputs.cameraLayoutMode == .sideBySide {
            var result = renderSideBySideLayout(
                screen: composite,
                webcam: webcam,
                background: background,
                inputs: inputs,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = renderPostLayoutOverlays(
                result,
                inputs: inputs,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            return result.cropped(to: viewportRect)
        }
        
        let framed = frameInContext(
            composite,
            background: background,
            config: config,
            outputSize: outputSize,
            canvasScale: canvasScale
        )
        
        var result = framed
        let recordingLayout = frameLayout(
            for: viewportRect,
            config: config,
            outputSize: outputSize,
            canvasScale: canvasScale
        )
        if inputs.cursorVisible, let pos = inputs.cursorPosition {
            let transformedPosition = pos
                .applying(inputs.zoomTransform)
                .applying(recordingLayout.transform)
            let cursor = renderCursor(
                at: transformedPosition,
                scale: inputs.cursorScale,
                alpha: inputs.cursorAlpha,
                isClicking: inputs.isClicking,
                clickAnimationProgress: inputs.clickAnimationProgress,
                config: config,
                canvasScale: canvasScale
            )
            result = cursor.composited(over: result)
        }

        if let webcam = inputs.webcamFrame, inputs.cameraLayoutMode != .screenOnly {
            let positioned = renderWebcam(
                webcam,
                config: config,
                cursorPos: inputs.cursorPosition,
                recordingRect: recordingLayout.rect,
                canvasScale: canvasScale,
                zoomScale: inputs.zoomScale
            )
            result = positioned.composited(over: result)
        }

        for shortcut in inputs.activeShortcuts {
            let badge = renderShortcutBadge(
                shortcut,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = badge.composited(over: result)
        }

        for overlay in inputs.activeOverlays {
            result = renderOverlay(
                overlay,
                over: result,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
        }

        if let subtitle = inputs.subtitleText, !subtitle.isEmpty {
            let subtitleImage = renderSubtitle(
                subtitle,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = subtitleImage.composited(over: result)
        }

        for titleCard in inputs.activeTitleCards {
            result = renderTitleCard(
                titleCard,
                outputSize: outputSize,
                canvasScale: canvasScale
            ).composited(over: result)
        }

        result = renderWatermarkIfNeeded(
            over: result,
            config: config,
            outputSize: outputSize,
            canvasScale: canvasScale
        )

        return result.cropped(to: viewportRect)
    }

    private func renderPostLayoutOverlays(
        _ image: CIImage,
        inputs: FrameInputs,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        var result = image
        for shortcut in inputs.activeShortcuts {
            let badge = renderShortcutBadge(
                shortcut,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = badge.composited(over: result)
        }

        for overlay in inputs.activeOverlays {
            result = renderOverlay(
                overlay,
                over: result,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
        }

        if let subtitle = inputs.subtitleText, !subtitle.isEmpty {
            let subtitleImage = renderSubtitle(
                subtitle,
                config: config,
                outputSize: outputSize,
                canvasScale: canvasScale
            )
            result = subtitleImage.composited(over: result)
        }

        for titleCard in inputs.activeTitleCards {
            result = renderTitleCard(
                titleCard,
                outputSize: outputSize,
                canvasScale: canvasScale
            ).composited(over: result)
        }

        return renderWatermarkIfNeeded(
            over: result,
            config: config,
            outputSize: outputSize,
            canvasScale: canvasScale
        )
    }

    private func render(_ image: CIImage, to pixelBuffer: CVPixelBuffer, outputSize: CGSize) {
        ciContext.render(
            image,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private func renderOverlay(
        _ overlay: OverlayElement,
        over image: CIImage,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let rect = denormalizedOverlayRect(overlay.rect, outputSize: outputSize)
        guard rect.width > 2, rect.height > 2 else { return image }

        switch overlay.type {
        case .blur:
            let radius = CGFloat(max(4, min(28, overlay.intensity * 28))) * canvasScale
            let blurred = image
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: rect)
            let overlayImage = drawOverlayChrome(
                rect: rect,
                outputSize: outputSize,
                fill: CGColor(red: 1, green: 1, blue: 1, alpha: 0.03),
                stroke: CGColor(red: 1, green: 1, blue: 1, alpha: 0.32),
                lineWidth: max(1, 2 * canvasScale),
                text: nil,
                canvasScale: canvasScale
            )
            return overlayImage.composited(over: blurred.composited(over: image))
        case .highlight:
            let alpha = CGFloat(max(0.08, min(0.35, overlay.intensity * 0.35)))
            let overlayImage = drawOverlayChrome(
                rect: rect,
                outputSize: outputSize,
                fill: CGColor(red: 1.0, green: 0.78, blue: 0.16, alpha: alpha),
                stroke: CGColor(red: 1.0, green: 0.82, blue: 0.22, alpha: 0.86),
                lineWidth: max(2, 3 * canvasScale),
                text: nil,
                canvasScale: canvasScale
            )
            return overlayImage.composited(over: image)
        case .spotlight:
            let dim = drawSpotlightOverlay(
                rect: rect,
                outputSize: outputSize,
                intensity: CGFloat(max(0.15, min(0.75, overlay.intensity))),
                canvasScale: canvasScale
            )
            return dim.composited(over: image)
        case .text:
            let overlayImage = drawOverlayChrome(
                rect: rect,
                outputSize: outputSize,
                fill: CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.78),
                stroke: CGColor(red: 1, green: 1, blue: 1, alpha: 0.12),
                lineWidth: max(1, canvasScale),
                text: overlay.text.isEmpty ? "Callout" : overlay.text,
                canvasScale: canvasScale
            )
            return overlayImage.composited(over: image)
        }
    }

    private func denormalizedOverlayRect(_ rect: CGRect, outputSize: CGSize) -> CGRect {
        let x = max(0, min(1, rect.origin.x)) * outputSize.width
        let y = max(0, min(1, rect.origin.y)) * outputSize.height
        let width = max(0.02, min(1, rect.width)) * outputSize.width
        let height = max(0.02, min(1, rect.height)) * outputSize.height
        return CGRect(
            x: min(x, max(0, outputSize.width - width)),
            y: min(y, max(0, outputSize.height - height)),
            width: min(width, outputSize.width),
            height: min(height, outputSize.height)
        )
    }

    private func drawSpotlightOverlay(
        rect: CGRect,
        outputSize: CGSize,
        intensity: CGFloat,
        canvasScale: CGFloat
    ) -> CIImage {
        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: outputSize))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: intensity))
        context.fill(CGRect(origin: .zero, size: outputSize))
        context.setBlendMode(.clear)
        context.fill(rect.insetBy(dx: -6 * canvasScale, dy: -6 * canvasScale))
        context.setBlendMode(.normal)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.75))
        context.setLineWidth(max(2, 3 * canvasScale))
        context.stroke(rect)

        guard let cgImage = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cgImage)
    }

    private func drawOverlayChrome(
        rect: CGRect,
        outputSize: CGSize,
        fill: CGColor,
        stroke: CGColor,
        lineWidth: CGFloat,
        text: String?,
        canvasScale: CGFloat
    ) -> CIImage {
        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: outputSize))
        let radius = min(14 * canvasScale, min(rect.width, rect.height) / 5)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(stroke)
        context.setLineWidth(lineWidth)
        context.strokePath()

        if let text {
            drawOverlayText(text, in: rect, context: context, canvasScale: canvasScale)
        }

        guard let cgImage = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cgImage)
    }

    private func drawOverlayText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        canvasScale: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let fontSize = max(13, min(28, 20 * canvasScale))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let padded = rect.insetBy(dx: 14 * canvasScale, dy: 10 * canvasScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(with: padded, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func renderTitleCard(
        _ card: TitleCardSegment,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: outputSize))
        let opacity = CGFloat(max(0.1, min(card.backgroundOpacity, 0.95)))
        let accent = card.accentColor.cgColor

        if card.style == .lowerThird || card.kind == .section {
            drawLowerThirdTitleCard(
                card,
                outputSize: outputSize,
                context: context,
                accent: accent,
                opacity: opacity,
                canvasScale: canvasScale
            )
        } else {
            drawFullScreenTitleCard(
                card,
                outputSize: outputSize,
                context: context,
                accent: accent,
                opacity: opacity,
                canvasScale: canvasScale
            )
        }

        guard let cgImage = context.makeImage() else {
            return CIImage.empty()
        }
        return CIImage(cgImage: cgImage)
    }

    private func drawFullScreenTitleCard(
        _ card: TitleCardSegment,
        outputSize: CGSize,
        context: CGContext,
        accent: CGColor,
        opacity: CGFloat,
        canvasScale: CGFloat
    ) {
        let fullRect = CGRect(origin: .zero, size: outputSize)
        switch card.style {
        case .clean:
            context.setFillColor(CGColor(red: 0.04, green: 0.045, blue: 0.055, alpha: opacity))
            context.fill(fullRect)
        case .gradient:
            context.setFillColor(CGColor(red: 0.02, green: 0.025, blue: 0.03, alpha: opacity))
            context.fill(fullRect)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    accent.copy(alpha: 0.62) ?? accent,
                    CGColor(red: 0.02, green: 0.02, blue: 0.024, alpha: 0.2)
                ] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: outputSize.height),
                    end: CGPoint(x: outputSize.width, y: 0),
                    options: []
                )
            }
        case .cinematic, .lowerThird:
            context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.024, alpha: opacity))
            context.fill(fullRect)
            context.setFillColor(accent.copy(alpha: 0.82) ?? accent)
            context.fill(CGRect(
                x: outputSize.width * 0.5 - 42 * canvasScale,
                y: outputSize.height * 0.5 - 72 * canvasScale,
                width: 84 * canvasScale,
                height: 4 * canvasScale
            ))
        }

        let titleRect = CGRect(
            x: outputSize.width * 0.16,
            y: outputSize.height * 0.50,
            width: outputSize.width * 0.68,
            height: outputSize.height * 0.22
        )
        let subtitleRect = CGRect(
            x: outputSize.width * 0.21,
            y: titleRect.minY - 58 * canvasScale,
            width: outputSize.width * 0.58,
            height: 52 * canvasScale
        )

        drawAttributedText(
            card.title,
            in: titleRect,
            context: context,
            fontSize: max(24, 54 * canvasScale),
            weight: .bold,
            color: NSColor.white,
            alignment: .center
        )

        let subtitle = card.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subtitle.isEmpty {
            drawAttributedText(
                subtitle,
                in: subtitleRect,
                context: context,
                fontSize: max(13, 22 * canvasScale),
                weight: .medium,
                color: NSColor.white.withAlphaComponent(0.82),
                alignment: .center
            )
        }
    }

    private func drawLowerThirdTitleCard(
        _ card: TitleCardSegment,
        outputSize: CGSize,
        context: CGContext,
        accent: CGColor,
        opacity: CGFloat,
        canvasScale: CGFloat
    ) {
        let cardRect = CGRect(
            x: outputSize.width * 0.07,
            y: outputSize.height * 0.10,
            width: outputSize.width * 0.56,
            height: max(86, 126 * canvasScale)
        )
        let radius = 18 * canvasScale
        let path = CGPath(
            roundedRect: cardRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.024, alpha: min(opacity, 0.78)))
        context.fillPath()

        context.setFillColor(accent.copy(alpha: 0.88) ?? accent)
        context.fill(CGRect(
            x: cardRect.minX,
            y: cardRect.minY,
            width: max(5, 6 * canvasScale),
            height: cardRect.height
        ))

        let textRect = cardRect.insetBy(dx: 24 * canvasScale, dy: 18 * canvasScale)
        drawAttributedText(
            card.title,
            in: CGRect(x: textRect.minX, y: textRect.midY, width: textRect.width, height: textRect.height * 0.45),
            context: context,
            fontSize: max(18, 30 * canvasScale),
            weight: .bold,
            color: NSColor.white,
            alignment: .left
        )

        let subtitle = card.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subtitle.isEmpty {
            drawAttributedText(
                subtitle,
                in: CGRect(x: textRect.minX, y: textRect.minY + 8 * canvasScale, width: textRect.width, height: textRect.height * 0.36),
                context: context,
                fontSize: max(12, 17 * canvasScale),
                weight: .medium,
                color: NSColor.white.withAlphaComponent(0.78),
                alignment: .left
            )
        }
    }

    private func renderWatermarkIfNeeded(
        over image: CIImage,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let text = config.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.watermarkEnabled, !text.isEmpty else { return image }

        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.clear(CGRect(origin: .zero, size: outputSize))
        let scale = max(0.7, min(config.watermarkScale, 2.2)) * canvasScale
        let fontSize = max(11, 16 * scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(CGFloat(max(0.12, min(config.watermarkOpacity, 1))))
        ]
        let measured = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: outputSize.width * 0.5, height: 80 * scale),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padding = 14 * scale
        let margin = 22 * canvasScale
        let rectSize = CGSize(
            width: min(outputSize.width * 0.45, measured.width + padding * 2),
            height: max(30 * scale, measured.height + padding)
        )
        let origin: CGPoint
        switch config.watermarkPosition {
        case .topLeft:
            origin = CGPoint(x: margin, y: outputSize.height - rectSize.height - margin)
        case .topRight:
            origin = CGPoint(x: outputSize.width - rectSize.width - margin, y: outputSize.height - rectSize.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: margin, y: margin)
        case .bottomRight:
            origin = CGPoint(x: outputSize.width - rectSize.width - margin, y: margin)
        }
        let badgeRect = CGRect(origin: origin, size: rectSize)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil)
        context.addPath(path)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(max(0.08, min(config.watermarkOpacity, 0.55))) * 0.55))
        context.fillPath()

        drawAttributedText(
            text,
            in: badgeRect.insetBy(dx: padding, dy: padding * 0.45),
            context: context,
            fontSize: fontSize,
            weight: .semibold,
            color: NSColor.white.withAlphaComponent(CGFloat(max(0.12, min(config.watermarkOpacity, 1)))),
            alignment: .center
        )

        guard let cgImage = context.makeImage() else { return image }
        return CIImage(cgImage: cgImage).composited(over: image)
    }

    private func drawAttributedText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func canvasScale(for outputSize: CGSize) -> CGFloat {
        max(0.25, min(outputSize.width, outputSize.height) / 1080)
    }
    
    private func renderBackground(size: CGSize, config: StylePreset) -> CIImage {
        let cacheKey = BackgroundCacheKey(size: size, config: config)
        if cachedBackgroundKey == cacheKey, let cachedBackgroundImage {
            return cachedBackgroundImage
        }

        let background: CIImage
        switch config.backgroundType {
        case .solid:
            background = createSolidBackground(size: size, color: config.backgroundColor)
        case .gradient:
            background = createGradientBackground(
                size: size,
                colors: config.backgroundGradientColors,
                angle: config.backgroundGradientAngle
            )
        case .image:
            if let imageURL = config.backgroundImageURL {
                background = createImageBackground(size: size, url: imageURL)
            } else {
                background = createSolidBackground(size: size, color: config.backgroundColor)
            }
        }

        cachedBackgroundKey = cacheKey
        cachedBackgroundImage = background
        return background
    }
    
    private func createSolidBackground(size: CGSize, color: CodableColor) -> CIImage {
        let cgColor = color.cgColor
        return CIImage(color: .init(cgColor: cgColor))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
    
    private func createGradientBackground(
        size: CGSize,
        colors: [CodableColor],
        angle: Double
    ) -> CIImage {
        guard colors.count >= 2 else {
            return createSolidBackground(size: size, color: colors.first ?? CodableColor(r: 0.1, g: 0.1, b: 0.1))
        }
        
        let gradientFilter = CIFilter(name: "CILinearGradient")
        gradientFilter?.setValue(CIColor(cgColor: colors[0].cgColor), forKey: "inputColor0")
        gradientFilter?.setValue(CIColor(cgColor: colors[1].cgColor), forKey: "inputColor1")
        
        let angleRad = angle * .pi / 180
        let cosAngle = cos(angleRad)
        let sinAngle = sin(angleRad)
        
        let centerX = size.width / 2
        let centerY = size.height / 2
        let length = sqrt(size.width * size.width + size.height * size.height) / 2
        
        let point0 = CGPoint(
            x: centerX - cosAngle * length,
            y: centerY - sinAngle * length
        )
        let point1 = CGPoint(
            x: centerX + cosAngle * length,
            y: centerY + sinAngle * length
        )
        
        gradientFilter?.setValue(CIVector(cgPoint: point0), forKey: "inputPoint0")
        gradientFilter?.setValue(CIVector(cgPoint: point1), forKey: "inputPoint1")
        
        guard let gradientImage = gradientFilter?.outputImage else {
            return createSolidBackground(size: size, color: colors[0])
        }
        
        return gradientImage.cropped(to: CGRect(origin: .zero, size: size))
    }
    
    private func createImageBackground(size: CGSize, url: URL) -> CIImage {
        guard Self.backgroundImageFileIsLoadable(url),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = Self.thumbnailImage(from: imageSource, targetSize: size) else {
            return createSolidBackground(size: size, color: CodableColor(r: 0.1, g: 0.1, b: 0.1))
        }
        
        let ciImage = CIImage(cgImage: cgImage)
        
        let scaleX = size.width / CGFloat(cgImage.width)
        let scaleY = size.height / CGFloat(cgImage.height)
        let scale = max(scaleX, scaleY)
        
        let scaledSize = CGSize(
            width: CGFloat(cgImage.width) * scale,
            height: CGFloat(cgImage.height) * scale
        )
        
        let offset = CGPoint(
            x: (size.width - scaledSize.width) / 2,
            y: (size.height - scaledSize.height) / 2
        )
        
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positionedImage = scaledImage.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        
        return positionedImage.cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func backgroundImageFileIsLoadable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > 0,
              fileSize.uint64Value <= maxBackgroundImageBytes else {
            return false
        }
        return true
    }

    private static func thumbnailImage(from imageSource: CGImageSource, targetSize: CGSize) -> CGImage? {
        let maxPixelSize = max(
            1,
            min(8192, Int(ceil(max(targetSize.width, targetSize.height) * 1.5)))
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    }
    
    private func frameInContext(
        _ frame: CIImage,
        background: CIImage,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        var result = background
        let layout = frameLayout(
            for: frame.extent,
            config: config,
            outputSize: outputSize,
            canvasScale: canvasScale
        )
        var positionedFrame = frame.transformed(by: layout.transform)

        positionedFrame = clip(
            positionedFrame,
            to: layout.rect,
            radius: config.cornerRadius * canvasScale
        )
        
        if config.shadowEnabled {
            positionedFrame = applyShadow(
                to: positionedFrame,
                rect: layout.rect,
                config: config,
                canvasScale: canvasScale
            )
        }
        
        result = positionedFrame.composited(over: result)
        
        return result
    }

    private func renderCameraOnlyLayout(
        _ webcam: CIImage,
        background: CIImage,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let padding = max(44, config.padding * 0.55) * canvasScale
        let targetRect = CGRect(
            x: padding,
            y: padding,
            width: max(1, outputSize.width - padding * 2),
            height: max(1, outputSize.height - padding * 2)
        )
        let camera = preparedWebcamImage(
            webcam,
            targetSize: targetRect.size,
            shape: .roundedRect,
            config: config
        )
        let clipped = clip(
            camera.transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY)),
            to: targetRect,
            radius: max(22, config.webcamCornerRadius) * canvasScale
        )
        let framed = applyCameraShadowIfNeeded(
            clipped,
            rect: targetRect,
            config: config,
            canvasScale: canvasScale
        )
        return framed.composited(over: background)
    }

    private func renderSideBySideLayout(
        screen: CIImage,
        webcam: CIImage,
        background: CIImage,
        inputs: FrameInputs,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let outerPadding = max(36, config.padding * 0.45) * canvasScale
        let gap = max(18, 28 * canvasScale)
        let availableWidth = max(1, outputSize.width - outerPadding * 2 - gap)
        let availableHeight = max(1, outputSize.height - outerPadding * 2)
        let screenWidth = availableWidth * 0.64
        let cameraWidth = availableWidth - screenWidth
        let screenRect = CGRect(
            x: outerPadding,
            y: outerPadding,
            width: screenWidth,
            height: availableHeight
        )
        let cameraRect = CGRect(
            x: screenRect.maxX + gap,
            y: outerPadding,
            width: cameraWidth,
            height: availableHeight
        )

        var result = background
        let screenLayout = fitImageLayout(screen, into: screenRect)
        let screenImage = screen.transformed(by: screenLayout.transform)
        let clippedScreen = clip(
            screenImage,
            to: screenRect,
            radius: max(10, config.cornerRadius) * canvasScale
        )
        result = applyShadow(
            to: clippedScreen,
            rect: screenRect,
            config: config,
            canvasScale: canvasScale
        ).composited(over: result)

        if inputs.cursorVisible, let pos = inputs.cursorPosition {
            let transformedPosition = pos
                .applying(inputs.zoomTransform)
                .applying(screenLayout.transform)
            let cursor = renderCursor(
                at: transformedPosition,
                scale: inputs.cursorScale,
                alpha: inputs.cursorAlpha,
                isClicking: inputs.isClicking,
                clickAnimationProgress: inputs.clickAnimationProgress,
                config: config,
                canvasScale: canvasScale
            )
            result = cursor.composited(over: result)
        }

        let cameraImage = preparedWebcamImage(
            webcam,
            targetSize: cameraRect.size,
            shape: .roundedRect,
            config: config
        )
        let clippedCamera = clip(
            cameraImage.transformed(by: CGAffineTransform(translationX: cameraRect.minX, y: cameraRect.minY)),
            to: cameraRect,
            radius: max(20, config.webcamCornerRadius) * canvasScale
        )
        result = applyCameraShadowIfNeeded(
            clippedCamera,
            rect: cameraRect,
            config: config,
            canvasScale: canvasScale
        ).composited(over: result)

        if config.webcamBorderEnabled {
            let border = drawLayoutBorder(
                rect: cameraRect,
                radius: max(20, config.webcamCornerRadius) * canvasScale,
                color: config.webcamBorderColor.cgColor,
                lineWidth: max(1, config.webcamBorderWidth * canvasScale),
                outputSize: outputSize
            )
            result = border.composited(over: result)
        }

        return result
    }

    private func preparedWebcamImage(
        _ frame: CIImage,
        targetSize: CGSize,
        shape: WebcamShape,
        config: StylePreset
    ) -> CIImage {
        let cropRect = webcamCropRect(for: frame.extent, targetSize: targetSize, shape: shape)
        let sourceWidth = max(1, cropRect.width)
        let sourceHeight = max(1, cropRect.height)
        var source = frame
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        if config.webcamMirror {
            source = source
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: sourceWidth, y: 0))
        }
        source = applyWebcamEnhancement(source, config: config)
        return source
            .transformed(by: CGAffineTransform(
                scaleX: targetSize.width / sourceWidth,
                y: targetSize.height / sourceHeight
            ))
            .cropped(to: CGRect(origin: .zero, size: targetSize))
    }

    private func fitImage(_ image: CIImage, into targetRect: CGRect) -> CIImage {
        image.transformed(by: fitImageLayout(image, into: targetRect).transform)
    }

    private struct ImageFitLayout {
        let transform: CGAffineTransform
        let rect: CGRect
    }

    private func fitImageLayout(_ image: CIImage, into targetRect: CGRect) -> ImageFitLayout {
        let extent = image.extent
        let scale = min(
            targetRect.width / max(extent.width, 1),
            targetRect.height / max(extent.height, 1)
        )
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let origin = CGPoint(
            x: targetRect.midX - scaledSize.width / 2,
            y: targetRect.midY - scaledSize.height / 2
        )
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: origin.x - extent.minX * scale,
            ty: origin.y - extent.minY * scale
        )
        return ImageFitLayout(
            transform: transform,
            rect: CGRect(origin: origin, size: scaledSize)
        )
    }

    private func applyCameraShadowIfNeeded(
        _ image: CIImage,
        rect: CGRect,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        guard config.webcamShadowEnabled else { return image }
        var shadowConfig = config
        shadowConfig.shadowEnabled = true
        shadowConfig.shadowRadius = config.webcamShadowRadius
        shadowConfig.shadowOpacity = config.webcamShadowOpacity
        shadowConfig.shadowOffsetY = 16
        shadowConfig.shadowOffsetX = 0
        shadowConfig.shadowColor = CodableColor(r: 0, g: 0, b: 0)
        return applyShadow(
            to: image,
            rect: rect,
            config: shadowConfig,
            canvasScale: canvasScale
        )
    }

    private func drawLayoutBorder(
        rect: CGRect,
        radius: CGFloat,
        color: CGColor,
        lineWidth: CGFloat,
        outputSize: CGSize
    ) -> CIImage {
        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: outputSize))
        context.setStrokeColor(color.copy(alpha: 0.72) ?? color)
        context.setLineWidth(lineWidth)
        let insetRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.addPath(CGPath(roundedRect: insetRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        guard let image = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image)
    }

    private struct FrameLayout {
        let transform: CGAffineTransform
        let rect: CGRect
    }

    private func frameLayout(
        for extent: CGRect,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> FrameLayout {
        let padding = max(0, (config.padding + config.margin) * canvasScale)
        let maxFrameSize = CGSize(
            width: max(outputSize.width - padding * 2, 1),
            height: max(outputSize.height - padding * 2, 1)
        )

        let scale = min(
            maxFrameSize.width / max(extent.width, 1),
            maxFrameSize.height / max(extent.height, 1)
        )

        let scaledSize = CGSize(
            width: extent.width * scale,
            height: extent.height * scale
        )

        let frameOrigin = CGPoint(
            x: (outputSize.width - scaledSize.width) / 2,
            y: (outputSize.height - scaledSize.height) / 2
        )

        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: frameOrigin.x - extent.minX * scale,
            ty: frameOrigin.y - extent.minY * scale
        )

        return FrameLayout(
            transform: transform,
            rect: CGRect(origin: frameOrigin, size: scaledSize)
        )
    }
    
    private func applyShadow(
        to image: CIImage,
        rect: CGRect,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        let opacity = CGFloat(max(0, min(config.shadowOpacity, 1)))
        guard opacity > 0 else { return image }

        let shadowRadius = config.shadowRadius * canvasScale
        let shadowRect = rect.insetBy(dx: -shadowRadius * 2, dy: -shadowRadius * 2)
        let mask = roundedRectMask(
            rect: rect,
            radius: config.cornerRadius * canvasScale
        )
        let shadowFilter = CIFilter(name: "CIGaussianBlur")
        shadowFilter?.setValue(mask, forKey: kCIInputImageKey)
        shadowFilter?.setValue(shadowRadius, forKey: kCIInputRadiusKey)
        
        guard let shadowMask = shadowFilter?.outputImage?.cropped(to: shadowRect) else {
            return image
        }

        let shadowColor = CIImage(color: CIColor(
            red: config.shadowColor.r,
            green: config.shadowColor.g,
            blue: config.shadowColor.b,
            alpha: opacity
        ))
            .cropped(to: shadowRect)
        let coloredShadow = shadowColor.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: shadowMask
            ]
        )

        let offsetShadow = coloredShadow.transformed(by: CGAffineTransform(
            translationX: config.shadowOffsetX * canvasScale,
            y: config.shadowOffsetY * canvasScale
        ))

        return image.composited(over: offsetShadow)
    }

    private func roundedRectMask(rect: CGRect, radius: CGFloat) -> CIImage {
        let radius = max(0, min(radius, min(rect.width, rect.height) / 2))
        let base = CIImage(color: .white).cropped(to: rect)
        guard radius > 0 else { return base }

        let generator = CIFilter(name: "CIRoundedRectangleGenerator")
        generator?.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        generator?.setValue(radius, forKey: "inputRadius")
        generator?.setValue(CIColor.white, forKey: "inputColor")
        return generator?.outputImage?.cropped(to: rect) ?? base
    }
    
    private func renderCursor(
        at position: CGPoint,
        scale: CGFloat,
        alpha: Float,
        isClicking: Bool,
        clickAnimationProgress: Double?,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        let effectiveScale = max(0.25, scale * canvasScale)
        let useClickCursor = isClicking || clickAnimationProgress != nil
        let cursorRenderScale = useClickCursor ? effectiveScale * 0.72 : effectiveScale
        let baseCursor = if useClickCursor {
            config.useHighResCursors ? highResHandCursorImage : lowResHandCursorImage
        } else {
            config.useHighResCursors ? highResCursorImage : lowResCursorImage
        }
        let pixelSize = useClickCursor ? handCursorPixelSize : cursorPixelSize
        let hotSpot = useClickCursor ? handCursorHotSpot : cursorHotSpot
        let scaledCursor = baseCursor
            .transformed(by: CGAffineTransform(scaleX: cursorRenderScale, y: cursorRenderScale))
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
                ]
            )
        let finalPosition = CGPoint(
            x: position.x - hotSpot.x * cursorRenderScale,
            y: position.y - hotSpot.y * cursorRenderScale
        )

        let positionedCursor = scaledCursor.transformed(by: CGAffineTransform(
            translationX: finalPosition.x,
            y: finalPosition.y
        ))

        guard isClicking || (clickAnimationProgress.map { $0 >= 0 } ?? false) else {
            return positionedCursor
        }

        let fingertipLift = max(8, pixelSize.height * 0.32 * cursorRenderScale)
        let clickAnchor = CGPoint(
            x: position.x,
            y: position.y + fingertipLift
        )
        let click = clickPulse(
            at: clickAnchor,
            progress: clickAnimationProgress ?? 0,
            cursorScale: cursorRenderScale,
            cursorPixelSize: max(pixelSize.width, pixelSize.height)
        )
        return positionedCursor.composited(over: click)
    }

    private func clickPulse(
        at position: CGPoint,
        progress: Double,
        cursorScale: CGFloat,
        cursorPixelSize: CGFloat
    ) -> CIImage {
        let t = max(0, min(progress, 1))
        let eased = 1 - pow(1 - t, 3)
        let radius = (cursorPixelSize * 0.09 + 5 * eased) * max(0.65, min(cursorScale, 1.2))
        let strokeWidth = max(1.1, 1.8 - 0.7 * t)
        let ringAlpha = CGFloat(0.34 * (1 - t))
        let glowAlpha = CGFloat(0.045 * (1 - t))
        let canvas = Int(ceil((radius + 8) * 2))
        let size = CGSize(width: canvas, height: canvas)

        guard let context = CGContext(
            data: nil,
            width: canvas,
            height: canvas,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: size))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let glowRect = CGRect(
            x: center.x - radius - 4,
            y: center.y - radius - 4,
            width: (radius + 4) * 2,
            height: (radius + 4) * 2
        )
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: glowAlpha))
        context.fillEllipse(in: glowRect)

        let ringRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: ringAlpha))
        context.setLineWidth(strokeWidth)
        context.strokeEllipse(in: ringRect)

        guard let image = context.makeImage() else {
            return CIImage.empty()
        }

        return CIImage(cgImage: image).transformed(by: CGAffineTransform(
            translationX: position.x - size.width / 2,
            y: position.y - size.height / 2
        ))
    }

    private func clip(_ image: CIImage, to rect: CGRect, radius: CGFloat) -> CIImage {
        guard radius > 0 else { return image.cropped(to: rect) }

        let mask = roundedRectMask(rect: rect, radius: radius)
        return image.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        )
        .cropped(to: rect)
    }

    private static func makeLowResCursorImage(from cgImage: CGImage) -> CIImage {
        let targetWidth = max(1, cgImage.width / 2)
        let targetHeight = max(1, cgImage.height / 2)

        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return CIImage(cgImage: cgImage)
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let reduced = context.makeImage() else {
            return CIImage(cgImage: cgImage)
        }

        return CIImage(cgImage: reduced)
    }

    private struct CursorImages {
        let high: CIImage
        let low: CIImage
        let pixelSize: CGSize
        let hotSpot: CGPoint
    }

    private static func makeCursorImages(from cursor: NSCursor) -> CursorImages {
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            let fallback = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 18, height: 24))
            return CursorImages(
                high: fallback,
                low: fallback,
                pixelSize: CGSize(width: 18, height: 24),
                hotSpot: .zero
            )
        }

        return CursorImages(
            high: CIImage(cgImage: cgImage),
            low: makeLowResCursorImage(from: cgImage),
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            hotSpot: CGPoint(
                x: cursor.hotSpot.x * CGFloat(cgImage.width) / max(image.size.width, 1),
                y: cursor.hotSpot.y * CGFloat(cgImage.height) / max(image.size.height, 1)
            )
        )
    }

    private func renderWebcam(
        _ frame: CIImage,
        config: StylePreset,
        cursorPos: CGPoint?,
        recordingRect: CGRect,
        canvasScale: CGFloat,
        zoomScale: CGFloat
    ) -> CIImage {
        let webcamSize = resolvedWebcamSize(config: config, canvasScale: canvasScale, zoomScale: zoomScale)
        let cropRect = webcamCropRect(for: frame.extent, targetSize: webcamSize, shape: config.webcamShape)
        let sourceWidth = max(1, cropRect.width)
        let sourceHeight = max(1, cropRect.height)
        var source = frame
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        if config.webcamMirror {
            source = source
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: sourceWidth, y: 0))
        }
        source = applyWebcamEnhancement(source, config: config)

        let scaledWebcam = source
            .transformed(by: CGAffineTransform(
            scaleX: webcamSize.width / sourceWidth,
            y: webcamSize.height / sourceHeight
        ))
            .cropped(to: CGRect(origin: .zero, size: webcamSize))

        var position: CGPoint
        let padding: CGFloat = 20 * canvasScale

        switch config.webcamPosition {
        case .bottomRight:
            position = CGPoint(
                x: recordingRect.maxX - webcamSize.width - padding,
                y: recordingRect.minY + padding
            )
        case .bottomLeft:
            position = CGPoint(
                x: recordingRect.minX + padding,
                y: recordingRect.minY + padding
            )
        case .topRight:
            position = CGPoint(
                x: recordingRect.maxX - webcamSize.width - padding,
                y: recordingRect.maxY - webcamSize.height - padding
            )
        case .topLeft:
            position = CGPoint(
                x: recordingRect.minX + padding,
                y: recordingRect.maxY - webcamSize.height - padding
            )
        }
        position.x += config.webcamOffsetX * canvasScale
        position.y += config.webcamOffsetY * canvasScale

        let clampedPosition = CGPoint(
            x: min(max(position.x, recordingRect.minX - webcamSize.width * 0.75), recordingRect.maxX - webcamSize.width * 0.25),
            y: min(max(position.y, recordingRect.minY - webcamSize.height * 0.75), recordingRect.maxY - webcamSize.height * 0.25)
        )

        let mask: CIImage
        switch config.webcamShape {
        case .circle:
            let circleMask = CIFilter(name: "CIRadialGradient")
            circleMask?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            circleMask?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
            circleMask?.setValue(CIVector(x: webcamSize.width / 2, y: webcamSize.height / 2), forKey: "inputCenter")
            circleMask?.setValue(webcamSize.width / 2 - 1, forKey: "inputRadius0")
            circleMask?.setValue(webcamSize.width / 2, forKey: "inputRadius1")
            mask = circleMask?.outputImage?.cropped(to: CGRect(origin: .zero, size: webcamSize))
                ?? CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: webcamSize))
        case .roundedRect:
            mask = roundedRectMask(
                rect: CGRect(origin: .zero, size: webcamSize),
                radius: config.webcamCornerRadius * canvasScale
            )
        case .square:
            mask = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: webcamSize))
        }

        let maskedWebcam = scaledWebcam
            .cropped(to: CGRect(origin: .zero, size: webcamSize))
            .applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        )
            .cropped(to: CGRect(origin: .zero, size: webcamSize))

        let polishedWebcam = applyWebcamChrome(
            to: maskedWebcam,
            size: webcamSize,
            shape: config.webcamShape,
            config: config,
            canvasScale: canvasScale
        )

        return polishedWebcam.transformed(by: CGAffineTransform(
            translationX: clampedPosition.x,
            y: clampedPosition.y
        ))
    }

    private func applyWebcamEnhancement(_ image: CIImage, config: StylePreset) -> CIImage {
        guard config.webcamEnhanceEnabled else { return image }
        return image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: CGFloat(max(-0.2, min(config.webcamBrightness, 0.2))),
                kCIInputContrastKey: CGFloat(max(0.75, min(config.webcamContrast, 1.35))),
                kCIInputSaturationKey: CGFloat(max(0.5, min(config.webcamSaturation, 1.6)))
            ]
        )
    }

    private func applyWebcamChrome(
        to image: CIImage,
        size: CGSize,
        shape: WebcamShape,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var result = image

        if config.webcamShadowEnabled, config.webcamShadowOpacity > 0 {
            let radius = max(1, config.webcamShadowRadius * canvasScale)
            let shadowMask = webcamShapeMask(rect: rect, shape: shape, config: config, canvasScale: canvasScale)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            let shadowExtent = rect.insetBy(dx: -radius * 2.5, dy: -radius * 2.5)
            let shadowColor = CIImage(color: CIColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: CGFloat(max(0, min(config.webcamShadowOpacity, 0.8)))
            ))
            .cropped(to: shadowExtent)
            let shadow = shadowColor.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: shadowMask.cropped(to: shadowExtent)
                ]
            )
            result = result.composited(over: shadow)
        }

        if config.webcamBorderEnabled, config.webcamBorderWidth > 0 {
            let border = drawWebcamBorder(
                size: size,
                shape: shape,
                config: config,
                canvasScale: canvasScale
            )
            result = border.composited(over: result)
        }

        return result
    }

    private func webcamShapeMask(
        rect: CGRect,
        shape: WebcamShape,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        switch shape {
        case .circle:
            let circleMask = CIFilter(name: "CIRadialGradient")
            circleMask?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
            circleMask?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
            circleMask?.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: "inputCenter")
            circleMask?.setValue(min(rect.width, rect.height) / 2 - 1, forKey: "inputRadius0")
            circleMask?.setValue(min(rect.width, rect.height) / 2, forKey: "inputRadius1")
            return circleMask?.outputImage?.cropped(to: rect)
                ?? CIImage(color: .white).cropped(to: rect)
        case .roundedRect:
            return roundedRectMask(
                rect: rect,
                radius: config.webcamCornerRadius * canvasScale
            )
        case .square:
            return CIImage(color: .white).cropped(to: rect)
        }
    }

    private func drawWebcamBorder(
        size: CGSize,
        shape: WebcamShape,
        config: StylePreset,
        canvasScale: CGFloat
    ) -> CIImage {
        let lineWidth = max(1, config.webcamBorderWidth * canvasScale)
        let inset = lineWidth / 2
        guard let context = CGContext(
            data: nil,
            width: Int(ceil(size.width + lineWidth * 2)),
            height: Int(ceil(size.height + lineWidth * 2)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        context.clear(CGRect(origin: .zero, size: CGSize(width: size.width + lineWidth * 2, height: size.height + lineWidth * 2)))
        context.setStrokeColor(config.webcamBorderColor.cgColor.copy(alpha: 0.72) ?? config.webcamBorderColor.cgColor)
        context.setLineWidth(lineWidth)

        let strokeRect = CGRect(
            x: inset + lineWidth / 2,
            y: inset + lineWidth / 2,
            width: max(1, size.width - lineWidth),
            height: max(1, size.height - lineWidth)
        )

        switch shape {
        case .circle:
            context.strokeEllipse(in: strokeRect)
        case .roundedRect:
            let radius = max(0, min(config.webcamCornerRadius * canvasScale, min(strokeRect.width, strokeRect.height) / 2))
            context.addPath(CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .square:
            context.stroke(strokeRect)
        }

        guard let image = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(
            translationX: -lineWidth,
            y: -lineWidth
        ))
    }

    private func resolvedWebcamSize(config: StylePreset, canvasScale: CGFloat, zoomScale: CGFloat) -> CGSize {
        let zoomAdjustment = zoomScale > 1.01 ? max(0.8, min(config.webcamZoomScale, 1.5)) : 1
        if config.webcamShape == .circle {
            let side = config.webcamSize * canvasScale * zoomAdjustment
            return CGSize(width: side, height: side)
        }

        let width = (config.webcamWidth > 0 ? config.webcamWidth : config.webcamSize) * canvasScale * zoomAdjustment
        let height = (config.webcamHeight > 0 ? config.webcamHeight : config.webcamSize) * canvasScale * zoomAdjustment
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private func webcamCropRect(
        for extent: CGRect,
        targetSize: CGSize,
        shape: WebcamShape
    ) -> CGRect {
        if shape == .circle {
            let side = max(1, min(extent.width, extent.height))
            return CGRect(
                x: extent.midX - side / 2,
                y: extent.midY - side / 2,
                width: side,
                height: side
            )
        }

        let targetAspect = max(targetSize.width, 1) / max(targetSize.height, 1)
        let sourceAspect = max(extent.width, 1) / max(extent.height, 1)

        if sourceAspect > targetAspect {
            let width = extent.height * targetAspect
            return CGRect(
                x: extent.midX - width / 2,
                y: extent.minY,
                width: width,
                height: extent.height
            )
        }

        let height = extent.width / targetAspect
        return CGRect(
            x: extent.minX,
            y: extent.midY - height / 2,
            width: extent.width,
            height: height
        )
    }

    private func renderShortcutBadge(
        _ event: KeyPressEvent,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let text = event.displayString
        let fontSize = max(12, min(config.shortcutBadgeFontSize, 34)) * canvasScale
        let textFilter = CIFilter(name: "CITextImageGenerator")
        textFilter?.setValue(text, forKey: "inputText")
        textFilter?.setValue("HelveticaNeue-Medium", forKey: "inputFontName")
        textFilter?.setValue(fontSize, forKey: "inputFontSize")
        let textImage = textFilter?.outputImage
        let textWidth = textImage?.extent.width ?? CGFloat(max(text.count, 1)) * fontSize * 0.68
        let textHeight = textImage?.extent.height ?? fontSize * 1.25
        let horizontalPadding = max(18 * canvasScale, fontSize * 1.05)
        let badgeHeight = max(34 * canvasScale, fontSize * 1.95)
        let badgeWidth = max(
            badgeHeight * 1.8,
            min(textWidth + horizontalPadding * 2, outputSize.width - 30 * canvasScale)
        )
        let padding: CGFloat = 15 * canvasScale

        let position: CGPoint
        switch config.shortcutBadgePosition {
        case .bottomCenter:
            position = CGPoint(
                x: outputSize.width / 2 - badgeWidth / 2,
                y: padding
            )
        case .bottomLeft:
            position = CGPoint(x: padding, y: padding)
        case .bottomRight:
            position = CGPoint(
                x: outputSize.width - badgeWidth - padding,
                y: padding
            )
        case .topCenter:
            position = CGPoint(
                x: outputSize.width / 2 - badgeWidth / 2,
                y: outputSize.height - badgeHeight - padding
            )
        }

        let badgeRect = CGRect(origin: position, size: CGSize(width: badgeWidth, height: badgeHeight))

        let cornerRadius: CGFloat
        let defaultBackgroundColor: CGColor
        let defaultTextColor: CIColor
        let opacityMultiplier = CGFloat(max(Float(0.15), min(config.shortcutBadgeBackgroundOpacity, 1)))

        switch config.shortcutBadgeStyle {
        case .pillDark:
            cornerRadius = badgeHeight / 2
            defaultBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.75 * opacityMultiplier)
            defaultTextColor = CIColor(red: 1, green: 1, blue: 1)
        case .roundedRect:
            cornerRadius = 10 * canvasScale
            defaultBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.75 * opacityMultiplier)
            defaultTextColor = CIColor(red: 1, green: 1, blue: 1)
        case .pillLight:
            cornerRadius = badgeHeight / 2
            defaultBackgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.9 * opacityMultiplier)
            defaultTextColor = CIColor(red: 0, green: 0, blue: 0)
        case .minimal:
            cornerRadius = 8 * canvasScale
            defaultBackgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.5 * opacityMultiplier)
            defaultTextColor = CIColor(red: 1, green: 1, blue: 1)
        }

        let badgeBackgroundColor = config.shortcutBadgeUseCustomColors
            ? (config.shortcutBadgeBackgroundColor.cgColor.copy(alpha: opacityMultiplier) ?? defaultBackgroundColor)
            : defaultBackgroundColor
        let badgeTextColor = config.shortcutBadgeUseCustomColors
            ? CIColor(cgColor: config.shortcutBadgeTextColor.cgColor)
            : defaultTextColor
        let badgeBackground = maskedFill(
            rect: badgeRect,
            radius: cornerRadius,
            color: badgeBackgroundColor
        )

        if let textImage = textFilter?.outputImage {
            let textX = badgeRect.origin.x + (badgeRect.width - textWidth) / 2
            let textY = badgeRect.origin.y + (badgeRect.height - textHeight) / 2

            let positionedText = colorizedTextImage(textImage, color: badgeTextColor)
                .transformed(by: CGAffineTransform(translationX: textX, y: textY))
            return positionedText.composited(over: badgeBackground)
        }

        return badgeBackground
    }

    private func renderSubtitle(
        _ text: String,
        config: StylePreset,
        outputSize: CGSize,
        canvasScale: CGFloat
    ) -> CIImage {
        let fontSize: CGFloat = max(14, config.subtitleFontSize) * canvasScale
        let subtitleHeight: CGFloat = max(56 * canvasScale, fontSize * 2.75)
        let padding: CGFloat = 40 * canvasScale
        let subtitleWidth = min(outputSize.width - padding * 2, 760 * canvasScale)

        let y: CGFloat
        switch config.subtitlePosition {
        case .bottomCenter:
            y = padding
        case .middleCenter:
            y = outputSize.height / 2 - subtitleHeight / 2
        case .topCenter:
            y = outputSize.height - subtitleHeight - padding
        }

        let position = CGPoint(x: outputSize.width / 2 - subtitleWidth / 2, y: y)
        let subtitleRect = CGRect(origin: position, size: CGSize(width: subtitleWidth, height: subtitleHeight))

        let opacity = CGFloat(max(0, min(config.subtitleBackgroundOpacity, 1)))
        let background = maskedFill(
            rect: subtitleRect,
            radius: 14 * canvasScale,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: opacity)
        )

        let textFilter = CIFilter(name: "CITextImageGenerator")
        let textColor = CIColor(red: 1, green: 1, blue: 1)
        let maxLineLength = max(22, Int(subtitleWidth / max(fontSize * 0.52, 1)))
        textFilter?.setValue(wrap(text, maxLineLength: maxLineLength), forKey: "inputText")
        textFilter?.setValue("HelveticaNeue-Medium", forKey: "inputFontName")
        textFilter?.setValue(fontSize, forKey: "inputFontSize")

        if let textImage = textFilter?.outputImage {
            let textWidth = textImage.extent.width
            let textHeight = textImage.extent.height
            let textX = subtitleRect.origin.x + (subtitleRect.width - textWidth) / 2
            let textY = subtitleRect.origin.y + (subtitleRect.height - textHeight) / 2

            let positionedText = colorizedTextImage(textImage, color: textColor)
                .transformed(by: CGAffineTransform(translationX: textX, y: textY))
            return positionedText.composited(over: background)
        }

        return background
    }

    private func colorizedTextImage(_ textImage: CIImage, color: CIColor) -> CIImage {
        let fill = CIImage(color: color).cropped(to: textImage.extent)
        return fill.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: textImage
            ]
        )
        .cropped(to: textImage.extent)
    }

    private func maskedFill(rect: CGRect, radius: CGFloat, color: CGColor) -> CIImage {
        let fill = CIImage(color: .init(cgColor: color)).cropped(to: rect)
        let mask = roundedRectMask(rect: rect, radius: radius)
        return fill.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ]
        )
        .cropped(to: rect)
    }

    private func wrap(_ text: String, maxLineLength: Int) -> String {
        let words = text.split(separator: " ")
        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count > maxLineLength, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }
        return lines.prefix(2).joined(separator: "\n")
    }
}
