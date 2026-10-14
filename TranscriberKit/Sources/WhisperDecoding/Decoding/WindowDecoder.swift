import Foundation
import TranscriberCore

/// One decoding attempt for a window at one temperature, as CTranslate2's
/// `WhisperReplica::generate` returns it to faster-whisper.
public struct WindowDecodingResult: Sendable, Equatable {
    /// Generated tokens without `<|endoftext|>`.
    public var tokens: [Int]
    /// Sum of the chosen tokens' untempered log probabilities, `<|endoftext|>` included.
    public var sumLogProbability: Float
    /// P(`<|nospeech|>`) right after `<|startoftranscript|>`.
    public var noSpeechProbability: Float
    public var temperature: Float

    /// faster-whisper's `avg_logprob`: the sum over `len(tokens) + 1`.
    public var averageLogProbability: Double {
        Double(sumLogProbability) / Double(tokens.count + 1)
    }
}

/// Generates tokens for one window: prompt `<|sot|><|lang|><|task|>`, then up
/// to `maximumGeneratedTokenCount` steps through the logits pipeline.
public struct WindowDecoder: Sendable {
    public let tokenizer: WhisperTokenizer
    public let settings: DecodingSettings
    private let pipeline: LogitsPipeline

    public init(tokenizer: WhisperTokenizer, settings: DecodingSettings) {
        self.tokenizer = tokenizer
        self.settings = settings
        self.pipeline = .fasterWhisper(
            specialTokens: tokenizer.specialTokens,
            vocabularySize: tokenizer.vocabularySize,
            settings: settings,
            spaceToken: tokenizer.spaceToken
        )
    }

    /// Greedy at temperature 0; otherwise `bestOf` sampled hypotheses, keeping
    /// the one with the best length-normalized score (CTranslate2 `sort_hypotheses`).
    public func decode(
        _ session: any WhisperDecoderSession,
        temperature: Float,
        generator: inout some RandomNumberGenerator
    ) throws -> WindowDecodingResult {
        let specialTokens = tokenizer.specialTokens
        guard let language = specialTokens.language(settings.languageCode) else {
            throw WindowDecoderError.unknownLanguage(settings.languageCode)
        }
        let task = settings.task == .translate ? specialTokens.translate : specialTokens.transcribe

        let startLogits = try session.logits(appending: [specialTokens.startOfTranscript], afterPrefixOf: 0)
        let noSpeechProbability = Self.probability(of: specialTokens.noSpeech, in: startLogits)
        let firstStepLogits = try session.logits(appending: [language, task], afterPrefixOf: 1)
        let promptLength = 3

        let sampler: any TokenSampler = temperature > 0 ? TemperatureSampler(temperature: temperature) : GreedySampler()
        let hypothesisCount = temperature > 0 ? settings.bestOf : 1
        var best = try generate(session, firstStepLogits: firstStepLogits, promptLength: promptLength, sampler: sampler, generator: &generator)
        for _ in 1..<hypothesisCount {
            let hypothesis = try generate(session, firstStepLogits: firstStepLogits, promptLength: promptLength, sampler: sampler, generator: &generator)
            if hypothesis.normalizedScore > best.normalizedScore {
                best = hypothesis
            }
        }

        return WindowDecodingResult(
            tokens: best.tokens,
            sumLogProbability: best.sumLogProbability,
            noSpeechProbability: noSpeechProbability,
            temperature: temperature
        )
    }

    private func generate(
        _ session: any WhisperDecoderSession,
        firstStepLogits: [Float],
        promptLength: Int,
        sampler: any TokenSampler,
        generator: inout some RandomNumberGenerator
    ) throws -> Hypothesis {
        var tokens: [Int] = []
        var sumLogProbability: Float = 0
        var logits = firstStepLogits
        for stepIndex in 0..<settings.maximumGeneratedTokenCount {
            let logProbabilities = pipeline.logProbabilities(from: logits, step: DecodingStep(index: stepIndex, generatedTokens: tokens))
            let token = sampler.sample(from: logProbabilities, using: &generator)
            sumLogProbability += logProbabilities[token]
            if token == tokenizer.specialTokens.endOfText {
                break
            }
            tokens.append(token)
            let isLastStep = stepIndex + 1 == settings.maximumGeneratedTokenCount
            if !isLastStep {
                logits = try session.logits(appending: [token], afterPrefixOf: promptLength + tokens.count - 1)
            }
        }
        return Hypothesis(tokens: tokens, sumLogProbability: sumLogProbability)
    }

    private static func probability(of token: Int, in logits: [Float]) -> Float {
        exp(LogSoftmax.apply(logits)[token])
    }

    private struct Hypothesis {
        let tokens: [Int]
        let sumLogProbability: Float

        /// `finalize_hypothesis_score` with length penalty 1.
        var normalizedScore: Float {
            sumLogProbability / Float(max(tokens.count, 1))
        }
    }
}

public enum WindowDecoderError: Error, Equatable {
    case unknownLanguage(String)
}
