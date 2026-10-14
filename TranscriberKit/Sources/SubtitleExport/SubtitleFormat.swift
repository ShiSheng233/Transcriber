public enum SubtitleFormat: String, CaseIterable, Sendable, Codable {
    case srt
    case vtt
    case lrc
    case ass
    case txt

    public var fileExtension: String {
        rawValue
    }
}
