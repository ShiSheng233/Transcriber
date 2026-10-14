/// A run of tokens between timestamps, times in seconds of the decoded audio.
public struct TokenSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var tokens: [Int]
}

/// faster-whisper's `_split_segments_by_timestamps`: cuts a window's tokens
/// into segments at each pair of consecutive timestamps and decides where the
/// next window starts.
public struct TimestampSegmenter: Sendable {
    /// Seconds per timestamp step.
    static let timePrecision = 0.02
    /// Mel frames per timestamp step.
    static let framesPerTimestamp = 2

    public let timestampBegin: Int

    public init(timestampBegin: Int) {
        self.timestampBegin = timestampBegin
    }

    public struct Split: Sendable, Equatable {
        public var segments: [TokenSegment]
        /// Frame where the next window starts.
        public var nextSeek: Int
        public var endsWithSingleTimestamp: Bool
    }

    /// - Parameters:
    ///   - timeOffset: `seek * 0.01`, the window start in seconds.
    ///   - segmentFrameCount: real (unpadded) frames in the window.
    ///   - segmentDuration: `segmentFrameCount * 0.01`.
    public func split(tokens: [Int], timeOffset: Double, segmentFrameCount: Int, segmentDuration: Double, seek: Int) -> Split {
        let endsWithSingleTimestamp = tokens.count >= 2
            && tokens[tokens.count - 2] < timestampBegin && timestampBegin <= tokens[tokens.count - 1]
        let pairEnds = tokens.indices.dropFirst().filter { isTimestamp(tokens[$0]) && isTimestamp(tokens[$0 - 1]) }

        guard !pairEnds.isEmpty else {
            // No complete segment: the whole window is one segment ending at its
            // last timestamp (unless that is <|0.00|>) or at the window end.
            var duration = segmentDuration
            if let lastTimestamp = tokens.last(where: isTimestamp), lastTimestamp != timestampBegin {
                duration = Double(lastTimestamp - timestampBegin) * Self.timePrecision
            }
            let segment = TokenSegment(start: timeOffset, end: timeOffset + duration, tokens: tokens)
            return Split(segments: [segment], nextSeek: seek + segmentFrameCount, endsWithSingleTimestamp: endsWithSingleTimestamp)
        }

        var sliceEnds = pairEnds
        if endsWithSingleTimestamp {
            sliceEnds.append(tokens.count)
        }
        var segments: [TokenSegment] = []
        var sliceStart = 0
        for sliceEnd in sliceEnds {
            let sliced = Array(tokens[sliceStart..<sliceEnd])
            segments.append(TokenSegment(
                start: timeOffset + Double(sliced[0] - timestampBegin) * Self.timePrecision,
                end: timeOffset + Double(sliced[sliced.count - 1] - timestampBegin) * Self.timePrecision,
                tokens: sliced
            ))
            sliceStart = sliceEnd
        }

        let nextSeek: Int
        if endsWithSingleTimestamp {
            // Nothing is spoken after the last timestamp.
            nextSeek = seek + segmentFrameCount
        } else {
            // Drop the unfinished tail and decode again from the last complete timestamp.
            nextSeek = seek + (tokens[sliceStart - 1] - timestampBegin) * Self.framesPerTimestamp
        }
        return Split(segments: segments, nextSeek: nextSeek, endsWithSingleTimestamp: endsWithSingleTimestamp)
    }

    private func isTimestamp(_ token: Int) -> Bool {
        token >= timestampBegin
    }
}
