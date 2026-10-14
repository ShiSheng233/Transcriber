/// Special token ids, looked up by their text in `tokenizer.json` like
/// faster-whisper's `Tokenizer`. Large-v3 has one more language than large-v2,
/// so every id after the language tokens differs between them.
public struct WhisperSpecialTokens: Sendable, Equatable {
    public let startOfTranscript: Int
    public let endOfText: Int
    public let translate: Int
    public let transcribe: Int
    public let startOfPrevious: Int
    public let startOfLanguageModel: Int
    /// `<|nospeech|>` (large-v3) or `<|nocaptions|>` (earlier models).
    public let noSpeech: Int
    public let noTimestamps: Int
    /// `<|0.00|>`; each following id is 20 ms later.
    public let timestampBegin: Int
    private let languages: [String: Int]

    init(addedTokens: [String: Int]) throws(WhisperTokenizerError) {
        func id(_ text: String) throws(WhisperTokenizerError) -> Int {
            guard let id = addedTokens[text] else {
                throw .missingSpecialToken(text)
            }
            return id
        }
        startOfTranscript = try id("<|startoftranscript|>")
        endOfText = try id("<|endoftext|>")
        translate = try id("<|translate|>")
        transcribe = try id("<|transcribe|>")
        startOfPrevious = try id("<|startofprev|>")
        startOfLanguageModel = try id("<|startoflm|>")
        if let noSpeech = addedTokens["<|nospeech|>"] {
            self.noSpeech = noSpeech
        } else {
            self.noSpeech = try id("<|nocaptions|>")
        }
        noTimestamps = try id("<|notimestamps|>")
        timestampBegin = noTimestamps + 1
        // Language tokens sit between <|startoftranscript|> and <|translate|>.
        let languageRange = (startOfTranscript + 1)..<translate
        languages = addedTokens.filter { languageRange.contains($0.value) }
    }

    /// `<|ja|>` for "ja".
    public func language(_ code: String) -> Int? {
        languages["<|\(code)|>"]
    }

    public func isTimestamp(_ token: Int) -> Bool {
        token >= timestampBegin
    }
}
