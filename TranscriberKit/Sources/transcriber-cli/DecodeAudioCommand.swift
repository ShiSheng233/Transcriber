import ArgumentParser
import Foundation
import MediaDecoding
import TranscriberCore

struct DecodeAudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-audio",
        abstract: "Decode a media file to 16 kHz mono float32 samples (raw little-endian)."
    )

    @Argument(help: "Input media file.")
    var inputPath: String

    @Argument(help: "Output file for the raw float32 samples.")
    var outputPath: String

    @Flag(help: "Join frames end to end like the original, instead of filling timestamp holes.")
    var joinFrames = false

    func run() throws {
        let decodeStart = ContinuousClock.now
        let decoder = MediaDecoder(timestampHandling: joinFrames ? .joinFrames : .followTimestamps)
        let audio = try decoder.decodeAudio(at: URL(fileURLWithPath: inputPath))
        let decodeDuration = ContinuousClock.now - decodeStart
        try audio.samples.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: outputPath)) }
        print("\(audio.samples.count) samples (\(audio.duration.seconds) s) in \(decodeDuration)")
        for jump in audio.timestampJumps {
            print("Timestamp jump of \(jump.offset.seconds) s at \(jump.position.seconds) s")
        }
    }
}
