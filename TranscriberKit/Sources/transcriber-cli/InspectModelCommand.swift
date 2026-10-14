import ArgumentParser
import Foundation
import WhisperCpp

struct InspectModelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect-model",
        abstract: "Load a ggml Whisper model and print its architecture."
    )

    @Argument(help: "Path to a ggml model file.")
    var modelPath: String

    @Flag(help: "Load on the CPU instead of the Metal GPU.")
    var cpu = false

    @Flag(help: "Run the encoder through the Core ML model next to the ggml file.")
    var coreML = false

    func run() throws {
        let modelURL = URL(fileURLWithPath: modelPath)
        let loadStart = ContinuousClock.now
        let model = try WhisperModel(
            contentsOf: modelURL,
            encoderBackend: coreML ? .coreML : .metal,
            usesGPU: !cpu
        )
        let loadDuration = ContinuousClock.now - loadStart

        let info = model.info
        print("""
            type:           \(info.typeName)
            mel bands:      \(info.melBandCount)
            vocabulary:     \(info.vocabularySize)
            encoder layers: \(info.encoderLayerCount)
            decoder layers: \(info.decoderLayerCount)
            multilingual:   \(info.isMultilingual)
            encoder:        \(model.encoderBackend)
            load time:      \(loadDuration)
            """)
    }
}
