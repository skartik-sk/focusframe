import Foundation
import CoreGraphics

struct FrameTransform {
    let timestamp: Double
    let transform: CGAffineTransform
    let sourceRect: CGRect
    let scale: CGFloat
    let isTransitioning: Bool
    let transitionProgress: Double // 0.0 to 1.0
}

class ZoomTransformer {
    
    func generateTransforms(
        zoomSegments: [ZoomSegment],
        sourceSize: CGSize,
        outputSize: CGSize,
        duration: Double,
        fps: Double = 60,
        orientation: ExportProfile.Orientation = .landscape
    ) -> [FrameTransform] {
        var transforms: [FrameTransform] = []
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeFPS = fps.isFinite && fps > 0 ? fps : 60
        let frameCount = Int(ceil(safeDuration * safeFPS))
        let safeSourceSize = CGSize(
            width: max(sourceSize.width, 1),
            height: max(sourceSize.height, 1)
        )
        
        let adjustedOutputSize: CGSize
        if orientation == .portrait && outputSize.width > outputSize.height {
            adjustedOutputSize = CGSize(width: outputSize.height, height: outputSize.width)
        } else {
            adjustedOutputSize = outputSize
        }
        let sortedSegments = zoomSegments.sorted { $0.startTime < $1.startTime }
        
        for frameIndex in 0..<frameCount {
            let time = Double(frameIndex) / safeFPS
            
            // Find which zoom segment we're in
            if let segment = findSegment(at: time, inSorted: sortedSegments) {
                let transformData = calculateTransform(
                    for: segment,
                    at: time,
                    sourceSize: safeSourceSize,
                    outputSize: adjustedOutputSize,
                    orientation: orientation
                )
                
                transforms.append(FrameTransform(
                    timestamp: time,
                    transform: transformData.transform,
                    sourceRect: transformData.sourceRect,
                    scale: transformData.scale,
                    isTransitioning: transformData.isTransitioning,
                    transitionProgress: transformData.transitionProgress
                ))
            } else {
                // No zoom - show full screen (scale to fit)
                let fullViewTransform = scaleToFit(
                    source: safeSourceSize,
                    target: adjustedOutputSize
                )
                
                transforms.append(FrameTransform(
                    timestamp: time,
                    transform: fullViewTransform,
                    sourceRect: CGRect(origin: .zero, size: safeSourceSize),
                    scale: fullViewTransform.a,
                    isTransitioning: false,
                    transitionProgress: 0.0
                ))
            }
        }
        
        return transforms
    }
    
    private struct TransformData {
        let transform: CGAffineTransform
        let sourceRect: CGRect
        let scale: CGFloat
        let isTransitioning: Bool
        let transitionProgress: Double
    }
    
    private func findSegment(at time: Double, inSorted segments: [ZoomSegment]) -> ZoomSegment? {
        guard !segments.isEmpty else { return nil }
        var low = 0
        var high = segments.count - 1
        var latestStartIndex: Int?

        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].startTime <= time {
                latestStartIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard var index = latestStartIndex else { return nil }
        while index >= 0 {
            let segment = segments[index]
            if time >= segment.startTime && time <= segment.endTime {
                return segment
            }
            index -= 1
        }
        return nil
    }
    
