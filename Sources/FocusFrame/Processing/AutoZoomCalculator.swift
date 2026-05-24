import Foundation
import CoreGraphics

class AutoZoomCalculator {
    
    struct Config {
        var minClusterDistance: CGFloat = 360     // px between actions to keep one continuous focus
        var minClusterTimeGap: Double = 1.35      // seconds
        var groupNearbyClicks: Bool = true        // Hold through dense nearby clicks.
        var focusPadding: CGFloat = 0.12          // 12% render-time padding around focus area
        var zoomInDuration: Double = 0.55
        var holdAfterClickDuration: Double = 1.05
        var zoomOutDuration: Double = 0.55
        var idleThreshold: Double = 5.0           // seconds of no clicks = idle
        var contextGapThreshold: Double = .infinity // show full view if gap > this
        var debounceInterval: Double = 0.08       // only remove duplicate event-tap/AppKit reports
        var continuousZoomGap: Double = 0.65      // keep zoomed when generated blocks overlap or nearly touch
        var trackFocusWithinContinuousZoom: Bool = true
        var maxZoomScale: CGFloat = 1.45
        var easing: EasingType = .easeInOut
        var outputAspectRatio: CGFloat = 16.0 / 9.0
    }
    
    struct ActionAnchor {
        let timestamp: Double
        let position: CGPoint
        let clickType: CursorFrame.ClickType?
    }
    
    func calculateZoomSegments(
        from cursorRecording: CursorRecording,
        sourceRect: CGRect,
        config: Config = .init()
    ) -> [ZoomSegment] {
        // Step 1: Extract click anchors. Only click-down edges should create
        // zooms; held click states from older recordings should not flood the timeline.
        let clicks = CursorClickClassifier.clickDownFrames(from: cursorRecording.frames)
        
        guard !clicks.isEmpty else {
            return []
        }
        
        // Step 2: Debounce rapid clicks
        let anchors = debounce(clicks: clicks, interval: config.debounceInterval)
        
        guard !anchors.isEmpty else {
            return []
        }
        
        // Step 3: By default, nearby repeated clicks stay in one longer focus
        // segment so the recording does not pulse in/out around dense actions.
        // One-block-per-click remains available for explicit editable flows.
        let clusters = config.groupNearbyClicks
            ? cluster(
                anchors: anchors,
                maxDistance: config.minClusterDistance,
                maxTimeGap: config.minClusterTimeGap
            )
            : anchors.map { [$0] }
        
        guard !clusters.isEmpty else {
            return []
        }
        
        // Step 4: Create zoom segments from clusters
        var segments = clusters.map { cluster in
            makeZoomSegment(
                from: cluster,
                sourceRect: sourceRect,
                config: config
            )
        }
        
        // Step 5: Default auto zoom should not pulse out/in between dense
        // actions. Merge generated blocks that overlap or nearly touch; explicit
        // ungrouped mode still keeps separate editable blocks.
        segments = config.groupNearbyClicks
            ? mergeContinuousSegments(
                segments,
                sourceRect: sourceRect,
                maxGap: config.continuousZoomGap,
                trackFocus: config.trackFocusWithinContinuousZoom
            )
            : trimOverlappingSegments(segments)

        // Step 6: Add context (zoomed out) segments between clusters
        segments = insertContextSegments(
            segments,
            totalDuration: cursorRecording.frames.last?.timestamp ?? 0,
            sourceRect: sourceRect,
            config: config
        )
        
        return segments.sorted { $0.startTime < $1.startTime }
    }
    
    // MARK: - Debounce
    
    private func debounce(clicks: [CursorFrame], interval: Double) -> [ActionAnchor] {
        guard !clicks.isEmpty else { return [] }
        
        var anchors: [ActionAnchor] = []
        var lastAcceptedTime: Double = -interval - 1
        var lastAcceptedPosition: CGPoint = .zero
        
        for click in clicks {
            let timeDiff = click.timestamp - lastAcceptedTime
            let posDiff = BezierMath.distance(
                from: click.position,
                to: lastAcceptedPosition
            )
            
            // If this click is very close in time and position to the last one, skip it
            if timeDiff < interval && posDiff < 50 {
                continue
            }
            
            // Add this new click
            anchors.append(ActionAnchor(
                timestamp: click.timestamp,
                position: click.position,
                clickType: click.clickType
            ))
            
            lastAcceptedTime = click.timestamp
            lastAcceptedPosition = click.position
        }
        
        return anchors
    }

    // MARK: - Clustering
    
