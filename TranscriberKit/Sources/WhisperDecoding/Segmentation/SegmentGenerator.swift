import AudioFeatures
import TranscriberCore

/// A decoded segment in seconds of the signal that was decoded.
public struct DecodedSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// As decoded, not stripped (Whisper text usually starts with a space).
    public var text: String
    public var tokens: [Int]
    public var temperature: Float
    public var averageLogProbability: Double
    public var compressionRatio: Double
    public var noSpeechProbability: Float
}

/// faster-whisper's `generate_segments` for ChickenRice's options (no
/// clip timestamps, no previous-text prompt, no word timestamps): decode 30 s
/// windows one after another, skip windows that are silence, split each
/// window's tokens into segments and seek to where the last complete one ended.
public struct SegmentGenerator: Sendable {
    private static let secondsPerFrame = 0.01

    public let backend: any WhisperBackend
    public let decoder: FallbackDecoder
    private let segmenter: TimestampSegmenter

    public init(backend: any WhisperBackend, decoder: FallbackDecoder) {
        self.backend = backend
        self.decoder = decoder
        self.segmenter = TimestampSegmenter(timestampBegin: decoder.windowDecoder.tokenizer.specialTokens.timestampBegin)
    }

    /// - Parameter features: the whole signal in faster-whisper framing (`.wholeSignal`).
    public func segments(
        for features: LogMelFeatures,
        generator: inout some RandomNumberGenerator
    ) throws -> [DecodedSegment] {
        let settings = decoder.windowDecoder.settings
        let tokenizer = decoder.windowDecoder.tokenizer
        // The extractor's last frame (from the 160 padding samples) is not content.
        let contentFrameCount = features.frameCount - 1
        var segments: [DecodedSegment] = []
        var seek = 0

        while seek < contentFrameCount {
            try Task.checkCancellation()
            let timeOffset = Double(seek) * Self.secondsPerFrame
            let segmentFrameCount = min(LogMelSpectrogram.windowFrameCount, contentFrameCount - seek)
            let segmentDuration = Double(segmentFrameCount) * Self.secondsPerFrame

            let window = features.paddedWindow(startingAt: seek, frameCount: segmentFrameCount)
            let result = try decoder.decode(try backend.makeSession(window: window), generator: &generator)
            let decoding = result.decoding

            let isSilence = Double(decoding.noSpeechProbability) > settings.noSpeechThreshold
                && !(decoding.averageLogProbability > settings.logProbabilityThreshold)
            if isSilence {
                seek += segmentFrameCount
                continue
            }

            let split = segmenter.split(
                tokens: decoding.tokens,
                timeOffset: timeOffset,
                segmentFrameCount: segmentFrameCount,
                segmentDuration: segmentDuration,
                seek: seek
            )
            for tokenSegment in split.segments {
                let text = tokenizer.decode(tokenSegment.tokens)
                if tokenSegment.start == tokenSegment.end || text.pythonStripped.isEmpty {
                    continue
                }
                segments.append(DecodedSegment(
                    start: tokenSegment.start,
                    end: tokenSegment.end,
                    text: text,
                    tokens: tokenSegment.tokens,
                    temperature: decoding.temperature,
                    averageLogProbability: decoding.averageLogProbability,
                    compressionRatio: result.compressionRatio,
                    noSpeechProbability: decoding.noSpeechProbability
                ))
            }
            // The timestamp rules make every window advance; guard against a
            // malformed result looping forever.
            seek = split.nextSeek > seek ? split.nextSeek : seek + segmentFrameCount
        }
        return segments
    }
}
