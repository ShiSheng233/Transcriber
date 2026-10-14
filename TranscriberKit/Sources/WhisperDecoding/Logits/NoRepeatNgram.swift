/// Hugging Face's `NoRepeatNGramLogitsProcessor`: a token may not complete
/// an n-gram that already occurred in the generated text.
public struct NoRepeatNgram: LogitsProcessor {
    public let size: Int

    public init(size: Int) {
        self.size = size
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        let tokens = step.generatedTokens
        guard size > 0, tokens.count + 1 >= size else {
            return
        }
        // The last size - 1 tokens, followed by any token seen after them before.
        let prefix = tokens.suffix(size - 1)
        for start in 0...(tokens.count - size) where tokens[start..<(start + size - 1)].elementsEqual(prefix) {
            mask.disable(tokens[start + size - 1])
        }
    }
}

/// Text-only decoding: timestamps and `<|notimestamps|>` are never generated.
public struct SuppressTimestamps: LogitsProcessor {
    public let firstSuppressed: Int
    public let lastToken: Int

    /// `noTimestamps` is followed by the timestamp ids up to the end of the vocabulary.
    public init(specialTokens: WhisperSpecialTokens, vocabularySize: Int) {
        firstSuppressed = specialTokens.noTimestamps
        lastToken = vocabularySize - 1
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        mask.disable(firstSuppressed...lastToken)
    }
}
