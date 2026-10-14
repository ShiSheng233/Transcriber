import ArgumentParser
import Foundation
import MediaDecoding

struct DecodeAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-audio",
        abstract: "Decode a media file to 16 kHz mono float32 samples (raw little-endian)."
    )

    @Argument(help: "Input media file.")
    var inputPath: String

    @Argument(help: "Output file for the raw float32 samples.")
    var outputPath: String

    func run() throws {
        let decodeStart = ContinuousClock.now
        let samples = try MediaDecoder().decodeAudio(at: URL(fileURLWithPath: inputPath))
        let decodeDuration = ContinuousClock.now - decodeStart
        try samples.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: outputPath)) }
        print("\(samples.count) samples (\(Double(samples.count) / 16_000) s) in \(decodeDuration)")
    }
}
