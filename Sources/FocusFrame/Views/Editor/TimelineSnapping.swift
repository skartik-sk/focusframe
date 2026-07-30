import Foundation

/// Magnetic snapping for timeline drags.
///
/// Given a proposed time and a set of candidate times (playhead, neighbouring clip
/// edges, ruler grid lines), returns the nearest candidate within a threshold, or the
/// original value when nothing is close enough. The threshold is expressed in
/// timeline-seconds and should be derived from pixels-per-second so the snap feel is
/// resolution-independent (a fixed pixel distance regardless of zoom level).
struct TimelineSnapResult {
    let time: Double
    let snapped: Bool
}

enum TimelineSnapper {
    static func snap(
        _ value: Double,
        candidates: [Double],
        thresholdSeconds: Double
    ) -> TimelineSnapResult {
        guard thresholdSeconds > 0, candidates.notEmpty else {
            return TimelineSnapResult(time: value, snapped: false)
        }
        var best = value
        var bestDelta = thresholdSeconds
        var snapped = false
        for candidate in candidates {
            let delta = abs(candidate - value)
            if delta <= bestDelta {
                bestDelta = delta
                best = candidate
                snapped = true
            }
        }
        return TimelineSnapResult(time: best, snapped: snapped)
    }
}

private extension Array {
    var notEmpty: Bool { !isEmpty }
}
