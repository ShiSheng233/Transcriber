import Foundation

public enum WhisperTokenizerError: Error, Equatable {
    case unreadableFile(URL)
    case missingSpecialToken(String)
    case unknownByteCharacter(Character)
}
