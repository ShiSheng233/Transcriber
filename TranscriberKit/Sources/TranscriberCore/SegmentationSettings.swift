/// How speech is cut into the pieces the model decodes, and where subtitle
/// times come from.
public struct SegmentationSettings: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable {
        /// ChickenRice: chunks of up to 30 s; times from the model's timestamps.
        case chunks
        /// Text-only models (anime-whisper): nearby VAD spans are grouped into
        /// short pieces, each decoded alone; each piece is one subtitle timed
        /// by the VAD.
        case vadGroups = "vad_groups"
    }

    public var mode: Mode
    /// `vadGroups`: spans closer than this join a group…
    public var groupGap: AudioTime
    /// …while the group stays this short. Longer spans stay alone.
    public var groupMaximumDuration: AudioTime
    /// `vadGroups`: silence put before each piece; it helps the first word.
    public var leadingSilence: AudioTime

    public init(mode: Mode, groupGap: AudioTime, groupMaximumDuration: AudioTime, leadingSilence: AudioTime) {
        self.mode = mode
        self.groupGap = groupGap
        self.groupMaximumDuration = groupMaximumDuration
        self.leadingSilence = leadingSilence
    }

    /// ChickenRice's chunking; the group values are WhisperJAV's "balanced"
    /// ChronosJAV settings, used when a model switches to `vadGroups`.
    public static let chunks = SegmentationSettings(
        mode: .chunks,
        groupGap: AudioTime(milliseconds: 250),
        groupMaximumDuration: AudioTime(milliseconds: 2_500),
        leadingSilence: AudioTime(milliseconds: 200)
    )
}

/// Text fixes applied to every subtitle after transcription.
public struct TextCleanupSettings: Hashable, Sendable, Codable {
    /// Drop lines that are only an ellipsis and closing punctuation ("…", "…？").
    public var dropsEllipsisOnlyLines: Bool
    /// "ああああああ" → "ああ": a 2–20 character run repeated three or more times is kept once.
    public var collapsesRepeats: Bool
    /// End every line with "。" unless it already ends in punctuation.
    public var appendsPeriod: Bool

    public init(dropsEllipsisOnlyLines: Bool, collapsesRepeats: Bool, appendsPeriod: Bool) {
        self.dropsEllipsisOnlyLines = dropsEllipsisOnlyLines
        self.collapsesRepeats = collapsesRepeats
        self.appendsPeriod = appendsPeriod
    }

    public static let none = TextCleanupSettings(dropsEllipsisOnlyLines: false, collapsesRepeats: false, appendsPeriod: false)
}
