/// Optional removal of likely-wrong subtitles, after WhisperJAV's sanitizer.
/// All off reproduces the original pipeline.
public struct SubtitleFilterSettings: Hashable, Sendable, Codable {
    /// Drop recognized text that is still repetitive (compression ratio over
    /// the model's threshold) after every temperature: faster-whisper keeps
    /// such text when every temperature fails, which is where loops come from.
    public var dropsRepetitionLoops: Bool
    /// Drop short lines that are only breathing or moaning sounds, music
    /// notes or an ellipsis.
    public var dropsNonverbalLines: Bool
    /// Drop video outros and subtitle credits Whisper invents over silence
    /// ("ご視聴ありがとうございました", "字幕由…提供").
    public var dropsHallucinatedPhrases: Bool
    /// Merge three or more identical lines in a row into one.
    public var mergesRepeatedLines: Bool
    /// Drop lines too fast to read or short lines stretched too long, and
    /// lines with no letters or digits.
    public var dropsImplausibleReadingSpeed: Bool
    /// Even out widths, ellipses and Japanese punctuation, without NFKC.
    public var normalizesText: Bool
    /// "ああああ" → "ああ", "ダメダメダメダメ" → "ダメダメ".
    public var shortensStretchedSounds: Bool
    /// Cut a line that loops to two copies and "…", instead of dropping its window.
    public var repairsLoopingLines: Bool
    /// Drop lines that are only "えーと", "あの" and the like.
    public var dropsFillerLines: Bool
    /// At least 5/6 s and at most 7 s on screen, small gaps closed.
    public var fixesTiming: Bool

    public init(
        dropsRepetitionLoops: Bool,
        dropsNonverbalLines: Bool,
        dropsHallucinatedPhrases: Bool,
        mergesRepeatedLines: Bool,
        dropsImplausibleReadingSpeed: Bool,
        normalizesText: Bool = false,
        shortensStretchedSounds: Bool = false,
        repairsLoopingLines: Bool = false,
        dropsFillerLines: Bool = false,
        fixesTiming: Bool = false
    ) {
        self.dropsRepetitionLoops = dropsRepetitionLoops
        self.dropsNonverbalLines = dropsNonverbalLines
        self.dropsHallucinatedPhrases = dropsHallucinatedPhrases
        self.mergesRepeatedLines = mergesRepeatedLines
        self.dropsImplausibleReadingSpeed = dropsImplausibleReadingSpeed
        self.normalizesText = normalizesText
        self.shortensStretchedSounds = shortensStretchedSounds
        self.repairsLoopingLines = repairsLoopingLines
        self.dropsFillerLines = dropsFillerLines
        self.fixesTiming = fixesTiming
    }

    public static let none = SubtitleFilterSettings(
        dropsRepetitionLoops: false,
        dropsNonverbalLines: false,
        dropsHallucinatedPhrases: false,
        mergesRepeatedLines: false,
        dropsImplausibleReadingSpeed: false
    )
}

extension SubtitleFilterSettings {
    /// Settings saved before a field existed decode with that field off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dropsRepetitionLoops: try container.decodeIfPresent(Bool.self, forKey: .dropsRepetitionLoops) ?? false,
            dropsNonverbalLines: try container.decodeIfPresent(Bool.self, forKey: .dropsNonverbalLines) ?? false,
            dropsHallucinatedPhrases: try container.decodeIfPresent(Bool.self, forKey: .dropsHallucinatedPhrases) ?? false,
            mergesRepeatedLines: try container.decodeIfPresent(Bool.self, forKey: .mergesRepeatedLines) ?? false,
            dropsImplausibleReadingSpeed: try container.decodeIfPresent(Bool.self, forKey: .dropsImplausibleReadingSpeed) ?? false,
            normalizesText: try container.decodeIfPresent(Bool.self, forKey: .normalizesText) ?? false,
            shortensStretchedSounds: try container.decodeIfPresent(Bool.self, forKey: .shortensStretchedSounds) ?? false,
            repairsLoopingLines: try container.decodeIfPresent(Bool.self, forKey: .repairsLoopingLines) ?? false,
            dropsFillerLines: try container.decodeIfPresent(Bool.self, forKey: .dropsFillerLines) ?? false,
            fixesTiming: try container.decodeIfPresent(Bool.self, forKey: .fixesTiming) ?? false
        )
    }
}
