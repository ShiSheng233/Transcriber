import TranscriberCore

/// Renders segments as subtitle file text. SRT, VTT, LRC and TXT reproduce the
/// original `SubWriter` byte for byte, except that VTT starts with the standard
/// `WEBVTT` header instead of the original's `WebVTT`. Lines end with "\n".
///
/// Bilingual files (not in the original) put each line's original under it:
/// on the next line of the cue in SRT, VTT and TXT, as a second lyric with
/// the same time in LRC, and in a smaller grey style in ASS.
public enum SubtitleRenderer {
    /// - Parameter originals: one per segment, written under it; `nil`
    ///   entries, and originals equal to their line, add nothing.
    public static func render(_ segments: [TimedText], as format: SubtitleFormat, originals: [String?] = []) -> String {
        let originals = segments.indices.map { index -> String? in
            guard originals.indices.contains(index), let original = originals[index],
                  !original.isEmpty, original != segments[index].text else {
                return nil
            }
            return original
        }
        return switch format {
        case .srt: srt(segments, originals)
        case .vtt: vtt(segments, originals)
        case .lrc: lrc(segments, originals)
        case .ass: ASSDocument(segments: segments, originals: originals).text
        case .txt: segments.indices.map { "\(stacked(segments[$0].text, under: originals[$0]))\n" }.joined()
        }
    }

    /// The line, then its original on the next line.
    private static func stacked(_ text: String, under original: String?) -> String {
        original.map { "\(text)\n\($0)" } ?? text
    }

    private static func srt(_ segments: [TimedText], _ originals: [String?]) -> String {
        numberedCues(segments, originals, millisecondSeparator: ",")
    }

    private static func vtt(_ segments: [TimedText], _ originals: [String?]) -> String {
        "WEBVTT\n\n" + numberedCues(segments, originals, millisecondSeparator: ".")
    }

    private static func numberedCues(_ segments: [TimedText], _ originals: [String?], millisecondSeparator: String) -> String {
        segments.enumerated().map { index, segment in
            let start = SubtitleTimestamp.hoursMinutesSeconds(segment.start, millisecondSeparator: millisecondSeparator)
            let end = SubtitleTimestamp.hoursMinutesSeconds(segment.end, millisecondSeparator: millisecondSeparator)
            return "\(index + 1)\n\(start) --> \(end)\n\(stacked(segment.text, under: originals[index]))\n\n"
        }.joined()
    }

    /// Each line gets a start tag; an end tag follows unless it would repeat
    /// the next line's start tag. An original is a second line with the same
    /// start tag, which lyric players show together.
    private static func lrc(_ segments: [TimedText], _ originals: [String?]) -> String {
        segments.enumerated().map { index, segment in
            let start = SubtitleTimestamp.lrc(segment.start)
            let end = SubtitleTimestamp.lrc(segment.end)
            var lines = "[\(start)]\(segment.text)\n"
            if let original = originals[index] {
                lines += "[\(start)]\(original.replacing("\n", with: " "))\n"  // a lyric is one line
            }
            let nextStart = segments.indices.contains(index + 1) ? SubtitleTimestamp.lrc(segments[index + 1].start) : nil
            if end != nextStart {
                lines += "[\(end)]\n"
            }
            return lines
        }.joined()
    }
}
