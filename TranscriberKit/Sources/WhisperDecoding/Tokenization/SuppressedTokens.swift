/// The tokens faster-whisper never generates with its default `suppress_tokens=[-1]`.
public enum SuppressedTokens {
    /// `Tokenizer.non_speech_tokens`: symbols that start speaker tags, sound
    /// annotations and music notes ("[", "(", "♪", ...). They come from BPE-encoding
    /// a fixed symbol list, which gives the same ids for every multilingual Whisper
    /// vocabulary (checked for both supported models in tests).
    static let nonSpeech: [Int] = [
        1, 2, 7, 8, 9, 10, 14, 25, 26, 27, 28, 29, 31, 58, 59, 60, 61, 62, 63, 90, 91, 92, 93, 359, 503, 522,
        542, 873, 893, 902, 918, 922, 931, 1350, 1853, 1982, 2460, 2627, 3246, 3253, 3268, 3536, 3846, 3961,
        4183, 4667, 6585, 6647, 7273, 9061, 9383, 10428, 10929, 11938, 12033, 12331, 12562, 13793, 14157,
        14635, 15265, 15618, 16553, 16604, 18362, 18956, 20075, 21675, 22520, 26130, 26161, 26435, 28279,
        29464, 31650, 32302, 32470, 36865, 42863, 47425, 49870, 50254,
    ]

    /// `get_suppressed_tokens(tokenizer, [-1])`: the non-speech tokens plus the
    /// task, start-of-* and no-speech tokens, sorted. Language tokens stay allowed.
    public static func fasterWhisperDefault(for specialTokens: WhisperSpecialTokens) -> [Int] {
        let specials = [
            specialTokens.transcribe,
            specialTokens.translate,
            specialTokens.startOfTranscript,
            specialTokens.startOfPrevious,
            specialTokens.startOfLanguageModel,
            specialTokens.noSpeech,
        ]
        return Set(nonSpeech + specials).sorted()
    }
}
