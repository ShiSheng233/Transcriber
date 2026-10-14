import TranscriberCore

/// Port of `enforce_segment_timeline` in the original `infer.py`.
public enum SegmentTimeline {
    /// Drops blank segments, sorts by time, makes each segment start no earlier
    /// than the previous one ends, caps its length, and drops it if nothing is left.
    public static func enforced(_ segments: [TimedText], maximumDuration: AudioTime?) -> [TimedText] {
        var normalized: [TimedText] = []
        for segment in segments.filter({ !$0.text.pythonStripped.isEmpty }).sortedByTime() {
            let start = max(segment.start, normalized.last?.end ?? segment.start)
            let end = cappedEnd(start: start, end: segment.end, maximumDuration: maximumDuration)
            guard end > start else {
                continue
            }
            normalized.append(TimedText(start: start, end: end, text: segment.text))
        }
        return normalized
    }

    /// `_max_segment_end`: no cap when the limit is missing or not positive.
    private static func cappedEnd(start: AudioTime, end: AudioTime, maximumDuration: AudioTime?) -> AudioTime {
        guard let maximumDuration, maximumDuration > .zero else {
            return end
        }
        return min(end, start + maximumDuration)
    }
}