    private func cluster(
        anchors: [ActionAnchor],
        maxDistance: CGFloat,
        maxTimeGap: Double
    ) -> [[ActionAnchor]] {
        guard !anchors.isEmpty else { return [] }
        
        var clusters: [[ActionAnchor]] = []
        var currentCluster: [ActionAnchor] = [anchors[0]]
        
        for i in 1..<anchors.count {
            let previous = anchors[i - 1]
            let current = anchors[i]
            
            let distance = BezierMath.distance(
                from: previous.position,
                to: current.position
            )
            
            let timeGap = current.timestamp - previous.timestamp
            
            // If close in both space and time, add to current cluster
            if distance < maxDistance && timeGap < maxTimeGap {
                currentCluster.append(current)
            } else {
                // Start new cluster
                clusters.append(currentCluster)
                currentCluster = [current]
            }
        }
        
        // Add final cluster
        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }
        
        return clusters
    }

    private func trimOverlappingSegments(_ segments: [ZoomSegment]) -> [ZoomSegment] {
        guard segments.count > 1 else { return segments }

        var sorted = segments.sorted { $0.startTime < $1.startTime }

        for index in 0..<(sorted.count - 1) {
            let nextStart = sorted[index + 1].startTime
            guard sorted[index].endTime > nextStart else { continue }

            let availableDuration = max(0, nextStart - sorted[index].startTime)
            sorted[index].endTime = max(sorted[index].startTime, nextStart)
            sorted[index].zoomInDuration = min(sorted[index].zoomInDuration, availableDuration * 0.6)
            sorted[index].zoomOutDuration = min(sorted[index].zoomOutDuration, availableDuration * 0.4)
        }

        return sorted
    }

    private func mergeContinuousSegments(
        _ segments: [ZoomSegment],
        sourceRect: CGRect,
        maxGap: Double,
        trackFocus: Bool
    ) -> [ZoomSegment] {
        guard segments.count > 1 else { return segments }

        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var merged: [ZoomSegment] = []
        var current = sorted[0]

        for next in sorted.dropFirst() {
            let gap = next.startTime - current.endTime
            if gap <= maxGap {
                let keyframes = trackFocus ? mergedTrackingKeyframes(current, next) : nil
                current.endTime = max(current.endTime, next.endTime)
                current.zoomRect = current.zoomRect.union(next.zoomRect).intersection(sourceRect)
                current.keyframes = keyframes
                current.zoomInDuration = min(current.zoomInDuration, max(0.35, current.duration * 0.22))
                current.zoomOutDuration = min(max(current.zoomOutDuration, next.zoomOutDuration), max(0.4, current.duration * 0.22))
            } else {
                merged.append(current)
                current = next
            }
        }

        merged.append(current)
        return merged
    }

    private func mergedTrackingKeyframes(_ lhs: ZoomSegment, _ rhs: ZoomSegment) -> [ZoomKeyframe]? {
        let combined = (trackingKeyframes(for: lhs) + trackingKeyframes(for: rhs))
            .sorted { $0.time < $1.time }
        guard combined.count > 1 else { return combined.isEmpty ? nil : combined }

        var unique: [ZoomKeyframe] = []
        for keyframe in combined {
            if let last = unique.last, abs(last.time - keyframe.time) < 0.03 {
                unique[unique.count - 1] = keyframe
            } else {
                unique.append(keyframe)
            }
        }
        return unique
    }

    private func trackingKeyframes(for segment: ZoomSegment) -> [ZoomKeyframe] {
        if let keyframes = segment.keyframes, !keyframes.isEmpty {
            return keyframes
        }
        return [ZoomKeyframe(time: segment.startTime + segment.zoomInDuration, zoomRect: segment.zoomRect)]
    }
    
    // MARK: - Make Zoom Segment
    
    private func makeZoomSegment(
        from cluster: [ActionAnchor],
        sourceRect: CGRect,
        config: Config
    ) -> ZoomSegment {
        // Calculate bounding box of all action positions
        guard let first = cluster.first, let last = cluster.last else {
            return ZoomSegment(
                id: UUID(),
                startTime: 0,
                endTime: 1,
                zoomRect: sourceRect,
                focusPadding: config.focusPadding,
                zoomInDuration: config.zoomInDuration,
                zoomOutDuration: config.zoomOutDuration,
                easingFunction: config.easing,
                source: .automatic
            )
        }
        
        let zoomRect = makeZoomRect(
            containing: cluster.map(\.position),
            sourceRect: sourceRect,
            config: config
        )
        
        // Calculate timing
        let startTime = max(0, first.timestamp - config.zoomInDuration)
        let endTime = last.timestamp + config.holdAfterClickDuration + config.zoomOutDuration
        let keyframes: [ZoomKeyframe]? = config.trackFocusWithinContinuousZoom
            ? cluster.map {
                ZoomKeyframe(
                    time: $0.timestamp,
                    zoomRect: makeZoomRect(containing: [$0.position], sourceRect: sourceRect, config: config)
                )
            }
            : nil
        
        return ZoomSegment(
            id: UUID(),
            startTime: startTime,
            endTime: endTime,
            zoomRect: zoomRect,
            focusPadding: config.focusPadding,
            zoomInDuration: config.zoomInDuration,
            zoomOutDuration: config.zoomOutDuration,
            easingFunction: config.easing,
            source: .automatic,
            keyframes: keyframes
        )
    }

    private func makeZoomRect(
        containing positions: [CGPoint],
        sourceRect: CGRect,
        config: Config
    ) -> CGRect {
        guard let first = positions.first else { return sourceRect }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for position in positions {
            minX = min(minX, position.x)
            maxX = max(maxX, position.x)
            minY = min(minY, position.y)
            maxY = max(maxY, position.y)
        }

        let maxZoomScale = max(config.maxZoomScale, 1.0)
        let paddingMultiplier = max(1, 1 + config.focusPadding * 2)
        let minWidthForScale = sourceRect.width / maxZoomScale / paddingMultiplier
        let minHeightForScale = sourceRect.height / maxZoomScale / paddingMultiplier
        let minSize: CGFloat = min(minWidthForScale, minHeightForScale)
        let width = max(maxX - minX, minSize)
        let height = max(maxY - minY, minSize)
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        var zoomRect = CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )

        let currentAspectRatio = zoomRect.width / zoomRect.height
        if abs(currentAspectRatio - config.outputAspectRatio) > 0.01 {
            if currentAspectRatio > config.outputAspectRatio {
                let newHeight = zoomRect.width / config.outputAspectRatio
                let extraY = newHeight - zoomRect.height
                zoomRect.origin.y -= extraY / 2
                zoomRect.size.height = newHeight
            } else {
                let newWidth = zoomRect.height * config.outputAspectRatio
                let extraX = newWidth - zoomRect.width
                zoomRect.origin.x -= extraX / 2
                zoomRect.size.width = newWidth
            }
        }

        zoomRect.origin.x = max(zoomRect.origin.x, sourceRect.origin.x)
        zoomRect.origin.y = max(zoomRect.origin.y, sourceRect.origin.y)

        if zoomRect.maxX > sourceRect.maxX {
            let shift = zoomRect.maxX - sourceRect.maxX
            zoomRect.origin.x = max(sourceRect.origin.x, zoomRect.origin.x - shift)
        }

        if zoomRect.maxY > sourceRect.maxY {
            let shift = zoomRect.maxY - sourceRect.maxY
            zoomRect.origin.y = max(sourceRect.origin.y, zoomRect.origin.y - shift)
        }

        return zoomRect
    }
    
    // MARK: - Insert Context Segments
    
    private func insertContextSegments(
        _ segments: [ZoomSegment],
        totalDuration: Double,
        sourceRect: CGRect,
        config: Config
    ) -> [ZoomSegment] {
        var result: [ZoomSegment] = []

        guard !segments.isEmpty else { return result }

        let fullViewRect = sourceRect

        // Add full view at the beginning if needed
        if segments[0].startTime > config.contextGapThreshold {
            result.append(ZoomSegment(
                id: UUID(),
                startTime: 0,
                endTime: segments[0].startTime,
                zoomRect: fullViewRect,
                focusPadding: 0,
                zoomInDuration: 0,
                zoomOutDuration: 0,
                easingFunction: .linear,
                source: .automatic
            ))
        }

        // Add context between segments
        for i in 0..<(segments.count - 1) {
            result.append(segments[i])

            let currentEnd = segments[i].endTime
            let nextStart = segments[i + 1].startTime
            let gap = nextStart - currentEnd

            if gap > config.contextGapThreshold {
                result.append(ZoomSegment(
                    id: UUID(),
                    startTime: currentEnd,
                    endTime: nextStart,
                    zoomRect: fullViewRect,
                    focusPadding: 0,
                    zoomInDuration: 0,
                    zoomOutDuration: 0,
                    easingFunction: .linear,
                    source: .automatic
                ))
            }
        }

        guard let lastSegment = segments.last else {
            return result
        }

        // Add last segment
        result.append(lastSegment)

        // Add full view at the end if needed
        let lastEnd = lastSegment.endTime
        if totalDuration - lastEnd > config.contextGapThreshold {
            result.append(ZoomSegment(
                id: UUID(),
                startTime: lastEnd,
                endTime: totalDuration,
                zoomRect: fullViewRect,
                focusPadding: 0,
                zoomInDuration: 0,
                zoomOutDuration: 0,
                easingFunction: .linear,
                source: .automatic
            ))
        }

        return result
    }
}
