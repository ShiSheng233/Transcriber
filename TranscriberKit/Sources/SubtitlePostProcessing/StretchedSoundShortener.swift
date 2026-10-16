import Foundation

/// Shortens sounds Whisper stretches out, keeping some of the stretch so the
/// tone survives (unlike `SubtitleTextCleanup`'s collapse to one copy):
/// - a character four or more times in a row keeps two ("ああああ" → "ああ");
/// - "ー", "っ", "ッ", "〜" and "～" repeated keep one;
/// - "!", "?", "！", "？" and "…" three or more times keep two;
/// - a 2–6 character run three or more times keeps two ("ダメダメダメダメ" → "ダメダメ").
public enum StretchedSoundShortener {
    private static let repeatedCharacter = try! NSRegularExpression(pattern: #"([^\s\-ーっッ〜～!?！？…])\1{3,}"#)
    private static let repeatedMark = try! NSRegularExpression(pattern: #"([ーっッ〜～])\1+"#)
    private static let repeatedPunctuation = try! NSRegularExpression(pattern: #"([!?！？…])\1{2,}"#)
    private static let repeatedRun = try! NSRegularExpression(pattern: #"(.{2,6}?)\1{2,}"#)

    public static func shortened(_ text: String) -> String {
        var result = text
        result = replace(repeatedCharacter, in: result, with: "$1$1")
        result = replace(repeatedMark, in: result, with: "$1")
        result = replace(repeatedPunctuation, in: result, with: "$1$1")
        return replace(repeatedRun, in: result, with: "$1$1")
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
