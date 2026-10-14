import Foundation

/// mlx-whisper's `ModelDimensions`, read from the model directory's config.json.
struct WhisperMLXConfiguration: Decodable {
    let melBandCount: Int
    let audioContextLength: Int
    let audioStateSize: Int
    let audioHeadCount: Int
    let audioLayerCount: Int
    let vocabularySize: Int
    let textContextLength: Int
    let textStateSize: Int
    let textHeadCount: Int
    let textLayerCount: Int

    enum CodingKeys: String, CodingKey {
        case melBandCount = "n_mels"
        case audioContextLength = "n_audio_ctx"
        case audioStateSize = "n_audio_state"
        case audioHeadCount = "n_audio_head"
        case audioLayerCount = "n_audio_layer"
        case vocabularySize = "n_vocab"
        case textContextLength = "n_text_ctx"
        case textStateSize = "n_text_state"
        case textHeadCount = "n_text_head"
        case textLayerCount = "n_text_layer"
    }

    static func load(from directory: URL) throws -> WhisperMLXConfiguration {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
    }
}
