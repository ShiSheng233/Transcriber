import ArgumentParser
import LLMTranslation

struct LLMModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm-models",
        abstract: "List the models an OpenAI-compatible API offers (on OpenRouter, those with structured output)."
    )

    @OptionGroup var endpoint: LLMEndpointOptions

    @Option(help: "Only show models whose id contains this text.")
    var filter: String?

    func run() async throws {
        let models = try await endpoint.makeClient().models()
        let shown = models.filter { filter.map($0.id.localizedCaseInsensitiveContains) ?? true }
        for model in shown {
            print("\(model.id)\t\(model.name)")
        }
        print("\(shown.count) of \(models.count) models")
    }
}
