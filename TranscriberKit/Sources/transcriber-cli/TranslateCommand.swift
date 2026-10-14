import ArgumentParser
import Foundation
import LLMTranslation
import SubtitleExport

struct TranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "Translate SRT or VTT files with the language model, writing <name>.<language>.srt next to each."
    )

    @OptionGroup var endpoint: LLMEndpointOptions

    @Option(help: "LLM model id.")
    var llmModel: String

    @Option(help: "Target language, as the model should read it.")
    var language: String = "简体中文"

    @Argument(help: "Subtitle files.")
    var inputs: [String]

    func run() async throws {
        let refiner = SubtitleRefiner(client: try endpoint.makeClient(), configuration: .init(model: llmModel))
        for input in inputs {
            let url = URL(fileURLWithPath: input)
            let original = try SubtitleParser.parse(fileAt: url)
            print("\(url.lastPathComponent): \(original.count) subtitles")
            let translated = try await refiner.refine(original, job: .translateSubtitles(targetLanguage: language)) { completed, total in
                print("  batch \(completed)/\(total)")
            }
            let outputURL = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).\(language).srt")
            try SubtitleRenderer.render(translated, as: .srt).write(to: outputURL, atomically: true, encoding: .utf8)
            print("  wrote \(outputURL.path)")
        }
    }
}
