import MLX
import MLXNN

/// Decoder state for a fixed number of sequences ("slots") decoded together.
///
/// Each slot holds one window's cross-attention keys/values and its own
/// self-attention cache. `step` advances the requested slots by one token in a
/// single forward pass: decoding is bound by reading the weights, so one pass
/// serves every slot for roughly the cost of one.
///
/// The step always computes and stores all slots so its shapes never change,
/// which lets MLX compile it once. A slot without a request writes at its next
/// free position: nothing reads that position before the slot's own next token
/// overwrites it.
final class DecoderSlotBatch {
    struct StepRequest {
        let slot: Int
        let token: Int
        /// Position of `token`; earlier positions of the slot are its prefix.
        let position: Int
    }

    let slotCount: Int
    private let contextLength: Int
    private let layerCount: Int
    private let decoder: TextDecoder
    /// Per slot: where its next token goes.
    private var nextPositions: [Int]
    /// Per layer, `[slots, contextLength, state]` and `[slots, audioPositions, state]`.
    private var selfKeys: [MLXArray]
    private var selfValues: [MLXArray]
    private var crossKeys: [MLXArray]
    private var crossValues: [MLXArray]
    private let compiledStep: ([MLXArray]) -> [MLXArray]

    init(decoder: TextDecoder, slotCount: Int, contextLength: Int, audioContextLength: Int, stateSize: Int, dtype: DType) {
        self.decoder = decoder
        self.slotCount = slotCount
        self.contextLength = contextLength
        self.layerCount = decoder.blocks.count
        nextPositions = Array(repeating: 0, count: slotCount)
        let empty = { (length: Int) in MLXArray.zeros([slotCount, length, stateSize], dtype: dtype) }
        selfKeys = (0..<layerCount).map { _ in empty(contextLength) }
        selfValues = (0..<layerCount).map { _ in empty(contextLength) }
        crossKeys = (0..<layerCount).map { _ in empty(audioContextLength) }
        crossValues = (0..<layerCount).map { _ in empty(audioContextLength) }
        eval(selfKeys, selfValues, crossKeys, crossValues)
        compiledStep = Self.makeStep(decoder: decoder, slotCount: slotCount, contextLength: contextLength)
    }

    /// Stores a newly encoded window's cross-attention keys/values in `slot`.
    func load(audioFeatures: MLXArray, into slot: Int) {
        for (layer, block) in decoder.blocks.enumerated() {
            guard let crossAttention = block.crossAttention else {
                continue
            }
            crossKeys[layer][slot] = crossAttention.key(audioFeatures)[0]
            crossValues[layer][slot] = crossAttention.value(audioFeatures)[0]
        }
        nextPositions[slot] = 0
        eval(crossKeys, crossValues)
    }

    /// Next-token logits for each request, in request order.
    func step(_ requests: [StepRequest]) -> [[Float]] {
        precondition(!requests.isEmpty, "a step needs at least one request")
        var tokens = [Int32](repeating: 0, count: slotCount)
        var positions = nextPositions.map { Int32(min($0, contextLength - 1)) }
        for request in requests {
            tokens[request.slot] = Int32(request.token)
            positions[request.slot] = Int32(request.position)
            nextPositions[request.slot] = request.position + 1
        }

        let outputs = compiledStep([MLXArray(tokens), MLXArray(positions)] + selfKeys + selfValues + crossKeys + crossValues)
        let logits = outputs[0]
        selfKeys = Array(outputs[1...layerCount])
        selfValues = Array(outputs[(layerCount + 1)...(2 * layerCount)])
        eval(logits, selfKeys, selfValues)

        let vocabularySize = logits.dim(1)
        let flat = logits.asArray(Float.self)
        return requests.map { request in
            let row = request.slot * vocabularySize
            return Array(flat[row..<(row + vocabularySize)])
        }
    }

    /// One decoding step for every slot. MLXArray is a reference type, so the
    /// cache arrays are updated in place by the subscript assignments.
    /// Inputs and outputs:
    /// `[tokens, positions, selfKeys..., selfValues..., crossKeys..., crossValues...]`
    /// -> `[logits, selfKeys..., selfValues...]`.
    private static func makeStep(decoder: TextDecoder, slotCount: Int, contextLength: Int) -> ([MLXArray]) -> [MLXArray] {
        let layerCount = decoder.blocks.count
        return { inputs in
            let tokens = inputs[0]
            let positions = inputs[1]
            let selfKeys = Array(inputs[2..<(2 + layerCount)])
            let selfValues = Array(inputs[(2 + layerCount)..<(2 + 2 * layerCount)])
            let crossKeys = Array(inputs[(2 + 2 * layerCount)..<(2 + 3 * layerCount)])
            let crossValues = Array(inputs[(2 + 3 * layerCount)..<(2 + 4 * layerCount)])
            let slots = MLXArray(0..<Int32(slotCount))

            // [slots, 1, state]
            var x = decoder.tokenEmbedding(tokens.expandedDimensions(axis: 1))
                + decoder.positionalEmbedding[positions].expandedDimensions(axis: 1)
            // A slot sees its own positions up to and including the new token.
            let keyPositions = MLXArray(0..<Int32(contextLength)).expandedDimensions(axis: 0)
            let mask = MLX.where(keyPositions .> positions.expandedDimensions(axis: 1), MLXArray(-Float.infinity), MLXArray(Float(0)))
                .asType(x.dtype)
                .reshaped(slotCount, 1, 1, contextLength)

            for (layer, block) in decoder.blocks.enumerated() {
                let attention = block.attention
                let normalized = block.attentionNorm(x)
                selfKeys[layer][slots, positions] = attention.key(normalized)[0..., 0]
                selfValues[layer][slots, positions] = attention.value(normalized)[0..., 0]
                x = x + attention.attend(attention.query(normalized), keys: selfKeys[layer], values: selfValues[layer], mask: mask, fused: false)

                if let crossAttention = block.crossAttention, let crossNorm = block.crossAttentionNorm {
                    let crossNormalized = crossNorm(x)
                    x = x + crossAttention.attend(crossAttention.query(crossNormalized), keys: crossKeys[layer], values: crossValues[layer], mask: nil, fused: false)
                }
                x = block.feedForward(x)
            }

            let logits = decoder.tokenEmbedding.asLinear(decoder.finalNorm(x[0..., 0])).asType(.float32)
            return [logits] + selfKeys + selfValues
        }
    }
}
