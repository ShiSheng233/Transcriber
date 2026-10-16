import TranscriberCore

/// Port of WhisperJAV's `_deduplicate_sequential_lines`
/// (whisperjav/modules/subtitle_sanitizer.py): three or more lines in a row
/// with the same text, each starting less than 600 ms after the previous one
/// ended, become one line spanning them all.
public enum RepeatedLineMerger {
    /// `DEDUP_THRESHOLD`.
    static let minimumRunLength = 3
    /// `cross_subtitle.MAX_GAP_MS`.
    static let maximumGap = AudioTime(milliseconds: 600)

    public static func merged(_ segments: [TimedText]) -> [TimedText] {
        var merged: [TimedText] = []
        var index = segments.startIndex
        while index < segments.endIndex {
            let first = segments[index]
            var runEnd = index + 1
            while runEnd < segments.endIndex, continuesRun(segments[runEnd - 1], with: segments[runEnd], text: first.text) {
                runEnd += 1
            }
            if runEnd - index >= minimumRunLength {
                let confidence = segments[index..<runEnd].reduce(nil as RecognitionConfidence?) { $0.combined(with: $1.confidence) }
                merged.append(TimedText(start: first.start, end: segments[runEnd - 1].end, text: first.text, confidence: confidence))
                index = runEnd
            } else {
                merged.append(first)
                index += 1
            }
        }
        return merged
    }

    private static func continuesRun(_ previous: TimedText, with next: TimedText, text: String) -> Bool {
        let gap = next.start - previous.end
        return next.text.pythonStripped == text.pythonStripped && gap >= .zero && gap < maximumGap
    }
}
