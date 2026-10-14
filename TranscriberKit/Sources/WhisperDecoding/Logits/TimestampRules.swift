/// CTranslate2's Whisper `ApplyTimestampRules` (src/models/whisper.cc), which
/// differs from OpenAI's and whisper.cpp's in the details kept here:
///
/// - Step 0 must be a timestamp no later than `maximumInitialTimestamp`.
/// - After a timestamp pair, text must follow. A single timestamp must be
///   followed by a later timestamp or end of text. At step 1 a first timestamp
///   counts as a pair, so text follows it.
/// - After text, timestamps must be strictly later than the last one.
/// - When the timestamps' total probability exceeds the best text token's, only
///   timestamps are allowed. This check uses the masked logits (no temperature)
///   and is skipped at step 0 and after a pair.
public struct TimestampRules: LogitsProcessor {
    public let endOfText: Int
    public let noTimestamps: Int
    public let timestampBegin: Int
    /// The last timestamp id: the last id of the vocabulary.
    public let timestampEnd: Int
    public let maximumInitialTimestamp: Int

    /// `maximumInitialTimestampIndex` counts 20 ms steps after `<|0.00|>`;
    /// faster-whisper passes `round(max_initial_timestamp / 0.02)`.
    public init(specialTokens: WhisperSpecialTokens, vocabularySize: Int, maximumInitialTimestampIndex: Int) {
        endOfText = specialTokens.endOfText
        noTimestamps = specialTokens.noTimestamps
        timestampBegin = specialTokens.timestampBegin
        timestampEnd = vocabularySize - 1
        maximumInitialTimestamp = specialTokens.timestampBegin + maximumInitialTimestampIndex
    }

    public func process(_ logits: inout [Float], mask: inout TokenMask, step: DecodingStep) {
        mask.disable(noTimestamps)

        if step.index == 0 {
            mask.disable(0..<timestampBegin)
            if maximumInitialTimestamp < timestampEnd {
                mask.disable((maximumInitialTimestamp + 1)...timestampEnd)
            }
            return
        }

        guard let lastToken = step.generatedTokens.last else {
            return
        }
        let shouldCheckTimestampProbability: Bool
        if isTimestamp(lastToken) {
            let penultimateToken = step.generatedTokens.count >= 2 ? step.generatedTokens[step.generatedTokens.count - 2] : lastToken
            if isTimestamp(penultimateToken) {
                mask.disable(timestampBegin...timestampEnd)
                shouldCheckTimestampProbability = false
            } else {
                mask.disable(0..<endOfText)
                mask.disable(timestampBegin..<lastToken)
                shouldCheckTimestampProbability = true
            }
        } else {
            if let lastTimestamp = step.generatedTokens.last(where: isTimestamp) {
                mask.disable(timestampBegin...lastTimestamp)
            }
            shouldCheckTimestampProbability = true
        }

        if shouldCheckTimestampProbability && timestampsAreMoreLikelyThanText(logits, mask: mask) {
            mask.disable(0..<timestampBegin)
        }
    }

    private func isTimestamp(_ token: Int) -> Bool {
        token >= timestampBegin
    }

    /// logsumexp over timestamps > max log probability over text tokens.
    private func timestampsAreMoreLikelyThanText(_ logits: [Float], mask: TokenMask) -> Bool {
        var masked = logits
        mask.apply(to: &masked)
        let logProbabilities = LogSoftmax.apply(masked)
        let bestTextLogProbability = logProbabilities[0..<timestampBegin].max() ?? -.infinity
        let timestampLogProbability = LogSoftmax.logSumExp(logProbabilities[timestampBegin...timestampEnd])
        return timestampLogProbability > bestTextLogProbability
    }
}
