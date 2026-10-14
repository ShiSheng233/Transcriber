import TranscriberCore

/// faster-whisper's `generate_with_fallback`: decode at each temperature until
/// a result is neither repetitive (compression ratio) nor unlikely (average log
/// probability), unless the window looks like silence.
public struct FallbackDecoder {
    public let windowDecoder: WindowDecoder

    public init(windowDecoder: WindowDecoder) {
        self.windowDecoder = windowDecoder
    }

    public struct Result: Sendable, Equatable {
        public var decoding: WindowDecodingResult
        public var compressionRatio: Double
    }

    public func decode(
        _ session: any WhisperDecoderSession,
        generator: inout some RandomNumberGenerator
    ) throws -> Result {
        let settings = windowDecoder.settings
        var allResults: [Result] = []
        var nonRepetitiveResults: [Result] = []

        for temperature in settings.temperatures {
            let decoding = try windowDecoder.decode(session, temperature: temperature, generator: &generator)
            let text = windowDecoder.tokenizer.decode(decoding.tokens).pythonStripped
            let result = Result(decoding: decoding, compressionRatio: CompressionRatio.of(text))
            allResults.append(result)

            var needsFallback = false
            if result.compressionRatio > settings.compressionRatioThreshold {
                needsFallback = true
            } else {
                nonRepetitiveResults.append(result)
            }
            let isUnlikely = decoding.averageLogProbability < settings.logProbabilityThreshold
            if isUnlikely {
                needsFallback = true
            }
            if isUnlikely && Double(decoding.noSpeechProbability) > settings.noSpeechThreshold {
                needsFallback = false  // silence: no temperature will do better
            }
            if !needsFallback {
                return result
            }
        }

        // Every temperature failed: the most likely result, preferring
        // non-repetitive ones; the first wins ties, like Python's max().
        let candidates = nonRepetitiveResults.isEmpty ? allResults : nonRepetitiveResults
        var best = candidates[0]
        for candidate in candidates.dropFirst()
        where candidate.decoding.averageLogProbability > best.decoding.averageLogProbability {
            best = candidate
        }
        // faster-whisper reports the last temperature tried.
        best.decoding.temperature = settings.temperatures.last ?? best.decoding.temperature
        return best
    }
}
