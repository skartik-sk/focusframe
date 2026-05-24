import Foundation
import CoreGraphics

struct BezierMath {
    
    // Cubic Bezier interpolation between two values
    static func cubicBezierInterpolate(
        p0: Double,
        p1: Double,
        p2: Double,
        p3: Double,
        t: Double
    ) -> Double {
        let oneMinusT = 1.0 - t
        let oneMinusTCubed = oneMinusT * oneMinusT * oneMinusT
        let tCubed = t * t * t
        
        return (oneMinusTCubed * p0) +
               (3.0 * oneMinusT * oneMinusT * t * p1) +
               (3.0 * oneMinusT * t * t * p2) +
               (tCubed * p3)
    }
    
    // Quadratic Bezier interpolation (for smoothing)
    static func quadraticBezierInterpolate(
        p0: CGPoint,
        p1: CGPoint,
        p2: CGPoint,
        t: Double
    ) -> CGPoint {
        let oneMinusT = 1.0 - t
        
        return CGPoint(
            x: (oneMinusT * oneMinusT * p0.x) +
                (2.0 * oneMinusT * t * p1.x) +
                (t * t * p2.x),
            y: (oneMinusT * oneMinusT * p0.y) +
                (2.0 * oneMinusT * t * p1.y) +
                (t * t * p2.y)
        )
    }
    
    // Linear interpolation
    static func lerp(from start: CGFloat, to end: CGFloat, t: Double) -> CGFloat {
        return CGFloat(Double(start) + (Double(end) - Double(start)) * t)
    }
    
    // Point linear interpolation
    static func lerpPoint(from start: CGPoint, to end: CGPoint, t: Double) -> CGPoint {
        return CGPoint(
            x: lerp(from: start.x, to: end.x, t: t),
            y: lerp(from: start.y, to: end.y, t: t)
        )
    }
    
    // Calculate distance between two points
    static func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        return sqrt(dx * dx + dy * dy)
    }
    
    // Clamp a value to a range
    static func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        if value < min { return min }
        if value > max { return max }
        return value
    }
    
    // Normalize a value to 0-1 range
    static func normalize(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard max != min else { return 0.5 }
        return (value - min) / (max - min)
    }
    
    // Easing functions for animations
    enum Easing {
        static func easeInOut(_ t: Double) -> Double {
            return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
        }
        
        static func easeIn(_ t: Double) -> Double {
            return t * t
        }
        
        static func easeOut(_ t: Double) -> Double {
            return t * (2 - t)
        }
        
        static func linear(_ t: Double) -> Double {
            return t
        }
        
        static func spring(_ t: Double) -> Double {
            return 1 - pow(1 - t, 3) * cos(t * .pi * 0.5)
        }
    }
    
    // Calculate control points for smooth curve through points
    static func calculateControlPoints(
        points: [CGPoint]
    ) -> ([CGPoint], [CGPoint]) {
        guard points.count >= 2 else { return ([], []) }
        
        let count = points.count
        var controlPoints1: [CGPoint] = Array(repeating: .zero, count: count)
        var controlPoints2: [CGPoint] = Array(repeating: .zero, count: count)
        
        // Special case: only two points - straight line
        if count == 2 {
            let p0 = points[0]
            let p1 = points[1]
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            controlPoints1[0] = CGPoint(x: p0.x + dx / 3, y: p0.y + dy / 3)
            controlPoints2[0] = CGPoint(x: p1.x - dx / 3, y: p1.y - dy / 3)
            return (controlPoints1, controlPoints2)
        }
        
        // Calculate tangents
        var tangents: [CGPoint] = Array(repeating: .zero, count: count)
        
        // Start and end points
        tangents[0] = CGPoint(
            x: points[1].x - points[0].x,
            y: points[1].y - points[0].y
        )
        tangents[count - 1] = CGPoint(
            x: points[count - 1].x - points[count - 2].x,
            y: points[count - 1].y - points[count - 2].y
        )
        
        // Interior points - use Catmull-Rom spline
        for i in 1..<(count - 1) {
            let prev = points[i - 1]
            let _ = points[i]
            let next = points[i + 1]
            
            let tx = (next.x - prev.x) * 0.5
            let ty = (next.y - prev.y) * 0.5
            
            tangents[i] = CGPoint(x: tx, y: ty)
        }
        
        // Calculate control points from tangents
        for i in 0..<(count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let t0 = tangents[i]
            let t1 = tangents[i + 1]
            
            controlPoints1[i] = CGPoint(x: p0.x + t0.x / 3, y: p0.y + t0.y / 3)
            controlPoints2[i] = CGPoint(x: p1.x - t1.x / 3, y: p1.y - t1.y / 3)
        }
        
        return (controlPoints1, controlPoints2)
    }
    
    // Gaussian smoothing for noise reduction
    static func gaussianSmooth(points: [CGPoint], sigma: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        
        let kernelSize = Int(ceil(3.0 * sigma))
        let radius = kernelSize / 2
        
        if radius == 0 || points.count <= 1 {
            return points
        }
        
        // Create Gaussian kernel
        var kernel: [Double] = []
        var sum = 0.0
        
        for i in -radius...radius {
            let value = exp(-0.5 * (Double(i) / sigma) * (Double(i) / sigma))
            kernel.append(value)
            sum += value
        }
        
        // Normalize kernel
        kernel = kernel.map { $0 / sum }
        
        // Apply convolution
        var smoothed: [CGPoint] = []
        
        for (index, _) in points.enumerated() {
            var weightedX = 0.0
            var weightedY = 0.0
            
            for i in -radius...radius {
                let sampleIndex = clamp(index + i, min: 0, max: points.count - 1)
                let weight = kernel[i + radius]
                weightedX += Double(points[sampleIndex].x) * weight
                weightedY += Double(points[sampleIndex].y) * weight
            }
            
            smoothed.append(CGPoint(x: CGFloat(weightedX), y: CGFloat(weightedY)))
        }
        
        return smoothed
    }
}
