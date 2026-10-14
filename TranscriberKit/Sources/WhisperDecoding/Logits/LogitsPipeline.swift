import TranscriberCore

/// Runs the processors of one step in CTranslate2's order and returns log
/// probabilities: processors, then the mask, then log-softmax.
public struct LogitsPipeline: Sendable {
    public let processors: [any LogitsProcessor]

    public init(processors: [any LogitsProcessor]) {
        self.processors = processors
    }

    /// The order `make_logits_processors` builds for faster-whisper's call:
    /// repetition penalty, suppressed tokens, suppress-at-begin, timestamp rules.
    public static func fasterWhisper(
        specialTokens: WhisperSpecialTokens,
        vocabularySize: Int,
        settings: DecodingSettings,
        spaceToken: Int
    ) -> LogitsPipeline {
        var processors: [any LogitsProcessor] = []
        if settings.repetitionPenalty != 1 {
            processors.append(RepetitionPenalty(penalty: settings.repetitionPenalty))
        }
        processors.append(SuppressTokens(tokens: SuppressedTokens.fasterWhisperDefault(for: specialTokens)))
        if settings.suppressesBlankStart {
            processors.append(SuppressTokensAtBegin(tokens: [spaceToken, specialTokens.endOfText]))
        }
        if settings.noRepeatNgramSize > 0 {
            processors.append(NoRepeatNgram(size: settings.noRepeatNgramSize))
        }
        if settings.usesTimestamps {
            processors.append(TimestampRules(
                specialTokens: specialTokens,
                vocabularySize: vocabularySize,
                maximumInitialTimestampIndex: settings.maximumInitialTimestampIndex
            ))
        } else {
            processors.append(SuppressTimestamps(specialTokens: specialTokens, vocabularySize: vocabularySize))
        }
        return LogitsPipeline(processors: processors)
    }

    public func logProbabilities(from logits: [Float], step: DecodingStep) -> [Float] {
        var processed = logits
        var mask = TokenMask()
        for processor in processors {
            processor.process(&processed, mask: &mask, step: step)
        }
        mask.apply(to: &processed)
        return LogSoftmax.apply(processed)
    }
}
