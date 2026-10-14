/// Tokens that may not be generated at the current step (CTranslate2 `DisableTokens`).
///
/// Processors add ids or id ranges; `apply` sets their logits to -infinity.
/// Ranges are kept as ranges because the timestamp rules disable tens of
/// thousands of ids at once on every step. Applying twice is harmless, which
/// the timestamp rules rely on when they apply the mask early.
public struct TokenMask {
    private var disabledRanges: [Range<Int>] = []

    public init() {}

    public mutating func disable(_ token: Int) {
        disabledRanges.append(token..<(token + 1))
    }

    public mutating func disable(_ tokens: Range<Int>) {
        if !tokens.isEmpty {
            disabledRanges.append(tokens)
        }
    }

    public mutating func disable(_ tokens: ClosedRange<Int>) {
        disable(tokens.lowerBound..<(tokens.upperBound + 1))
    }

    public mutating func disable(_ tokens: some Sequence<Int>) {
        for token in tokens {
            disable(token)
        }
    }

    public func apply(to logits: inout [Float]) {
        let validTokens = 0..<logits.count
        logits.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            for range in disabledRanges {
                let clamped = range.clamped(to: validTokens)
                (base + clamped.lowerBound).update(repeating: -.infinity, count: clamped.count)
            }
        }
    }
}
