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
            let engines = [
                model.files.whisperCpp.map { fileManager.fileExists(atPath: $0.path) ? "whisper.cpp" : nil } ?? nil,
                model.files.mlx.map { fileManager.fileExists(atPath: $0.path) ? "MLX" : nil } ?? nil,
            ].compactMap { $0 }
            let engineList = engines.isEmpty ? "no weights" : engines.joined(separator: ", ")
            print("\(model.id)\t\(model.displayName) — \(model.summary) [\(engineList)]")
        }
        for problem in catalog.problems {
            print("error: \(problem.configurationURL.path): \(problem.message)")
        }
    }
}
