/// CTranslate2 `SuppressTokens`: these tokens are never generated.
public struct SuppressTokens: LogitsProcessor {
    public let tokens: [Int]

    public init(tokens: [Int]) {
        self.tokens = tokens
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        mask.disable(tokens)
    }
}

/// CTranslate2 `SuppressTokensBegin` (faster-whisper's `suppress_blank`): these
/// tokens cannot be the first generated token. For Whisper they are the space
/// token and `<|endoftext|>` (`suppress_ids_begin` in the model config).
public struct SuppressTokensAtBegin: LogitsProcessor {
    public let tokens: [Int]

    public init(tokens: [Int]) {
        self.tokens = tokens
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        if step.index == 0 {
            mask.disable(tokens)
        }
    }
}
