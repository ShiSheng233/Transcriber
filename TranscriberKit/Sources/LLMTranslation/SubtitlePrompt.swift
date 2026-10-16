import Foundation
import TranscriberCore

/// The instructions and JSON payload for one batch of subtitle lines.
enum SubtitlePrompt {
    enum Job {
        /// Fix what the speech model misheard in Japanese lines, without translating.
        case proofreadJapanese
        case polishChinese
        case translate(targetLanguage: String)
        case translateSubtitles(targetLanguage: String)
    }

    static let schemaName = "subtitle_lines"

    /// `{ "lines": [ { "id": Int, "text": String } ], "batch_summary": String,
    /// "scene_summary": String }`, nothing else; with `correctsSources`, each
    /// line also has "source": String (its corrected original), and with
    /// `marksHallucinations`, "drop": Bool. Strict schemas need every
    /// property required.
    static func schema(correctsSources: Bool = false, marksHallucinations: Bool = false) -> [String: any Sendable] {
        var properties: [String: any Sendable] = ["id": ["type": "integer"], "text": ["type": "string"]]
        var required = ["id", "text"]
        if correctsSources {
            properties["source"] = ["type": "string"]
            required.append("source")
        }
        if marksHallucinations {
            properties["drop"] = ["type": "boolean"]
            required.append("drop")
        }
        let line: [String: any Sendable] = [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "batch_summary": ["type": "string"] as [String: any Sendable],
                "scene_summary": ["type": "string"] as [String: any Sendable],
                "lines": ["type": "array", "items": line] as [String: any Sendable],
            ] as [String: any Sendable],
            "required": ["lines", "batch_summary", "scene_summary"],
            "additionalProperties": false,
        ]
    }

    /// - Parameter correctsSources: for `.translate`, also return each
    ///   Japanese line with what the speech model misheard fixed.
    static func systemMessage(
        for job: Job,
        glossary: [(source: String, target: String)],
        correctsSources: Bool = false,
        marksHallucinations: Bool = false
    ) -> String {
        var instructions: String
        switch job {
        case .proofreadJapanese:
            instructions = """
                You proofread Japanese subtitles that a speech model transcribed from audio (anime, drama, \
                ASMR and similar). Fix only the words the model misheard: wrong kanji for a homophone, \
                broken or garbled words, names and terms written inconsistently, using the surrounding \
                lines as context. Keep the speaker's own wording, tone, fillers and sounds; do not rewrite \
                for style, do not polish and do not translate. Leave a line that is already right unchanged.
                """
        case .polishChinese:
            instructions = """
                You edit Chinese subtitles that a speech model translated directly from Japanese audio \
                (anime, drama, ASMR and similar). Fix mistranslations, unnatural or ungrammatical wording, \
                and names or terms that are rendered inconsistently, using the surrounding lines as context. \
                Keep the meaning and tone of the speech. Leave lines that are already good unchanged. \
                Write Simplified Chinese.
                """
        case .translate(let targetLanguage):
            instructions = """
                You translate Japanese subtitles (transcribed from anime, drama, ASMR and similar audio) \
                into \(targetLanguage). Write natural spoken subtitles, keep names and terms consistent, \
                and keep the speaker's tone. Transcription can contain mistakes; translate what was most \
                likely said.
                """
            if correctsSources {
                instructions += """

                    Also return "source" for every line: the Japanese line with the words the speech model \
                    misheard fixed (wrong kanji for a homophone, broken or garbled words, names and terms \
                    written inconsistently), and translate that corrected line. In "source", keep the \
                    speaker's own wording, tone, fillers and sounds, do not rewrite for style, and leave a \
                    line that is already right unchanged.
                    """
            }
        case .translateSubtitles(let targetLanguage):
            instructions = """
                You translate existing subtitles into \(targetLanguage). Detect the source language \
                yourself. Write natural spoken subtitles, keep names and terms consistent, and keep \
                the speaker's tone. Lines already in \(targetLanguage) are kept, only corrected if \
                clearly wrong.
                """
        }
        instructions += """

            Rules:
            - Return exactly one output line for every input line in "lines", with the same "id".
            - Never merge, split, reorder, drop or add lines; never explain or annotate.
            - "context_before" and "context_after" are only for understanding; do not return them. \
            A context line's "output", when present, is what you already wrote for it: stay consistent with it.
            - "start" and "end" (minutes:seconds) show when each line is spoken, so you can tell pauses, \
            pace and where it falls. They are fixed: never change or return them, and never write times \
            into the text.
            - Keep each line about as long as the original so it still fits its time on screen.
            - "scene_so_far" and "earlier_batches", when present, summarize what came before; \
            use them to keep names, relationships and tone consistent.
            - Also return "batch_summary": one or two sentences on what happens in these lines, \
            and "scene_summary": a short summary of the scene so far, including "scene_so_far". \
            Write both in the language of your output lines.
            - Lines with "doubtful": true were uncertain for the speech model; check them with extra care.
            """
        if marksHallucinations {
            instructions += """

                - Set "drop" to true only for a line that cannot be speech from this audio: video outros \
                and channel promotion (ご視聴ありがとうございました, チャンネル登録, 点赞订阅), subtitle \
                credits, text stuck in a loop, or text unrelated to everything around it, most often on \
                doubtful lines. Give such a line its original text. Otherwise set "drop" to false; when \
                unsure, keep the line.
                """
        }
        if !glossary.isEmpty {
            if case .proofreadJapanese = job {
                // Only the Japanese side matters: it is how these names are spelled.
                instructions += "\nThese names and terms are spelled this way:\n"
                instructions += glossary.map { "- \($0.source)" }.joined(separator: "\n")
            } else {
                instructions += "\nAlways use these renderings:\n"
                instructions += glossary.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
            }
        }
        return instructions
    }

    /// - Parameters:
    ///   - sceneSoFar: the previous batch's scene summary, if any.
    ///   - earlierBatches: summaries of the scene's previous batches, oldest first.
    ///   - sortsKeys: one fixed key order, for comparing requests; JSONEncoder's
    ///     order otherwise changes from one launch to the next.
    /// A line to send; `isDoubtful` marks lines the speech model was unsure of.
    struct Line: Sendable {
        let id: Int
        let text: String
        let start: AudioTime
        let end: AudioTime
        var isDoubtful = false
    }

    /// A neighbouring line sent for understanding; `output` is what the model
    /// already wrote for it in this run, if anything.
    struct ContextLine: Sendable {
        let text: String
        let start: AudioTime
        let end: AudioTime
        var output: String?
    }

    static func userMessage(
        lines: [Line],
        contextBefore: [ContextLine],
        contextAfter: [ContextLine],
        sceneSoFar: String? = nil,
        earlierBatches: [String] = [],
        sortsKeys: Bool = false
    ) throws -> String {
        let payload = Payload(
            sceneSoFar: sceneSoFar,
            earlierBatches: earlierBatches.isEmpty ? nil : earlierBatches,
            contextBefore: contextBefore.map(Payload.ContextLine.init),
            lines: lines.map { Payload.Line(id: $0.id, text: $0.text, start: clock($0.start), end: clock($0.end), doubtful: $0.isDoubtful ? true : nil) },
            contextAfter: contextAfter.map(Payload.ContextLine.init)
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = sortsKeys ? [.withoutEscapingSlashes, .sortedKeys] : [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private struct Payload: Encodable {
        struct Line: Encodable {
            let id: Int
            let text: String
            let start: String
            let end: String
            /// Only sent when true.
            let doubtful: Bool?
        }

        struct ContextLine: Encodable {
            let text: String
            let start: String
            let end: String
            let output: String?

            init(_ line: SubtitlePrompt.ContextLine) {
                text = line.text
                start = SubtitlePrompt.clock(line.start)
                end = SubtitlePrompt.clock(line.end)
                output = line.output
            }
        }

        let sceneSoFar: String?
        let earlierBatches: [String]?
        let contextBefore: [ContextLine]
        let lines: [Line]
        let contextAfter: [ContextLine]
    }

    /// "1:23.4", or "1:02:03.4" past an hour: short, and enough to tell pauses.
    static func clock(_ time: AudioTime) -> String {
        let tenths = (time.milliseconds + 50) / 100
        let hours = tenths / 36_000
        let minutes = tenths / 600 % 60
        let seconds = tenths / 10 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, seconds, tenths % 10)
    }

    /// A time the model wrote at the start of a line ("[1:23.4] ", "01:23 "),
    /// which the original did not have.
    private static let leadingTime = try! NSRegularExpression(pattern: #"^\s*[\[(]?\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?([\s]*[-–~][\s]*\d{1,2}:\d{2}(:\d{2})?([.,]\d+)?)?[\])]?\s*"#)

    /// The reply's text without a time the model added; times live only in
    /// the line's start and end, never in its text.
    static func removingAddedTime(from text: String, original: String) -> String {
        let originalRange = NSRange(original.startIndex..., in: original)
        guard leadingTime.firstMatch(in: original, range: originalRange) == nil else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return leadingTime.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// What the model returns.
    struct Reply: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            let id: Int
            let text: String
            /// The corrected original; only asked for when a translation also proofreads.
            var source: String? = nil
            /// Only asked for when the run may remove invented lines.
            var drop: Bool? = nil
        }

        let lines: [Line]
        /// Missing from servers that only follow the prompt loosely.
        let batchSummary: String?
        let sceneSummary: String?

        enum CodingKeys: String, CodingKey {
            case lines
            case batchSummary = "batch_summary"
            case sceneSummary = "scene_summary"
        }

        /// The text per id; a repeated id keeps its first text.
        var textByID: [Int: String] {
            Dictionary(lines.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        }

        /// The corrected original per id, when asked for; a repeated id keeps its first.
        var sourceByID: [Int: String] {
            Dictionary(lines.compactMap { line in line.source.map { (line.id, $0) } }, uniquingKeysWith: { first, _ in first })
        }

        /// Ids the model marked as not speech.
        var droppedIDs: Set<Int> {
            Set(lines.filter { $0.drop == true }.map(\.id))
        }
    }
}
