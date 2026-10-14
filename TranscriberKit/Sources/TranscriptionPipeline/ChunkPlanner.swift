import TranscriberCore

/// Port of `create_contiguous_chunks` in the original `infer.py`.
///
/// Splits audio into contiguous chunks of at most `maximumDurationSeconds`.
/// Each cut goes in the middle of the longest pause (> 0.1 s) between speech
/// spans inside the chunk's last `splitWindowFactor`, or at the maximum length
/// when there is none. Chunks cover all audio, speech or not.
public enum ChunkPlanner {
    private static let minimumGapSeconds = 0.1

    public static func contiguousChunks(
        speech spans: [SpeechSpan],
        totalDurationSeconds: Double,
        maximumDurationSeconds: Double,
        splitWindowFactor: Double
    ) -> [AudioChunk] {
        precondition(maximumDurationSeconds > 0, "maximum chunk duration must be positive")
        guard totalDurationSeconds > 0 else {
            return []
        }
        guard totalDurationSeconds > maximumDurationSeconds else {
            return [AudioChunk(index: 0, startSeconds: 0, endSeconds: totalDurationSeconds)]
        }

        let speech = speechInSeconds(spans)
        var chunks: [AudioChunk] = []
        var chunkStart = 0.0
        while chunkStart < totalDurationSeconds {
            let latestEnd = chunkStart + maximumDurationSeconds
            if latestEnd >= totalDurationSeconds {
                chunks.append(AudioChunk(index: chunks.count, startSeconds: chunkStart, endSeconds: totalDurationSeconds))
                break
            }

            let windowStart = chunkStart + maximumDurationSeconds * (1 - splitWindowFactor)
            let pauseMidpoint = midpointOfLongestPause(in: speech, from: windowStart, to: latestEnd)
            let chunkEnd = max(chunkStart, min(pauseMidpoint ?? latestEnd, latestEnd, totalDurationSeconds))
            chunks.append(AudioChunk(index: chunks.count, startSeconds: chunkStart, endSeconds: chunkEnd))
            chunkStart = chunkEnd
        }
        return chunks
    }

    /// The longest pause between consecutive spans that lies entirely within
    /// `windowStart...windowEnd`; the first one wins ties.
    private static func midpointOfLongestPause(
        in speech: [(start: Double, end: Double)],
        from windowStart: Double,
        to windowEnd: Double
    ) -> Double? {
        var bestMidpoint: Double?
        var bestDuration = 0.0
        for (previous, next) in zip(speech, speech.dropFirst()) {
            let pauseStart = previous.end
            let pauseEnd = next.start
            guard windowStart <= pauseStart, pauseEnd <= windowEnd else {
                continue
            }
            let duration = pauseEnd - pauseStart
            if duration > minimumGapSeconds, duration > bestDuration {
                bestDuration = duration
                bestMidpoint = pauseStart + duration / 2
            }
        }
        return bestMidpoint
    }

    /// Non-empty spans in seconds (`samples / 16000`), stably sorted by start.
    private static func speechInSeconds(_ spans: [SpeechSpan]) -> [(start: Double, end: Double)] {
        spans
            .filter { $0.end > $0.start }
            .map { (start: $0.start.seconds, end: $0.end.seconds) }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }
}
