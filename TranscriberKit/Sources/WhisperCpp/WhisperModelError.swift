import Foundation

public enum WhisperModelError: Error, Equatable {
    case fileNotFound(URL)
    case coreMLEncoderNotFound(URL)
    case loadFailed(URL)
}
