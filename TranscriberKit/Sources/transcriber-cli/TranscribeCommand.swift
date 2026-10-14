import ArgumentParser
import Foundation
import LLMTranslation
import SpeechDetection
import Synchronization
import SubtitleExport
import TranscriberCore
import TranscriptionPipeline
import WhisperCpp
import WhisperDecoding
import WhisperMLX

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Run the full pipeline on media files and write subtitles next to them or into --output-dir."
    )

    @Option(help: "Directory holding one folder per model and vad/ (default: the repository's Models).")
    var modelsDirectory: String = "Models"

    @Option(help: "Model id, as listed by the models command.")
    var model: String = "chickenrice-v0.2"

    @Option(help: "Comma-separated subtitle formats.")
    var formats: String = "srt,vtt,lrc"

    @Option(help: "Write subtitles here instead of next to each input.")
    var outputDirectory: String?

    @Option(help: "whispercpp or mlx.")
    var backend: String = "whispercpp"

    @Flag(help: "Enable whisper.cpp flash attention (faster, less faithful timestamps).")
    var flashAttention = false

    @Flag(help: "Run whisper.cpp on the CPU instead of Metal.")
    var cpu = false

    @Option(help: "ggml file in the model's folder instead of the configured one, e.g. ggml-q8_0.bin.")
    var ggmlFile: String?

    @Option(help: "Chunks decoded at the same time.")
    var concurrency: Int = TranscriptionPipeline.Settings.chickenRice.concurrentChunkCount

    @Option(help: "LLM model id: polishes or translates the output, as the model's llm_mode says.")
    var llmModel: String?

    @OptionGroup var llmEndpoint: LLMEndpointOptions

    @Option(help: "Target language when the LLM translates.")
    var llmTargetLanguage: String = "简体中文"

    @Argument(help: "Media files.")
    var inputs: [String]

    func run() async throws {
        let models = URL(fileURLWithPath: modelsDirectory)
        guard let recognitionModel = ModelCatalog.scan(models).model(withID: model) else {
            throw ValidationError("no model \(model) in \(modelsDirectory); see the models command")
        }
        let subtitleFormats = try formats.split(separator: ",").map { name in
            guard let format = SubtitleFormat(rawValue: String(name)) else {
                throw ValidationError("unknown subtitle format \(name)")
            }
            return format
        }

        let tokenizer = try WhisperTokenizer(contentsOf: recognitionModel.files.tokenizer)
        let whisperBackend: any WhisperBackend
        switch backend {
        case "whispercpp":
            let weights = ggmlFile.map { recognitionModel.directory.appendingPathComponent($0) } ?? recognitionModel.files.whisperCpp
            guard let weights else {
                throw ValidationError("\(model) has no whisper.cpp weights")
            }
            whisperBackend = WhisperCppBackend(model: try WhisperModel(contentsOf: weights, usesGPU: !cpu, usesFlashAttention: flashAttention))
        case "mlx":
            guard let weights = recognitionModel.files.mlx else {
                throw ValidationError("\(model) has no MLX weights")
            }
            whisperBackend = try WhisperMLXBackend(modelDirectory: weights)
        default:
            throw ValidationError("backend must be whispercpp or mlx")
        }
        let vadModel = try WhisperVADModel(compiledModelAt: models.appendingPathComponent("vad/\(recognitionModel.vadModelName).mlmodelc"))
        let segmentGenerator = SegmentGenerator(
            backend: whisperBackend,
            decoder: FallbackDecoder(windowDecoder: WindowDecoder(tokenizer: tokenizer, settings: recognitionModel.decoding))
        )
        let settings = TranscriptionPipeline.Settings(model: recognitionModel, concurrentChunkCount: concurrency)
        let pipeline = TranscriptionPipeline(vadModel: vadModel, segmentGenerator: segmentGenerator, settings: settings)

        for input in inputs {
            let inputURL = URL(fileURLWithPath: input)
            let start = ContinuousClock.now
            let fileName = inputURL.lastPathComponent
            let decodedDuration = Mutex(AudioTime.zero)
            var segments = try await pipeline.transcribe(fileAt: inputURL) { progress in
                switch progress {
                case .decodedAudio(let duration): decodedDuration.withLock { $0 = duration }
                case .plannedChunks(let count): print("\(fileName): \(count) chunk(s)")
                case .transcribedChunk(let completed, let count, _, _): print("  chunk \(completed)/\(count)")
                case .detectedSpeech, .postProcessed: break
                }
            }
            let audioDuration = decodedDuration.withLock { $0 }
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(String(format: "  %d segments, %.1f s audio in %.1f s (%.1fx realtime)",
                         segments.count, audioDuration.seconds, seconds, audioDuration.seconds / seconds))

            if let llmModel {
                segments = try await refineWithLLM(segments, recognitionModel: recognitionModel, model: llmModel)
            }

            let directory = outputDirectory.map { URL(fileURLWithPath: $0) } ?? inputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = inputURL.deletingPathExtension().lastPathComponent
            for format in subtitleFormats {
                let outputURL = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
                try SubtitleRenderer.render(segments, as: format).write(to: outputURL, atomically: true, encoding: .utf8)
                print("  wrote \(outputURL.path)")
            }
        }
    }

    private func refineWithLLM(_ segments: [TimedText], recognitionModel: RecognitionModel, model: String) async throws -> [TimedText] {
        let refiner = SubtitleRefiner(client: try llmEndpoint.makeClient(), configuration: .init(model: model))
        let job: SubtitleRefiner.Job = recognitionModel.llmMode == .polish ? .polishChinese : .translate(targetLanguage: llmTargetLanguage)
        let start = ContinuousClock.now
        let refined = try await refiner.refine(segments, job: job) { completed, total in
            print("  LLM batch \(completed)/\(total)")
        }
        print("  LLM (\(model)) finished in \(ContinuousClock.now - start)")
        return refined
    }
}
