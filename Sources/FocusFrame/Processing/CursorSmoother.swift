import Foundation
import CoreGraphics

class CursorSmoother {
    
    func smooth(
        frames: [CursorFrame],
        style: CursorMovementStyle = .default,
        targetFPS: Double = 60
    ) -> [CursorFrame] {
        let safeFrames = frames
            .filter { frame in
                frame.timestamp.isFinite &&
                frame.position.x.isFinite &&
                frame.position.y.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard !safeFrames.isEmpty else { return [] }
        guard safeFrames.count > 1 else { return safeFrames }
        
        // Step 1: Resample to target FPS
        let resampled = resample(frames: safeFrames, targetFPS: targetFPS)
        
        guard resampled.count > 2 else { return resampled }
        
        // Step 2: Extract positions array
        var points = resampled.map { $0.position }
        
        // Step 3: Apply Chaikin iterations based on style
        let iterations: Int
        switch style {
        case .rapid: iterations = 0
        case .quick: iterations = 1
        case .default: iterations = 2
        case .slow: iterations = 3
        }
        
        for _ in 0..<iterations {
            points = chaikinCut(points: points)
        }
        
        // Step 4: Apply Gaussian smoothing for the smoother motion modes
        if style == .default {
            points = BezierMath.gaussianSmooth(points: points, sigma: 0.75)
        } else if style == .slow {
            points = BezierMath.gaussianSmooth(points: points, sigma: 2.0)
        }
        
        // Step 5: Reconstruct frames with smooth positions
        let smoothedFrames = interpolateFrames(
            originalFrames: resampled,
            smoothedPoints: points
        )
        
        // Step 6: Detect and handle static periods
        return markStaticPeriods(frames: smoothedFrames)
    }
    
    private func resample(frames: [CursorFrame], targetFPS: Double) -> [CursorFrame] {
        guard !frames.isEmpty else { return [] }
        let safeFPS = targetFPS.isFinite && targetFPS > 0 ? targetFPS : 60
        
        let duration = frames.last?.timestamp ?? 0
        let frameInterval = 1.0 / safeFPS
        let targetDuration = max(duration, frameInterval)
        let targetFrameCount = Int(floor(targetDuration * safeFPS)) + 1
        
        guard targetFrameCount > 0 else { return frames }
        
        var resampled: [CursorFrame] = []
        var frameIndex = 0
        let clickEvents = frames.filter { $0.clickType != nil || $0.isClicking }
        var clickEventIndex = 0
        
        for i in 0..<targetFrameCount {
            let targetTime = Double(i) * frameInterval
            
            while frameIndex < frames.count - 1 && frames[frameIndex + 1].timestamp <= targetTime {
                frameIndex += 1
            }
            
            let frame1 = frames[frameIndex]
            let clickState = clickStateNear(
                targetTime,
                clickEvents: clickEvents,
                interval: frameInterval,
                searchStart: &clickEventIndex
            )

            if frameIndex == frames.count - 1 || targetTime >= (frames.last?.timestamp ?? 0) {
                resampled.append(CursorFrame(
                    timestamp: targetTime,
                    position: frames.last?.position ?? frame1.position,
                    isClicking: clickState?.isClicking ?? false,
                    clickType: clickState?.clickType,
                    scrollDelta: frames.last?.scrollDelta ?? frame1.scrollDelta
                ))
            } else {
                let frame2 = frames[frameIndex + 1]
                let frameDuration = frame2.timestamp - frame1.timestamp
                let t = frameDuration > 0 ? (targetTime - frame1.timestamp) / frameDuration : 0
                
                let position = BezierMath.lerpPoint(
                    from: frame1.position,
                    to: frame2.position,
                    t: t
                )
                
                let scrollDelta = BezierMath.lerp(
                    from: frame1.scrollDelta ?? 0,
                    to: frame2.scrollDelta ?? 0,
                    t: t
                )
                
                resampled.append(CursorFrame(
                    timestamp: targetTime,
                    position: position,
                    isClicking: clickState?.isClicking ?? false,
                    clickType: clickState?.clickType,
                    scrollDelta: scrollDelta == 0 ? nil : scrollDelta
                ))
            }
        }
        
        return resampled
    }

    private func clickStateNear(
        _ targetTime: Double,
        clickEvents: [CursorFrame],
        interval: Double,
        searchStart: inout Int
    ) -> (clickType: CursorFrame.ClickType?, isClicking: Bool)? {
        guard !clickEvents.isEmpty else { return nil }
        let tolerance = max(0.001, interval * 0.55)

        while searchStart < clickEvents.count,
              clickEvents[searchStart].timestamp < targetTime - tolerance {
            searchStart += 1
        }

        var best: CursorFrame?
        var bestDistance = Double.greatestFiniteMagnitude
        var index = searchStart
        while index < clickEvents.count {
            let click = clickEvents[index]
            let distance = abs(click.timestamp - targetTime)
            guard distance <= tolerance else {
                if click.timestamp > targetTime + tolerance { break }
                index += 1
                continue
            }
            if distance < bestDistance {
                best = click
                bestDistance = distance
            }
            index += 1
        }

        guard let click = best else {
            return nil
        }
        guard let clickType = click.clickType else {
            return (nil, click.isClicking)
        }
        let isClicking: Bool
        switch clickType {
        case .leftDown, .rightDown:
            isClicking = true
        case .leftUp, .rightUp:
            isClicking = false
        case .other:
            isClicking = click.isClicking
        }
        return (clickType, isClicking)
    }
    
    private func chaikinCut(points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        
        var smoothed: [CGPoint] = []
        smoothed.append(points[0])
        
        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            
            let q = CGPoint(
                x: 0.75 * p0.x + 0.25 * p1.x,
                y: 0.75 * p0.y + 0.25 * p1.y
            )
            
            let r = CGPoint(
                x: 0.25 * p0.x + 0.75 * p1.x,
                y: 0.25 * p0.y + 0.75 * p1.y
            )
            
            smoothed.append(q)
            smoothed.append(r)
        }
        
        if let lastPoint = points.last {
            smoothed.append(lastPoint)
        }
        return smoothed
    }
    
