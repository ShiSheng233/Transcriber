import TranscriberCore

/// An Advanced SubStation Alpha file with a default style, and a smaller
/// grey one for the originals of bilingual subtitles.
///
/// Not part of the original pipeline. Text is escaped so it cannot start
/// override blocks: braces become full-width, newlines become `\N`.
struct ASSDocument {
    private static let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, \
        Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, \
        Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,PingFang SC,64,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,\
        0,0,0,0,100,100,0,0,1,3,1,2,40,40,48,1
        Style: Original,PingFang SC,44,&H00D0D0D0,&H000000FF,&H00000000,&H64000000,\
        0,0,0,0,100,100,0,0,1,2,1,2,40,40,48,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """

    let segments: [TimedText]
    /// One per segment; an original follows its line in the Original style.
    var originals: [String?] = []

    var text: String {
        Self.header + segments.enumerated().map { index, segment in
            let start = SubtitleTimestamp.ass(segment.start)
            let end = SubtitleTimestamp.ass(segment.end)
            var text = Self.escaped(segment.text)
            if originals.indices.contains(index), let original = originals[index] {
                text += "\\N{\\rOriginal}" + Self.escaped(original)
            }
            return "Dialogue: 0,\(start),\(end),Default,,0,0,0,,\(text)\n"
        }.joined()
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacing("{", with: "｛")
            .replacing("}", with: "｝")
            .replacing("\r\n", with: "\\N")
            .replacing("\n", with: "\\N")
    }
}
