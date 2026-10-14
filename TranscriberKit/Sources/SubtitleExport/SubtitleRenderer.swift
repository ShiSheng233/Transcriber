import TranscriberCore

/// Renders segments as subtitle file text. SRT, VTT, LRC and TXT reproduce the
/// original `SubWriter` byte for byte, except that VTT starts with the standard
/// `WEBVTT` header instead of the original's `WebVTT`. Lines end with "\n".
public enum SubtitleRenderer {
    public static func render(_ segments: [TimedText], as format: SubtitleFormat) -> String {
        switch format {
        case .srt: srt(segments)
        case .vtt: vtt(segments)
        case .lrc: lrc(segments)
        case .ass: ASSDocument(segments: segments).text
        case .txt: segments.map { "\($0.text)\n" }.joined()
        }
    }

    private static func srt(_ segments: [TimedText]) -> String {
        numberedCues(segments, millisecondSeparator: ",")
    }

    private static func vtt(_ segments: [TimedText]) -> String {
        "WEBVTT\n\n" + numberedCues(segments, millisecondSeparator: ".")
    }

    private static func numberedCues(_ segments: [TimedText], millisecondSeparator: String) -> String {
        segments.enumerated().map { index, segment in
            let start = SubtitleTimestamp.hoursMinutesSeconds(segment.start, millisecondSeparator: millisecondSeparator)
            let end = SubtitleTimestamp.hoursMinutesSeconds(segment.end, millisecondSeparator: millisecondSeparator)
            return "\(index + 1)\n\(start) --> \(end)\n\(segment.text)\n\n"
        }.joined()
    }

    /// Each line gets a start tag; an end tag follows unless it would repeat
    /// the next line's start tag.
    private static func lrc(_ segments: [TimedText]) -> String {
        segments.enumerated().map { index, segment in
            let start = SubtitleTimestamp.lrc(segment.start)
            let end = SubtitleTimestamp.lrc(segment.end)
            var lines = "[\(start)]\(segment.text)\n"
            let nextStart = segments.indices.contains(index + 1) ? SubtitleTimestamp.lrc(segments[index + 1].start) : nil
            if end != nextStart {
                lines += "[\(end)]\n"
            }
            return lines
        }.joined()
    }
}
