import Accelerate

/// Vectorized log-softmax; each decoding step runs it over the whole vocabulary.
enum LogSoftmax {
    static func apply(_ logits: [Float]) -> [Float] {
        let normalizer = logSumExp(logits[...])
        return vDSP.add(-normalizer, logits)
    }

    /// Stable log(sum(exp(x))); -infinity when every value is -infinity.
    static func logSumExp(_ values: ArraySlice<Float>) -> Float {
        guard !values.isEmpty else {
            return -.infinity
        }
        let maximum = vDSP.maximum(values)
        guard maximum > -.infinity else {
            return -.infinity
        }
        let exponentials = vForce.exp(vDSP.add(-maximum, values))
        return maximum + log(vDSP.sum(exponentials))
    }
}
