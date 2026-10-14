import Foundation
import TranscriberCore

/// Per-line text fixes for models that need them, after WhisperJAV's
/// `AnimeWhisperCleaner` (whisperjav/modules/subtitle_pipeline/cleaners/anime_whisper.py).
public enum SubtitleTextCleanup {
    /// Only an ellipsis, closing brackets and sentence punctuation.
    private static let ellipsisOnly = try! NSRegularExpression(pattern: #"^[…‥.．?!？！」』)）\]\s]+$"#)
    private static let ellipsisCharacters = CharacterSet(charactersIn: "…‥.．")
    /// A 2–20 character run followed by two or more copies of itself.
    private static let repeatedRun = try! NSRegularExpression(pattern: #"(.{2,20}?)\1{2,}"#)
    /// Lines ending in one of these get no added "。".
    private static let finalPunctuation = Set("。、!?…！？♪～")

    public static func apply(_ segments: [TimedText], settings: TextCleanupSettings) -> [TimedText] {
        guard settings != .none else {
            return segments
        }
        return segments.compactMap { segment in
            var text = segment.text
            if settings.dropsEllipsisOnlyLines, isEllipsisOnly(text) {
                return nil
            }
            if settings.collapsesRepeats {
                text = repeatedRun.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1"
                )
            }
            if settings.appendsPeriod, let last = text.last, !finalPunctuation.contains(last) {
                text += "。"
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var cleaned = segment
            cleaned.text = text
            return cleaned
        }
    }

    static func isEllipsisOnly(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return ellipsisOnly.firstMatch(in: text, range: range) != nil
            && text.unicodeScalars.contains(where: ellipsisCharacters.contains)
    }
}
