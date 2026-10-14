import Foundation

/// The models installed in a models folder: every subfolder with a `model.json`.
public struct ModelCatalog: Sendable {
    public static let configurationFileName = "model.json"

    public struct Problem: Hashable, Sendable {
        public let configurationURL: URL
        public let message: String
    }

    public let models: [RecognitionModel]
    /// Configurations that could not be read, so the user can fix them.
    public let problems: [Problem]

    public func model(withID id: String) -> RecognitionModel? {
        models.first { $0.id == id }
    }

    public static func scan(_ modelsDirectory: URL) -> ModelCatalog {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        var models: [RecognitionModel] = []
        var problems: [Problem] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let configurationURL = folder.appendingPathComponent(configurationFileName)
            guard let data = try? Data(contentsOf: configurationURL) else {
                continue  // not a model folder (e.g. vad/)
            }
            do {
                let configuration = try decoder.decode(ModelConfiguration.self, from: data)
                models.append(configuration.model(in: folder))
            } catch {
                problems.append(Problem(configurationURL: configurationURL, message: String(describing: error)))
            }
        }
        return ModelCatalog(models: models, problems: problems)
    }
}
