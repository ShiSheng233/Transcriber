import ArgumentParser
import AudioFeatures
import Foundation
import TranscriberCore
import WhisperCpp
import WhisperDecoding

struct DecodeWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-window",
        abstract: "Decode the first 30 s window of raw 16 kHz float32 samples, faster-whisper style."
    )

    @Option(help: "ggml model file.")
    var model: String

    @Option(help: "The model's tokenizer.json.")
    var tokenizer: String

    @Option(help: "translate or transcribe.")
    var task: String = "translate"

    @Argument(help: "Raw little-endian float32 samples, 16 kHz mono.")
    var samplesPath: String

    func run() throws {
        guard let task = TranscriptionTask(rawValue: task) else {
            throw ValidationError("task must be translate or transcribe")
        }
        let samples = try Data(contentsOf: URL(fileURLWithPath: samplesPath)).withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        let whisperTokenizer = try WhisperTokenizer(contentsOf: URL(fileURLWithPath: tokenizer))
        let backend = WhisperCppBackend(model: try WhisperModel(contentsOf: URL(fileURLWithPath: model)))
        let features = LogMelSpectrogram(melBandCount: backend.melBandCount, framing: .wholeSignal).features(for: samples)

        let start = ContinuousClock.now
        let contentFrameCount = features.frameCount - 1
        let window = features.paddedWindow(startingAt: 0, frameCount: min(contentFrameCount, LogMelSpectrogram.windowFrameCount))
        let session = try backend.makeSession(window: window)
        let decoder = FallbackDecoder(windowDecoder: WindowDecoder(
            tokenizer: whisperTokenizer, settings: ChickenRiceDefaults.decoding(task: task)
        ))
        var generator = SystemRandomNumberGenerator()
        let result = try decoder.decode(session, generator: &generator)
        let duration = ContinuousClock.now - start

        let decoding = result.decoding
        print("T=\(decoding.temperature) avg=\(decoding.averageLogProbability) no_speech=\(decoding.noSpeechProbability) compression=\(result.compressionRatio) in \(duration)")
        print("tokens=\(decoding.tokens)")
        print("text=\(whisperTokenizer.decode(decoding.tokens))")
    }
}
