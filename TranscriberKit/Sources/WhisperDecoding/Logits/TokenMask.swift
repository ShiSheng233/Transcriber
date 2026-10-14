/// Tokens that may not be generated at the current step (CTranslate2 `DisableTokens`).
///
/// Processors add ids; `apply` sets their logits to -infinity. Applying twice is
/// harmless, which the timestamp rules rely on when they apply the mask early.
public struct TokenMask {
    private var disabledTokens: Set<Int> = []

    public init() {}

    public mutating func disable(_ token: Int) {
        disabledTokens.insert(token)
    }

    public mutating func disable(_ tokens: some Sequence<Int>) {
        disabledTokens.formUnion(tokens)
    }

    public func apply(to logits: inout [Float]) {
        for token in disabledTokens where logits.indices.contains(token) {
            logits[token] = -.infinity
        }
    }
}
