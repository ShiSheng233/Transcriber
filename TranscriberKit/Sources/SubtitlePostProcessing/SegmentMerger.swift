import TranscriberCore

/// Port of `merge_segments` in the original `infer.py`.
///
/// Whisper often repeats itself across neighboring segments ("A" then "A B",
/// or "A B" then "B"). Close segments whose text contains the other's are
/// merged into one, keeping the longer text.
public enum SegmentMerger {
    public static func merged(_ segments: [TimedText], settings: MergeSettings) -> [TimedText] {
        let candidates = segments.filter { !$0.text.pythonStripped.isEmpty }.sortedByTime()
        guard settings.isEnabled else {
            return candidates
        }

        var merged: [TimedText] = []
        for segment in candidates {
            guard let last = merged.last,
                  segment.start - last.end <= settings.maximumGap,
                  segment.end - last.start <= settings.maximumSegmentDuration,
                  let keptText = textAfterMerging(last.text, with: segment.text)
            else {
                merged.append(segment)
                continue
            }
            merged[merged.count - 1] = TimedText(
                start: last.start, end: max(last.end, segment.end), text: keptText, confidence: last.confidence.combined(with: segment.confidence)
            )
        }
        return merged
    }

    /// The text to keep when one text repeats the other, or `nil` to keep both.
    /// The checks run in the original's order, comparing whitespace-collapsed text.
    private static func textAfterMerging(_ previousText: String, with nextText: String) -> String? {
        let previous = previousText.pythonWhitespaceCollapsed
        let next = nextText.pythonWhitespaceCollapsed
        if next.pythonHasPrefix(previous) {
            return nextText
        }
        if previous.pythonHasPrefix(next) || previous.pythonHasSuffix(next) {
            return previousText
        }
        if next.pythonHasSuffix(previous) {
            return nextText
        }
        return nil
    }
}
