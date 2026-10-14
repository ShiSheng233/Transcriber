/// How neighboring segments are merged before export (`SegmentMergeOptions`).
public struct MergeSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    /// Segments further apart than this are never merged.
    public var maximumGap: AudioTime
    /// No merged segment may span longer than this. Also caps every segment's
    /// length when the timeline is enforced, even with merging disabled.
    public var maximumSegmentDuration: AudioTime

    public init(isEnabled: Bool, maximumGap: AudioTime, maximumSegmentDuration: AudioTime) {
        self.isEnabled = isEnabled
        self.maximumGap = maximumGap
        self.maximumSegmentDuration = maximumSegmentDuration
    }
}
