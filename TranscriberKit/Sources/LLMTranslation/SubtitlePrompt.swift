import Foundation

/// The instructions and JSON payload for one batch of subtitle lines.
enum SubtitlePrompt {
    enum Job {
        case polishChinese
        case translate(targetLanguage: String)
        case translateSubtitles(targetLanguage: String)
    }

    static let schemaName = "subtitle_lines"

    /// `{ "lines": [ { "id": Int, "text": String } ], "batch_summary": String,
    /// "scene_summary": String }`, nothing else. Strict schemas need every
    /// property required.
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

    static func systemMessage(for job: Job, glossary: [(source: String, target: String)]) -> String {
        var instructions: String
        switch job {
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
            """
        if !glossary.isEmpty {
            instructions += "\nAlways use these renderings:\n"
            instructions += glossary.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        }
        return instructions
    }

    /// - Parameters:
    ///   - sceneSoFar: the previous batch's scene summary, if any.
    ///   - earlierBatches: summaries of the scene's previous batches, oldest first.
    ///   - sortsKeys: one fixed key order, for comparing requests; JSONEncoder's
    ///     order otherwise changes from one launch to the next.
    static func userMessage(
        lines: [(id: Int, text: String)],
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
            lines: lines.map { Payload.Line(id: $0.id, text: $0.text) },
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
    }
}
