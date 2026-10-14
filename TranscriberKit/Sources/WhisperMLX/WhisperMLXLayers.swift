import Foundation
import MLX
import MLXFast
import MLXNN

/// Swift port of mlx-whisper's `whisper.py` (Apple, MIT). Property keys match
/// its weight names so models converted with mlx-whisper load as they are.

final class MultiHeadAttention: Module {
    @ModuleInfo var query: Linear
    @ModuleInfo var key: Linear
    @ModuleInfo var value: Linear
    @ModuleInfo var out: Linear
    let headCount: Int

    init(stateSize: Int, headCount: Int) {
        self.headCount = headCount
        _query.wrappedValue = Linear(stateSize, stateSize)
        _key.wrappedValue = Linear(stateSize, stateSize, bias: false)
        _value.wrappedValue = Linear(stateSize, stateSize)
        _out.wrappedValue = Linear(stateSize, stateSize)
    }

    /// Attention of `queries` over `keys`/`values` (already projected).
    ///
    /// `fused` uses MLX's scaled-dot-product-attention kernel; otherwise it is
    /// whisper.py's `qkv_attention` with a precise softmax. Measured against
    /// the original: the encoder may use the fused kernel (it avoids building
    /// 1500x1500 score matrices and made translation ~30% faster with no change
    /// in output), but in the decoder it changed ChickenRice's results (CER
    /// 9.6% -> 15.4%), so the decoder keeps the precise softmax.
    func attend(_ queries: MLXArray, keys: MLXArray, values: MLXArray, mask: MLXArray?, fused: Bool) -> MLXArray {
        let (batchSize, queryLength, stateSize) = (queries.dim(0), queries.dim(1), queries.dim(2))
        let headSize = stateSize / headCount
        let attended: MLXArray
        if fused {
            let q = queries.reshaped(batchSize, queryLength, headCount, headSize).transposed(0, 2, 1, 3)
            let k = keys.reshaped(batchSize, keys.dim(1), headCount, headSize).transposed(0, 2, 1, 3)
            let v = values.reshaped(batchSize, values.dim(1), headCount, headSize).transposed(0, 2, 1, 3)
            attended = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1 / sqrt(Float(headSize)), mask: mask)
        } else {
            let scale = pow(Float(headSize), -0.25)
            let q = queries.reshaped(batchSize, queryLength, headCount, headSize).transposed(0, 2, 1, 3) * scale
            let k = keys.reshaped(batchSize, keys.dim(1), headCount, headSize).transposed(0, 2, 3, 1) * scale
            let v = values.reshaped(batchSize, values.dim(1), headCount, headSize).transposed(0, 2, 1, 3)
            var scores = matmul(q, k)
            if let mask {
                scores = scores + mask
            }
            attended = matmul(softmax(scores, axis: -1, precise: true), v)
        }
        return out(attended.transposed(0, 2, 1, 3).reshaped(batchSize, queryLength, stateSize))
    }
}

final class ResidualAttentionBlock: Module {
    @ModuleInfo(key: "attn") var attention: MultiHeadAttention
    @ModuleInfo(key: "attn_ln") var attentionNorm: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttention: MultiHeadAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttentionNorm: LayerNorm?
    @ModuleInfo var mlp1: Linear
    @ModuleInfo var mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpNorm: LayerNorm

    init(stateSize: Int, headCount: Int, hasCrossAttention: Bool) {
        _attention.wrappedValue = MultiHeadAttention(stateSize: stateSize, headCount: headCount)
        _attentionNorm.wrappedValue = LayerNorm(dimensions: stateSize)
        _crossAttention.wrappedValue = hasCrossAttention ? MultiHeadAttention(stateSize: stateSize, headCount: headCount) : nil
        _crossAttentionNorm.wrappedValue = hasCrossAttention ? LayerNorm(dimensions: stateSize) : nil
        _mlp1.wrappedValue = Linear(stateSize, stateSize * 4)
        _mlp2.wrappedValue = Linear(stateSize * 4, stateSize)
        _mlpNorm.wrappedValue = LayerNorm(dimensions: stateSize)
    }

