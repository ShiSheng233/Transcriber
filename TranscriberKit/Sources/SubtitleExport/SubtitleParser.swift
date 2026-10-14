import Foundation
import TranscriberCore

public enum SubtitleParserError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadable
    case noCues

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fileExtension): "Subtitles of type .\(fileExtension) cannot be read; use SRT or VTT."
        case .unreadable: "The subtitle file is not UTF-8 or UTF-16 text."
        case .noCues: "The subtitle file contains no subtitles."
        }
    }
}

/// Reads SRT and WebVTT files into timed lines, for translating existing
/// subtitles. Cue numbers, VTT headers, notes and cue settings are skipped;
/// a cue's lines are kept joined by "\n".
public enum SubtitleParser {
    public static let fileExtensions: Set<String> = ["srt", "vtt"]

    public static func parse(fileAt url: URL) throws -> [TimedText] {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtensions.contains(fileExtension) else {
            throw SubtitleParserError.unsupportedFormat(fileExtension)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw SubtitleParserError.unreadable
        }
        let cues = parse(text)
        guard !cues.isEmpty else {
            throw SubtitleParserError.noCues
        }
        return cues
    }

    /// SRT and VTT share the cue shape: an optional identifier line, a
    /// "start --> end" line, then text up to a blank line.
    public static func parse(_ text: String) -> [TimedText] {
        let lines = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [TimedText] = []
        var index = 0
        while index < lines.count {
            guard let (start, end) = timing(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var textLines: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            let cueText = textLines.joined(separator: "\n")
            if !cueText.isEmpty, end > start {
                cues.append(TimedText(start: start, end: end, text: cueText))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,500 --> 00:01:04,000" (SRT) or "01:02.500 --> 01:04.000 align:start" (VTT).
    private static func timing(_ line: String) -> (AudioTime, AudioTime)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = time(parts[0].trimmingCharacters(in: .whitespaces)),
              let endText = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let end = time(String(endText)) else {
            return nil
        }
        return (start, end)
    }

    /// "hh:mm:ss,mmm", "hh:mm:ss.mmm" or "mm:ss.mmm".
    private static func time(_ text: String) -> AudioTime? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":")
        guard (2...3).contains(fields.count) else {
            return nil
        }
        let numbers = fields.compactMap { Double($0) }
        guard numbers.count == fields.count else {
            return nil
        }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return AudioTime(milliseconds: Int((seconds * 1_000).rounded()))
    }
}
