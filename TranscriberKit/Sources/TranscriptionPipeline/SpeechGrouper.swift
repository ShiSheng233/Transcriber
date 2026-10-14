import TranscriberCore

/// For `SegmentationSettings.Mode.vadGroups`: joins neighbouring speech spans
/// into short groups, after WhisperJAV's VAD-grouped framer. A span joins the
/// current group when the gap before it is shorter than `groupGap` and the
/// group stays within `groupMaximumDuration`; a longer span stays alone.
enum SpeechGrouper {
    static func groups(_ spans: [SpeechSpan], settings: SegmentationSettings) -> [AudioChunk] {
        var groups: [(start: AudioTime, end: AudioTime)] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = groups.last,
               span.start - last.end < settings.groupGap,
               max(span.end, last.end) - last.start <= settings.groupMaximumDuration {
                groups[groups.count - 1].end = max(span.end, last.end)
            } else {
                groups.append((span.start, span.end))
            }
        }
        return groups.enumerated().map { index, group in
            AudioChunk(index: index, startSeconds: group.start.seconds, endSeconds: group.end.seconds)
        }
    }
}
