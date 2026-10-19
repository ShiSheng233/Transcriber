/// Aegisub's timing post-processor for machine-made times: pad lines with a
/// lead-in and lead-out, snap starts and ends to nearby speech boundaries,
/// close small gaps between neighbours, then snap to nearby keyframes. Each
/// step can be off. Speech snapping is ours; the rest run in Aegisub's order
/// (`DialogTimingProcessor::Process`), keyframes last so a scene change
/// wins over the gap closing.
public enum TimingPostProcessing {
    /// How far a start or end may move to reach a keyframe, by direction.
    public struct KeyframeSnap: Hashable, Sendable, Codable {
        /// A start this close before a keyframe moves later onto it.
        public var beforeStart: AudioTime
        /// A start this close after a keyframe moves earlier onto it.
        public var afterStart: AudioTime
        /// An end this close before the frame before a keyframe moves later.
        public var beforeEnd: AudioTime
        /// An end this close after the frame before a keyframe moves earlier.
        public var afterEnd: AudioTime

        public init(beforeStart: AudioTime, afterStart: AudioTime, beforeEnd: AudioTime, afterEnd: AudioTime) {
            self.beforeStart = beforeStart
            self.afterStart = afterStart
            self.beforeEnd = beforeEnd
            self.afterEnd = afterEnd
        }

        /// Aegisub's defaults (src/libresrc/default_config.json,
        /// `Tool/Timing Post Processor/Threshold/Key Start Before` 200,
        /// `Key Start After` 150, `Key End Before` 200, `Key End After` 250;
        /// milliseconds, compared with the line's times).
        public static let aegisub = KeyframeSnap(
            beforeStart: AudioTime(milliseconds: 200),
            afterStart: AudioTime(milliseconds: 150),
            beforeEnd: AudioTime(milliseconds: 200),
            afterEnd: AudioTime(milliseconds: 250)
        )
    }

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
        /// Snapping to the video's keyframes; `nil` skips the step.
        public var keyframeSnap: KeyframeSnap?

        public init(
            leadIn: AudioTime?,
            leadOut: AudioTime?,
            adjacentThreshold: AudioTime?,
            adjacentBias: Double,
            startSnapDistance: AudioTime?,
            endSnapDistance: AudioTime?,
            keyframeSnap: KeyframeSnap? = nil
        ) {
            self.leadIn = leadIn
            self.leadOut = leadOut
            self.adjacentThreshold = adjacentThreshold
            self.adjacentBias = adjacentBias
            self.startSnapDistance = startSnapDistance
            self.endSnapDistance = endSnapDistance
            self.keyframeSnap = keyframeSnap
        }

        /// Aegisub's defaults (`Audio/Lead/IN` 200, `OUT` 300,
        /// `Tool/Timing Post Processor/Threshold/Adjacent` 300), closing gaps
        /// by extending the earlier line, with snaps a little wider at the end,
        /// where speech trails off, and Aegisub's keyframe thresholds.
        public static let aegisub = Settings(
            leadIn: AudioTime(milliseconds: 200),
            leadOut: AudioTime(milliseconds: 300),
            adjacentThreshold: AudioTime(milliseconds: 300),
            adjacentBias: 1,
            startSnapDistance: AudioTime(milliseconds: 100),
            endSnapDistance: AudioTime(milliseconds: 150),
            keyframeSnap: .aegisub
        )
    }

    /// Processes the chosen lines (all for an empty `indices`). Lead-in and
    /// lead-out stop at the neighbouring line so they add no overlap.
    /// - Parameters:
    ///   - speech: where speech starts and ends, for snapping.
    ///   - video: the frames and keyframes, for snapping; `nil` skips it.
    public static func processed(
        _ indices: [Int],
        in lines: [TimedText],
        settings: Settings,
        speech: [SpeechSpan] = [],
        video: VideoFrames? = nil
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

        if let snap = settings.keyframeSnap, let video {
            for index in chosen {
                result[index] = snapped(result[index], toKeyframesOf: video, within: snap)
            }
        }

        return SubtitleEditing.Outcome(lines: result, selection: indices.isEmpty ? [] : chosen)
    }

    /// Aegisub's keyframe snapping: a start moves onto the nearest keyframe,
    /// an end onto the end of the frame before it, when within the
    /// threshold for that direction. A start already on the keyframe, or an
    /// end on the frame before one, stays as it is. Never past the other edge.
    static func snapped(_ line: TimedText, toKeyframesOf video: VideoFrames, within snap: KeyframeSnap) -> TimedText {
        var line = line
        let startFrame = video.firstFrame(shownFrom: line.start)
        let startKeyframe = video.closestKeyframe(to: startFrame)
        let start = video.startTime(ofFrame: startKeyframe)
        let startMoves = (startKeyframe > startFrame && start - line.start <= snap.beforeStart)
            || (startKeyframe < startFrame && line.start - start <= snap.afterStart)
        if startMoves, start < line.end {
            line.start = start
        }
        let endFrame = video.lastFrame(shownBefore: line.end)
        let frameBeforeKeyframe = video.closestKeyframe(to: endFrame) - 1
        let end = video.endTime(ofFrame: frameBeforeKeyframe)
        let endMoves = (frameBeforeKeyframe > endFrame && end - line.end <= snap.beforeEnd)
            || (frameBeforeKeyframe < endFrame && line.end - end <= snap.afterEnd)
        if endMoves, end > line.start {
            line.end = end
        }
        return line
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
