import TranscriberCore

/// Readable timing for subtitles (Netflix's Japanese timed-text rules):
/// - a line shorter than 5/6 s is extended into the silence after it, never
///   past the next line's start;
/// - a line longer than 7 s is cut to 7 s;
/// - a gap shorter than 300 ms is closed to two frames (about 83 ms), so the
///   screen does not flash empty between lines.
public enum SubtitleTimingFixer {
    static let minimumDuration = AudioTime(milliseconds: 833)
    static let maximumDuration = AudioTime(seconds: 7)
    static let smallGap = AudioTime(milliseconds: 300)
    static let twoFrames = AudioTime(milliseconds: 83)

    /// `segments` sorted by start time.
    public static func fixed(_ segments: [TimedText]) -> [TimedText] {
        var result = segments
        for index in result.indices {
            let nextStart = index + 1 < result.count ? result[index + 1].start : nil
            var line = result[index]
            if line.end - line.start > maximumDuration {
                line.end = line.start + maximumDuration
            }
            if line.end - line.start < minimumDuration {
                let wanted = line.start + minimumDuration
                line.end = nextStart.map { max(min(wanted, $0), line.end) } ?? wanted
            }
            if let nextStart {
                let gap = nextStart - line.end
                if gap > twoFrames, gap < smallGap {
                    line.end = nextStart - twoFrames
                }
            }
            result[index] = line
        }
        return result
    }
}
