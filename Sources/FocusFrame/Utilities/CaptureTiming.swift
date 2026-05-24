import AVFoundation

enum CaptureTiming {
    static func adjustedPresentationTime(
        timestamp: CMTime,
        firstSampleTime: CMTime,
        accumulatedPauseDuration: CMTime
    ) -> CMTime {
        let adjustedTime = CMTimeSubtract(
            CMTimeSubtract(timestamp, firstSampleTime),
            accumulatedPauseDuration
        )
        guard adjustedTime.isValid,
              adjustedTime.isNumeric,
              adjustedTime.seconds.isFinite,
              adjustedTime.seconds >= 0 else {
            return .zero
        }
        return adjustedTime
    }
}
