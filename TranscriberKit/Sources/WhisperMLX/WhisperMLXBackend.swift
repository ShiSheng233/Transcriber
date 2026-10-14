import AudioFeatures
import Foundation
import MLX
import MLXNN
import WhisperDecoding

public enum WhisperMLXError: Error, Equatable {
    case missingWeights(URL)
}

/// Whisper on MLX as a `WhisperBackend`. Loads models converted with
/// mlx-whisper's convert() (`make mlx-models`) and computes in the weights'
/// own precision (bfloat16 for ChickenRice).
public final class WhisperMLXBackend: WhisperBackend, @unchecked Sendable {
    // @unchecked: the network is only read after loading; MLX evaluation is
    // thread-safe for independent graphs.
    let network: WhisperNetwork
    let dtype: DType
    private let configuration: WhisperMLXConfiguration

    public init(modelDirectory: URL) throws {
        let configuration = try WhisperMLXConfiguration.load(from: modelDirectory)
        let weightsURL = modelDirectory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw WhisperMLXError.missingWeights(weightsURL)
        }
        // alignment_heads is metadata for word timestamps, not a parameter.
        let weights = try loadArrays(url: weightsURL).filter { $0.key != "alignment_heads" }
        let dtype = weights["decoder.token_embedding.weight"]?.dtype ?? .float16

        let network = WhisperNetwork(configuration: configuration, dtype: dtype)
        try network.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(network)

        self.network = network
        self.dtype = dtype
        self.configuration = configuration
    }

    public var melBandCount: Int {
        configuration.melBandCount
    }

    public func makeSession(window: LogMelFeatures) throws -> any WhisperDecoderSession {
        // LogMelFeatures is band major; the encoder takes [batch, frames, bands].
        let mel = MLXArray(window.values, [1, window.melBandCount, window.frameCount])
            .transposed(0, 2, 1)
            .asType(dtype)
        let audioFeatures = network.encoder(mel)
        eval(audioFeatures)
        return WhisperMLXSession(decoder: network.decoder, audioFeatures: audioFeatures)
    }
}

/// One encoded window with the decoder's key/value caches.
final class WhisperMLXSession: WhisperDecoderSession {
    private let decoder: TextDecoder
    private let audioFeatures: MLXArray
    /// Self-attention keys and values per layer, `[1, positions, state]`.
    private var selfKeys: [MLXArray?]
    private var selfValues: [MLXArray?]
    /// Cross-attention keys and values per layer, computed once per window.
    private let crossKeys: [MLXArray]
    private let crossValues: [MLXArray]

    init(decoder: TextDecoder, audioFeatures: MLXArray) {
        self.decoder = decoder
        self.audioFeatures = audioFeatures
        selfKeys = Array(repeating: nil, count: decoder.blocks.count)
        selfValues = Array(repeating: nil, count: decoder.blocks.count)
        // Every decoder block has cross-attention.
        crossKeys = decoder.blocks.compactMap { $0.crossAttention?.key(audioFeatures) }
        crossValues = decoder.blocks.compactMap { $0.crossAttention?.value(audioFeatures) }
    }

    func logits(appending tokens: [Int], afterPrefixOf prefixLength: Int) throws -> [Float] {
        let tokenCount = tokens.count
        let positions = prefixLength..<(prefixLength + tokenCount)
        var x = decoder.tokenEmbedding(MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0))
            + decoder.positionalEmbedding[positions]
        let mask = Self.causalMask(newTokenCount: tokenCount, prefixLength: prefixLength, dtype: x.dtype)

        for (index, block) in decoder.blocks.enumerated() {
            let normalized = block.attentionNorm(x)
            let attention = block.attention
            let keys = Self.appending(attention.key(normalized), to: selfKeys[index], keeping: prefixLength)
            let values = Self.appending(attention.value(normalized), to: selfValues[index], keeping: prefixLength)
            selfKeys[index] = keys
            selfValues[index] = values
            x = x + attention.attend(attention.query(normalized), keys: keys, values: values, mask: mask)

            if let crossAttention = block.crossAttention, let crossNorm = block.crossAttentionNorm {
                let crossNormalized = crossNorm(x)
                x = x + crossAttention.attend(crossAttention.query(crossNormalized), keys: crossKeys[index], values: crossValues[index], mask: nil)
            }
            x = block.feedForward(x)
        }

        let last = decoder.finalNorm(x[0..., (tokenCount - 1)..., 0...])
        let logits = decoder.tokenEmbedding.asLinear(last).asType(.float32)
        eval(logits)
        return logits.asArray(Float.self)
    }

    /// The cached prefix followed by the new entries.
    private static func appending(_ new: MLXArray, to cached: MLXArray?, keeping prefixLength: Int) -> MLXArray {
        guard let cached, prefixLength > 0 else {
            return new
        }
        return concatenated([cached[0..., ..<prefixLength, 0...], new], axis: 1)
    }

    /// New token i (at position prefix + i) may not see positions after itself.
    /// mlx-whisper slices a square mask, which is only right without a prefix.
    private static func causalMask(newTokenCount: Int, prefixLength: Int, dtype: DType) -> MLXArray? {
        guard newTokenCount > 1 else {
            return nil
        }
        let keyPositions = MLXArray(0..<(prefixLength + newTokenCount)).expandedDimensions(axis: 0)
        let queryPositions = MLXArray(prefixLength..<(prefixLength + newTokenCount)).expandedDimensions(axis: 1)
        return MLX.where(keyPositions .> queryPositions, MLXArray(-Float.infinity), MLXArray(Float(0))).asType(dtype)
    }
}
