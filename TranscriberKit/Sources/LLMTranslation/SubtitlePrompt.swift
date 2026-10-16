import Foundation

/// The instructions and JSON payload for one batch of subtitle lines.
enum SubtitlePrompt {
    enum Job {
        /// Fix what the speech model misheard, in the subtitles' own language.
        case proofread
        case polishChinese
        case translate(targetLanguage: String)
        case translateSubtitles(targetLanguage: String)
    }

    static let schemaName = "subtitle_lines"

    /// `{ "lines": [ { "id": Int, "text": String } ], "batch_summary": String,
    /// "scene_summary": String }`, nothing else; with `marksHallucinations`,
    /// each line also has "drop": Bool. Strict schemas need every property
    /// required.
    static func schema(marksHallucinations: Bool) -> [String: any Sendable] {
        guard marksHallucinations else {
            return schema
        }
        let line: [String: any Sendable] = [
            "type": "object",
            "properties": ["id": ["type": "integer"], "text": ["type": "string"], "drop": ["type": "boolean"]] as [String: any Sendable],
            "required": ["id", "text", "drop"],
            "additionalProperties": false,
        ]
        var withDrop = schema
        withDrop["properties"] = [
            "batch_summary": ["type": "string"] as [String: any Sendable],
            "scene_summary": ["type": "string"] as [String: any Sendable],
            "lines": ["type": "array", "items": line] as [String: any Sendable],
        ] as [String: any Sendable]
        return withDrop
    }

    static let schema: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "batch_summary": ["type": "string"] as [String: any Sendable],
            "scene_summary": ["type": "string"] as [String: any Sendable],
            "lines": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["id": ["type": "integer"], "text": ["type": "string"]],
                    "required": ["id", "text"],
                    "additionalProperties": false,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
        "required": ["lines", "batch_summary", "scene_summary"],
        "additionalProperties": false,
    ]

    static func systemMessage(for job: Job, glossary: [(source: String, target: String)], marksHallucinations: Bool = false) -> String {
        var instructions: String
        switch job {
        case .proofread:
            instructions = """
                You proofread subtitles that a speech model transcribed from Japanese audio (anime, drama, \
                ASMR and similar). Fix words the model misheard: wrong kanji for a homophone, broken or \
                garbled words, names and terms written inconsistently, using the surrounding lines as \
                context. Keep the speaker's own wording, tone, fillers and sounds; do not rewrite for \
                style and do not translate. Keep each line in its language. Leave lines that are already \
                right unchanged.
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
            - "context_before" and "context_after" are only for understanding; do not return them.
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
            if case .proofread = job {
                // The glossary maps Japanese to the translation; proofreading stays
                // in Japanese, so only its source terms help (as spellings to expect).
                instructions += "\nThese names and terms occur; write them this way:\n"
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
        var isDoubtful = false
    }

    static func userMessage(
        lines: [Line],
        contextBefore: [String],
        contextAfter: [String],
        sceneSoFar: String? = nil,
        earlierBatches: [String] = [],
        sortsKeys: Bool = false
    ) throws -> String {
        let payload = Payload(
            sceneSoFar: sceneSoFar,
            earlierBatches: earlierBatches.isEmpty ? nil : earlierBatches,
            contextBefore: contextBefore,
            lines: lines.map { Payload.Line(id: $0.id, text: $0.text, doubtful: $0.isDoubtful ? true : nil) },
            contextAfter: contextAfter
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
            /// Only sent when true, so other requests (and their cache keys) stay as they were.
            let doubtful: Bool?
        }

        let sceneSoFar: String?
        let earlierBatches: [String]?
        let contextBefore: [String]
        let lines: [Line]
        let contextAfter: [String]
    }

    /// What the model returns.
    struct Reply: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            let id: Int
            let text: String
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

        /// Ids the model marked as not speech.
        var droppedIDs: Set<Int> {
            Set(lines.filter { $0.drop == true }.map(\.id))
        }
    }
}
