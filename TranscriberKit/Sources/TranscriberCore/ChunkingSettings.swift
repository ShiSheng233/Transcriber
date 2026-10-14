/// How long audio is split into chunks before transcription (`SmartSplitOptions`).
///
/// Durations stay in seconds as `Double`, like the original: chunk boundaries
/// fall at gap midpoints and are only rounded to samples when audio is cut.
public struct ChunkingSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    public var targetChunkDurationSeconds: Double
    /// The last `splitWindowFactor` of each chunk is searched for a silence to cut at.
    public var splitWindowFactor: Double

    public init(isEnabled: Bool, targetChunkDurationSeconds: Double, splitWindowFactor: Double) {
        self.isEnabled = isEnabled
        self.targetChunkDurationSeconds = targetChunkDurationSeconds
        self.splitWindowFactor = splitWindowFactor
    }
}
