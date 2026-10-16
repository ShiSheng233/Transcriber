/// Aegisub's timing post-processor for machine-made times: pad lines with a
/// lead-in and lead-out, snap starts and ends to nearby speech boundaries,
/// then close small gaps between neighbours. Each step can be off.
public enum TimingPostProcessing {
    public struct Settings: Hashable, Sendable, Codable {
        /// Added before each start; `nil` skips the step.
        public var leadIn: AudioTime?
        /// Added after each end; `nil` skips the step.
        public var leadOut: AudioTime?
        /// Neighbours closer than this (gap or overlap) are made to touch;
        /// `nil` skips the step.
        public var adjacentThreshold: AudioTime?
        /// Where two neighbours meet, from 0 (the first line's end stays) to
        /// 1 (the second line's start stays).
        public var adjacentBias: Double
        /// How far a start may move to reach where speech starts; `nil` skips.
        public var startSnapDistance: AudioTime?
        /// How far an end may move to reach where speech ends; `nil` skips.
        public var endSnapDistance: AudioTime?

        public init(
            leadIn: AudioTime?,
            leadOut: AudioTime?,
            adjacentThreshold: AudioTime?,
            adjacentBias: Double,
            startSnapDistance: AudioTime?,
            endSnapDistance: AudioTime?
        ) {
            self.leadIn = leadIn
            self.leadOut = leadOut
            self.adjacentThreshold = adjacentThreshold
            self.adjacentBias = adjacentBias
            self.startSnapDistance = startSnapDistance
            self.endSnapDistance = endSnapDistance
        }

        /// Aegisub's defaults (`Audio/Lead/IN` 200, `OUT` 300,
        /// `Tool/Timing Post Processor/Threshold/Adjacent` 300), closing gaps
        /// by extending the earlier line, with snaps a little wider at the end,
        /// where speech trails off.
        public static let aegisub = Settings(
            leadIn: AudioTime(milliseconds: 200),
            leadOut: AudioTime(milliseconds: 300),
            adjacentThreshold: AudioTime(milliseconds: 300),
            adjacentBias: 1,
            startSnapDistance: AudioTime(milliseconds: 100),
            endSnapDistance: AudioTime(milliseconds: 150)
        )
    }

    /// Processes the chosen lines (all for an empty `indices`). Lead-in and
    /// lead-out stop at the neighbouring line so they add no overlap.
    /// - Parameter speech: where speech starts and ends, for snapping.
    public static func processed(
        _ indices: [Int],
        in lines: [TimedText],
        settings: Settings,
        speech: [SpeechSpan] = []
    ) -> SubtitleEditing.Outcome {
        let chosen = indices.isEmpty ? Array(lines.indices) : indices.filter(lines.indices.contains).sorted()
        let chosenSet = Set(chosen)
        var result = lines
        let order = lines.indices.sorted { (lines[$0].start, $0) < (lines[$1].start, $1) }

        // Lead-ins first, so each lead-out stops at the next line's padded start.
        if let leadIn = settings.leadIn {
            for (position, index) in order.enumerated() where chosenSet.contains(index) {
                let previousEnd = position > 0 ? result[order[position - 1]].end : AudioTime.zero
                let padded = result[index].start > leadIn ? result[index].start - leadIn : .zero
                result[index].start = max(padded, min(previousEnd, result[index].start))
            }
        }
        if let leadOut = settings.leadOut {
            for (position, index) in order.enumerated() where chosenSet.contains(index) {
                let padded = result[index].end + leadOut
                if position + 1 < order.count {
                    let nextStart = result[order[position + 1]].start
                    result[index].end = min(padded, max(nextStart, result[index].end))
                } else {
                    result[index].end = padded
                }
            }
        }

        if !speech.isEmpty {
            let starts = speech.map(\.start).sorted()
            let ends = speech.map(\.end).sorted()
            for index in chosen {
                if let distance = settings.startSnapDistance,
                   let start = nearest(to: result[index].start, in: starts, within: distance), start < result[index].end {
                    result[index].start = start
                }
                if let distance = settings.endSnapDistance,
                   let end = nearest(to: result[index].end, in: ends, within: distance), end > result[index].start {
                    result[index].end = end
                }
            }
        }

        if let threshold = settings.adjacentThreshold {
            for (position, index) in order.enumerated().dropLast() {
                let next = order[position + 1]
                guard chosenSet.contains(index) || chosenSet.contains(next) else {
                    continue
                }
                let end = result[index].end
                let start = result[next].start
                let distance = end > start ? end - start : start - end
                guard distance > .zero && distance < threshold else {
                    continue
                }
                let low = min(end, start)
                let meeting = low + AudioTime(samples: Int((Double(distance.samples) * settings.adjacentBias).rounded()))
                result[index].end = max(meeting, result[index].start)
                result[next].start = min(meeting, result[next].end)
            }
        }

        return SubtitleEditing.Outcome(lines: result, selection: indices.isEmpty ? [] : chosen)
    }

    /// The closest of the sorted `times` no further than `distance` away.
    static func nearest(to time: AudioTime, in times: [AudioTime], within distance: AudioTime) -> AudioTime? {
        var low = 0
        var high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter(times.indices.contains).map { times[$0] }
        let best = candidates.min { abs(($0 - time).samples) < abs(($1 - time).samples) }
        return best.flatMap { abs(($0 - time).samples) <= distance.samples ? $0 : nil }
    }
}