    func feedForward(_ x: MLXArray) -> MLXArray {
        x + mlp2(gelu(mlp1(mlpNorm(x))))
    }
}

final class AudioEncoder: Module {
    @ModuleInfo var conv1: Conv1d
    @ModuleInfo var conv2: Conv1d
    @ModuleInfo var blocks: [ResidualAttentionBlock]
    @ModuleInfo(key: "ln_post") var finalNorm: LayerNorm
    // Computed, not loaded: MLX skips properties whose names start with an
    // underscore when matching weights, as in mlx-whisper's `_positional_embedding`.
    private let _positionalEmbedding: MLXArray

    init(configuration: WhisperMLXConfiguration, dtype: DType) {
        let state = configuration.audioStateSize
        _conv1.wrappedValue = Conv1d(inputChannels: configuration.melBandCount, outputChannels: state, kernelSize: 3, padding: 1)
        _conv2.wrappedValue = Conv1d(inputChannels: state, outputChannels: state, kernelSize: 3, stride: 2, padding: 1)
        _blocks.wrappedValue = (0..<configuration.audioLayerCount).map { _ in
            ResidualAttentionBlock(stateSize: state, headCount: configuration.audioHeadCount, hasCrossAttention: false)
        }
        _finalNorm.wrappedValue = LayerNorm(dimensions: state)
        _positionalEmbedding = Self.sinusoids(length: configuration.audioContextLength, channels: state).asType(dtype)
    }

    /// - Parameter mel: `[batch, frames, melBands]`.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = gelu(conv1(mel))
        x = gelu(conv2(x))
        x = x + _positionalEmbedding
        for block in blocks {
            let normalized = block.attentionNorm(x)
            let attention = block.attention
            x = x + attention.attend(attention.query(normalized), keys: attention.key(normalized), values: attention.value(normalized), mask: nil, fused: true)
            x = block.feedForward(x)
        }
        return finalNorm(x)
    }

    /// Whisper's fixed sinusoidal positions (`sinusoids` in whisper.py).
    static func sinusoids(length: Int, channels: Int, maximumTimescale: Float = 10_000) -> MLXArray {
        let logIncrement = log(maximumTimescale) / Float(channels / 2 - 1)
        let inverseTimescales = exp(-logIncrement * MLXArray(0..<(channels / 2)).asType(.float32))
        let scaledTime = MLXArray(0..<length).asType(.float32).expandedDimensions(axis: 1) * inverseTimescales.expandedDimensions(axis: 0)
        return concatenated([sin(scaledTime), cos(scaledTime)], axis: 1)
    }
}

final class TextDecoder: Module {
    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo(key: "positional_embedding") var positionalEmbedding: MLXArray
    @ModuleInfo var blocks: [ResidualAttentionBlock]
    @ModuleInfo(key: "ln") var finalNorm: LayerNorm

    init(configuration: WhisperMLXConfiguration) {
        let state = configuration.textStateSize
        _tokenEmbedding.wrappedValue = Embedding(embeddingCount: configuration.vocabularySize, dimensions: state)
        _positionalEmbedding.wrappedValue = MLXArray.zeros([configuration.textContextLength, state])
        _blocks.wrappedValue = (0..<configuration.textLayerCount).map { _ in
            ResidualAttentionBlock(stateSize: state, headCount: configuration.textHeadCount, hasCrossAttention: true)
        }
        _finalNorm.wrappedValue = LayerNorm(dimensions: state)
    }
}

final class WhisperNetwork: Module {
    @ModuleInfo var encoder: AudioEncoder
    @ModuleInfo var decoder: TextDecoder

    init(configuration: WhisperMLXConfiguration, dtype: DType) {
        _encoder.wrappedValue = AudioEncoder(configuration: configuration, dtype: dtype)
        _decoder.wrappedValue = TextDecoder(configuration: configuration)
    }
}

