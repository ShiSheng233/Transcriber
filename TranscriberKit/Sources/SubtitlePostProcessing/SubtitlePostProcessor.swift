import TranscriberCore

public enum SubtitlePostProcessor {
    /// Timeline, merge, timeline again: the order `infer.py` applies before
    /// writing subtitle files. The timeline cap uses the merge settings'
    /// maximum duration even when merging is disabled, as in the original.
    public static func process(_ segments: [TimedText], settings: MergeSettings) -> [TimedText] {
        let maximumDuration = settings.maximumSegmentDuration
        let ordered = SegmentTimeline.enforced(segments, maximumDuration: maximumDuration)
        let merged = SegmentMerger.merged(ordered, settings: settings)
        return SegmentTimeline.enforced(merged, maximumDuration: maximumDuration)
    }
}
