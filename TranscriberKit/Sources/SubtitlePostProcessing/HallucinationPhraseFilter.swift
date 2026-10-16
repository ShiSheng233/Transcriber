import Foundation
import TranscriberCore

/// Drops lines Whisper invents from video outros and subtitle credits in its
/// training data, in Japanese and in ChickenRice's Chinese.
///
/// - Credit and outro phrases ("チャンネル登録よろしくお願いします",
///   "字幕由…提供") are never dialogue: a line made only of them goes.
/// - Polite closings ("ありがとうございました", "谢谢观看") are often real
///   speech, so they go only when the line stands alone near the start or
///   end of the audio, where Whisper fills silence with an outro.
///
/// Lines are compared after NFKC, lowercasing, and removing spaces and
/// punctuation, so "ご視聴、ありがとうございました！" matches.
public enum HallucinationPhraseFilter {
    /// Whole-line patterns, matched against the normalized line.
    private static let creditPatterns: [NSRegularExpression] = [
        // Japanese
        #"(最後まで)?ご(視聴|清聴|覧)(いただき|頂き|くださり|下さり)?(まことに|誠に|本当に)?ありがとうございました?"#,
        #"(高評価(と|や)?)?チャンネル登録(と高評価)?(を|も)?(よろしく|宜しく)?(お願い(します|いたします|致します))?"#,
        #"高評価(を|も)?(よろしく|宜しく)?(お願い(します|いたします|致します))?"#,
        #"次回(も|を)お楽しみに"#,
        #"(それでは|では)?また(次の|今度の)?動画で(お会いしましょう|会いましょう)?"#,
        #"字幕(制作|作成|提供|翻訳|担当)(者)?.*"#,
        // Chinese
        #"(中文)?字幕(由|制作|提供|翻译|组|by).*"#,
        #"请不吝点赞订阅转发打赏(支持明镜与点点栏目)?"#,
        #"(支持)?明镜与点点栏目"#,
        #"(请|欢迎)?(点赞|订阅|关注|转发|打赏|分享)+(我的频道|本频道|频道)?"#,
        #"(由)?amaraorg(社区|社群)?(提供(的)?字幕)?"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let closingPatterns: [NSRegularExpression] = [
        #"(どうも|本当に|皆さん|みなさん)?ありがとうございました?"#,
        #"お疲れ様でした"#,
        #"(谢谢|感谢)(大家|您|你们)?(的)?(观看|收看|收听|聆听)?"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A closing counts as alone with this much silence on both sides.
    static let isolationGap = AudioTime(seconds: 2)
    /// How close to either end of the audio a closing must be.
    static let edgeWindow = AudioTime(seconds: 60)

    public static func filtered(_ segments: [TimedText], audioDuration: AudioTime) -> [TimedText] {
        segments.indices.compactMap { index in
            let segment = segments[index]
            let normalized = normalize(segment.text)
            guard !normalized.isEmpty else {
                return segment
            }
            if isCovered(normalized, by: creditPatterns) {
                return nil
            }
            if isCovered(normalized, by: closingPatterns + creditPatterns),
               isAloneNearEdge(at: index, in: segments, audioDuration: audioDuration) {
                return nil
            }
            return segment
        }
    }

    /// Keeps letters and digits only, so spacing and punctuation don't matter.
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }

    /// Whether the line is one or more of the phrases back to back.
    private static func isCovered(_ text: String, by patterns: [NSRegularExpression]) -> Bool {
        var remaining = text
        var removedSomething = true
        while !remaining.isEmpty && removedSomething {
            removedSomething = false
            for pattern in patterns {
                let range = NSRange(remaining.startIndex..., in: remaining)
                guard let match = pattern.firstMatch(in: remaining, options: .anchored, range: range),
                      match.range.length > 0,
                      let matched = Range(match.range, in: remaining) else {
                    continue
                }
                remaining.removeSubrange(matched)
                removedSomething = true
                break
            }
        }
        return remaining.isEmpty
    }

    private static func isAloneNearEdge(at index: Int, in segments: [TimedText], audioDuration: AudioTime) -> Bool {
        let segment = segments[index]
        let nearEdge = segment.start < edgeWindow || segment.end > audioDuration - edgeWindow
        let previousEnd = index > segments.startIndex ? segments[index - 1].end : .zero
        let nextStart = index + 1 < segments.endIndex ? segments[index + 1].start : audioDuration
        return nearEdge
            && segment.start - previousEnd >= isolationGap
            && nextStart - segment.end >= isolationGap
    }
}
