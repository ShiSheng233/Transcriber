import Foundation
import Testing
@testable import TranscriberCore

struct ModelCatalogTests {
    private func makeModelsFolder(_ configurations: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (name, json) in configurations {
            let modelFolder = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: modelFolder.appendingPathComponent(ModelCatalog.configurationFileName))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("vad"), withIntermediateDirectories: true)
        return folder
    }

    @Test func missingSettingsTakeTheChickenRiceDefaults() throws {
        let folder = try makeModelsFolder([
            "minimal": #"{"id": "minimal", "name": "Minimal", "language": "ja", "task": "transcribe", "llm_mode": "translate"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let catalog = ModelCatalog.scan(folder)
        let model = try #require(catalog.model(withID: "minimal"))

        #expect(catalog.models.count == 1)  // vad/ has no model.json
        #expect(model.decoding == .whisper(ChickenRiceDefaults.decoding(task: .transcribe)))
        #expect(model.vad == ChickenRiceDefaults.vad)
        #expect(model.chunking == ChickenRiceDefaults.chunking)
        #expect(model.merge == ChickenRiceDefaults.merge)
        #expect(model.vadModelName == "whisper-vad-asmr")
        #expect(model.files.whisperCpp?.lastPathComponent == "ggml.bin")
        #expect(model.files.mlx?.lastPathComponent == "mlx")
        #expect(model.files.tokenizer.deletingLastPathComponent().lastPathComponent == "minimal")
    }

    @Test func readsOverridesInSnakeCase() throws {
        let folder = try makeModelsFolder([
            "custom": """
            {
              "id": "custom", "name": "Custom", "language": "en", "task": "transcribe", "llm_mode": "polish",
              "files": { "mlx": "" },
              "whisper_cpp": { "encoder": "coreml" },
              "decoding": { "temperatures": [0.0], "repetition_penalty": 1.1, "max_initial_timestamp": 0.5 },
              "vad": { "threshold": 0.4, "speech_pad_ms": 100 },
              "chunking": { "enabled": false },
              "merge": { "max_gap_ms": 300 }
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = try #require(ModelCatalog.scan(folder).model(withID: "custom"))

        guard case .whisper(let decoding) = model.decoding else {
            Issue.record("Expected Whisper decoding for custom")
            return
        }
        #expect(decoding.languageCode == "en")
        #expect(decoding.temperatures == [0.0])
        #expect(decoding.repetitionPenalty == 1.1)
        #expect(decoding.maximumInitialTimestampSeconds == 0.5)
        #expect(decoding.bestOf == ChickenRiceDefaults.decoding(task: .transcribe).bestOf)
        #expect(model.vad.threshold == 0.4)
        #expect(model.vad.speechPadding == AudioTime(milliseconds: 100))
        #expect(!model.chunking.isEnabled)
        #expect(model.merge.maximumGap == AudioTime(milliseconds: 300))
        #expect(model.files.mlx == nil)
        #expect(model.whisperCppEncoder == .coreML)
        #expect(model.llmMode == .polish)
    }

    @Test func reportsUnreadableConfigurations() throws {
        let folder = try makeModelsFolder([
            "broken": #"{"id": "broken"}"#,
            "whisper-without-task": #"{"id": "whisper-without-task", "name": "Whisper without task", "language": "ja", "llm_mode": "translate"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let catalog = ModelCatalog.scan(folder)

        #expect(catalog.models.isEmpty)
        #expect(catalog.problems.map { $0.configurationURL.deletingLastPathComponent().lastPathComponent } == ["broken", "whisper-without-task"])
    }

    @Test func theRepositoryConfigurationsAreValid() throws {
        let configurations = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ModelConfigurations")
        let files = try FileManager.default.contentsOfDirectory(at: configurations, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var installed: [String: String] = [:]
        for file in files {
            installed[file.deletingPathExtension().lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        let folder = try makeModelsFolder(installed)
        defer { try? FileManager.default.removeItem(at: folder) }

        let catalog = ModelCatalog.scan(folder)

        #expect(catalog.problems.isEmpty)
        #expect(Set(catalog.models.map(\.id)) == Set(installed.keys))  // folder name == id
        let chickenRice = try #require(catalog.model(withID: "chickenrice-v0.2"))
        #expect(chickenRice.decoding == .whisper(ChickenRiceDefaults.decoding(task: .translate)))
        #expect(chickenRice.llmMode == .polish)
        #expect(catalog.model(withID: "whisper-ja-1.5b")?.decoding == .whisper(ChickenRiceDefaults.decoding(task: .transcribe)))
        let qwen = try #require(catalog.model(withID: "qwen3-asr-1.7b-ja-anime-galgame"))
        let qwenDecoding = try #require(qwen.qwen3ASR)
        #expect(qwenDecoding.directory.lastPathComponent == "qwen3-asr")
        #expect(qwenDecoding.languageCode == "ja")
        #expect(qwenDecoding.maximumGeneratedTokenCount == 128)
        #expect(qwen.llmMode == .translate)
        #expect(qwen.files.whisperCpp == nil && qwen.files.mlx == nil)
        #expect(qwen.segmentation.mode == .vadGroups)
    }
}