    private func calculateTransform(
        for segment: ZoomSegment,
        at time: Double,
        sourceSize: CGSize,
        outputSize: CGSize,
        orientation: ExportProfile.Orientation = .landscape
    ) -> TransformData {
        // Check if we're in a transition (entering or leaving zoom)
        let timeInSegment = time - segment.startTime
        let transitionDurations = normalizedTransitionDurations(for: segment)
        let zoomInDuration = transitionDurations.zoomIn
        let zoomOutDuration = transitionDurations.zoomOut
        let isInZoomIn = zoomInDuration > 0 && timeInSegment < zoomInDuration
        let isInZoomOut = zoomOutDuration > 0 && (segment.endTime - time) < zoomOutDuration
        
        let isTransitioning = isInZoomIn || isInZoomOut
        
        let effectiveZoomRect = zoomRect(for: segment, at: time)

        // Calculate the target transform for the zoomed state
        let targetTransform = calculateZoomTransform(
            zoomRect: effectiveZoomRect,
            focusPadding: segment.focusPadding,
            sourceSize: sourceSize,
            outputSize: outputSize,
            orientation: orientation
        )
        
        let fullViewTransform = scaleToFit(
            source: sourceSize,
            target: outputSize
        )
        
        let finalTransform: CGAffineTransform
        let finalSourceRect: CGRect
        let finalScale: CGFloat
        var transitionProgress: Double = 0.0
        
        if isTransitioning {
            if isInZoomIn {
                // Transitioning from full view to zoomed
                transitionProgress = timeInSegment / zoomInDuration
                let easedProgress = segment.easingFunction.apply(transitionProgress)
                
                finalTransform = interpolateTransform(
                    from: fullViewTransform,
                    to: targetTransform.transform,
                    t: easedProgress
                )
                
                finalSourceRect = interpolateRect(
                    from: CGRect(origin: .zero, size: sourceSize),
                    to: targetTransform.sourceRect,
                    t: easedProgress
                )
                
                finalScale = lerp(
                    from: fullViewTransform.a,
                    to: targetTransform.scale,
                    t: easedProgress
                )
            } else {
                // Transitioning from zoomed to full view
                let zoomOutStart = segment.endTime - zoomOutDuration
                transitionProgress = (time - zoomOutStart) / zoomOutDuration
                let easedProgress = segment.easingFunction.apply(transitionProgress)
                
                finalTransform = interpolateTransform(
                    from: targetTransform.transform,
                    to: fullViewTransform,
                    t: easedProgress
                )
                
                finalSourceRect = interpolateRect(
                    from: targetTransform.sourceRect,
                    to: CGRect(origin: .zero, size: sourceSize),
                    t: easedProgress
                )
                
                finalScale = lerp(
                    from: targetTransform.scale,
                    to: fullViewTransform.a,
                    t: easedProgress
                )
            }
        } else {
            // Fully zoomed state
            finalTransform = targetTransform.transform
            finalSourceRect = targetTransform.sourceRect
            finalScale = targetTransform.scale
        }
        
        return TransformData(
            transform: finalTransform,
            sourceRect: finalSourceRect,
            scale: finalScale,
            isTransitioning: isTransitioning,
            transitionProgress: transitionProgress
        )
    }
    
    private struct ZoomTransformResult {
        let transform: CGAffineTransform
        let sourceRect: CGRect
        let scale: CGFloat
    }

    private func zoomRect(for segment: ZoomSegment, at time: Double) -> CGRect {
        guard segment.source == .automatic,
              let keyframes = segment.keyframes?.sorted(by: { $0.time < $1.time }),
              !keyframes.isEmpty else {
            return segment.zoomRect
        }

        guard keyframes.count > 1 else {
            return keyframes[0].zoomRect
        }

        if time <= keyframes[0].time {
            return keyframes[0].zoomRect
        }

        let lastIndex = keyframes.count - 1
        if time >= keyframes[lastIndex].time {
            return keyframes[lastIndex].zoomRect
        }

        for index in 0..<lastIndex {
            let start = keyframes[index]
            let end = keyframes[index + 1]
            guard time >= start.time && time <= end.time else { continue }
            let duration = max(0.001, end.time - start.time)
            let progress = max(0, min(1, (time - start.time) / duration))
            let easedProgress = segment.easingFunction.apply(progress)
            return interpolateRect(from: start.zoomRect, to: end.zoomRect, t: easedProgress)
        }

        return segment.zoomRect
    }

    private func normalizedTransitionDurations(for segment: ZoomSegment) -> (zoomIn: Double, zoomOut: Double) {
        let duration = max(0, segment.endTime - segment.startTime)
        guard duration > 0 else { return (0, 0) }

        let requestedIn = max(0, segment.zoomInDuration)
        let requestedOut = max(0, segment.zoomOutDuration)
        let requestedTotal = requestedIn + requestedOut
        guard requestedTotal > duration else {
            return (requestedIn, requestedOut)
        }

        let scale = duration / requestedTotal
        return (requestedIn * scale, requestedOut * scale)
    }
    
