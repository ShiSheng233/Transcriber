import Foundation
import Testing
import TranscriberCore
@testable import WhisperDecoding

/// Rules from CTranslate2 4.8.3 on a small vocabulary:
/// text 0...9, <|endoftext|> 10, specials 11...19, timestamps 20...29.
struct LogitsProcessorTests {
    static let specialTokens = try! WhisperSpecialTokens(addedTokens: [
        "<|endoftext|>": 10, "<|startoftranscript|>": 11, "<|ja|>": 12, "<|zh|>": 13,
        "<|translate|>": 14, "<|transcribe|>": 15, "<|startoflm|>": 16, "<|startofprev|>": 17,
        "<|nocaptions|>": 18, "<|notimestamps|>": 19,
    ])
    static let vocabularySize = 30
    static let endOfText = 10
    static let timestamps = 20...29

    private func allowedTokens(
        after generatedTokens: [Int],
        processor: some LogitsProcessor,
        logits: [Float] = Array(repeating: 0, count: vocabularySize)
    ) -> Set<Int> {
        var processed = logits
        var mask = TokenMask()
        processor.process(&processed, mask: &mask, step: DecodingStep(index: generatedTokens.count, generatedTokens: generatedTokens))
        mask.apply(to: &processed)
        return Set(processed.indices.filter { processed[$0] > -.infinity })
    }

    private func timestampRules(maximumInitialTimestampIndex: Int = 9) -> TimestampRules {
        TimestampRules(specialTokens: Self.specialTokens, vocabularySize: Self.vocabularySize,
                       maximumInitialTimestampIndex: maximumInitialTimestampIndex)
    }

    // MARK: Repetition penalty

    @Test func repetitionPenaltyScalesGeneratedTokensOnce() {
        var logits: [Float] = [2, -2, 2, 2]
        var mask = TokenMask()
        RepetitionPenalty(penalty: 2).process(&logits, mask: &mask, step: DecodingStep(index: 3, generatedTokens: [0, 1, 0]))
        #expect(logits == [1, -4, 2, 2])
    }

    // MARK: Suppression

    @Test func suppressAtBeginOnlyAffectsTheFirstStep() {
        let processor = SuppressTokensAtBegin(tokens: [3, Self.endOfText])
        #expect(!allowedTokens(after: [], processor: processor).contains(3))
        #expect(allowedTokens(after: [20], processor: processor).contains(3))
    }

    // MARK: Timestamp rules

    @Test func firstTokenIsATimestampNoLaterThanTheMaximumInitialTimestamp() {
        let allowed = allowedTokens(after: [], processor: timestampRules(maximumInitialTimestampIndex: 3))
        #expect(allowed == Set(20...23))
    }

    @Test func firstTimestampCountsAsAPairSoTextFollows() {
        let allowed = allowedTokens(after: [20], processor: timestampRules())
        #expect(allowed.isDisjoint(with: Self.timestamps))
        #expect(allowed.contains(0))
    }

    @Test func singleTimestampAfterTextIsFollowedByALaterTimestamp() {
        // Equal logits: the timestamps' total probability beats any single
        // non-timestamp token, so everything below <|0.00|> is forbidden too.
        let allowed = allowedTokens(after: [20, 1, 24], processor: timestampRules())
        #expect(allowed == Set(24...29))
    }

    @Test func singleTimestampAfterTextMayBeFollowedByEndOfText() {
        var logits = [Float](repeating: 0, count: Self.vocabularySize)
        logits[Self.endOfText] = 10
        let allowed = allowedTokens(after: [20, 1, 24], processor: timestampRules(), logits: logits)
        #expect(allowed.contains(Self.endOfText))
        #expect(allowed.isDisjoint(with: 0..<10))
        #expect(allowed.intersection(Self.timestamps) == Set(24...29))
    }

    @Test func timestampPairIsFollowedByText() {
        let allowed = allowedTokens(after: [20, 1, 24, 24], processor: timestampRules())
        #expect(allowed.isDisjoint(with: Self.timestamps))
    }

    @Test func timestampsAfterTextAreStrictlyLater() {
        let allowed = allowedTokens(after: [20, 1, 24, 24, 2], processor: timestampRules())
        #expect(allowed.intersection(Self.timestamps) == Set(25...29))
    }

    @Test func dominantTimestampProbabilityForbidsText() {
        var logits = [Float](repeating: -5, count: Self.vocabularySize)
        for token in Self.timestamps { logits[token] = 0 }
        let allowed = allowedTokens(after: [20, 1], processor: timestampRules(), logits: logits)
        #expect(allowed.isDisjoint(with: 0..<20))
        #expect(allowed.intersection(Self.timestamps) == Set(21...29))
    }

    @Test func noTimestampsTokenIsAlwaysForbidden() {
        #expect(!allowedTokens(after: [20, 1], processor: timestampRules()).contains(19))
    }

    // MARK: Pipeline and samplers

    @Test func pipelineReturnsNormalizedLogProbabilities() {
        let pipeline = LogitsPipeline(processors: [SuppressTokens(tokens: [0])])
        let logProbabilities = pipeline.logProbabilities(from: [5, 1, 1], step: DecodingStep(index: 0, generatedTokens: []))
        #expect(logProbabilities[0] == -.infinity)
        #expect(abs(logProbabilities[1] - log(0.5)) < 1e-6)
    }

    @Test func greedySamplerPicksTheLowestIdOnTies() {
        var generator = SystemRandomNumberGenerator()
        #expect(GreedySampler().sample(from: [-1, 0, 0], using: &generator) == 1)
    }

    @Test func temperatureSamplerNeverPicksMaskedTokens() {
        var generator = SystemRandomNumberGenerator()
        let sampler = TemperatureSampler(temperature: 1)
        for _ in 0..<200 {
            #expect(sampler.sample(from: [-.infinity, log(0.5), log(0.5)], using: &generator) != 0)
        }
    }
}
