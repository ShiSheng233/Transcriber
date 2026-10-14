import Foundation

/// The instructions and JSON payload for one batch of subtitle lines.
enum SubtitlePrompt {
    enum Job {
        case polishChinese
        case translate(targetLanguage: String)
    }

    static let schemaName = "subtitle_lines"

    /// `{ "lines": [ { "id": Int, "text": String } ] }`, nothing else.
    static let schema: [String: any Sendable] = [
        "type": "object",
        "properties": [
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
        "required": ["lines"],
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
        }
        instructions += """

            Rules:
            - Return exactly one output line for every input line in "lines", with the same "id".
            - Never merge, split, reorder, drop or add lines; never explain or annotate.
            - "context_before" and "context_after" are only for understanding; do not return them.
            - Keep each line about as long as the original so it still fits its time on screen.
            """
        if !glossary.isEmpty {
            instructions += "\nAlways use these renderings:\n"
            instructions += glossary.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        }
        return instructions
    }

    static func userMessage(lines: [(id: Int, text: String)], contextBefore: [String], contextAfter: [String]) throws -> String {
        let payload = Payload(
            contextBefore: contextBefore,
            lines: lines.map { Payload.Line(id: $0.id, text: $0.text) },
            contextAfter: contextAfter
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private struct Payload: Encodable {
        struct Line: Encodable {
            let id: Int
            let text: String
        }

        let contextBefore: [String]
        let lines: [Line]
        let contextAfter: [String]
    }
}
