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

    public init(
        dropsRepetitionLoops: Bool,
        dropsNonverbalLines: Bool,
        dropsHallucinatedPhrases: Bool,
        mergesRepeatedLines: Bool,
        dropsImplausibleReadingSpeed: Bool
    ) {
        self.dropsRepetitionLoops = dropsRepetitionLoops
        self.dropsNonverbalLines = dropsNonverbalLines
        self.dropsHallucinatedPhrases = dropsHallucinatedPhrases
        self.mergesRepeatedLines = mergesRepeatedLines
        self.dropsImplausibleReadingSpeed = dropsImplausibleReadingSpeed
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
            dropsImplausibleReadingSpeed: try container.decodeIfPresent(Bool.self, forKey: .dropsImplausibleReadingSpeed) ?? false
        )
    }
}
