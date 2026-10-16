import Foundation

/// Evens out how Whisper writes Japanese (and ChickenRice's Chinese) without
/// NFKC, which would also turn "～" into "~", "…" into "..." and "！" into "!":
/// - half-width katakana become full-width ("ｶﾞ" → "ガ");
/// - full-width Latin letters and digits become half-width ("ＡＢ１" → "AB1");
/// - "・・・", "..." and "。。。" become "…";
/// - "!", "?" and "~" next to Japanese or Chinese become "！", "？" and "〜";
/// - spaces between two Japanese or Chinese characters go.
public enum JapaneseTextNormalizer {
    private static let halfWidthKatakana: ClosedRange<UInt32> = 0xFF61...0xFF9F
    private static let fullWidthAlphanumerics: [ClosedRange<UInt32>] = [0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A]
    /// Full-width forms sit this far above their ASCII counterparts.
    private static let fullWidthOffset: UInt32 = 0xFEE0

    private static let dottedEllipsis = try! NSRegularExpression(pattern: #"・{3,}|\.{3,}|。{3,}|‥+"#)
    private static let cjk = #"[\p{Han}\p{Hiragana}\p{Katakana}ー々〆〜、。「」『』（）！？…]"#
    private static let spaceBetweenCJK = try! NSRegularExpression(pattern: "(?<=\(cjk))[ \\t]+(?=\(cjk))")
    private static let asciiMarkNearCJK = try! NSRegularExpression(pattern: "(?<=\(cjk))[!?~]+|[!?~]+(?=\(cjk))")

    public static func normalized(_ text: String) -> String {
        var result = widthNormalized(text)
        result = replacing(dottedEllipsis, in: result) { _ in "…" }
        result = replacing(asciiMarkNearCJK, in: result) { marks in
            String(marks.map { mark in
                switch mark {
                case "!": "！"
                case "?": "？"
                default: "〜"
                }
            })
        }
        return replacing(spaceBetweenCJK, in: result) { _ in "" }
    }

    /// Half-width katakana runs to full width (with their sound marks), and
    /// full-width letters and digits to ASCII.
    private static func widthNormalized(_ text: String) -> String {
        var output = ""
        var katakanaRun = String.UnicodeScalarView()
        func flushKatakana() {
            guard !katakanaRun.isEmpty else { return }
            output += String(katakanaRun).applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? String(katakanaRun)
            katakanaRun.removeAll()
        }
        for scalar in text.unicodeScalars {
            if halfWidthKatakana.contains(scalar.value) {
                katakanaRun.append(scalar)
                continue
            }
            flushKatakana()
            if fullWidthAlphanumerics.contains(where: { $0.contains(scalar.value) }),
               let ascii = Unicode.Scalar(scalar.value - fullWidthOffset) {
                output.unicodeScalars.append(ascii)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        flushKatakana()
        return output
    }

    static func replacing(_ pattern: NSRegularExpression, in text: String, with replacement: (String) -> String) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(String(result[range])))
        }
        return result
    }
}
