import Foundation

public enum MediaDecodingError: Error, Equatable {
    case openFailed(URL, FFmpegError)
    case noAudioStream(URL)
    case decoderUnavailable(codecName: String)
    case decoderSetupFailed(FFmpegError)
    case resamplerSetupFailed(FFmpegError)
    case decodingFailed(FFmpegError)
}
