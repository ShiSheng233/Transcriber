import Foundation
import Testing
import TranscriberCore
@testable import WhisperDecoding

/// Drives WindowDecoder with a scripted session: each call returns logits that
/// strongly prefer the next scripted token, and records what was fed.
final class ScriptedSession: WhisperDecoderSession {
    private let vocabularySize: Int
    private var script: [Int]
    private let noSpeechToken: Int
    private let noSpeechLogit: Float
    private(set) var calls: [(tokens: [Int], prefixLength: Int)] = []

    init(vocabularySize: Int, script: [Int], noSpeechToken: Int, noSpeechLogit: Float = 0) {
        self.vocabularySize = vocabularySize
        self.script = script
        self.noSpeechToken = noSpeechToken
        self.noSpeechLogit = noSpeechLogit
    }

    func logits(appending tokens: [Int], afterPrefixOf prefixLength: Int) throws -> [Float] {
        calls.append((tokens, prefixLength))
        var logits = [Float](repeating: 0, count: vocabularySize)
        if prefixLength == 0 {
            logits[noSpeechToken] = noSpeechLogit
            return logits
        }
        if !script.isEmpty {
            logits[script.removeFirst()] = 50
        }
        return logits
    }
}

struct WindowDecoderTests {
    private let tokenizer: WhisperTokenizer
    private var specials: WhisperSpecialTokens { tokenizer.specialTokens }

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "chickenrice-v0.2.tokenizer", withExtension: "json", subdirectory: "Fixtures"))
        tokenizer = try WhisperTokenizer(contentsOf: url)
    }

    private func decoder(maximumTokens: Int = 224) -> WindowDecoder {
        var settings = ChickenRiceDefaults.decoding(task: .translate)
        settings.maximumGeneratedTokenCount = maximumTokens
        return WindowDecoder(tokenizer: tokenizer, settings: settings)
    }

    @Test func feedsPromptThenEachTokenAtTheRightPosition() throws {
        let timestamp = specials.timestampBegin
        let script = [timestamp, 1000, 1001, timestamp + 50, specials.endOfText]
        let session = ScriptedSession(vocabularySize: tokenizer.vocabularySize, script: script, noSpeechToken: specials.noSpeech)
        var generator = SystemRandomNumberGenerator()

        let result = try decoder().decode(session, temperature: 0, generator: &generator)

        #expect(result.tokens == [timestamp, 1000, 1001, timestamp + 50])
        #expect(session.calls.map(\.tokens) == [
            [specials.startOfTranscript], [specials.language("ja")!, specials.translate],
            [timestamp], [1000], [1001], [timestamp + 50],
        ])
        #expect(session.calls.map(\.prefixLength) == [0, 1, 3, 4, 5, 6])
        // EOT's log probability is part of the sum: five steps, each near-certain.
        #expect(result.sumLogProbability <= 0 && result.sumLogProbability > -0.01)
        #expect(result.averageLogProbability == Double(result.sumLogProbability) / 5)
    }

    @Test func stopsAtTheMaximumTokenCountWithoutEndOfText() throws {
        let timestamp = specials.timestampBegin
        let session = ScriptedSession(vocabularySize: tokenizer.vocabularySize, script: [timestamp] + Array(repeating: 1000, count: 10), noSpeechToken: specials.noSpeech)
        var generator = SystemRandomNumberGenerator()

        let result = try decoder(maximumTokens: 4).decode(session, temperature: 0, generator: &generator)

        #expect(result.tokens.count == 4)
        // No logits are requested after the last allowed token.
        #expect(session.calls.count == 2 + 3)
    }

    @Test func noSpeechProbabilityComesFromTheStartOfTranscriptPosition() throws {
        let session = ScriptedSession(
            vocabularySize: tokenizer.vocabularySize,
            script: [specials.timestampBegin, specials.endOfText],
            noSpeechToken: specials.noSpeech,
            noSpeechLogit: 30
        )
        var generator = SystemRandomNumberGenerator()
        let result = try decoder().decode(session, temperature: 0, generator: &generator)
        #expect(result.noSpeechProbability > 0.99)
    }

    @Test func compressionRatioMatchesPythonZlib() {
        // len("こんにちは" * 3 in UTF-8) = 45, zlib.compress -> 27 bytes.
        #expect(CompressionRatio.of("こんにちはこんにちはこんにちは") == 45.0 / 27.0)
    }
}
