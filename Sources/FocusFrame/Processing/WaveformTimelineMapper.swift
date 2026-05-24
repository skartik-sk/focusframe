import Foundation

struct WaveformTimelineMapper {
    struct Options {
        var displayDuration: Double
        var audioDuration: Double
        var displaySampleCount: Int
        var editActions: [EditAction]
        var loops: Bool
        var muteCutRanges: Bool

        init(
            displayDuration: Double,
            audioDuration: Double,
            displaySampleCount: Int = 900,
            editActions: [EditAction] = [],
            loops: Bool = false,
            muteCutRanges: Bool = true
        ) {
            self.displayDuration = displayDuration
            self.audioDuration = audioDuration
            self.displaySampleCount = displaySampleCount
            self.editActions = editActions
            self.loops = loops
            self.muteCutRanges = muteCutRanges
        }
    }

    static func map(rawSamples: [Float], options: Options) -> [Float] {
        let count = max(1, options.displaySampleCount)
        guard !rawSamples.isEmpty,
              options.displayDuration.isFinite,
              options.displayDuration > 0,
              options.audioDuration.isFinite,
              options.audioDuration > 0 else {
            return []
        }

        return (0..<count).map { index in
            let progress = count == 1 ? 0 : Double(index) / Double(count - 1)
            let displayTime = progress * options.displayDuration
            guard let audioTime = audioTime(for: displayTime, options: options) else {
                return 0
            }
            return sample(at: audioTime, rawSamples: rawSamples, audioDuration: options.audioDuration)
        }
    }

    static func audioTime(for displayTime: Double, options: Options) -> Double? {
        let time = max(0, displayTime)

        if options.muteCutRanges,
           options.editActions.contains(where: { action in
               action.type == .cut && time >= action.startTime && time < action.endTime
           }) {
            return nil
        }

        if options.loops {
            return time.truncatingRemainder(dividingBy: options.audioDuration)
        }

        guard time <= options.audioDuration else {
            return nil
        }
        return time
    }

    private static func sample(at time: Double, rawSamples: [Float], audioDuration: Double) -> Float {
        guard rawSamples.count > 1 else {
            return rawSamples.first ?? 0
        }

        let progress = max(0, min(1, time / max(audioDuration, 0.001)))
        let exactIndex = progress * Double(rawSamples.count - 1)
        let lowerIndex = max(0, min(rawSamples.count - 1, Int(floor(exactIndex))))
        let upperIndex = max(0, min(rawSamples.count - 1, lowerIndex + 1))
        let fraction = Float(exactIndex - Double(lowerIndex))
        return rawSamples[lowerIndex] + (rawSamples[upperIndex] - rawSamples[lowerIndex]) * fraction
    }
}