    private func calculateZoomTransform(
        zoomRect: CGRect,
        focusPadding: CGFloat,
        sourceSize: CGSize,
        outputSize: CGSize,
        orientation: ExportProfile.Orientation = .landscape
    ) -> ZoomTransformResult {
        let sourceBounds = CGRect(origin: .zero, size: sourceSize)
        let normalizedZoomRect = normalizeZoomRect(zoomRect, sourceBounds: sourceBounds)
        let safePadding = max(0, min(focusPadding, 0.16))
        let paddedRect = clampRect(normalizedZoomRect.insetBy(
            dx: -normalizedZoomRect.width * safePadding,
            dy: -normalizedZoomRect.height * safePadding
        ), to: sourceBounds)
        
        let targetAspectRatio = outputSize.width / outputSize.height
        let currentAspectRatio = paddedRect.width / paddedRect.height
        let aspectMatchedRect: CGRect

        if currentAspectRatio > targetAspectRatio {
            let newHeight = paddedRect.width / targetAspectRatio
            aspectMatchedRect = paddedRect.insetBy(dx: 0, dy: -(newHeight - paddedRect.height) / 2)
        } else {
            let newWidth = paddedRect.height * targetAspectRatio
            aspectMatchedRect = paddedRect.insetBy(dx: -(newWidth - paddedRect.width) / 2, dy: 0)
        }

        let adjustedRect = clampRect(aspectMatchedRect, to: sourceBounds)
        
        let scaleX = outputSize.width / adjustedRect.width
        let scaleY = outputSize.height / adjustedRect.height
        let scale = min(scaleX, scaleY)
        
        let offsetX = outputSize.width / 2 - adjustedRect.midX * scale
        let offsetY = outputSize.height / 2 - adjustedRect.midY * scale

        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
        
        return ZoomTransformResult(
            transform: transform,
            sourceRect: adjustedRect,
            scale: scale
        )
    }

    private func normalizeZoomRect(_ rect: CGRect, sourceBounds: CGRect) -> CGRect {
        let clamped = clampRect(rect, to: sourceBounds)
        let sourceArea = max(sourceBounds.width * sourceBounds.height, 1)
        let rectArea = clamped.width * clamped.height
        guard rectArea / sourceArea > 0.72 else { return clamped }

        let maxWidth = sourceBounds.width * 0.56
        let maxHeight = sourceBounds.height * 0.56
        let targetAspect = sourceBounds.width / sourceBounds.height

        var width = min(clamped.width, maxWidth)
        var height = width / targetAspect
        if height > maxHeight {
            height = maxHeight
            width = height * targetAspect
        }

        return clampRect(
            CGRect(
                x: clamped.midX - width / 2,
                y: clamped.midY - height / 2,
                width: width,
                height: height
            ),
            to: sourceBounds
        )
    }

    private func clampRect(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        var result = rect

        if result.width > bounds.width {
            result.size.width = bounds.width
            result.origin.x = bounds.origin.x
        }

        if result.height > bounds.height {
            result.size.height = bounds.height
            result.origin.y = bounds.origin.y
        }

        if result.minX < bounds.minX {
            result.origin.x = bounds.minX
        }
        if result.minY < bounds.minY {
            result.origin.y = bounds.minY
        }
        if result.maxX > bounds.maxX {
            result.origin.x = bounds.maxX - result.width
        }
        if result.maxY > bounds.maxY {
            result.origin.y = bounds.maxY - result.height
        }

        return result
    }
    
    private func scaleToFit(source: CGSize, target: CGSize) -> CGAffineTransform {
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        let scale = min(scaleX, scaleY)
        
        let scaledWidth = source.width * scale
        let scaledHeight = source.height * scale
        let offsetX = (target.width - scaledWidth) / 2
        let offsetY = (target.height - scaledHeight) / 2
        
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: offsetX, y: offsetY)
        transform = transform.scaledBy(x: scale, y: scale)
        
        return transform
    }
    
    private func interpolateTransform(
        from start: CGAffineTransform,
        to end: CGAffineTransform,
        t: Double
    ) -> CGAffineTransform {
        return CGAffineTransform(
            a: lerp(from: start.a, to: end.a, t: t),
            b: lerp(from: start.b, to: end.b, t: t),
            c: lerp(from: start.c, to: end.c, t: t),
            d: lerp(from: start.d, to: end.d, t: t),
            tx: lerp(from: start.tx, to: end.tx, t: t),
            ty: lerp(from: start.ty, to: end.ty, t: t)
        )
    }
    
    private func interpolateRect(
        from start: CGRect,
        to end: CGRect,
        t: Double
    ) -> CGRect {
        return CGRect(
            x: lerp(from: start.origin.x, to: end.origin.x, t: t),
            y: lerp(from: start.origin.y, to: end.origin.y, t: t),
            width: lerp(from: start.size.width, to: end.size.width, t: t),
            height: lerp(from: start.size.height, to: end.size.height, t: t)
        )
    }
    
    private func lerp(from start: CGFloat, to end: CGFloat, t: Double) -> CGFloat {
        return CGFloat(Double(start) + (Double(end) - Double(start)) * t)
    }
}
