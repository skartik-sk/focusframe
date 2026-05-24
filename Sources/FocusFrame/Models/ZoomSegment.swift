import Foundation
import CoreGraphics

struct ZoomSegment: Codable, Identifiable, Equatable {
    let id: UUID

    // Timing (in seconds from recording start)
    var startTime: Double
    var endTime: Double

    // The rectangular region to zoom INTO (in source coordinates)
    var zoomRect: CGRect

    // How much padding around the focus area (as fraction of zoomRect size)
    var focusPadding: CGFloat  // default 0.12 for automatic zoom, 0.2 for manual zoom

    // Transition settings
    var zoomInDuration: Double     // seconds to zoom in
    var zoomOutDuration: Double    // seconds to zoom out
    var easingFunction: EasingType // how the animation interpolates

    // Source
    var source: ZoomSource         // .automatic or .manual
    var keyframes: [ZoomKeyframe]? = nil // optional render-time focus path for continuous automatic zooms

    var duration: Double { endTime - startTime }

    // The full rect to show in the output frame (zoomRect + padding)
    var paddedRect: CGRect {
        zoomRect.insetBy(dx: -zoomRect.width * focusPadding,
                         dy: -zoomRect.height * focusPadding)
    }
}

struct ZoomKeyframe: Codable, Equatable {
    let time: Double
    let zoomRect: CGRect
}

enum EasingType: String, Codable {
    case easeInOut     // default cubic bezier
    case easeIn
    case easeOut
    case linear
    case spring        // slightly overshoots then settles

    func apply(_ t: Double) -> Double {
        switch self {
        case .easeInOut: return t < 0.5 ? 2*t*t : -1+(4-2*t)*t
        case .easeIn:    return t * t
        case .easeOut:   return t * (2 - t)
        case .linear:    return t
        case .spring:    return 1 - pow(1 - t, 3) * cos(t * .pi * 0.5)
        }
    }
}

enum ZoomSource: String, Codable {
    case automatic
    case manual
}
