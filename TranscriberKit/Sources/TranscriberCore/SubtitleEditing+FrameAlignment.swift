extension SubtitleEditing {
    /// Moves the chosen lines' starts and ends (all lines for an empty
    /// `indices`) onto video frame boundaries without changing which frames
    /// they are shown on: a start goes to Aegisub's `TimeAtFrame(START)` of
    /// the first frame at or after it, an end to `TimeAtFrame(END)` of the
    /// last frame before it (ends are exclusive). The boundaries sit between
    /// frames on the centisecond grid, so any format's rounding keeps them on
    /// those frames. A line shown on no frame keeps zero length. The order
    /// does not change, since aligning never reorders two times.
    public static func alignedToFrames(_ indices: [Int], in lines: [TimedText], frames: VideoFrames) -> Outcome {
        let chosen = indices.isEmpty ? Array(lines.indices) : indices.filter(lines.indices.contains).sorted()
        var result = lines
        for index in chosen {
            result[index].start = frames.alignedTime(lines[index].start)
            result[index].end = max(frames.alignedTime(lines[index].end), result[index].start)
        }
        return Outcome(lines: result, selection: indices.isEmpty ? [] : chosen)
    }
}