    private func interpolateFrames(
        originalFrames: [CursorFrame],
        smoothedPoints: [CGPoint]
    ) -> [CursorFrame] {
        var result: [CursorFrame] = []
        
        for (index, frame) in originalFrames.enumerated() {
            let pointIndex = Int(Double(index) * Double(smoothedPoints.count) / Double(originalFrames.count))
            let clampedIndex = min(pointIndex, smoothedPoints.count - 1)
            
            result.append(CursorFrame(
                timestamp: frame.timestamp,
                position: smoothedPoints[clampedIndex],
                isClicking: frame.isClicking,
                clickType: frame.clickType,
                scrollDelta: frame.scrollDelta
            ))
        }
        
        return result
    }
    
    private func markStaticPeriods(frames: [CursorFrame]) -> [CursorFrame] {
        var framesWithStatic: [CursorFrame] = []
        var lastSignificantMoveTime: Double = 0
        let staticThreshold: Double = 0.5
        let moveThreshold: CGFloat = 2.0

        for (index, frame) in frames.enumerated() {
            let isStatic: Bool

            if index > 0 {
                let prevFrame = frames[index - 1]
                let timeDiff = frame.timestamp - prevFrame.timestamp
                let distance = BezierMath.distance(
                    from: prevFrame.position,
                    to: frame.position
                )

                if distance < moveThreshold && timeDiff > 0 {
                    isStatic = frame.timestamp - lastSignificantMoveTime > staticThreshold
                } else {
                    lastSignificantMoveTime = frame.timestamp
                    isStatic = false
                }
            } else {
                isStatic = false
            }

            if isStatic {
                framesWithStatic.append(CursorFrame(
                    timestamp: frame.timestamp,
                    position: frame.position,
                    isClicking: frame.isClicking,
                    clickType: frame.clickType,
                    scrollDelta: frame.scrollDelta
                ))
            } else {
                lastSignificantMoveTime = frame.timestamp
                framesWithStatic.append(frame)
            }
        }

        return framesWithStatic
    }
}
