import Foundation
import CoreGraphics

enum TimelineEventSampler {
    static func sampleKeyEvents(
        _ events: [KeyPressEvent],
        duration: Double,
        width: CGFloat,
        minimumPixelSpacing: CGFloat = 28
    ) -> [KeyPressEvent] {
        guard !events.isEmpty else { return [] }
        let duration = max(duration, 0.001)
        let width = max(width, 1)
        let bucketCount = max(1, Int(width / max(minimumPixelSpacing, 1)))
        guard events.count > bucketCount else {
            return events.sorted { $0.timestamp < $1.timestamp }
        }

        var sampled: [KeyPressEvent] = []
        var occupiedBuckets = Set<Int>()

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let progress = max(0, min(1, event.timestamp / duration))
            let bucket = max(0, min(bucketCount - 1, Int(progress * Double(bucketCount))))
            if occupiedBuckets.insert(bucket).inserted {
                sampled.append(event)
            }
        }

        return sampled
    }
}
