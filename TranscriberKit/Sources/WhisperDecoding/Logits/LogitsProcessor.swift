/// What a processor may look at when adjusting one decoding step.
public struct DecodingStep {
    /// 0 for the first generated token.
    public let index: Int
    /// Tokens generated so far in this hypothesis (no prompt, no start token).
    public let generatedTokens: [Int]

    public init(index: Int, generatedTokens: [Int]) {
        self.index = index
        self.generatedTokens = generatedTokens
    }
}

/// One rule applied to the raw logits of a step, as in CTranslate2's
/// `LogitsProcessor`: it may change `logits` directly (repetition penalty) or
/// add tokens to `mask`, which is applied after all processors ran.
public protocol LogitsProcessor: Sendable {
    func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep)
}
