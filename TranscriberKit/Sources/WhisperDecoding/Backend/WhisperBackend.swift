import AudioFeatures

/// A Whisper model runtime: encodes audio and computes decoder logits.
/// Everything else about decoding lives in `WhisperDecoding`, so each backend
/// behaves the same.
public protocol WhisperBackend: Sendable {
    var melBandCount: Int { get }

    /// Encodes one 30 s window: exactly `LogMelSpectrogram.windowFrameCount`
    /// frames, already padded (see `LogMelFeatures.paddedWindow`).
    func makeSession(window: LogMelFeatures) throws -> any WhisperDecoderSession
}

/// One encoded 30 s window and the decoder's key/value cache.
///
/// Not thread-safe: a session belongs to the task that decodes its window.
public protocol WhisperDecoderSession: AnyObject {
    /// Feeds `tokens` after the first `prefixLength` tokens already decoded
    /// (anything cached beyond them is discarded) and returns the logits that
    /// predict the token after the last one.
    func logits(appending tokens: [Int], afterPrefixOf prefixLength: Int) throws -> [Float]
}
