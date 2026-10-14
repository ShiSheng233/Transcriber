import AudioFeatures

/// A Whisper model runtime: encodes audio and computes decoder logits.
/// Everything else about decoding lives in `WhisperDecoding`, so each backend
/// behaves the same.
public protocol WhisperBackend: Sendable {
    var melBandCount: Int { get }

    /// Encodes the 3000 frames of `features` starting at `frameOffset`; frames
    /// past the end are zeros, like faster-whisper's `pad_or_trim`.
    func makeSession(features: LogMelFeatures, frameOffset: Int) throws -> any WhisperDecoderSession
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
