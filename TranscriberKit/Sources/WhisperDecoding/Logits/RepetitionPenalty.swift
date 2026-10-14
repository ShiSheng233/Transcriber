/// CTranslate2 `RepetitionPenalty`: every token already generated in this
/// hypothesis (timestamps included, prompt excluded) has its raw logit divided
/// by the penalty when positive, multiplied when negative. A token generated
/// several times is penalized once.
public struct RepetitionPenalty: LogitsProcessor {
    public let penalty: Float

    public init(penalty: Float) {
        self.penalty = penalty
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        for token in Set(step.generatedTokens) where logits.indices.contains(token) {
            let logit = logits[token]
            logits[token] = logit < 0 ? logit * penalty : logit / penalty
        }
    }
}
