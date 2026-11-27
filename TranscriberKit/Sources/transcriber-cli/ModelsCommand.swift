import ArgumentParser
import Foundation
import TranscriberCore

struct ModelsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List the models (folders with a model.json) in a models folder."
    )

    @Option(help: "Directory holding one folder per model.")
    var modelsDirectory: String = "Models"

    func run() throws {
        let catalog = ModelCatalog.scan(URL(fileURLWithPath: modelsDirectory))
        for model in catalog.models {
            let fileManager = FileManager.default
            let hasQwenWeights = model.qwen3ASR.map { $0.firstMissingFile == nil } ?? false
            let installedEngines: [String?] = [
                model.files.whisperCpp.flatMap { fileManager.fileExists(atPath: $0.path) ? "whisper.cpp" : nil },
                model.files.mlx.flatMap { fileManager.fileExists(atPath: $0.path) ? "MLX" : nil },
                hasQwenWeights ? "Qwen3-ASR (MLX)" : nil,
            ]
            let engines = installedEngines.compactMap { $0 }
            let engineList = engines.isEmpty ? "no weights" : engines.joined(separator: ", ")
            print("\(model.id)\t\(model.displayName) — \(model.summary) [\(engineList)]")
        }
        for problem in catalog.problems {
            print("error: \(problem.configurationURL.path): \(problem.message)")
        }
    }
}
