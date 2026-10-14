import ArgumentParser
import Foundation
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

    @Option(help: "Directory holding whisper/, vad/ (default: the repository's Models).")
    var modelsDirectory: String = "Models"

    @Option(help: "translate (ChickenRice, Chinese) or transcribe (whisper-ja-1.5B, Japanese).")
    var task: String = "translate"

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

    @Option(help: "ggml model file name suffix, e.g. -f32 for chickenrice-v0.2-f32.bin.")
    var modelSuffix: String = ""

    @Option(help: "Chunks decoded at the same time.")
    var concurrency: Int = TranscriptionPipeline.Settings.chickenRice.concurrentChunkCount

    @Argument(help: "Media files.")
    var inputs: [String]

    func run() async throws {
        guard let task = TranscriptionTask(rawValue: task) else {
            throw ValidationError("task must be translate or transcribe")
        }
        let subtitleFormats = try formats.split(separator: ",").map { name in
            guard let format = SubtitleFormat(rawValue: String(name)) else {
                throw ValidationError("unknown subtitle format \(name)")
            }
            return format
        }

        let models = URL(fileURLWithPath: modelsDirectory)
        let modelName = task == .translate ? "chickenrice-v0.2" : "whisper-ja-1.5b"
        let tokenizer = try WhisperTokenizer(contentsOf: models.appendingPathComponent("whisper/\(modelName).tokenizer.json"))
        let whisperBackend: any WhisperBackend
        switch backend {
        case "whispercpp":
            whisperBackend = WhisperCppBackend(model: try WhisperModel(
                contentsOf: models.appendingPathComponent("whisper/\(modelName)\(modelSuffix).bin"),
                usesGPU: !cpu,
                usesFlashAttention: flashAttention
            ))
        case "mlx":
            whisperBackend = try WhisperMLXBackend(modelDirectory: models.appendingPathComponent("mlx/\(modelName)"))
        default:
            throw ValidationError("backend must be whispercpp or mlx")
        }
        let vadModel = try WhisperVADModel(compiledModelAt: models.appendingPathComponent("vad/whisper-vad-asmr.mlmodelc"))
        let segmentGenerator = SegmentGenerator(
            backend: whisperBackend,
            decoder: FallbackDecoder(windowDecoder: WindowDecoder(tokenizer: tokenizer, settings: ChickenRiceDefaults.decoding(task: task)))
        )
        var settings = TranscriptionPipeline.Settings.chickenRice
        settings.concurrentChunkCount = concurrency
        let pipeline = TranscriptionPipeline(vadModel: vadModel, segmentGenerator: segmentGenerator, settings: settings)

        for input in inputs {
            let inputURL = URL(fileURLWithPath: input)
            let start = ContinuousClock.now
            let fileName = inputURL.lastPathComponent
            let decodedDuration = Mutex(AudioTime.zero)
            let segments = try await pipeline.transcribe(fileAt: inputURL) { progress in
                switch progress {
                case .decodedAudio(let duration): decodedDuration.withLock { $0 = duration }
                case .plannedChunks(let count): print("\(fileName): \(count) chunk(s)")
                case .transcribedChunk(let index, let count): print("  chunk \(index + 1)/\(count)")
                }
            }
            let audioDuration = decodedDuration.withLock { $0 }
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(String(format: "  %d segments, %.1f s audio in %.1f s (%.1fx realtime)",
                         segments.count, audioDuration.seconds, seconds, audioDuration.seconds / seconds))

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
}
