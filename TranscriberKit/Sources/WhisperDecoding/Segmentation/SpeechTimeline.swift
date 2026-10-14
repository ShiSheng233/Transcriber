import TranscriberCore

/// faster-whisper's VAD bookkeeping: `collect_chunks` joins the speech spans
/// into one signal, and `SpeechTimestampsMap` maps times in that signal back
/// to the original audio.
///
/// Spans may end past the audio (the VAD keeps its padded last window); like
/// NumPy slicing, the samples are clamped but the mapping uses the span as is.
public struct SpeechTimeline: Sendable {
    private static let decimalPlaces = 2

    /// Each span's end in the joined signal, in samples.
    private let chunkEndSamples: [Int]
    /// Silence removed before each span, in seconds.
    private let silenceBefore: [Double]

    public init(spans: [SpeechSpan]) {
        var chunkEndSamples: [Int] = []
        var silenceBefore: [Double] = []
        var previousEnd = 0
        var silentSamples = 0
        for span in spans {
            silentSamples += span.start.samples - previousEnd
            previousEnd = span.end.samples
            chunkEndSamples.append(span.end.samples - silentSamples)
            silenceBefore.append(Double(silentSamples) / Double(AudioTime.sampleRate))
        }
        self.chunkEndSamples = chunkEndSamples
        self.silenceBefore = silenceBefore
    }

    /// `collect_chunks` without a maximum duration: the speech samples back to back.
    public static func joinedSpeech(from samples: [Float], spans: [SpeechSpan]) -> [Float] {
        var joined: [Float] = []
        for span in spans {
            let start = min(max(span.start.samples, 0), samples.count)
            let end = min(max(span.end.samples, start), samples.count)
            joined.append(contentsOf: samples[start..<end])
        }
        return joined
    }

    /// `get_original_time`: adds the silence removed before the span the time
    /// falls in, rounded to 0.01 s like the original. An end time lying exactly
    /// on a span's end stays in that span.
    public func originalTime(_ time: Double, isEnd: Bool) -> Double {
        let spanIndex = spanIndex(containing: time, isEnd: isEnd)
        return (silenceBefore[spanIndex] + time).pythonRounded(toPlaces: Self.decimalPlaces)
    }

    private func spanIndex(containing time: Double, isEnd: Bool) -> Int {
        let sample = Int(time * Double(AudioTime.sampleRate))
        if isEnd, let exactEnd = chunkEndSamples.firstIndex(of: sample) {
            return exactEnd
        }
        // bisect.bisect (right): spans whose end is at or before the sample.
        let spansEndedBefore = chunkEndSamples.prefix { $0 <= sample }.count
        return min(spansEndedBefore, chunkEndSamples.count - 1)
    }
}
