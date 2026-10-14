import ArgumentParser
import LLMTranslation

struct LLMModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llm-models",
        abstract: "List OpenRouter models that support structured output."
    )

    @Option(help: "Only show models whose id contains this text.")
    var filter: String?

    func run() async throws {
        let models = try await OpenRouterClient.structuredOutputModels()
        let shown = models.filter { filter.map($0.id.localizedCaseInsensitiveContains) ?? true }
        for model in shown {
            print("\(model.id)\t\(model.name)\t\(model.contextLength)")
        }
        print("\(shown.count) of \(models.count) models")
    }
}
