import Foundation
import Testing
@testable import WhisperDecoding

/// Expected values come from faster-whisper's Tokenizer on each model's
/// tokenizer.json (Tools/parity/make_tokenizer_fixture.py).
struct WhisperTokenizerTests {
    @Test(arguments: try TokenizerFixture.load().models)
    func specialTokensMatchFasterWhisper(_ model: TokenizerFixture.Model) throws {
        let tokens = try Self.tokenizer(for: model).specialTokens
        let expected = model.specials
        #expect(tokens.startOfTranscript == expected.sot)
        #expect(tokens.endOfText == expected.eot)
        #expect(tokens.language("ja") == expected.japanese)
        #expect(tokens.translate == expected.translate)
        #expect(tokens.transcribe == expected.transcribe)
        #expect(tokens.startOfPrevious == expected.sotPrev)
        #expect(tokens.startOfLanguageModel == expected.sotLm)
        #expect(tokens.noSpeech == expected.noSpeech)
        #expect(tokens.noTimestamps == expected.noTimestamps)
        #expect(tokens.timestampBegin == expected.timestampBegin)
    }

    @Test(arguments: try TokenizerFixture.load().models)
    func suppressedTokensMatchFasterWhisper(_ model: TokenizerFixture.Model) throws {
        let tokenizer = try Self.tokenizer(for: model)
        #expect(SuppressedTokens.nonSpeech == model.nonSpeechTokens)
        #expect(SuppressedTokens.fasterWhisperDefault(for: tokenizer.specialTokens) == model.suppressedTokens)
    }

    @Test(arguments: try TokenizerFixture.load().models)
    func decodesLikeTokenizers(_ model: TokenizerFixture.Model) throws {
        let tokenizer = try Self.tokenizer(for: model)
        for testCase in model.decodeCases {
            #expect(tokenizer.decode(testCase.tokens) == testCase.text, "\(testCase.tokens)")
        }
    }

    private static func tokenizer(for model: TokenizerFixture.Model) throws -> WhisperTokenizer {
        let url = try #require(Bundle.module.url(
            forResource: "\(model.name).tokenizer", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try WhisperTokenizer(contentsOf: url)
    }
}

struct TokenizerFixture: Decodable {
    struct Model: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let specials: Specials
        let nonSpeechTokens: [Int]
        let suppressedTokens: [Int]
        let decodeCases: [DecodeCase]

        var testDescription: String { name }
    }

    struct Specials: Decodable, Sendable {
        let sot, eot, japanese, translate, transcribe, sotPrev, sotLm, noSpeech, noTimestamps, timestampBegin: Int
    }

    struct DecodeCase: Decodable, Sendable {
        let tokens: [Int]
        let text: String
    }

    let models: [Model]

    static func load() throws -> TokenizerFixture {
        let url = try #require(Bundle.module.url(forResource: "tokenizer-cases", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TokenizerFixture.self, from: Data(contentsOf: url))
    }
}
